/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreLocation
import Foundation
import MapKit
import SwiftData

/// The app's domain operations, in one place, in machine-facing form.
///
/// This is deliberately *not* an automation layer. It knows nothing about
/// AppIntents, Shortcuts or any transport — it's the set of things Worldward can
/// do to its own data, expressed as `Codable` in, `Codable` out. AppIntents call
/// it and add spoken phrasing; anything else that needs to drive the app calls
/// the same functions and gets the same behaviour, which is the point: the two
/// surfaces cannot drift because there is only one implementation.
///
/// Every mutation goes through `mutate`, which owns the trio that used to be
/// hand-rolled in each intent — context, save, widget refresh. Miss one and the
/// widgets silently go stale, which is exactly the bug this shape prevents.
@MainActor
enum WorldwardAPI {

    // MARK: - Plumbing

    /// Runs a mutation: one short-lived context, one save, one widget refresh.
    ///
    /// The context is fresh rather than the container's `mainContext` because
    /// callers can run with no UI at all (Siri, Shortcuts, a background
    /// automation request) — the same reason the intents have always done this.
    /// SwiftData propagates the save to the `@Query` views that are open.
    ///
    /// There is no undo grouping here: the app runs without an `UndoManager` on
    /// purpose (see `Worldward.swift` — SwiftData FB13659086 crashes when one is
    /// attached and changes come quickly). Reversibility is carried by the return
    /// values instead: anything that replaces state reports what it replaced.
    private static func mutate<T>(_ body: (ModelContext) throws -> T) throws -> T {
        let context = ModelContext(Worldward.sharedModelContainer)
        let result = try body(context)
        try context.save()
        refreshWidgetSnapshot(using: context)
        return result
    }

    /// Runs a read. Separate from `mutate` only so the save/refresh cost isn't
    /// paid on every question — the stop-id backfill is the one read-path write,
    /// and it saves for itself.
    private static func read<T>(_ body: (ModelContext) throws -> T) throws -> T {
        try body(ModelContext(Worldward.sharedModelContainer))
    }

    /// Next free `order` among siblings — the `max() + 1` dance every add path
    /// used to repeat.
    private static func nextOrder<M>(_ siblings: [M]?, _ key: KeyPath<M, Int>) -> Int {
        ((siblings ?? []).map { $0[keyPath: key] }.max() ?? -1) + 1
    }

    private static func findTrip(_ id: String, in context: ModelContext) throws -> Trip {
        let all = try context.fetch(FetchDescriptor<Trip>())
        guard let trip = all.first(where: { $0.dedupID == id }) else {
            throw APIError.tripNotFound(id)
        }
        return trip
    }

    /// Resolves an optional trip id the way every trip intent already does:
    /// the named trip, else the journey underway, else the soonest upcoming one.
    /// Shared with `resolveTrip(_:in:)` in `TripIntents.swift` so voice, widgets
    /// and automation all agree on what "my trip" means.
    private static func resolveTrip(_ id: String?, in context: ModelContext) throws -> Trip {
        if let id { return try findTrip(id, in: context) }
        guard let trip = currentOrNextTrip(in: context) else { throw APIError.noUpcomingTrip }
        return trip
    }

    /// Resolves a container by name against the shared catalog, creating it when
    /// it's new. Mirrors `TripDetailView.resolveContainer` — same trimming, same
    /// case-insensitive match, same `sortOrder` append — so a container made here
    /// is indistinguishable from one made in the UI.
    private static func resolveContainer(
        named raw: String, in context: ModelContext, cache: inout [String: PackingContainer]
    ) throws -> PackingContainer? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let cached = cache[key] { return cached }

