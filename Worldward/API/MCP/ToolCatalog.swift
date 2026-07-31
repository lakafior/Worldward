/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS)

    import Foundation

    // MARK: - JSON Schema

    /// The sliver of JSON Schema that MCP tool definitions actually need.
    ///
    /// Properties are an ordered array rather than a dictionary: a schema is read
    /// by a language model, and the order fields are declared in is part of how it
    /// reads them. A `[String: JSONSchema]` would scramble that on every encode.
    nonisolated indirect enum JSONSchema: Encodable {
        case string(String, format: String? = nil)
        case integer(String)
        case boolean(String)
        case number(String)
        case enumeration([String], String)
        case array(String, of: JSONSchema)
        case object(String? = nil, required: [String] = [], properties: [(String, JSONSchema)])

        private struct Key: CodingKey {
            let stringValue: String
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case .string(let description, let format):
                try container.encode("string", forKey: Key("type"))
                try container.encode(description, forKey: Key("description"))
                try container.encodeIfPresent(format, forKey: Key("format"))
            case .integer(let description):
                try container.encode("integer", forKey: Key("type"))
                try container.encode(description, forKey: Key("description"))
            case .boolean(let description):
                try container.encode("boolean", forKey: Key("type"))
                try container.encode(description, forKey: Key("description"))
            case .number(let description):
                try container.encode("number", forKey: Key("type"))
                try container.encode(description, forKey: Key("description"))
            case .enumeration(let values, let description):
                try container.encode("string", forKey: Key("type"))
                try container.encode(values, forKey: Key("enum"))
                try container.encode(description, forKey: Key("description"))
            case .array(let description, let items):
                try container.encode("array", forKey: Key("type"))
                try container.encode(description, forKey: Key("description"))
                try container.encode(items, forKey: Key("items"))
            case .object(let description, let required, let properties):
                try container.encode("object", forKey: Key("type"))
                try container.encodeIfPresent(description, forKey: Key("description"))
                if !required.isEmpty { try container.encode(required, forKey: Key("required")) }
                var nested = container.nestedContainer(
                    keyedBy: Key.self, forKey: Key("properties"))
                for (name, schema) in properties {
                    try nested.encode(schema, forKey: Key(name))
                }
            }
        }
    }

    // MARK: - Tool

    /// One MCP tool: how it's advertised, and what running it does.
    @MainActor
    struct MCPTool {
        let name: String
        let title: String
        let description: String
        let schema: JSONSchema
        /// Advertised as `annotations.readOnlyHint`, and the gate the "allow
        /// changes" setting flips — a read-only tool always runs.
        let isReadOnly: Bool
        /// Advertised as `annotations.destructiveHint`. True only where a call
        /// destroys something no other tool can put back — a client may well use
        /// this to ask the user first, so claiming it falsely is worse than
        /// useless. Adding rows or replacing a value the result hands back is not
        /// destructive.
        var isDestructive: Bool = false
        /// Raw `arguments` JSON in, any `Encodable` result out.
        let handler: (Data) throws -> any Encodable
    }

    /// The tools Worldward advertises, and the dispatch behind them.
    ///
    /// Descriptions here are not documentation — they're the prompt. Anything a
    /// caller must know to use the app correctly (that an itinerary is a *flat*
    /// list, that containers are a shared catalog worth reusing, that batching
    /// beats chatter) belongs in the text, because nothing else will tell it.
    @MainActor
    enum ToolCatalog {

        // MARK: Coding

        /// Dates in, leniently. A model writes `"2026-09-14"` as readily as a full
        /// timestamp, and bouncing the request over a missing `T00:00:00Z` would be
        /// pedantry — a plain day is exactly what a trip date usually is.
        static let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                if let date = isoWithFraction.date(from: text) { return date }
                if let date = iso.date(from: text) { return date }
                if let date = dayOnly.date(from: text) { return date }
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "Expected an ISO-8601 date such as '2026-09-14' or "
                            + "'2026-09-14T09:00:00Z', got '\(text)'."))
            }
            return decoder
        }()

        /// Dates out, always full ISO-8601 — unambiguous for whoever reads them.
        static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return encoder
        }()

        // `dateDecodingStrategy` hands these to a `@Sendable` closure, so they have
        // to leave the main actor. `DateFormatter` is `Sendable` and just needs
        // `nonisolated`; `ISO8601DateFormatter` isn't, hence the `(unsafe)` — safe
        // here because it's documented thread-safe for parsing once configured and
        // nothing mutates it after creation. Rebuilding them per call would also be
        // correct, but formatter construction is the expensive part.
        private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        private nonisolated(unsafe) static let isoWithFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        /// A bare day is read in the user's own time zone, so "14 September" means
        /// the 14th where they are rather than sliding a day at either edge of UTC.
        private nonisolated static let dayOnly: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()

        // MARK: Reusable schema fragments

        private static let countryParameter = JSONSchema.string(
            "Country as an ISO 3166-1 alpha-2 code ('ES'), or its English name ('Spain').")

        private static let stopSchema = JSONSchema.object(
            required: ["title"],
            properties: [
                ("title", .string("Place name, e.g. 'Sagrada Família' or 'Barcelona'.")),
                ("country", countryParameter),
                ("date", .string("Day at this stop, e.g. '2026-09-14'.", format: "date")),
                ("detail", .string("Short address line, e.g. 'Carrer de Mallorca, Barcelona'.")),
                ("note", .string("Free-form note for this stop.")),
                (
                    "transport",
                    .enumeration(
                        TransportMode.allCases.map(\.rawValue),
                        "How the traveller reaches this stop.")
                ),
                (
                    "transportDetail",
                    .string("Flight number, times, confirmation code — free text.")
                ),
                ("latitude", .number("Decimal degrees, if known.")),
                ("longitude", .number("Decimal degrees, if known.")),
            ])

        private static let packingItemSchema = JSONSchema.object(
            required: ["title"],
            properties: [
                ("title", .string("Item name, e.g. 'Passport'.")),
                ("quantity", .integer("How many to pack. Defaults to 1.")),
                (
                    "container",
                    .string(
                        "Container name, e.g. 'Toiletries'. Call list_containers first and "
                            + "reuse what's already there; an unknown name creates a container.")
                ),
            ])

        // MARK: The catalog

        static let tools: [MCPTool] = [
            MCPTool(
                name: "list_trips",
                title: "List trips",
                description:
                    "Lists the traveller's trips. Defaults to upcoming ones, soonest first.",
                schema: .object(properties: [
                    (
                        "scope",
                        .enumeration(
                            TripScope.allCases.map(\.rawValue),
                            "'upcoming' (default) includes a trip currently underway.")
                    ),
                    ("limit", .integer("Maximum trips to return. Defaults to 20.")),
                ]),
                isReadOnly: true,
                handler: { data in
                    let args = try decoder.decode(ListTripsArgs.self, from: data)
                    return try WorldwardAPI.listTrips(
                        scope: args.scope ?? .upcoming, limit: args.limit ?? 20)
                }),

            MCPTool(
                name: "get_trip",
                title: "Get a trip",
                description:
                    "A trip in full: itinerary stops, packing list, links, contacts and "
                    + "document names. Omit tripId for the trip underway, or the next one.",
                schema: .object(properties: [
                    ("tripId", .string("Trip id from list_trips. Omit for the current/next trip."))
                ]),
                isReadOnly: true,
                handler: { data in
                    try WorldwardAPI.getTrip(id: decoder.decode(TripIDArgs.self, from: data).tripID)
                }),

            MCPTool(
                name: "list_countries",
                title: "List countries",
                description:
                    "Countries from the traveller's catalog, narrowed by filters. All filters "
                    + "combine; with none the whole 239-country catalog comes back, which is "
                    + "rarely what you want — filter by status or plan instead.",
                schema: .object(properties: [
                    (
                        "status",
                        .array(
                            "Keep only these travel statuses.",
                            of: .enumeration(CountryStatus.allCases.map(\.rawValue), "A status."))
                    ),
                    (
                        "plan",
                        .array(
                            "Keep only these plan states.",
                            of: .enumeration(PlanStatus.allCases.map(\.rawValue), "A plan state."))
                    ),
                    (
                        "continent",
                        .enumeration(Continent.allCases.map(\.rawValue), "Keep only this continent.")
                    ),
                ]),
                isReadOnly: true,
                handler: { data in
                    let args = try decoder.decode(ListCountriesArgs.self, from: data)
                    return try WorldwardAPI.listCountries(
                        status: args.status, plan: args.plan, continent: args.continent)
                }),

            MCPTool(
                name: "get_stats",
                title: "Get travel statistics",
                description:
                    "Lifetime travel numbers: countries and continents visited, totals by "
                    + "status and plan, per-continent and per-year breakdowns.",
                schema: .object(properties: []),
                isReadOnly: true,
                handler: { _ in try WorldwardAPI.getStats() }),

            MCPTool(
                name: "get_country_facts",
                title: "Get country facts",
                description:
                    "Bundled offline practicalities for one country — currency, languages, "
                    + "plug types, driving side, emergency number. No network involved.",
                schema: .object(
                    required: ["country"], properties: [("country", countryParameter)]),
                isReadOnly: true,
                handler: { data in
                    try WorldwardAPI.getCountryFacts(
                        country: decoder.decode(CountryArgs.self, from: data).country)
                }),

            MCPTool(
                name: "list_containers",
                title: "List packing containers",
                description:
                    "The traveller's bags and cases, shared across every trip. Call this before "
                    + "writing a packing list and file items into containers that already "
                    + "exist rather than inventing new ones.",
                schema: .object(properties: []),
                isReadOnly: true,
                handler: { _ in try WorldwardAPI.listContainers() }),

            MCPTool(
                name: "list_packing_templates",
                title: "List packing templates",
                description:
                    "Saved, reusable packing lists. Applying one is usually better than "
                    + "writing a list from scratch — it's what the traveller actually packs.",
                schema: .object(properties: []),
                isReadOnly: true,
                handler: { _ in try WorldwardAPI.listTemplates() }),

            MCPTool(
                name: "create_trip",
                title: "Create a trip",
                description:
                    "Creates an empty trip. To build a complete one — stops, packing, notes — "
                    + "use plan_trip instead; it does the whole thing in a single atomic write.",
                schema: .object(
                    required: ["title", "startDate", "endDate"],
                    properties: [
                        ("title", .string("Trip name, e.g. 'Spain, September'.")),
                        ("startDate", .string("First day, e.g. '2026-09-12'.", format: "date")),
                        (
                            "endDate",
                            .string("Last day, on or after startDate.", format: "date")
                        ),
                        ("notes", .string("Markdown notes. '# Heading' lines start sections.")),
                    ]),
                isReadOnly: false,
                handler: { data in
                    try WorldwardAPI.createTrip(decoder.decode(CreateTripInput.self, from: data))
                }),

            MCPTool(
                name: "add_stops",
                title: "Add itinerary stops",
                description:
                    "Appends stops to a trip's itinerary. The itinerary is a flat, ordered list "
                    + "of places — a country is a property of a stop, not a level of nesting. "
                    + "Pass every stop in one call rather than calling repeatedly.",
                schema: .object(
                    required: ["stops"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("stops", .array("Appended in array order, after existing stops.", of: stopSchema)),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(AddStopsArgs.self, from: data)
                    return try WorldwardAPI.addStops(tripID: args.tripID, stops: args.stops)
                }),

            MCPTool(
                name: "add_packing_items",
                title: "Add packing items",
                description:
                    "Appends items to a trip's packing list, skipping titles already on it. "
                    + "The result holds only the items actually created, so a shorter array "
                    + "than you sent means duplicates were dropped.",
                schema: .object(
                    required: ["items"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("items", .array("Items to add.", of: packingItemSchema)),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(AddPackingArgs.self, from: data)
                    return try WorldwardAPI.addPackingItems(tripID: args.tripID, items: args.items)
                }),

            MCPTool(
                name: "set_packed",
                title: "Tick packing items off",
                description: "Marks packing items packed or unpacked.",
                schema: .object(
                    required: ["itemIds", "isPacked"],
                    properties: [
                        ("itemIds", .array("Packing item ids from get_trip.", of: .string("An id."))),
                        ("isPacked", .boolean("true to mark packed, false to clear.")),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(SetPackedArgs.self, from: data)
                    return try WorldwardAPI.setPacked(
                        itemIDs: args.itemIDs, isPacked: args.isPacked)
                }),

            MCPTool(
                name: "set_trip_notes",
                title: "Write trip notes",
                description:
                    "Replaces or appends a trip's notes. Markdown; a line starting '# ' opens a "
                    + "new section in the app's note editor. The previous text comes back in "
                    + "the result, so a mistaken write can be put back.",
                schema: .object(
                    required: ["notes"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("notes", .string("Markdown note text.")),
                        (
                            "mode",
                            .enumeration(
                                TextMode.allCases.map(\.rawValue),
                                "'replace' (default) or 'append' after a blank line.")
                        ),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(SetNotesArgs.self, from: data)
                    return try WorldwardAPI.setTripNotes(
                        tripID: args.tripID, notes: args.notes, mode: args.mode ?? .replace)
                }),

            MCPTool(
                name: "set_country_status",
                title: "Set a country's status",
                description:
                    "Sets where a country sits on the travel axis (status) and/or the planning "
                    + "axis (plan). The two are independent — somewhere can be visited and on "
                    + "the wishlist at once. Omitting an axis leaves it untouched. The previous "
                    + "values come back in the result.",
                schema: .object(
                    required: ["country"],
                    properties: [
                        ("country", countryParameter),
                        (
                            "status",
                            .enumeration(
                                CountryStatus.allCases.map(\.rawValue), "Travel status to set.")
                        ),
                        (
                            "plan",
                            .enumeration(PlanStatus.allCases.map(\.rawValue), "Plan state to set.")
                        ),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(SetCountryStatusArgs.self, from: data)
                    return try WorldwardAPI.setCountryStatus(
                        country: args.country, status: args.status, plan: args.plan)
                }),

            MCPTool(
                name: "log_visit",
                title: "Log a visit",
                description:
                    "Records a dated visit to a country. A country never visited before is "
                    + "promoted to 'visited'; a stronger bond (lived/living) is left alone.",
                schema: .object(
                    required: ["country"],
                    properties: [
                        ("country", countryParameter),
                        ("date", .string("Visit date. Defaults to today.", format: "date")),
                        ("notes", .string("Free-form note about the visit.")),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(LogVisitArgs.self, from: data)
                    return try WorldwardAPI.logVisit(
                        country: args.country, date: args.date, notes: args.notes ?? "")
                }),

            MCPTool(
                name: "apply_packing_template",
                title: "Apply a packing template",
                description:
                    "Appends a saved template's items to a trip, skipping anything already on "
                    + "the list. Call list_packing_templates for the names.",
                schema: .object(
                    required: ["template"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("template", .string("Template name.")),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(ApplyTemplateArgs.self, from: data)
                    return try WorldwardAPI.applyPackingTemplate(
                        tripID: args.tripID, template: args.template)
                }),

            MCPTool(
                name: "update_trip",
                title: "Edit a trip's title or dates",
                description: "Renames a trip or moves its dates. Omitted fields are left alone.",
                schema: .object(properties: [
                    ("tripId", .string("Trip id. Omit for the current/next trip.")),
                    ("title", .string("New trip name.")),
                    ("startDate", .string("New first day.", format: "date")),
                    ("endDate", .string("New last day.", format: "date")),
                ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(UpdateTripArgs.self, from: data)
                    return try WorldwardAPI.updateTrip(
                        tripID: args.tripID,
                        TripUpdateInput(
                            title: args.title, startDate: args.startDate, endDate: args.endDate))
                }),

            MCPTool(
                name: "delete_trip",
                title: "Delete a trip",
                description:
                    "Permanently deletes a trip with its itinerary, packing list, links, contacts "
                    + "and attached files. This cannot be undone — confirm with the user first.",
                schema: .object(
                    required: ["tripId"],
                    properties: [("tripId", .string("Trip id from list_trips."))]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    try WorldwardAPI.deleteTrip(
                        tripID: decoder.decode(RequiredTripIDArgs.self, from: data).tripID)
                }),

            MCPTool(
                name: "update_stops",
                title: "Edit itinerary stops",
                description:
                    "Changes existing stops — this is where travel details go once a trip is "
                    + "roughed out: flight numbers and times in transportDetail, addresses in "
                    + "detail, anything else in note. Omitted fields are left alone; to empty a "
                    + "field pass \"\" for text, or the matching clear flag for date, country "
                    + "and transport.",
                schema: .object(
                    required: ["stops"],
                    properties: [
                        (
                            "stops",
                            .array(
                                "Stops to change, each naming the id it applies to.",
                                of: .object(
                                    required: ["id"],
                                    properties: [
                                        ("id", .string("Stop id from get_trip.")),
                                        ("title", .string("New place name.")),
                                        ("country", countryParameter),
                                        ("clearCountry", .boolean("Remove the stop's country.")),
                                        ("date", .string("New date.", format: "date")),
                                        ("clearDate", .boolean("Remove the stop's date.")),
                                        ("detail", .string("Short address line.")),
                                        ("note", .string("Free-form note for this stop.")),
                                        (
                                            "transport",
                                            .enumeration(
                                                TransportMode.allCases.map(\.rawValue),
                                                "How the traveller reaches this stop.")
                                        ),
                                        ("clearTransport", .boolean("Remove the transport mode.")),
                                        (
                                            "transportDetail",
                                            .string(
                                                "Flight number, times, confirmation code — free text.")
                                        ),
                                        ("latitude", .number("Decimal degrees.")),
                                        ("longitude", .number("Decimal degrees.")),
                                    ]))
                        )
                    ]),
                isReadOnly: false,
                handler: { data in
                    try WorldwardAPI.updateStops(
                        decoder.decode(UpdateStopsArgs.self, from: data).stops)
                }),

            MCPTool(
                name: "delete_stops",
                title: "Delete itinerary stops",
                description:
                    "Removes stops from a trip's itinerary. Files and links pinned to a deleted "
                    + "stop are kept, demoted to trip-level. Cannot be undone.",
                schema: .object(
                    required: ["stopIds"],
                    properties: [
                        ("stopIds", .array("Stop ids from get_trip.", of: .string("A stop id.")))
                    ]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    try WorldwardAPI.deleteStops(
                        stopIDs: decoder.decode(StopIDsArgs.self, from: data).stopIDs)
                }),

            MCPTool(
                name: "reorder_stops",
                title: "Reorder the itinerary",
                description:
                    "Rearranges a trip's stops. Stops you don't name keep their relative order "
                    + "after the ones you do, so moving a couple doesn't mean listing them all.",
                schema: .object(
                    required: ["stopIds"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("stopIds", .array("Stop ids in their new order.", of: .string("A stop id."))),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(ReorderStopsArgs.self, from: data)
                    return try WorldwardAPI.reorderStops(tripID: args.tripID, stopIDs: args.stopIDs)
                }),

            MCPTool(
                name: "update_packing_items",
                title: "Edit packing items",
                description:
                    "Renames packing items, changes quantities, moves them between containers, "
                    + "or ticks them off. Omitted fields are left alone.",
                schema: .object(
                    required: ["items"],
                    properties: [
                        (
                            "items",
                            .array(
                                "Items to change.",
                                of: .object(
                                    required: ["id"],
                                    properties: [
                                        ("id", .string("Packing item id from get_trip.")),
                                        ("title", .string("New item name.")),
                                        ("quantity", .integer("How many to pack.")),
                                        ("container", .string("Container name to file it into.")),
                                        (
                                            "clearContainer",
                                            .boolean("Move the item out of any container.")
                                        ),
                                        ("isPacked", .boolean("Whether it's packed.")),
                                    ]))
                        )
                    ]),
                isReadOnly: false,
                handler: { data in
                    try WorldwardAPI.updatePackingItems(
                        decoder.decode(UpdatePackingArgs.self, from: data).items)
                }),

            MCPTool(
                name: "delete_packing_items",
                title: "Delete packing items",
                description: "Removes items from a trip's packing list. Cannot be undone.",
                schema: .object(
                    required: ["itemIds"],
                    properties: [
                        ("itemIds", .array("Packing item ids from get_trip.", of: .string("An id.")))
                    ]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    try WorldwardAPI.deletePackingItems(
                        itemIDs: decoder.decode(ItemIDsArgs.self, from: data).itemIDs)
                }),

            MCPTool(
                name: "set_note_section",
                title: "Write one section of a trip's notes",
                description:
                    "Creates or rewrites a single '# Heading' section of a trip's notes, leaving "
                    + "every other section untouched. Prefer this over set_trip_notes, which "
                    + "replaces the whole note and can lose what the traveller wrote. get_trip "
                    + "returns the current sections under noteSections.",
                schema: .object(
                    required: ["heading", "body"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("heading", .string("Section heading, without the '# '.")),
                        ("body", .string("Markdown body for the section.")),
                        (
                            "mode",
                            .enumeration(
                                TextMode.allCases.map(\.rawValue),
                                "'replace' (default) overwrites the section; 'append' adds to it.")
                        ),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(NoteSectionArgs.self, from: data)
                    return try WorldwardAPI.setNoteSection(
                        tripID: args.tripID, heading: args.heading, body: args.body,
                        mode: args.mode ?? .replace)
                }),

            MCPTool(
                name: "delete_note_section",
                title: "Delete a section of a trip's notes",
                description: "Removes one '# Heading' section and its text. Cannot be undone.",
                schema: .object(
                    required: ["heading"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("heading", .string("Section heading, without the '# '.")),
                    ]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    let args = try decoder.decode(NoteSectionArgs.self, from: data)
                    return try WorldwardAPI.deleteNoteSection(
                        tripID: args.tripID, heading: args.heading)
                }),

            MCPTool(
                name: "add_links",
                title: "Add links to a trip",
                description:
                    "Saves web links on a trip — a hotel booking page, a timetable, a ticket "
                    + "page. Give stopId to pin a link to one stop instead of the whole trip.",
                schema: .object(
                    required: ["links"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        (
                            "links",
                            .array(
                                "Links to add.",
                                of: .object(
                                    required: ["url"],
                                    properties: [
                                        ("url", .string("The link. A bare host gets https://.")),
                                        ("title", .string("Label. Defaults to the URL itself.")),
                                        ("stopId", .string("Pin to this stop. Omit for trip-level.")),
                                    ]))
                        ),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(AddLinksArgs.self, from: data)
                    return try WorldwardAPI.addLinks(tripID: args.tripID, links: args.links)
                }),

            MCPTool(
                name: "add_contacts",
                title: "Add contacts to a trip",
                description:
                    "Saves people or desks to reach — a hotel front desk, a car-rental WhatsApp, "
                    + "an insurer's emergency line. Each becomes a tappable row in the app. Give "
                    + "stopId to pin a contact to one stop.",
                schema: .object(
                    required: ["contacts"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        (
                            "contacts",
                            .array(
                                "Contacts to add.",
                                of: .object(
                                    required: ["name", "value"],
                                    properties: [
                                        ("name", .string("Who this is, e.g. 'Hotel Ibis front desk'.")),
                                        ("value", .string("Number or address, as it should read.")),
                                        (
                                            "kind",
                                            .enumeration(
                                                ContactKind.allCases.map(\.rawValue),
                                                "Defaults to 'phone'.")
                                        ),
                                        ("stopId", .string("Pin to this stop. Omit for trip-level.")),
                                    ]))
                        ),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(AddContactsArgs.self, from: data)
                    return try WorldwardAPI.addContacts(tripID: args.tripID, contacts: args.contacts)
                }),

            MCPTool(
                name: "add_attachments",
                title: "Attach files to a trip",
                description:
                    "Attaches files — boarding passes, tickets, booking confirmations, scans. "
                    + "Worldward is sandboxed and cannot open a path on your behalf, so send the "
                    + "file's bytes base64-encoded; read the file yourself first. Limit "
                    + "\(WorldwardAPI.attachmentSizeLimitMB) MB each. Give stopId to file it "
                    + "under one stop, which is where a ticket for that place belongs.",
                schema: .object(
                    required: ["attachments"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        (
                            "attachments",
                            .array(
                                "Files to attach.",
                                of: .object(
                                    required: ["filename", "dataBase64"],
                                    properties: [
                                        ("filename", .string("Name to show, e.g. 'boarding-pass.pdf'.")),
                                        ("dataBase64", .string("File content, base64-encoded.")),
                                        (
                                            "caption",
                                            .string("What the file is for, e.g. 'Louvre e-ticket'.")
                                        ),
                                        ("stopId", .string("File under this stop. Omit for trip-level.")),
                                    ]))
                        ),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(AddAttachmentsArgs.self, from: data)
                    return try WorldwardAPI.addAttachments(
                        tripID: args.tripID, attachments: args.attachments)
                }),

            MCPTool(
                name: "delete_trip_items",
                title: "Delete links, contacts or attachments",
                description:
                    "Removes links, contacts and attached files by id — the ids get_trip returns "
                    + "under links, contacts and attachments. Cannot be undone.",
                schema: .object(
                    required: ["itemIds"],
                    properties: [
                        ("itemIds", .array("Ids from get_trip.", of: .string("An id.")))
                    ]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    try WorldwardAPI.deleteTripItems(
                        itemIDs: decoder.decode(ItemIDsArgs.self, from: data).itemIDs)
                }),

            MCPTool(
                name: "create_container",
                title: "Create a packing container",
                description:
                    "Adds a bag or case to the shared catalog every trip can file items into. "
                    + "Adding items with a new container name creates one automatically, so this "
                    + "is mainly for setting up a container ahead of time or giving it an icon.",
                schema: .object(
                    required: ["name"],
                    properties: [
                        ("name", .string("Container name, e.g. 'Camera bag'.")),
                        ("symbolName", .string("SF Symbol name. Defaults to 'bag.fill'.")),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(ContainerArgs.self, from: data)
                    return try WorldwardAPI.createContainer(
                        name: args.name, symbolName: args.symbolName)
                }),

            MCPTool(
                name: "rename_container",
                title: "Rename a packing container",
                description:
                    "Renames a container everywhere. It's a shared catalog, so every trip filing "
                    + "items into it follows automatically.",
                schema: .object(
                    required: ["name", "newName"],
                    properties: [
                        ("name", .string("Current container name.")),
                        ("newName", .string("New container name.")),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(ContainerArgs.self, from: data)
                    guard let newName = args.newName else {
                        throw APIError.emptyValue(field: "newName")
                    }
                    return try WorldwardAPI.renameContainer(name: args.name, newName: newName)
                }),

            MCPTool(
                name: "delete_container",
                title: "Delete a packing container",
                description:
                    "Removes a container from the shared catalog. Items filed in it are kept and "
                    + "become ungrouped — nothing on any packing list is lost.",
                schema: .object(
                    required: ["name"], properties: [("name", .string("Container name."))]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    try WorldwardAPI.deleteContainer(
                        name: decoder.decode(ContainerArgs.self, from: data).name)
                }),

            MCPTool(
                name: "save_packing_template",
                title: "Save a packing list as a template",
                description:
                    "Saves a trip's packing list for reuse on future trips, keeping each item's "
                    + "container by name. Saving over an existing name replaces it.",
                schema: .object(
                    required: ["name"],
                    properties: [
                        ("tripId", .string("Trip id. Omit for the current/next trip.")),
                        ("name", .string("Template name, e.g. 'City break'.")),
                    ]),
                isReadOnly: false,
                handler: { data in
                    let args = try decoder.decode(TemplateArgs.self, from: data)
                    return try WorldwardAPI.savePackingTemplate(tripID: args.tripID, name: args.name)
                }),

            MCPTool(
                name: "delete_packing_template",
                title: "Delete a packing template",
                description: "Removes a saved packing template. Cannot be undone.",
                schema: .object(
                    required: ["name"], properties: [("name", .string("Template name."))]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    try WorldwardAPI.deletePackingTemplate(
                        name: decoder.decode(TemplateArgs.self, from: data).name)
                }),

            MCPTool(
                name: "list_visits",
                title: "List visits to a country",
                description:
                    "Every recorded visit to one country, newest first, with the ids needed to "
                    + "edit or remove them.",
                schema: .object(
                    required: ["country"], properties: [("country", countryParameter)]),
                isReadOnly: true,
                handler: { data in
                    try WorldwardAPI.listVisits(
                        country: decoder.decode(CountryArgs.self, from: data).country)
                }),

            MCPTool(
                name: "update_visits",
                title: "Edit visits",
                description: "Changes the date or notes of recorded visits.",
                schema: .object(
                    required: ["visits"],
                    properties: [
                        (
                            "visits",
                            .array(
                                "Visits to change.",
                                of: .object(
                                    required: ["id"],
                                    properties: [
                                        ("id", .string("Visit id from list_visits.")),
                                        ("date", .string("New visit date.", format: "date")),
                                        ("notes", .string("New note.")),
                                    ]))
                        )
                    ]),
                isReadOnly: false,
                handler: { data in
                    try WorldwardAPI.updateVisits(
                        decoder.decode(UpdateVisitsArgs.self, from: data).visits)
                }),

            MCPTool(
                name: "delete_visits",
                title: "Delete visits",
                description:
                    "Removes recorded visits. The country's travel status is left as it is — "
                    + "deleting one mis-dated visit doesn't mean the traveller was never there. "
                    + "Use set_country_status if the status should change too. Cannot be undone.",
                schema: .object(
                    required: ["visitIds"],
                    properties: [
                        ("visitIds", .array("Visit ids from list_visits.", of: .string("An id.")))
                    ]),
                isReadOnly: false, isDestructive: true,
                handler: { data in
                    try WorldwardAPI.deleteVisits(
                        visitIDs: decoder.decode(VisitIDsArgs.self, from: data).visitIDs)
                }),

            MCPTool(
                name: "plan_trip",
                title: "Plan a whole trip",
                description:
                    "Builds a complete trip in one atomic write — dates, itinerary, packing "
                    + "list and notes together. Prefer this over create_trip followed by "
                    + "add_stops and add_packing_items: it either lands whole or not at all, "
                    + "leaving no half-built trip behind. By default it also marks every "
                    + "country the itinerary touches as 'planning', which is what makes them "
                    + "light up on the map.",
                schema: .object(
                    required: ["title", "startDate", "endDate"],
                    properties: [
                        ("title", .string("Trip name, e.g. 'Spain, September'.")),
                        ("startDate", .string("First day, e.g. '2026-09-12'.", format: "date")),
                        ("endDate", .string("Last day, on or after startDate.", format: "date")),
                        ("notes", .string("Markdown notes. '# Heading' lines start sections.")),
                        ("stops", .array("The itinerary, in order.", of: stopSchema)),
                        ("packing", .array("Packing items.", of: packingItemSchema)),
                        (
                            "packingTemplate",
                            .string(
                                "Name of a saved template to apply first; items in 'packing' "
                                    + "are added on top, without duplicating.")
                        ),
                        (
                            "markCountriesPlanning",
                            .boolean("Mark the trip's countries as 'planning'. Defaults to true.")
                        ),
                    ]),
                isReadOnly: false,
                handler: { data in
                    try WorldwardAPI.planTrip(decoder.decode(PlanTripInput.self, from: data))
                }),
        ]

        private static let byName: [String: MCPTool] = Dictionary(
            uniqueKeysWithValues: tools.map { ($0.name, $0) })

        // MARK: Dispatch

        /// The outcome of a `tools/call`. A failure here is a *result* with
        /// `isError`, never a JSON-RPC error: protocol errors can abort the
        /// request, but a model that asked for a country that doesn't exist needs
        /// to see the complaint so it can correct itself and try again.
        struct CallResult {
            let text: String
            let isError: Bool
        }

        static func call(_ name: String, arguments: Data, writesAllowed: Bool) -> CallResult {
            guard let tool = byName[name] else {
                return CallResult(
                    text: "Unknown tool '\(name)'. Call tools/list for what's available.",
                    isError: true)
            }
            guard tool.isReadOnly || writesAllowed else {
                return CallResult(
                    text:
                        "'\(name)' changes data, and Worldward is set to read-only. The user can "
                        + "allow changes in Worldward → Settings → Automation.",
                    isError: true)
            }
            do {
                let value = try tool.handler(arguments)
                let encoded = try encoder.encode(value)
                return CallResult(
                    text: String(decoding: encoded, as: UTF8.self), isError: false)
            } catch let error as APIError {
                return CallResult(text: error.agentDescription, isError: true)
            } catch let error as DecodingError {
                return CallResult(text: Self.describe(error), isError: true)
            } catch {
                return CallResult(text: error.localizedDescription, isError: true)
            }
        }

        /// Turns a `DecodingError` into something a caller can act on. The stock
        /// description names a Swift type and a coding path, which tells a model
        /// nothing about which argument it got wrong.
        private static func describe(_ error: DecodingError) -> String {
            let path = { (context: DecodingError.Context) -> String in
                context.codingPath.map(\.stringValue).joined(separator: ".")
            }
            return switch error {
            case .keyNotFound(let key, _):
                "Missing required argument '\(key.stringValue)'."
            case .typeMismatch(_, let context):
                "Argument '\(path(context))' has the wrong type. \(context.debugDescription)"
            case .valueNotFound(_, let context):
                "Argument '\(path(context))' must not be null."
            case .dataCorrupted(let context):
                context.codingPath.isEmpty
                    ? "Arguments are not valid JSON. \(context.debugDescription)"
                    : "Argument '\(path(context))' is invalid. \(context.debugDescription)"
            @unknown default:
                "Arguments could not be read."
            }
        }
    }

    // MARK: - Argument shapes
    //
    // One per tool whose parameters don't already have an input type in
    // `APIModels`. `tripID` is spelled `tripId` on the wire — the schemas use
    // camelCase throughout so there's no snake_case translation layer to get
    // wrong, and this is the one place Swift's capitalisation differs.

    private struct ListTripsArgs: Decodable {
        let scope: TripScope?
        let limit: Int?
    }

    private struct TripIDArgs: Decodable {
        let tripID: String?
        enum CodingKeys: String, CodingKey { case tripID = "tripId" }
    }

    private struct ListCountriesArgs: Decodable {
        let status: [String]?
        let plan: [String]?
        let continent: String?
    }

    private struct CountryArgs: Decodable {
        let country: String
    }

    private struct AddStopsArgs: Decodable {
        let tripID: String?
        let stops: [StopInput]
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case stops
        }
    }

    private struct AddPackingArgs: Decodable {
        let tripID: String?
        let items: [PackingItemInput]
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case items
        }
    }

    private struct SetPackedArgs: Decodable {
        let itemIDs: [String]
        let isPacked: Bool
        enum CodingKeys: String, CodingKey {
            case itemIDs = "itemIds"
            case isPacked
        }
    }

    private struct SetNotesArgs: Decodable {
        let tripID: String?
        let notes: String
        let mode: TextMode?
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case notes, mode
        }
    }

    private struct SetCountryStatusArgs: Decodable {
        let country: String
        let status: String?
        let plan: String?
    }

    private struct LogVisitArgs: Decodable {
        let country: String
        let date: Date?
        let notes: String?
    }

    private struct ApplyTemplateArgs: Decodable {
        let tripID: String?
        let template: String
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case template
        }
    }

    private struct RequiredTripIDArgs: Decodable {
        let tripID: String
        enum CodingKeys: String, CodingKey { case tripID = "tripId" }
    }

    private struct UpdateTripArgs: Decodable {
        let tripID: String?
        let title: String?
        let startDate: Date?
        let endDate: Date?
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case title, startDate, endDate
        }
    }

    private struct UpdateStopsArgs: Decodable {
        let stops: [StopUpdateInput]
    }

    private struct StopIDsArgs: Decodable {
        let stopIDs: [String]
        enum CodingKeys: String, CodingKey { case stopIDs = "stopIds" }
    }

    private struct ReorderStopsArgs: Decodable {
        let tripID: String?
        let stopIDs: [String]
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case stopIDs = "stopIds"
        }
    }

    private struct UpdatePackingArgs: Decodable {
        let items: [PackingItemUpdateInput]
    }

    private struct ItemIDsArgs: Decodable {
        let itemIDs: [String]
        enum CodingKeys: String, CodingKey { case itemIDs = "itemIds" }
    }

    private struct NoteSectionArgs: Decodable {
        let tripID: String?
        let heading: String
        // Absent for `delete_note_section`, which names a section but writes none.
        let body: String
        let mode: TextMode?
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case heading, body, mode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tripID = try container.decodeIfPresent(String.self, forKey: .tripID)
            heading = try container.decode(String.self, forKey: .heading)
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            mode = try container.decodeIfPresent(TextMode.self, forKey: .mode)
        }
    }

    private struct AddLinksArgs: Decodable {
        let tripID: String?
        let links: [LinkInput]
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case links
        }
    }

    private struct AddContactsArgs: Decodable {
        let tripID: String?
        let contacts: [ContactInput]
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case contacts
        }
    }

    private struct AddAttachmentsArgs: Decodable {
        let tripID: String?
        let attachments: [AttachmentInput]
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case attachments
        }
    }

    private struct ContainerArgs: Decodable {
        let name: String
        let newName: String?
        let symbolName: String?
    }

    private struct TemplateArgs: Decodable {
        let tripID: String?
        let name: String
        enum CodingKeys: String, CodingKey {
            case tripID = "tripId"
            case name
        }
    }

    private struct UpdateVisitsArgs: Decodable {
        let visits: [VisitUpdateInput]
    }

    private struct VisitIDsArgs: Decodable {
        let visitIDs: [String]
        enum CodingKeys: String, CodingKey { case visitIDs = "visitIds" }
    }

#endif
