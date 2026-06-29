import Foundation
import SwiftData

@Model
final class Country {
    /// ISO 3166-1 alpha-2 id. Not marked `@Attribute(.unique)` because CloudKit
    /// can't enforce uniqueness — `ContentView.deduplicateCountries` keeps the
    /// catalog single-per-id instead. Every stored property has a default value,
    /// another CloudKit requirement.
    var id: String = ""  // ISO 2
    var iso3: String = ""
    var name: String = ""
    var continent: String = "Unknown"

    /// Travel status persisted as a primitive `String`. A stored primitive
    /// migrates and observes reliably in SwiftData (a stored enum can crash on
    /// migration), while `status` exposes it as the typed enum.
    var statusRaw: String = CountryStatus.notVisited.rawValue

    /// `true` when the current `status` was assigned by the photo importer rather
    /// than set by hand. Lets an "Overwrite" re-scan clear statuses it previously
    /// imported (e.g. a country you no longer have photos from) without touching
    /// statuses the user chose manually.
    var statusIsImported: Bool = false

    /// The country's place in your travel *plans* (wishlist/planning), persisted as
    /// a primitive `String` for the same migration-safety reasons as `statusRaw`.
    /// Independent of `statusRaw` — a country can be both visited and planned.
    var planStatusRaw: String = PlanStatus.none.rawValue

    /// Legacy fields - kept for backward compatibility with existing data
    /// New code should use the `visits` relationship instead
    var visitDate: Date?
    var notes: String = ""

    @Relationship(deleteRule: .cascade, inverse: \Visit.country)
    var visits: [Visit] = []

    /// Inverse of `ItineraryItem.country` — the trip stops that take place in this
    /// country. `.nullify` so deleting a country (only happens during dedup) just
    /// clears the stop's country rather than deleting the stop.
    @Relationship(deleteRule: .nullify, inverse: \ItineraryItem.country)
    var itineraryItems: [ItineraryItem] = []

    /// A per-row token assigned once when the country is inserted. CloudKit can't
    /// enforce a unique `id`, so two devices that both seed offline produce two
    /// rows for the same ISO id. `deduplicateCountries` resolves that by keeping
    /// the row with the smallest `dedupID` — a value every device sees identically
    /// after sync, so they all converge on the same winner instead of each
    /// deleting a different copy.
    var dedupID: String = UUID().uuidString

    /// The country's travel status. Writing it updates `statusRaw`, which SwiftData
    /// persists and publishes — driving live map and list updates.
    var status: CountryStatus {
        get { CountryStatus(rawValue: statusRaw) ?? .notVisited }
        set { statusRaw = newValue.rawValue }
    }

    /// Convenience used by statistics and filtering. Reads the raw stored property
    /// directly so it can be `nonisolated` — SwiftData allows cross-actor reads of
    /// stored properties, but computed `status` is main-actor-only for its setter.
    nonisolated var isVisited: Bool { statusRaw != "notVisited" }

    /// The country's plan state. Writing it updates `planStatusRaw`, which SwiftData
    /// persists and publishes — driving live map, list, and stats updates.
    var planStatus: PlanStatus {
        get { PlanStatus(rawValue: planStatusRaw) ?? .none }
        set { planStatusRaw = newValue.rawValue }
    }

    /// Convenience used by the map's "Going" layer and the country list. Reads
    /// the raw stored property directly — same rationale as `isVisited`.
    nonisolated var isPlanned: Bool { planStatusRaw != "none" }

    /// Unicode flag derived from the ISO 3166-1 alpha-2 id, so it never needs storing.
    var flagEmoji: String {
        Country.flagEmoji(for: id)
    }

    init(
        id: String, iso3: String = "", name: String, continent: String = "Unknown",
        status: CountryStatus = .notVisited, visitDate: Date? = nil, notes: String = ""
    ) {
        self.id = id
        self.iso3 = iso3
        self.name = name
        self.continent = continent
        self.statusRaw = status.rawValue
        self.visitDate = visitDate
        self.notes = notes
    }

    private static func flagEmoji(for countryCode: String) -> String {
        let scalars =
            countryCode
            .uppercased()
            .unicodeScalars
            .filter { $0.value >= 65 && $0.value <= 90 }

        guard scalars.count == 2 else { return "🏳️" }

        let regionalIndicatorBase: UInt32 = 127397
        let flagScalars = scalars.compactMap { UnicodeScalar(regionalIndicatorBase + $0.value) }
        return flagScalars.count == 2 ? String(String.UnicodeScalarView(flagScalars)) : "🏳️"
    }
}