        let all = try context.fetch(FetchDescriptor<PackingContainer>())
        if let existing = all.first(where: { $0.name.lowercased() == key }) {
            cache[key] = existing
            return existing
        }
        let container = PackingContainer(
            name: name, sortOrder: (all.map(\.sortOrder).max() ?? -1) + 1 + cache.count)
        context.insert(container)
        cache[key] = container
        return container
    }

    /// Backfills stop ids and persists them if any were missing. Read paths that
    /// hand out stop ids must call this — an id that isn't saved won't be the
    /// same id next time it's asked for.
    private static func ensureStopIDs(_ trip: Trip, in context: ModelContext) throws {
        if trip.assignStopIDs() { try context.save() }
    }

    /// Finds one stop anywhere in the store by its `dedupID`. Stops are addressed
    /// globally rather than per-trip because a caller holding an id from
    /// `get_trip` shouldn't have to repeat which trip it came from.
    private static func findStop(_ id: String, in context: ModelContext) throws -> ItineraryItem {
        for trip in try context.fetch(FetchDescriptor<Trip>()) {
            trip.assignStopIDs()
            if let stop = (trip.itinerary ?? []).first(where: { $0.dedupID == id }) { return stop }
        }
        throw APIError.stopNotFound(id)
    }

    private static func findPackingItem(_ id: String, in context: ModelContext) throws -> PackingItem {
        guard
            let item = try context.fetch(FetchDescriptor<PackingItem>())
                .first(where: { $0.dedupID == id })
        else { throw APIError.packingItemNotFound(id) }
        return item
    }

    private static func findVisit(_ id: String, in context: ModelContext) throws -> Visit {
        for country in try context.fetch(FetchDescriptor<Country>()) {
            country.assignVisitIDs()
            if let visit = (country.visits ?? []).first(where: { $0.dedupID == id }) { return visit }
        }
        throw APIError.visitNotFound(id)
    }

    // MARK: - Reads

    static func listTrips(scope: TripScope = .upcoming, limit: Int = 20) throws -> [TripDTO] {
        try read { context in
            let now = Date()
            let all = try context.fetch(FetchDescriptor<Trip>())
            let filtered =
                switch scope {
                case .upcoming: all.filter { $0.isUpcoming(asOf: now) }
                case .past: all.filter { !$0.isUpcoming(asOf: now) }
                case .all: all
                }
            // Upcoming reads soonest-first (what's next matters); past reads
            // most-recent-first (what just happened matters).
            let sorted =
                scope == .past
                ? filtered.sorted { $0.startDate > $1.startDate }
                : filtered.sorted { $0.startDate < $1.startDate }
            return sorted.prefix(max(1, limit)).map(TripDTO.init)
        }
    }

    /// A trip and everything on it. `id` omitted means the current/next trip.
    ///
    /// `includePersonal` withholds contacts and attachment metadata rather than
    /// refusing the whole call — this is the tool a caller reaches for constantly,
    /// and failing it outright would make "Share personal details: off" feel like
    /// the feature is broken. What was withheld is named in `redacted`.
    static func getTrip(id: String? = nil, includePersonal: Bool = true) throws -> TripDetailDTO {
        try read { context in
            let trip = try resolveTrip(id, in: context)
            try ensureStopIDs(trip, in: context)
            return TripDetailDTO(trip, includePersonal: includePersonal)
        }
    }

    /// Countries, narrowed. All filters are optional and combine with AND; with
    /// none given this returns the whole 239-row catalog, which is almost never
    /// what a caller wants — hence the filters being the documented path.
    static func listCountries(
        status: [String]? = nil, plan: [String]? = nil, continent: String? = nil
    ) throws -> [CountryDTO] {
        let statuses = try status.map { try parse($0, as: CountryStatus.self, field: "status") }
        let plans = try plan.map { try parse($0, as: PlanStatus.self, field: "plan") }
        return try read { context in
            var all = try context.fetch(FetchDescriptor<Country>())
            if let statuses { all = all.filter { statuses.contains($0.status) } }
            if let plans { all = all.filter { plans.contains($0.planStatus) } }
            if let continent {
                // Matched against the stored English name, like everything else
                // machine-facing here.
                let folded = continent.lowercased()
                all = all.filter { $0.continent.lowercased() == folded }
            }
            return all.sorted { $0.name < $1.name }.map(CountryDTO.init)
        }
    }

    static func getStats() throws -> StatsDTO {
        try read { context in
            StatsDTO(TravelStats(countries: try context.fetch(FetchDescriptor<Country>())))
        }
    }

    static func getCountryFacts(country: String) throws -> FactsDTO {
        try read { context in
            let model = try CountryResolver.require(country, in: context)
            guard let facts = CountryFactsDB.facts(for: model.id) else {
                throw APIError.countryNotFound(country)
            }
            return FactsDTO(facts, country: model.id)
        }
    }

    /// The shared container catalog. Worth calling before writing a packing list —
    /// filing items into containers the traveller already uses beats inventing
    /// new ones.
    static func listContainers() throws -> [ContainerDTO] {
        try read { context in
            try context.fetch(FetchDescriptor<PackingContainer>())
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(ContainerDTO.init)
        }
    }

    static func listTemplates() throws -> [TemplateDTO] {
        try read { context in
            try context.fetch(FetchDescriptor<PackingTemplate>())
                .sorted { $0.name < $1.name }
                .map { TemplateDTO(name: $0.name, itemCount: ($0.items ?? []).count) }
        }
    }

    // MARK: - Writes

    static func createTrip(_ input: CreateTripInput) throws -> TripDTO {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw APIError.emptyValue(field: "title") }
        guard input.endDate >= input.startDate else { throw APIError.invalidDateRange }

        return try mutate { context in
            let trip = Trip(
                title: title, startDate: input.startDate, endDate: input.endDate,
                notes: input.notes ?? "")
            context.insert(trip)
            return TripDTO(trip)
        }
    }

    /// Changes a trip's title or dates. `nil` leaves a field alone.
    static func updateTrip(tripID: String? = nil, _ input: TripUpdateInput) throws -> TripDTO {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            if let title = input.title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw APIError.emptyValue(field: "title") }
                trip.title = trimmed
            }
            // Validated against whatever the *other* end will be after this call,
            // so moving a trip one date at a time can't be rejected halfway.
            let start = input.startDate ?? trip.startDate
            let end = input.endDate ?? trip.endDate
            guard end >= start else { throw APIError.invalidDateRange }
            trip.startDate = start
            trip.endDate = end
            return TripDTO(trip)
        }
    }

    /// Deletes a trip and everything cascading from it. Reports what went, since
    /// there is no undo to fall back on.
    static func deleteTrip(tripID: String) throws -> DeletionDTO {
        try mutate { context in
            let trip = try findTrip(tripID, in: context)
            let label = trip.title.isEmpty ? "Untitled trip" : trip.title
            context.delete(trip)
            return DeletionDTO(kind: "trip", id: tripID, label: label)
        }
    }

    /// Edits existing stops — where flight numbers, notes and addresses go once a
    /// trip is roughed out. Batched, and every field optional, so a caller can set
    /// one thing on several stops in a single write.
    static func updateStops(_ updates: [StopUpdateInput]) throws -> [StopDTO] {
        try mutate { context in
            var touched: [ItineraryItem] = []
            for update in updates {
                let stop = try findStop(update.id, in: context)
                if let title = update.title {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw APIError.emptyValue(field: "stop title") }
                    stop.title = trimmed
                }
                if let detail = update.detail { stop.detail = detail }
                if let note = update.note { stop.note = note }
                if let transportDetail = update.transportDetail {
                    stop.transportDetail = transportDetail
                }
                if update.clearDate == true { stop.date = nil } else if let date = update.date {
                    stop.date = date
                }
                if update.clearCountry == true {
                    stop.country = nil
                } else if let country = update.country {
                    stop.country = try CountryResolver.require(country, in: context)
                }
                if update.clearTransport == true {
                    stop.transport = nil
                } else if let transport = update.transport {
                    guard let mode = TransportMode(rawValue: transport) else {
                        throw APIError.badValue(
                            field: "transport", value: transport,
                            allowed: TransportMode.allCases.map(\.rawValue))
                    }
                    stop.transport = mode
                }
                if let latitude = update.latitude { stop.latitude = latitude }
                if let longitude = update.longitude { stop.longitude = longitude }
                touched.append(stop)
            }
            // Indices come from each stop's own trip, so they stay meaningful even
            // when the batch spans more than one journey.
            return touched.map { stop in
                let siblings = stop.trip?.sortedStops ?? []
                return StopDTO(stop, index: siblings.firstIndex(of: stop) ?? 0)
            }
        }
    }

    static func deleteStops(stopIDs: [String]) throws -> [DeletionDTO] {
        try mutate { context in
            try stopIDs.map { id in
                let stop = try findStop(id, in: context)
                let label = stop.displayTitle
                context.delete(stop)
                return DeletionDTO(kind: "stop", id: id, label: label)
            }
        }
    }

    /// Rearranges a trip's itinerary. `stopIDs` is the new order; any stop left out
    /// keeps its relative position after the ones named, so a caller can move a
    /// couple of stops without listing the whole trip.
    static func reorderStops(tripID: String? = nil, stopIDs: [String]) throws -> [StopDTO] {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            trip.assignStopIDs()

            var remaining = trip.sortedStops
            var ordered: [ItineraryItem] = []
            for id in stopIDs {
                guard let index = remaining.firstIndex(where: { $0.dedupID == id }) else {
                    throw APIError.stopNotFound(id)
                }
                ordered.append(remaining.remove(at: index))
            }
            for (index, stop) in (ordered + remaining).enumerated() { stop.order = index }
            return TripDetailDTO(trip).stops
        }
    }

    /// Edits packing items — rename, re-count, move between bags, tick off.
    static func updatePackingItems(_ updates: [PackingItemUpdateInput]) throws -> [PackingItemDTO] {
        try mutate { context in
            var cache: [String: PackingContainer] = [:]
            return try updates.map { update in
                let item = try findPackingItem(update.id, in: context)
                if let title = update.title {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw APIError.emptyValue(field: "title") }
                    item.title = trimmed
                }
                if let quantity = update.quantity { item.quantity = max(1, quantity) }
                if let isPacked = update.isPacked { item.isPacked = isPacked }
                if update.clearContainer == true {
                    item.container = nil
                } else if let container = update.container {
                    item.container = try resolveContainer(
                        named: container, in: context, cache: &cache)
                }
                return PackingItemDTO(item)
            }
        }
    }

    static func deletePackingItems(itemIDs: [String]) throws -> [DeletionDTO] {
        try mutate { context in
            try itemIDs.map { id in
                let item = try findPackingItem(id, in: context)
                let label = item.title
                context.delete(item)
                return DeletionDTO(kind: "packingItem", id: id, label: label)
            }
        }
    }

    // MARK: - Notes by section

    /// Creates or replaces one `# Heading` section of a trip's notes, leaving every
    /// other section byte for byte as it was.
    ///
    /// This is what `set_trip_notes` couldn't do: rewriting "Budget" through the
    /// raw-text tool means reading the whole note, splicing, and writing it back —
    /// three chances to lose the traveller's own prose. `NoteSection.parse` and
    /// `.serialize` are exact inverses, so a section swap here is lossless.
    static func setNoteSection(
        tripID: String? = nil, heading: String, body: String, mode: TextMode = .replace
    ) throws -> TripNotesChangeDTO {
        let title = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw APIError.emptyValue(field: "heading") }

        return try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            let previous = trip.notes
            var sections = NoteSection.parse(previous)

            if let index = sections.firstIndex(where: { $0.title?.lowercased() == title.lowercased() }) {
                sections[index].body =
                    mode == .append && !sections[index].isBodyBlank
                    ? sections[index].body + "\n\n" + body
                    : body
            } else {
                // A brand-new section goes at the end, where a person writing the
                // note by hand would have put it.
                sections.append(NoteSection(title: title, bodyLines: body.components(separatedBy: "\n")))
            }
            trip.notes = NoteSection.serialize(sections)
            return TripNotesChangeDTO(trip: TripDTO(trip), previousNotes: previous)
        }
    }

    static func deleteNoteSection(tripID: String? = nil, heading: String) throws
        -> TripNotesChangeDTO
    {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            let previous = trip.notes
            var sections = NoteSection.parse(previous)
            guard
                let index = sections.firstIndex(where: {
                    $0.title?.lowercased() == heading.lowercased()
                })
            else {
                throw APIError.noteSectionNotFound(
                    heading, available: sections.compactMap(\.title))
            }
            sections.remove(at: index)
            trip.notes = NoteSection.serialize(sections)
            return TripNotesChangeDTO(trip: TripDTO(trip), previousNotes: previous)
        }
    }

    /// Appends stops in array order. Batched on purpose: an itinerary is written
    /// once, and one call means one save, one widget refresh, one CloudKit push.
    static func addStops(tripID: String? = nil, stops: [StopInput]) throws -> [StopDTO] {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            trip.assignStopIDs()
            var order = nextOrder(trip.itinerary, \.order)
            for input in stops {
                let stop = try makeStop(input, order: order, trip: trip, in: context)
                context.insert(stop)
                order += 1
            }
            // Read back off the relationship rather than trusting the local array,
            // so the indices in the result match what a later `get_trip` reports.
            return TripDetailDTO(trip).stops
        }
    }

    /// Appends packing items, skipping titles already on the list
    /// (case-insensitive) exactly as the template/copy paths in the UI do.
    /// Returns only the items actually created — a shorter array than the input
    /// means duplicates were dropped.
    static func addPackingItems(tripID: String? = nil, items: [PackingItemInput]) throws
        -> [PackingItemDTO]
    {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            return try appendPacking(items, to: trip, in: context)
        }
    }

    static func setPacked(itemIDs: [String], isPacked: Bool) throws -> [PackingItemDTO] {
        try mutate { context in
            let all = try context.fetch(FetchDescriptor<PackingItem>())
            return try itemIDs.map { id in
                guard let item = all.first(where: { $0.dedupID == id }) else {
                    throw APIError.packingItemNotFound(id)
                }
                item.isPacked = isPacked
                return PackingItemDTO(item)
            }
        }
    }

    static func setTripNotes(tripID: String? = nil, notes: String, mode: TextMode = .replace) throws
        -> TripNotesChangeDTO
    {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            let previous = trip.notes
            switch mode {
            case .replace:
                trip.notes = notes
            case .append:
                // A blank line between, so an appended `# Heading` still opens a
                // section rather than running into the previous paragraph — see
                // `NoteSection.parse`.
                trip.notes = previous.isEmpty ? notes : previous + "\n\n" + notes
            }
            return TripNotesChangeDTO(trip: TripDTO(trip), previousNotes: previous)
        }
    }

    /// Sets either axis of a country's state; `nil` leaves that axis alone. The
    /// two are independent — a country can be visited *and* on the wishlist.
    static func setCountryStatus(country: String, status: String? = nil, plan: String? = nil) throws
        -> CountryChangeDTO
    {
        let newStatus = try status.map { try parse([$0], as: CountryStatus.self, field: "status")[0] }
        let newPlan = try plan.map { try parse([$0], as: PlanStatus.self, field: "plan")[0] }

        return try mutate { context in
            let model = try CountryResolver.require(country, in: context)
            let previousStatus = model.status
            let previousPlan = model.planStatus
            if let newStatus {
                model.status = newStatus
                // Whatever set this, it wasn't the photo importer — so a re-scan
                // must not clear it. `MarkCountryStatusIntent` enforces the same.
                model.statusIsImported = false
            }
            if let newPlan { model.planStatus = newPlan }
            return CountryChangeDTO(
                country: CountryDTO(model),
                previousStatus: previousStatus.rawValue,
                previousPlan: previousPlan.rawValue)
        }
    }

    static func logVisit(country: String, date: Date? = nil, notes: String = "") throws
        -> VisitResultDTO
    {
        try mutate { context in
            let model = try CountryResolver.require(country, in: context)
            let visitDate = date ?? Date()
            context.insert(Visit(date: visitDate, notes: notes, country: model, isImported: false))

            // An untouched country becomes "visited" the moment a visit lands on
            // it; a stronger bond (lived/living) is left alone.
            let promoted = model.status == .notVisited
            if promoted {
                model.status = .visited
                model.statusIsImported = false
            }
            return VisitResultDTO(
                country: CountryDTO(model), visitDate: visitDate, statusPromoted: promoted)
        }
    }

    static func applyPackingTemplate(tripID: String? = nil, template: String) throws
        -> [PackingItemDTO]
    {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            return try applyTemplate(named: template, to: trip, in: context)
        }
    }

    // MARK: - Links, contacts, attachments

    /// Adds web links to a trip, or to one of its stops when `stopID` is set —
    /// a booking page on the hotel stop, a timetable on the whole journey.
    static func addLinks(tripID: String? = nil, links: [LinkInput]) throws -> [LinkDTO] {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            var order = nextOrder(trip.links, \.order)
            return try links.map { input in
                let url = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { throw APIError.emptyValue(field: "url") }
                let link = TripLink(
                    title: input.title ?? "", url: url, order: order, trip: trip,
                    item: try input.stopID.map { try findStop($0, in: context) })
                // A URL the app can't open would render as dead text everywhere it
                // appears, so it's rejected here rather than stored.
                guard link.resolvedURL != nil else {
                    throw APIError.badData(field: "url", reason: "'\(url)' isn't a usable URL.")
                }
                context.insert(link)
                order += 1
                return LinkDTO(link)
            }
        }
    }

    /// Adds people or desks to reach — trip-wide, or pinned to a stop.
    static func addContacts(tripID: String? = nil, contacts: [ContactInput]) throws -> [ContactDTO] {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            var order = nextOrder(trip.contacts, \.order)
            return try contacts.map { input in
                let value = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { throw APIError.emptyValue(field: "value") }
                let kind: ContactKind
                if let raw = input.kind {
                    guard let parsed = ContactKind(rawValue: raw) else {
                        throw APIError.badValue(
                            field: "kind", value: raw,
                            allowed: ContactKind.allCases.map(\.rawValue))
                    }
                    kind = parsed
                } else {
                    kind = .phone
                }
                let contact = TripContact(
                    name: input.name, value: value, kind: kind, order: order, trip: trip,
                    item: try input.stopID.map { try findStop($0, in: context) })
                context.insert(contact)
                order += 1
                return ContactDTO(contact)
            }
        }
    }

    /// Largest file accepted, in megabytes. The bytes arrive base64-encoded inside
    /// a JSON message, so this bounds the message too — big enough for boarding
    /// passes, tickets and scans, which is what actually gets attached.
    static let attachmentSizeLimitMB = 10

    /// Attaches a file to a trip or one of its stops. The content comes in
    /// base64: the app is sandboxed and cannot read a path on the caller's behalf,
    /// so whoever has the file has to send it.
    static func addAttachments(tripID: String? = nil, attachments: [AttachmentInput]) throws
        -> [AttachmentDTO]
    {
        try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            var order = nextOrder(trip.attachments, \.order)
            return try attachments.map { input in
                let filename = input.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !filename.isEmpty else { throw APIError.emptyValue(field: "filename") }
                guard let data = Data(base64Encoded: input.dataBase64, options: .ignoreUnknownCharacters)
                else {
                    throw APIError.badData(field: "dataBase64", reason: "not valid base64.")
                }
                guard data.count <= attachmentSizeLimitMB * 1_000_000 else {
                    throw APIError.attachmentTooLarge(megabytes: attachmentSizeLimitMB)
                }
                let attachment = TripAttachment(
                    filename: filename, data: data, order: order, trip: trip,
                    caption: input.caption ?? "",
                    item: try input.stopID.map { try findStop($0, in: context) })
                context.insert(attachment)
                order += 1
                return AttachmentDTO(attachment)
            }
        }
    }

    /// Removes links, contacts and attachments by id. One entry point for all
    /// three because their ids are drawn from the same space and a caller holding
    /// one from `get_trip` shouldn't have to work out which kind it is.
    static func deleteTripItems(itemIDs: [String]) throws -> [DeletionDTO] {
        try mutate { context in
            let links = try context.fetch(FetchDescriptor<TripLink>())
            let contacts = try context.fetch(FetchDescriptor<TripContact>())
            let attachments = try context.fetch(FetchDescriptor<TripAttachment>())

            return try itemIDs.map { id in
                if let link = links.first(where: { $0.dedupID == id }) {
                    let label = link.displayTitle
                    context.delete(link)
                    return DeletionDTO(kind: "link", id: id, label: label)
                }
                if let contact = contacts.first(where: { $0.dedupID == id }) {
                    let label = contact.displayName
                    context.delete(contact)
                    return DeletionDTO(kind: "contact", id: id, label: label)
                }
                if let attachment = attachments.first(where: { $0.dedupID == id }) {
                    let label = attachment.filename
                    context.delete(attachment)
                    return DeletionDTO(kind: "attachment", id: id, label: label)
                }
                throw APIError.itemNotFound(id)
            }
        }
    }

    // MARK: - Containers and templates

    static func createContainer(name: String, symbolName: String? = nil) throws -> ContainerDTO {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.emptyValue(field: "name") }
        return try mutate { context in
            var cache: [String: PackingContainer] = [:]
            guard let container = try resolveContainer(named: trimmed, in: context, cache: &cache)
            else { throw APIError.emptyValue(field: "name") }
            if let symbolName { container.symbolName = symbolName }
            return ContainerDTO(container)
        }
    }

    /// Renames a container everywhere at once — it's a shared catalog, so every
    /// trip filing items into it follows automatically.
    static func renameContainer(name: String, newName: String) throws -> ContainerDTO {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.emptyValue(field: "newName") }
        return try mutate { context in
            let container = try requireContainer(named: name, in: context)
            container.name = trimmed
            return ContainerDTO(container)
        }
    }

    /// Deletes a container. Its items survive, ungrouped — the model's `.nullify`
    /// rule, and the same thing the app's own container editor does.
    static func deleteContainer(name: String) throws -> DeletionDTO {
        try mutate { context in
            let container = try requireContainer(named: name, in: context)
            let label = container.name
            let id = container.dedupID
            context.delete(container)
            return DeletionDTO(kind: "container", id: id, label: label)
        }
    }

    /// Saves a trip's packing list as a reusable template, storing each item's
    /// container by name so the template stays portable.
    static func savePackingTemplate(tripID: String? = nil, name: String) throws -> TemplateDTO {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.emptyValue(field: "name") }
        return try mutate { context in
            let trip = try resolveTrip(tripID, in: context)
            let existing = try context.fetch(FetchDescriptor<PackingTemplate>())
            // Saving over a name replaces it, which is what "save as" means to the
            // person doing it — two templates with one name would be unusable.
            if let previous = existing.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                context.delete(previous)
            }
            let template = PackingTemplate(name: trimmed)
            context.insert(template)
            for (index, item) in trip.packingGroups.flatMap(\.items).enumerated() {
                context.insert(
                    PackingTemplateItem(
                        title: item.title, quantity: item.quantity, order: index,
                        containerName: item.container?.name ?? "", template: template))
            }
            return TemplateDTO(name: trimmed, itemCount: (trip.packing ?? []).count)
        }
    }

    static func deletePackingTemplate(name: String) throws -> DeletionDTO {
        try mutate { context in
            let templates = try context.fetch(FetchDescriptor<PackingTemplate>())
            guard let template = templates.first(where: { $0.name.lowercased() == name.lowercased() })
            else {
                throw APIError.templateNotFound(name, available: templates.map(\.name).sorted())
            }
            let id = template.dedupID
            context.delete(template)
            return DeletionDTO(kind: "packingTemplate", id: id, label: template.name)
        }
    }

    // MARK: - Visits

    /// Recorded visits, newest first.
    ///
    /// All three filters are optional and combine. Without `country` this spans
    /// every country, which is what makes "where did I go in 2024?" a single call —
    /// it used to require asking about each of 239 countries in turn.
    static func listVisits(
        country: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 100
    ) throws -> [VisitDTO] {
        try read { context in
            let countries =
                if let country {
                    [try CountryResolver.require(country, in: context)]
                } else {
                    try context.fetch(FetchDescriptor<Country>()).filter { !($0.visits ?? []).isEmpty }
                }

            var assigned = false
            var visits: [(Visit, String)] = []
            for model in countries {
                if model.assignVisitIDs() { assigned = true }
                for visit in model.visits ?? [] {
                    if let from, visit.date < from { continue }
                    if let to, visit.date > to { continue }
                    visits.append((visit, model.id))
                }
            }
            if assigned { try context.save() }

            return visits
                .sorted { $0.0.date > $1.0.date }
                .prefix(max(1, limit))
                .map { VisitDTO($0.0, country: $0.1) }
        }
    }

    /// Every badge with its progress, derived from the same `TravelStats` the
    /// dashboard uses — so what a caller reports and what the app shows can't drift.
    static func listAchievements() throws -> [AchievementDTO] {
        try read { context in
            let stats = TravelStats(countries: try context.fetch(FetchDescriptor<Country>()))
            return Achievement.all(for: stats).map(AchievementDTO.init)
        }
    }

    /// Where to go next: either the nearest unvisited countries, or ones that fill
    /// gaps in continents already started.
    static func suggestCountries(mode: CountrySuggestionMode = .nearest, limit: Int = 5) throws
        -> [CountrySuggestionDTO]
    {
        try read { context in
            let countries = try context.fetch(FetchDescriptor<Country>())
            let centroids = countryCentroids()
            guard !centroids.isEmpty else { return [] }
            let ranked =
                switch mode {
                case .nearest:
                    nearestUnvisited(countries: countries, centroids: centroids, limit: max(1, limit))
                case .gaps:
                    unvisitedFillingGaps(
                        countries: countries, centroids: centroids, limit: max(1, limit))
                }
            return ranked.map {
                CountrySuggestionDTO(
                    id: $0.country.id, name: $0.country.name, continent: $0.country.continent,
                    distanceKM: Int($0.distanceKM.rounded()), plan: $0.country.planStatus.rawValue)
            }
        }
    }

    /// Country centroids, decoded once and kept.
    ///
    /// Only the raw ring decode is needed — a min/max pass per country — not the
    /// polygon, path and hit-rect construction the map pays for. That keeps this
    /// off the launch path entirely: nothing loads until something asks where to
    /// go next.
    private static var cachedCentroids: [String: CLLocationCoordinate2D]?

    private static func countryCentroids() -> [String: CLLocationCoordinate2D] {
        if let cachedCentroids { return cachedCentroids }
        guard let geo = loadBundledGeo() else { return [:] }
        var result: [String: CLLocationCoordinate2D] = [:]
        for (id, rings) in geo.rings {
            var minX = Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude
            for ring in rings {
                for point in ring {
                    minX = min(minX, point.x)
                    minY = min(minY, point.y)
                    maxX = max(maxX, point.x)
                    maxY = max(maxY, point.y)
                }
            }
            guard minX <= maxX else { continue }
            result[id] = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2).coordinate
        }
        cachedCentroids = result
        return result
    }

    /// What Settings knows about how the traveller wants trips planned.
    ///
    /// The gender-derived hint is withheld unless `includePersonal` — see
    /// `TravelerProfileDTO` for why that one is treated differently from the two
    /// free-text fields beside it.
    static func getTravelerProfile(includePersonal: Bool = false) -> TravelerProfileDTO {
        let defaults = UserDefaults.standard
        let profile =
            PackingProfile(rawValue: defaults.string(forKey: TripPlanner.profileKey) ?? "")
            ?? .unspecified
        return TravelerProfileDTO(
            sightseeingInterests: (defaults.string(forKey: TripPlanner.interestsKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            packingPreferences: (defaults.string(forKey: TripPlanner.preferencesKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            packingProfileHint: includePersonal ? profile.promptHint : nil,
            redacted: includePersonal ? [] : ["packingProfileHint"])
    }

    /// Sets status and/or plan on several countries at once — "mark Spain,
    /// Portugal and Morocco as visited" in one write rather than three.
    static func setCountryStatuses(_ inputs: [CountryStatusInput]) throws -> [CountryChangeDTO] {
        try mutate { context in
            try inputs.map { input in
                let model = try CountryResolver.require(input.country, in: context)
                let previousStatus = model.status
                let previousPlan = model.planStatus
                if let status = input.status {
                    guard let parsed = CountryStatus(rawValue: status) else {
                        throw APIError.badValue(
                            field: "status", value: status,
                            allowed: CountryStatus.allCases.map(\.rawValue))
                    }
                    model.status = parsed
                    model.statusIsImported = false
                }
                if let plan = input.plan {
                    guard let parsed = PlanStatus(rawValue: plan) else {
                        throw APIError.badValue(
                            field: "plan", value: plan,
                            allowed: PlanStatus.allCases.map(\.rawValue))
                    }
                    model.planStatus = parsed
                }
                return CountryChangeDTO(
                    country: CountryDTO(model), previousStatus: previousStatus.rawValue,
                    previousPlan: previousPlan.rawValue)
            }
        }
    }

    static func updateVisits(_ updates: [VisitUpdateInput]) throws -> [VisitDTO] {
        try mutate { context in
            try updates.map { update in
                let visit = try findVisit(update.id, in: context)
                if let date = update.date { visit.date = date }
                if let notes = update.notes { visit.notes = notes }
                return VisitDTO(visit, country: visit.country?.id ?? "")
            }
        }
    }

    /// Deletes visits. The country's status is deliberately left alone — someone
    /// removing a mis-dated visit from a country they've been to twice hasn't
    /// stopped having been there.
    static func deleteVisits(visitIDs: [String]) throws -> [DeletionDTO] {
        try mutate { context in
            try visitIDs.map { id in
                let visit = try findVisit(id, in: context)
                let label =
                    "\(visit.country?.name ?? "Unknown"), \(visit.date.formatted(date: .abbreviated, time: .omitted))"
                context.delete(visit)
                return DeletionDTO(kind: "visit", id: id, label: label)
            }
        }
    }

    private static func requireContainer(named name: String, in context: ModelContext) throws
        -> PackingContainer
    {
        let all = try context.fetch(FetchDescriptor<PackingContainer>())
        guard let match = all.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw APIError.containerNotFound(name, available: all.map(\.name).sorted())
        }
        return match
    }

    // MARK: - Composite

    /// Builds a whole trip in one atomic write.
    ///
    /// The reason this exists rather than leaving callers to chain the granular
    /// calls: a planned journey is five operations, and chaining them means five
    /// saves, five CloudKit pushes, and a half-built trip stranded in the store if
    /// the caller stops after the third. Here the trip either lands complete or
    /// the throw unwinds before any save happens.
    static func planTrip(_ input: PlanTripInput) throws -> TripDetailDTO {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw APIError.emptyValue(field: "title") }
        guard input.endDate >= input.startDate else { throw APIError.invalidDateRange }

        return try mutate { context in
            let trip = Trip(
                title: title, startDate: input.startDate, endDate: input.endDate,
                notes: input.notes ?? "")
            context.insert(trip)

            var order = 0
            for stopInput in input.stops ?? [] {
                context.insert(try makeStop(stopInput, order: order, trip: trip, in: context))
                order += 1
            }

            // Template first, then the explicit list on top — so a caller can lean
            // on the traveller's saved list and still add trip-specific items,
            // with the dedupe in `appendPacking` keeping overlaps from doubling up.
            if let templateName = input.packingTemplate {
                _ = try applyTemplate(named: templateName, to: trip, in: context)
            }
            if let packing = input.packing {
                _ = try appendPacking(packing, to: trip, in: context)
            }

            // What makes the map light up when a trip is planned.
            if input.markCountriesPlanning ?? true {
                for country in trip.countries where country.planStatus == .none {
                    country.planStatus = .planning
                }
            }
            return TripDetailDTO(trip)
        }
    }

    // MARK: - Shared write helpers

    private static func makeStop(
        _ input: StopInput, order: Int, trip: Trip, in context: ModelContext
    ) throws -> ItineraryItem {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw APIError.emptyValue(field: "stop title") }

        let stop = ItineraryItem(
            title: title, note: input.note ?? "", date: input.date, order: order,
            country: try input.country.map { try CountryResolver.require($0, in: context) },
            trip: trip, detail: input.detail ?? "",
            latitude: input.latitude, longitude: input.longitude)
        stop.dedupID = UUID().uuidString
        if let transport = input.transport {
            guard let mode = TransportMode(rawValue: transport) else {
                throw APIError.badValue(
                    field: "transport", value: transport,
                    allowed: TransportMode.allCases.map(\.rawValue))
            }
            stop.transport = mode
        }
        stop.transportDetail = input.transportDetail ?? ""
        return stop
    }

    private static func appendPacking(
        _ items: [PackingItemInput], to trip: Trip, in context: ModelContext
    ) throws -> [PackingItemDTO] {
        var existing = Set((trip.packing ?? []).map { $0.title.lowercased() })
        var cache: [String: PackingContainer] = [:]
        var order = nextOrder(trip.packing, \.order)
        var created: [PackingItemDTO] = []

        for input in items {
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = title.lowercased()
            guard !key.isEmpty, !existing.contains(key) else { continue }
            existing.insert(key)

            let item = PackingItem(
                title: title, quantity: max(1, input.quantity ?? 1), order: order, trip: trip)
            item.container = try resolveContainer(
                named: input.container ?? "", in: context, cache: &cache)
            context.insert(item)
            order += 1
            created.append(PackingItemDTO(item))
        }
        return created
    }

    private static func applyTemplate(
        named name: String, to trip: Trip, in context: ModelContext
    ) throws -> [PackingItemDTO] {
        let templates = try context.fetch(FetchDescriptor<PackingTemplate>())
        let folded = name.lowercased()
        guard let template = templates.first(where: { $0.name.lowercased() == folded }) else {
            throw APIError.templateNotFound(name, available: templates.map(\.name).sorted())
        }
        return try appendPacking(
            (template.items ?? []).sorted { $0.order < $1.order }
                .map {
                    PackingItemInput(
                        title: $0.title, quantity: $0.quantity, container: $0.containerName)
                },
            to: trip, in: context)
    }

    /// Parses raw enum values, reporting the allowed set on failure so a caller
    /// that guessed can correct itself without a round trip through the docs.
    private static func parse<E: RawRepresentable & CaseIterable>(
        _ values: [String], as type: E.Type, field: String
    ) throws -> [E] where E.RawValue == String {
        try values.map { value in
            guard let parsed = E(rawValue: value) else {
                throw APIError.badValue(
                    field: field, value: value, allowed: E.allCases.map(\.rawValue))
            }
            return parsed
        }
    }
}

