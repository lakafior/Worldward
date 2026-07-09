/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import CoreSpotlight
import SwiftData
import UniformTypeIdentifiers

/// A lightweight, `Codable` / `Sendable` representation of a `Country` suitable as
/// an `AppEntity`.  The struct carries only identity and display fields; the
/// underlying `@Model` object is fetched on demand by `CountryEntityQuery`.
///
/// Keying on the ISO alpha‑2 `id` keeps identities stable across launches and
/// import/export cycles — the same id that `TravelDataTransfer` already uses.
struct CountryEntity: IndexedEntity {

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

    /// `NSUserActivity` type used to advertise the country a person is currently
    /// viewing, so Siri and Apple Intelligence can answer questions about it
    /// ("have I been here?", "when did I visit?").
    static let viewingActivityType = "net.smigi.worldward.ViewingCountry"
}

// MARK: - Entity Query

struct CountryEntityQuery: EntityQuery {

    /// Look up a handful of countries by ISO id — used when a shortcut is run with
    /// a pre‑selected country.
    func entities(for identifiers: [CountryEntity.ID]) async throws -> [CountryEntity] {
        let context = await ModelContext(Worldward.sharedModelContainer)
        let all = try context.fetch(FetchDescriptor<Country>())
        return all.filter { identifiers.contains($0.id) }.map(CountryEntity.init)
    }

    /// Return every country for the Shortcuts picker, with visited countries first
    /// so the most relevant destinations are immediately visible.
    func suggestedEntities() async throws -> [CountryEntity] {
        let context = await ModelContext(Worldward.sharedModelContainer)
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

// MARK: - Spotlight indexing

extension CountryEntity {
    /// Augments the default (title/subtitle) attributes with keywords so a search
    /// for the country name or its continent surfaces the entry in Spotlight.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = "\(flagEmoji) \(name)"
        attributes.contentDescription = continent
        attributes.keywords = [name, continent, "country", "travel"]
        return attributes
    }
}

/// Publishes the country catalog to Spotlight so countries are findable in
/// system search and reasoned over by Apple Intelligence. Indexing is gated on a
/// signature (version + count) so the ~250-entry catalog is only re-indexed when
/// it actually changes, not on every launch.
enum CountrySpotlightIndexer {
    private static let stateKey = "CountrySpotlightIndexSignature"
    private static let version = 1

    @MainActor
    static func indexIfNeeded(_ countries: [Country]) async {
        let signature = version * 1_000_000 + countries.count
        guard UserDefaults.standard.integer(forKey: stateKey) != signature else { return }

        let entities = countries.map(CountryEntity.init(from:))
        do {
            try await CSSearchableIndex.default().indexAppEntities(entities)
            UserDefaults.standard.set(signature, forKey: stateKey)
        } catch {
            // Best-effort: a failure just leaves the signature unset, so the next
            // launch retries. Nothing user-facing depends on the index.
        }
    }
}
