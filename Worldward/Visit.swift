/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftData

@Model
final class Visit {
    var date: Date = Date()
    var notes: String = ""
    var country: Country?

    /// `true` when this visit was created by the photo importer rather than
    /// entered by hand. Lets the importer rewrite or clear its own data on a
    /// re-scan without disturbing visits the user added manually.
    var isImported: Bool = false

    /// Stable PhotoKit `localIdentifier`s of the photos behind this visit, capped
    /// during import. Used to re-fetch thumbnails from the photo library on demand
    /// without ever storing the image data itself.
    var photoIdentifiers: [String] = []

    /// Per-row token for CloudKit de-duplication, mirroring `Country.dedupID`, and
    /// the stable handle anything outside the app uses to name one visit.
    ///
    /// Defaults to `""` rather than a fresh UUID for the same reason as
    /// `ItineraryItem.dedupID`: lightweight migration applies a single default to
    /// every existing row, so a `UUID()` default would give every visit already in
    /// the store the same token. `Country.assignVisitIDs()` fills the blanks in
    /// when something first needs them.
    var dedupID: String = ""

    init(date: Date = Date(), notes: String = "", country: Country? = nil, isImported: Bool = false) {
        self.date = date
        self.notes = notes
        self.country = country
        self.isImported = isImported
    }
}