// MARK: - Model → DTO

extension TripDTO {
    init(_ trip: Trip) {
        let phase = trip.phase()
        self.init(
            id: trip.dedupID,
            title: trip.title,
            startDate: trip.startDate,
            endDate: trip.endDate,
            notes: trip.notes,
            countries: trip.countries.map(\.id),
            phase: {
                switch phase {
                case .upcoming: "upcoming"
                case .underway: "underway"
                case .past: "past"
                }
            }(),
            daysAway: { if case .upcoming(let days) = phase { days } else { nil } }(),
            day: { if case .underway(let day, _) = phase { day } else { nil } }(),
            dayCount: { if case .underway(_, let count) = phase { count } else { nil } }(),
            stopCount: (trip.itinerary ?? []).count,
            packedCount: trip.packedCount,
            packingTotal: (trip.packing ?? []).count)
    }
}

extension StopDTO {
    init(_ stop: ItineraryItem, index: Int) {
        self.init(
            id: stop.dedupID,
            index: index,
            title: stop.displayTitle,
            detail: stop.detail,
            note: stop.note,
            date: stop.date,
            country: stop.country?.id,
            transport: stop.transport?.rawValue,
            transportDetail: stop.transportDetail,
            latitude: stop.latitude,
            longitude: stop.longitude,
            stayDays: stop.stayDayCount)
    }
}

