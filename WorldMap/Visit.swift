import Foundation
import SwiftData

@Model
final class Visit {
    var date: Date
    var notes: String
    var country: Country?

    init(date: Date = Date(), notes: String = "", country: Country? = nil) {
        self.date = date
        self.notes = notes
        self.country = country
    }
}
