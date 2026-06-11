import Foundation
import SwiftData

@Model
final class Country {
    @Attribute(.unique) var id: String // ISO 2
    var iso3: String
    var name: String
    var continent: String
    var flag: String
    
    var isVisited: Bool
    var visitDate: Date?
    var notes: String

    var flagEmoji: String {
        Country.flagEmoji(for: id)
    }
    
    init(id: String, iso3: String = "", name: String, continent: String = "Unknown", flag: String = "🏳️", isVisited: Bool = false, visitDate: Date? = nil, notes: String = "") {
        self.id = id
        self.iso3 = iso3
        self.name = name
        self.continent = continent
        self.flag = flag
        self.isVisited = isVisited
        self.visitDate = visitDate
        self.notes = notes
    }

    private static func flagEmoji(for countryCode: String) -> String {
        let scalars = countryCode
            .uppercased()
            .unicodeScalars
            .filter { $0.value >= 65 && $0.value <= 90 }

        guard scalars.count == 2 else { return "🏳️" }

        let regionalIndicatorBase: UInt32 = 127397
        let flagScalars = scalars.compactMap { UnicodeScalar(regionalIndicatorBase + $0.value) }
        return flagScalars.count == 2 ? String(String.UnicodeScalarView(flagScalars)) : "🏳️"
    }
}