extension PackingItemDTO {
    init(_ item: PackingItem) {
        self.init(
            id: item.dedupID,
            title: item.title,
            quantity: item.quantity,
            isPacked: item.isPacked,
            container: item.container?.name)
    }
}

extension LinkDTO {
    init(_ link: TripLink) {
        self.init(
            id: link.dedupID, title: link.displayTitle, url: link.url,
            stopID: link.item?.dedupID)
    }
}

extension ContactDTO {
    init(_ contact: TripContact) {
        self.init(
            id: contact.dedupID, name: contact.displayName, kind: contact.contactKind.rawValue,
            value: contact.value, stopID: contact.item?.dedupID)
    }
}

extension AttachmentDTO {
    init(_ attachment: TripAttachment) {
        self.init(
            id: attachment.dedupID, filename: attachment.filename, caption: attachment.caption,
            byteCount: attachment.byteCount, stopID: attachment.item?.dedupID)
    }
}

extension VisitDTO {
    init(_ visit: Visit, country: String) {
        self.init(
            id: visit.dedupID, country: country, date: visit.date, notes: visit.notes,
            isImported: visit.isImported, photoCount: visit.photoIdentifiers.count)
    }
}

extension ContainerDTO {
    init(_ container: PackingContainer) {
        self.init(
            name: container.name, symbolName: container.symbolName,
            itemCount: (container.items ?? []).count)
    }
}

