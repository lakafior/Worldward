/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS)

    import Foundation
    import Network

    /// A Model Context Protocol server, speaking JSON-RPC over HTTP on loopback.
    ///
    /// This is the one place Worldward listens for anything. It exists so an
    /// assistant running on this Mac can *use* the app — read the traveller's
    /// countries and trips, and (when allowed) plan a journey into it — without the
    /// app itself ever reaching out. Nothing here dials out, and nothing is sent
    /// anywhere: a client connects in, or nothing happens at all.
    ///
    /// Everything is off unless the user turns it on. Three things then keep it
    /// honest, and all three are deliberate:
    ///
    ///  • **Loopback only.** `requiredLocalEndpoint` pins the socket to 127.0.0.1,
    ///    so it isn't reachable from the network however the Mac is configured.
    ///  • **A bearer token.** Generated on first use, compared in constant time.
    ///  • **An `Origin` check.** A web page can reach 127.0.0.1 from the browser
    ///    the user already has open; refusing non-local origins is what stops a
    ///    DNS-rebinding page from driving the app. The MCP spec requires this of
    ///    local HTTP servers, and it is the attack that actually applies here.
    ///
    /// macOS only, on purpose: iOS can't keep a listener alive in the background,
    /// and there's no client there to talk to it.
    @MainActor
    @Observable
    final class MCPServer {
        static let shared = MCPServer()

        /// Whether the user has switched the server on. Off by default — this is
        /// the whole opt-in.
        static let enabledKey = "mcpServerEnabled"
        /// Whether tools that change data may run. Read tools always may.
        static let writesAllowedKey = "mcpWritesAllowed"
        /// Whether the destructive tools may run. Separate from writes because
        /// there is no UndoManager in this app — deletes are the only calls
        /// nothing can walk back.
        static let deletionsAllowedKey = "mcpDeletionsAllowed"
        /// Whether contacts, attachment metadata and the traveller's profile are
        /// disclosed. Off by default: these are phone numbers, document names and
        /// a gender-derived hint, none of which a trip-planning conversation needs.
        static let personalAllowedKey = "mcpPersonalAllowed"
        static let portKey = "mcpServerPort"
        /// Read back by `MCPStdioBridge`, which runs as this same executable and so
        /// shares these preferences — which is how a client config file ends up
        /// carrying no credential at all.
        static let tokenKey = "mcpServerToken"

        static let defaultPort = 8787

        /// The protocol revision spoken when a client doesn't ask for one.
        private static let defaultProtocolVersion = "2025-06-18"

        enum State: Equatable {
            case stopped
            case running(port: UInt16)
            /// Carries a sentence fit to put in front of the user.
            case failed(String)

            var isRunning: Bool {
                if case .running = self { true } else { false }
            }
        }

        private(set) var state: State = .stopped
        private var listener: NWListener?

        private init() {}

        // MARK: - Lifecycle

        /// Starts or stops the listener to match the stored preference. Called at
        /// launch and whenever the setting changes; costs one `UserDefaults` read
        /// when the feature is off, which is the common case.
        func applyPreference() {
            UserDefaults.standard.bool(forKey: Self.enabledKey) ? start() : stop()
        }

        /// The configured port, falling back to the default when unset or nonsense.
        /// `integer(forKey:)` rather than `object(forKey:) as? Int` on purpose: it
        /// coerces a value stored as a string (which is how a preference set from
        /// outside the app arrives) instead of silently returning the default.
        private static var configuredPort: Int {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            return (1...65535).contains(stored) ? stored : defaultPort
        }

        func start() {
            stop()
            let port = UInt16(Self.configuredPort)
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                state = .failed(String(localized: "Port \(Int(port)) isn't valid."))
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Binding the local endpoint is what confines the socket to loopback.
            // Passing a port to `NWListener(using:on:)` instead would bind every
            // interface, which is precisely what must not happen here.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)

            do {
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { newState in
                    MainActor.assumeIsolated {
                        switch newState {
                        case .ready:
                            self.state = .running(port: port)
                        case .failed(let error), .waiting(let error):
                            // "Address already in use" is by far the likeliest, and
                            // the user can act on it — so say which port.
                            self.state = .failed(
                                String(
                                    localized:
                                        "Couldn't listen on port \(Int(port)): \(error.localizedDescription)"
                                ))
                            self.stop()
                        case .cancelled:
                            if case .failed = self.state {} else { self.state = .stopped }
                        default:
                            break
                        }
                    }
                }
                listener.newConnectionHandler = { connection in
                    MainActor.assumeIsolated { self.accept(connection) }
                }
                listener.start(queue: .main)
                self.listener = listener
                // Touch the token so it exists on disk before any bridge process
                // goes looking for it.
                _ = token
            } catch {
                state = .failed(
                    String(localized: "Couldn't start the server: \(error.localizedDescription)"))
            }
        }

        func stop() {
            listener?.cancel()
            listener = nil
            if case .failed = state {} else { state = .stopped }
        }

        // MARK: - Token

        /// The bearer token clients must present, generated on first read.
        var token: String {
            if let existing = UserDefaults.standard.string(forKey: Self.tokenKey),
                !existing.isEmpty
            {
                return existing
            }
            let fresh = Self.makeToken()
            UserDefaults.standard.set(fresh, forKey: Self.tokenKey)
            return fresh
        }

        /// Replaces the token, cutting off every client configured with the old
        /// one. The user's way to revoke access without turning the server off.
        ///
        /// Clients need no re-configuring afterwards: they launch the bridge, which
        /// reads the new token from these same preferences. That's the quiet benefit
        /// of never putting it in their config files to begin with.
        func regenerateToken() {
            UserDefaults.standard.set(Self.makeToken(), forKey: Self.tokenKey)
        }

        private static func makeToken() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            // The system CSPRNG; `SystemRandomNumberGenerator` is the same source
            // without pulling in Security just for `SecRandomCopyBytes`.
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        /// Absolute path to this executable — what a client is told to launch, with
        /// `MCPStdioBridge.launchFlag`, to get a bridge. Taken from the running
        /// bundle rather than hard-coded, so it's correct whether the app lives in
        /// /Applications, in a DerivedData build, or anywhere else.
        var bridgePath: String {
            Bundle.main.executableURL?.path
                ?? "/Applications/Worldward.app/Contents/MacOS/Worldward"
        }

        /// The command that registers this server with Claude Code, ready to paste.
        var setupCommand: String {
            "claude mcp add worldward -- \"\(bridgePath)\" \(MCPStdioBridge.launchFlag)"
        }

        /// The JSON config snippet that registers this server with a
        /// JSON-configured client, ready to paste into that client's config file.
        ///
        /// Every client is given the same thing: launch the bridge. Handing them
        /// the HTTP endpoint directly doesn't work — Claude Desktop's config schema
        /// takes stdio servers only and silently skips anything else — and the
        /// bridge reads the port and token from the shared container, so none of
        /// these snippets carries a credential at all.
        func setupJSON(for client: MCPClient) -> String {
            let entry: [String: Any] = [
                "command": bridgePath, "args": [MCPStdioBridge.launchFlag],
            ]
            let root: [String: Any] =
                switch client {
                case .claudeDesktop, .cursor:
                    ["mcpServers": ["worldward": entry]]
                case .vsCode:
                    // VS Code's `.vscode/mcp.json` uses `servers`, not `mcpServers`,
                    // and wants the transport named even for a launched process.
                    ["servers": ["worldward": entry.merging(["type": "stdio"]) { a, _ in a }]]
                }
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: root,
                    // Without this, every "/" in the URL is written "\/" — valid
                    // JSON that parses identically, but it reads like a mistake to
                    // anyone pasting it into a config file by hand.
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                let json = String(data: data, encoding: .utf8)
            else {
                assertionFailure("The client config is a static dictionary — serialization cannot fail")
                return ""
            }
            return json
        }

        /// The port a client should connect to: the one actually listening when
        /// it is, otherwise the configured one — a snippet copied before the
        /// server restarts shouldn't point at a stale port.
        private var currentPort: Int {
            if case .running(let running) = state { Int(running) } else { Self.configuredPort }
        }

        // MARK: - Connections

        private func accept(_ connection: NWConnection) {
            connection.start(queue: .main)
            receive(on: connection, buffer: Data())
        }

        /// Reads until a whole HTTP request has arrived, then answers it. Requests
        /// here are a few kilobytes at most; the cap is a guard against a client
        /// that never stops talking, not a tuning parameter.
        private func receive(on connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                chunk, _, isComplete, error in
                MainActor.assumeIsolated {
                    var buffer = buffer
                    if let chunk { buffer.append(chunk) }

                    guard buffer.count <= 4 * 1024 * 1024 else {
                        self.send(.status(413, "Payload Too Large"), on: connection)
                        return
                    }
                    switch HTTPRequest.parse(buffer) {
                    case .complete(let request):
                        self.send(self.respond(to: request), on: connection)
                    case .invalid:
                        self.send(.status(400, "Bad Request"), on: connection)
                    case .incomplete:
                        if isComplete || error != nil {
                            connection.cancel()
                        } else {
                            self.receive(on: connection, buffer: buffer)
                        }
                    }
                }
            }
        }

        private func send(_ response: HTTPResponse, on connection: NWConnection) {
            connection.send(
                content: response.serialized,
                completion: .contentProcessed { _ in connection.cancel() })
        }

        // MARK: - HTTP

        private func respond(to request: HTTPRequest) -> HTTPResponse {
            // A browser page can reach loopback, so a web origin naming somewhere
            // other than this machine is refused before anything else happens.
            if let origin = request.headers["origin"], !Self.isAllowedOrigin(origin) {
                return .status(403, "Forbidden")
            }
            guard Self.constantTimeEquals(request.bearerToken ?? "", token) else {
                return HTTPResponse(
                    status: 401, reason: "Unauthorized",
                    headers: ["WWW-Authenticate": "Bearer"])
            }
            // No SSE stream and no sessions to tear down: this server only ever
            // answers, so GET and DELETE have nothing to do. The spec allows
            // saying so.
            guard request.method == "POST" else {
                return HTTPResponse(
                    status: 405, reason: "Method Not Allowed", headers: ["Allow": "POST"])
            }

            guard
                let message = try? JSONSerialization.jsonObject(with: request.body),
                let object = message as? [String: Any]
            else {
                // Batches were dropped from MCP, so an array lands here too.
                return .json(Self.errorEnvelope(id: nil, code: -32700, message: "Parse error"))
            }
            guard let method = object["method"] as? String else {
                return .json(Self.errorEnvelope(id: nil, code: -32600, message: "Invalid request"))
            }

            // No "id" means a notification: acknowledged, never answered.
            guard let id = object["id"], !(id is NSNull) else {
                return .status(202, "Accepted")
            }

            let params = object["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                return .json(Self.envelope(id: id, result: Self.initializeResult(params)))
            case "ping":
                return .json(Self.envelope(id: id, result: [:] as [String: Any]))
            case "tools/list":
                return .json(Self.envelope(id: id, result: Self.toolsListResult()))
            case "tools/call":
                return .json(Self.envelope(id: id, result: Self.toolsCallResult(params)))
            default:
                return .json(
                    Self.errorEnvelope(
                        id: id, code: -32601, message: "Method not found: \(method)"))
            }
        }

        /// Whether an `Origin` is one a *web page* could have. Only those are
        /// refused, and only when the host isn't local.
        ///
        /// The attack this guards against is DNS rebinding: a page served from
        /// `evil.com`, whose name now resolves to 127.0.0.1, posting here. That
        /// always arrives with an `http`/`https` origin naming the attacker's host,
        /// so screening those covers it.
        ///
        /// Anything else is allowed through, because native clients are not
        /// browsers and don't follow browser rules: an Electron app sends
        /// `app://…`, a local file page sends `null`, a plain CLI sends nothing at
        /// all. Rejecting those bought no safety and locked out real clients —
        /// Claude Desktop among them. The token remains the actual gate, and no
        /// browser can attach an `Authorization` header cross-origin without a
        /// CORS preflight this server never approves.
        private static func isAllowedOrigin(_ origin: String) -> Bool {
            guard let components = URLComponents(string: origin),
                let scheme = components.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return true }
            return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host ?? "")
        }

        /// Compares without leaking how much of the token matched through timing.
        private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
            let left = Array(lhs.utf8)
            let right = Array(rhs.utf8)
            guard left.count == right.count else { return false }
            var difference: UInt8 = 0
            for index in left.indices { difference |= left[index] ^ right[index] }
            return difference == 0
        }

        // MARK: - MCP methods

        private static func initializeResult(_ params: [String: Any]) -> [String: Any] {
            // Echo the revision the client asked for when it looks like one: these
            // four methods have been stable across revisions, and agreeing with the
            // client beats refusing it over a date.
            let requested = params["protocolVersion"] as? String
            let version =
                (requested?.count == 10 && requested?.first == "2")
                ? requested! : defaultProtocolVersion

            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "worldward",
                    "title": "Worldward",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "1.0",
                ],
                "instructions": """
                    Worldward is the user's personal travel tracker on this Mac: the countries \
                    they've been to, and the trips they're planning. All of it is local — \
                    nothing here searches the web or books anything.

                    Reading: get_stats and list_countries for where they've been, list_trips and \
                    get_trip for what's planned. get_country_facts has offline practicalities \
                    (currency, plugs, driving side, emergency number).

                    Planning a trip: use plan_trip. It writes the itinerary, packing list and \
                    notes in one atomic call, and marks the countries as planned so they light \
                    up on the map. Call list_containers and list_packing_templates first — \
                    filing items into the bags the traveller already uses, or applying the list \
                    they already saved, beats inventing either.

                    The itinerary is a flat, ordered list of stops. A country is a property of a \
                    stop, not a grouping level.
                    """,
            ]
        }

        private static func toolsListResult() -> [String: Any] {
            let descriptors = ToolCatalog.tools.map {
                ToolDescriptor(
                    name: $0.name, title: $0.title, description: $0.description,
                    inputSchema: $0.schema,
                    annotations: ToolDescriptor.Annotations(
                        readOnlyHint: $0.isReadOnly,
                        destructiveHint: $0.isDestructive,
                        idempotentHint: $0.isReadOnly,
                        openWorldHint: false))
            }
            let encoded = (try? ToolCatalog.encoder.encode(descriptors)) ?? Data("[]".utf8)
            let tools = (try? JSONSerialization.jsonObject(with: encoded)) ?? []
            return ["tools": tools]
        }

        private static func toolsCallResult(_ params: [String: Any]) -> [String: Any] {
            guard let name = params["name"] as? String else {
                return [
                    "content": [["type": "text", "text": "Missing tool name."]],
                    "isError": true,
                ]
            }
            let arguments: Data =
                if let raw = params["arguments"],
                    let encoded = try? JSONSerialization.data(withJSONObject: raw)
                {
                    encoded
                } else {
                    Data("{}".utf8)
                }

            let defaults = UserDefaults.standard
            let result = ToolCatalog.call(
                name, arguments: arguments,
                permissions: ToolPermissions(
                    writesAllowed: defaults.bool(forKey: writesAllowedKey),
                    deletionsAllowed: defaults.bool(forKey: deletionsAllowedKey),
                    personalAllowed: defaults.bool(forKey: personalAllowedKey)))
            return [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError,
            ]
        }

        private static func envelope(id: Any, result: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": result]
        }

        private static func errorEnvelope(id: Any?, code: Int, message: String) -> [String: Any] {
            var envelope: [String: Any] = [
                "jsonrpc": "2.0", "error": ["code": code, "message": message],
            ]
            envelope["id"] = id ?? NSNull()
            return envelope
        }

        private struct ToolDescriptor: Encodable {
            let name: String
            let title: String
            let description: String
            let inputSchema: JSONSchema
            let annotations: Annotations

            struct Annotations: Encodable {
                let readOnlyHint: Bool
                let destructiveHint: Bool
                let idempotentHint: Bool
                let openWorldHint: Bool
            }
        }
    }

    // MARK: - Minimal HTTP

    /// Just enough HTTP/1.1 to carry JSON-RPC: a request line, headers, and a
    /// `Content-Length` body. No chunked encoding, no keep-alive — every response
    /// closes its connection, which clients handle and which keeps this small.
    private struct HTTPRequest {
        let method: String
        let path: String
        /// Lower-cased names; HTTP header names are case-insensitive.
        let headers: [String: String]
        let body: Data

        var bearerToken: String? {
            guard let value = headers["authorization"],
                value.lowercased().hasPrefix("bearer ")
            else { return nil }
            return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }

        enum ParseResult {
            case complete(HTTPRequest)
            /// Headers haven't arrived yet, or the body is still short.
            case incomplete
            case invalid
        }

        static func parse(_ buffer: Data) -> ParseResult {
            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = buffer.range(of: separator) else { return .incomplete }

            let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            var lines = headerText.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return .invalid }

            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { return .invalid }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }

            let expected = Int(headers["content-length"] ?? "0") ?? 0
            let body = buffer[headerEnd.upperBound...]
            guard body.count >= expected else { return .incomplete }

            return .complete(
                HTTPRequest(
                    method: String(requestLine[0]).uppercased(),
                    path: String(requestLine[1]),
                    headers: headers,
                    body: Data(body.prefix(expected))))
        }
    }

    private struct HTTPResponse {
        var status: Int
        var reason: String
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func status(_ status: Int, _ reason: String) -> HTTPResponse {
            HTTPResponse(status: status, reason: reason)
        }

        static func json(_ object: [String: Any]) -> HTTPResponse {
            let body =
                (try? JSONSerialization.data(withJSONObject: object))
                ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
            return HTTPResponse(
                status: 200, reason: "OK",
                headers: ["Content-Type": "application/json"], body: body)
        }

        var serialized: Data {
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                head += "\(name): \(value)\r\n"
            }
            head += "\r\n"
            return Data(head.utf8) + body
        }
    }

    // MARK: - JSON-configured clients

    /// A client that reads MCP server config from a JSON file. Each case knows
    /// which file it reads and the shape of the JSON it expects, so Settings can
    /// offer the right snippet for the user's assistant without showing the token.
    enum MCPClient: CaseIterable, Identifiable {
        case claudeDesktop
        case cursor
        case vsCode

        var id: Self { self }

        /// Name shown in the Settings picker. Brand names — never translated.
        var displayName: String {
            switch self {
            case .claudeDesktop: "Claude Desktop"
            case .cursor: "Cursor"
            case .vsCode: "VS Code"
            }
        }

        /// The config file the snippet goes in. Project-scoped files are shown
        /// relative to the project folder; Claude Desktop's is a fixed path.
        var configFile: String {
            switch self {
            case .claudeDesktop: "~/Library/Application Support/Claude/claude_desktop_config.json"
            case .cursor: ".cursor/mcp.json"
            case .vsCode: ".vscode/mcp.json"
            }
        }
    }

#endif
