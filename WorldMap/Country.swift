import Foundation
import SwiftData

@Model
final class Country {
    @Attribute(.unique) var id: String  // ISO 2
    var iso3: String
    var name: String
    var continent: String

    /// Travel status persisted as a primitive `String`. A stored primitive
    /// migrates and observes reliably in SwiftData (a stored enum can crash on
    /// migration), while `status` exposes it as the typed enum.
    var statusRaw: String

    var visitDate: Date?
    var notes: String

    /// The country's travel status. Writing it updates `statusRaw`, which SwiftData
    /// persists and publishes — driving live map and list updates.
    var status: CountryStatus {
        get { CountryStatus(rawValue: statusRaw) ?? .notVisited }
        set { statusRaw = newValue.rawValue }
    }

    /// Convenience used by statistics and filtering.
    var isVisited: Bool { status.isVisited }

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