extension TripDetailDTO {
    init(_ trip: Trip, includePersonal: Bool = true) {
        let stops = trip.sortedStops
        self.init(
            trip: TripDTO(trip),
            stops: stops.enumerated().map { StopDTO($1, index: $0) },
            packing: trip.packingGroups.flatMap(\.items).map(PackingItemDTO.init),
            links: trip.sortedLinks.map(LinkDTO.init),
            // Contacts are phone numbers and addresses; a filename like
            // "passport-scan.pdf" tells you plenty on its own. Both wait for
            // consent — links don't, being public pages the traveller saved.
            contacts: includePersonal ? trip.sortedContacts.map(ContactDTO.init) : [],
            attachments: includePersonal ? trip.sortedAttachments.map(AttachmentDTO.init) : [],
            // The lead chunk of a note that opens with prose has no heading and is
            // often blank; carrying it would just be noise in the result.
            noteSections: NoteSection.parse(trip.notes)
                .filter { $0.title != nil || !$0.isBodyBlank }
                .map { NoteSectionDTO(heading: $0.title, body: $0.body) },
            redacted: includePersonal
                ? []
                : [
                    trip.sortedContacts.isEmpty ? nil : "contacts",
                    trip.sortedAttachments.isEmpty ? nil : "attachments",
                ].compactMap { $0 })
    }
}

