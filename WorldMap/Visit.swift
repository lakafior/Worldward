import Foundation
import SwiftData

@Model
final class Visit {
    var date: Date
    var notes: String
    var country: Country?

    /// `true` when this visit was created by the photo importer rather than
    /// entered by hand. Lets the importer rewrite or clear its own data on a
    /// re-scan without disturbing visits the user added manually.
    var isImported: Bool = false

    init(date: Date = Date(), notes: String = "", country: Country? = nil, isImported: Bool = false) {
        self.date = date
        self.notes = notes
        self.country = country
        self.isImported = isImported
    }
}
