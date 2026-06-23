import AppIntents
import SwiftData

/// A lightweight, `Codable` / `Sendable` representation of a `Country` suitable as
/// an `AppEntity`.  The struct carries only identity and display fields; the
/// underlying `@Model` object is fetched on demand by `CountryEntityQuery`.
///
/// Keying on the ISO alpha‑2 `id` keeps identities stable across launches and
/// import/export cycles — the same id that `TravelDataTransfer` already uses.
struct CountryEntity: AppEntity {

    /// ISO 3166‑1 alpha‑2 code (e.g. "JP", "FR").  Stable, universal, and already
    /// the `Country.@Attribute(.unique)` key in SwiftData.
    let id: String

    /// Human‑readable name in English, as stored in SwiftData.
    let name: String

    /// Unicode flag derived from `id`, mirrored here so the entity can render its
    /// display representation without consulting SwiftData.
    let flagEmoji: String

    /// Continent name — used as the subtitle for disambiguation.
    let continent: String

    // ---- AppEntity conformance ----

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Country"
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: "\(flagEmoji) \(name)"),
            subtitle: LocalizedStringResource(stringLiteral: continent)
        )
    }

    static let defaultQuery = CountryEntityQuery()
}

// MARK: - Entity Query

struct CountryEntityQuery: EntityQuery {

    /// Look up a handful of countries by ISO id — used when a shortcut is run with
    /// a pre‑selected country.
    func entities(for identifiers: [CountryEntity.ID]) async throws -> [CountryEntity] {
        let context = ModelContext(WorldMap.sharedModelContainer)
        let all = try context.fetch(FetchDescriptor<Country>())
        return all.filter { identifiers.contains($0.id) }.map(CountryEntity.init)
    }

    /// Return every country for the Shortcuts picker, with visited countries first
    /// so the most relevant destinations are immediately visible.
    func suggestedEntities() async throws -> [CountryEntity] {
        let context = ModelContext(WorldMap.sharedModelContainer)
        let descriptor = FetchDescriptor<Country>(
            sortBy: [SortDescriptor(\.name)]
        )
        let countries = try context.fetch(descriptor)

        // Bubble visited countries to the top; within each group, alphabetical.
        let visited =
            countries
            .filter { $0.isVisited }
            .map(CountryEntity.init)

        let unvisited =
            countries
            .filter { !$0.isVisited }
            .map(CountryEntity.init)

        return visited + unvisited
    }
}

// MARK: - Mapping

extension CountryEntity {
    /// Convert a SwiftData `Country` into the lightweight entity.
    init(from country: Country) {
        self.id = country.id
        self.name = country.name
        self.flagEmoji = country.flagEmoji
        self.continent = country.continent
    }
}

// MARK: - Intent Notification Names

extension Notification.Name {
    /// Posted by `OpenTravelStatsIntent` when the app should navigate to Statistics.
    static let worldMapOpenStats = Notification.Name("WorldMapOpenStats")
    /// Posted by `OpenCountryMapIntent`; the notification's `object` carries the ISO alpha‑2 country id.
    static let worldMapOpenCountry = Notification.Name("WorldMapOpenCountry")
}