extension AchievementDTO {
    init(_ achievement: Achievement) {
        self.init(
            id: achievement.id, category: achievement.category.rawValue,
            title: achievement.title, detail: achievement.detail,
            isUnlocked: achievement.isUnlocked, progress: achievement.progress)
    }
}

extension CountryDTO {
    init(_ country: Country) {
        let dates = (country.visits ?? []).map(\.date).sorted()
        self.init(
            id: country.id,
            name: country.name,
            continent: country.continent,
            status: country.status.rawValue,
            plan: country.planStatus.rawValue,
            visitCount: dates.count,
            firstVisit: dates.first,
            lastVisit: dates.last)
    }
}

extension FactsDTO {
    init(_ facts: CountryFacts, country: String) {
        self.init(
            country: country,
            currency: facts.currency,
            languages: facts.languages,
            plugTypes: facts.plugTypes,
            drivingSide: facts.drivingSide.rawValue,
            emergencyNumber: facts.emergencyNumber)
    }
}

extension StatsDTO {
    init(_ stats: TravelStats) {
        self.init(
            visitedCountries: stats.visitedCountries,
            totalCountries: stats.totalCountries,
            visitedContinents: stats.visitedContinents,
            totalContinents: stats.totalContinents,
            totalVisits: stats.totalVisits,
            statusCounts: Dictionary(
                uniqueKeysWithValues: stats.statusCounts.map { ($0.key.rawValue, $0.value) }),
            planCounts: Dictionary(
                uniqueKeysWithValues: stats.planCounts.map { ($0.key.rawValue, $0.value) }),
            continents: stats.continents.map {
                ContinentStatDTO(name: $0.name, visited: $0.visited, total: $0.total)
            },
            years: stats.years.map {
                YearStatDTO(year: $0.year, visits: $0.visits, countries: $0.countries)
            },
            firstVisit: stats.firstVisitDate,
            lastVisit: stats.lastVisitDate)
    }
}
