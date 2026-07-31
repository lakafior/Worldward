/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
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
    static func getTrip(id: String? = nil) throws -> TripDetailDTO {
        try read { context in
            let trip = try resolveTrip(id, in: context)
            try ensureStopIDs(trip, in: context)
            return TripDetailDTO(trip)
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
    static func listContainers() throws -> [String] {
        try read { context in
            try context.fetch(FetchDescriptor<PackingContainer>())
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.name)
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

extension TripDetailDTO {
    init(_ trip: Trip) {
        let stops = trip.sortedStops
        self.init(
            trip: TripDTO(trip),
            stops: stops.enumerated().map { StopDTO($1, index: $0) },
            packing: trip.packingGroups.flatMap(\.items).map(PackingItemDTO.init),
            links: trip.sortedLinks.map {
                LinkDTO(id: $0.dedupID, title: $0.displayTitle, url: $0.url, stopID: $0.item?.dedupID)
            },
            contacts: trip.sortedContacts.map {
                ContactDTO(
                    id: $0.dedupID, name: $0.displayName, kind: $0.contactKind.rawValue,
                    value: $0.value, stopID: $0.item?.dedupID)
            },
            documents: trip.sortedAttachments.map(\.filename))
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
