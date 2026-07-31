/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS)

    import Foundation

    /// Worldward running as a stdio ⇄ HTTP shim instead of as an app.
    ///
    /// The automation server speaks MCP over HTTP on loopback, but most clients —
    /// Claude Desktop among them — can only *launch a program* and talk to it over
    /// stdin and stdout. Claude Desktop's config file rejects anything that isn't a
    /// launched command outright, so without this the feature simply cannot be
    /// connected to the client it most exists for.
    ///
    /// This is the same executable as the app, entered through a launch flag before
    /// any UI, SwiftData or CloudKit exists (see `WorldwardMain`). Making it the app
    /// binary rather than a second bundled tool is what keeps it honest: one
    /// signature, one sandbox container, one set of entitlements. In particular the
    /// port and token are read straight from the app's own preferences — there is no
    /// credential in any client's config file, and none on a command line where
    /// every process on the machine could read it.
    ///
    /// A client launches one of these per session and closes the pipe when it's
    /// done, which is exactly this process's lifetime.
    enum MCPStdioBridge {

        /// Passing this makes the executable a bridge rather than an app.
        static let launchFlag = "--mcp-stdio"

        /// JSON-RPC reserves −32000 and below for implementation-defined errors,
        /// which is where "the app isn't reachable" belongs — it's not a protocol
        /// fault, and a client shouldn't treat it as one.
        private static let serverUnavailable = -32000

        static func run() {
            let defaults = UserDefaults.standard
            let storedPort = defaults.integer(forKey: MCPServer.portKey)
            let port = (1...65535).contains(storedPort) ? storedPort : MCPServer.defaultPort
            let token = defaults.string(forKey: MCPServer.tokenKey) ?? ""
            guard let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp") else { return }

            // `readLine` blocks until the client sends a message and returns nil when
            // it closes the pipe, so this loop *is* the process lifetime.
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let body = Data(trimmed.utf8)

                do {
                    if let reply = try forward(body, to: endpoint, token: token) { emit(reply) }
                } catch {
                    // A notification has no id, so there's nothing to answer and
                    // nowhere to put the complaint — dropping it is correct.
                    guard let id = messageID(body) else { continue }
                    emit(errorReply(id: id, message: unavailableMessage(port: port, token: token, error: error)))
                }
            }
        }

        /// Sends one message and returns the reply, or `nil` when there is nothing
        /// to say back — a 202 answers a notification, which gets no response.
        private static func forward(_ body: Data, to endpoint: URL, token: String) throws -> Data? {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            // The app answers from its main actor and does no I/O of its own, so a
            // slow reply means something is wrong, not that something is large.
            request.timeoutInterval = 30

            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var payload: Data?
            nonisolated(unsafe) var failure: Error?
            nonisolated(unsafe) var status = 0

            URLSession.shared.dataTask(with: request) { data, response, error in
                payload = data
                failure = error
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                semaphore.signal()
            }.resume()
            semaphore.wait()

            if let failure { throw failure }
            return status == 202 ? nil : payload
        }

        /// The `id` of an incoming message, so a locally-generated failure can be
        /// matched to the request that caused it.
        private static func messageID(_ body: Data) -> Any? {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let id = object["id"], !(id is NSNull)
            else { return nil }
            return id
        }

        /// Says which of the two likely things went wrong. Without this a client
        /// that launched the bridge while Worldward was closed just sees the request
        /// hang, and reports its own timeout instead of the actual cause.
        private static func unavailableMessage(port: Int, token: String, error: Error) -> String {
            token.isEmpty
                ? "Worldward's automation server has never been switched on. Turn it on in Worldward → Settings → Automation."
                : "Couldn't reach Worldward on 127.0.0.1:\(port). Check that the app is running and its automation server is on. (\(error.localizedDescription))"
        }

        private static func errorReply(id: Any, message: String) -> Data {
            let envelope: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "error": ["code": serverUnavailable, "message": message],
            ]
            return (try? JSONSerialization.data(withJSONObject: envelope))
                ?? Data(
                    #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Worldward is unavailable."}}"#
                        .utf8)
        }

        private static func emit(_ data: Data) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

#endif
