import MapKit
import Photos
import SwiftData
import SwiftUI

/// How a re-scan reconciles photo data with what's already stored.
enum ImportScanMode: String, CaseIterable, Identifiable {
    case fillBlanks
    case overwrite
    case addNew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fillBlanks: "Fill blanks"
        case .overwrite:  "Overwrite"
        case .addNew:     "Add new only"
        }
    }

    var detail: String {
        switch self {
        case .fillBlanks: "Keep everything and add visits that aren't already recorded."
        case .overwrite:  "Replace previously imported visits; manual entries are kept."
        case .addNew:     "Only scan photos newer than the latest imported visit."
        }
    }
}

/// User-tunable settings for a photo import run.
struct ImportSettings {
    var scanMode: ImportScanMode = .fillBlanks
    /// Photos within this many days of each other belong to the same trip.
    var mergeGapDays: Int = 7
    /// A single trip lasting at least this many days promotes the country to `lived`.
    var livedThresholdDays: Int = 60
    /// When on, the country with the most days present is marked as home (`living`).
    var markHome: Bool = false
}

/// A single merged trip to one country, derived from a run of nearby photo dates.
struct ProposedTrip: Identifiable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let distinctDays: Int
    let photoCount: Int
    /// Capped PhotoKit identifiers backing this trip (for thumbnails later).
    let photoIdentifiers: [String]

    /// Inclusive length of the stay in calendar days.
    var durationDays: Int {
        (Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1
    }

    /// Status this trip alone would imply.
    func impliedStatus(livedThresholdDays: Int) -> CountryStatus {
        if durationDays >= livedThresholdDays { return .lived }
        if distinctDays > 1 { return .visited }
        return .crossed
    }
}

/// A country with its merged trips and the status the import would assign.
struct ProposedCountry: Identifiable {
    let id: String
    let country: Country
    var trips: [ProposedTrip]
    var proposedStatus: CountryStatus
    var isHome: Bool

    var flagEmoji: String { country.flagEmoji }
    var countryName: String { country.name }
    var totalDistinctDays: Int { trips.reduce(0) { $0 + $1.distinctDays } }
    var totalPhotos: Int { trips.reduce(0) { $0 + $1.photoCount } }
}

/// Drives the import sheet through its stages.
enum ImportPhase {
    case config
    case scanning
    case results
}

/// Handles importing visit data from Apple Photos based on location metadata.
/// Uses the existing country polygon data to map photo coordinates to countries.
@Observable
class PhotoImporter {
    var phase: ImportPhase = .config
    var isImporting = false
    var importProgress: String = ""
    var proposedCountries: [ProposedCountry] = []
    var homeWarning: String?
    var showImporterSheet = false

    @ObservationIgnored private var countryBoundingRects: [String: MKMapRect] = [:]
    @ObservationIgnored private var countryPaths: [String: [CGPath]] = [:]
    @ObservationIgnored private var allCountries: [Country] = []

    /// Upper bound on photo identifiers stored per visit, so a long stay (or your
    /// home country) doesn't bloat the database with thousands of references.
    @ObservationIgnored private let maxStoredIdentifiers = 30

    /// Whether the geographic data has been loaded and the importer is ready to run.
    var isReady: Bool { !countryBoundingRects.isEmpty }

    /// Status ordering used to ensure imports only ever raise a country's status.
    private func rank(_ status: CountryStatus) -> Int {
        CountryStatus.allCases.firstIndex(of: status) ?? 0
    }

    /// Initialize with the existing geographic data from ContentView
    func configure(
        countryBoundingRects: [String: MKMapRect],
        countryPaths: [String: [CGPath]],
        allCountries: [Country]
    ) {
        self.countryBoundingRects = countryBoundingRects
        self.countryPaths = countryPaths
        self.allCountries = allCountries
    }

    /// Open the sheet on its configuration step, clearing any prior run.
    func presentConfiguration() {
        phase = .config
        proposedCountries = []
        homeWarning = nil
        importProgress = ""
        isImporting = false
        showImporterSheet = true
    }

    /// Request photo library permission and start the scan with the given settings.
    func startImport(settings: ImportSettings) {
        guard !isImporting else { return }

        isImporting = true
        phase = .scanning
        importProgress = "Requesting access..."
        proposedCountries = []
        homeWarning = nil

        PHPhotoLibrary.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if status == .authorized || status == .limited {
                    // Run the scan off the main thread so the UI stays responsive.
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.fetchPhotosAndImport(settings: settings)
                    }
                } else {
                    self.isImporting = false
                    self.phase = .config
                    self.importProgress = "Photo access denied"
                }
            }
        }
    }

    /// Fetch photos with location data and turn them into proposed trips.
    private func fetchPhotosAndImport(settings: ImportSettings) {
        DispatchQueue.main.async { self.importProgress = "Fetching photos..." }

        // PhotoKit can't filter on `location` in a fetch predicate, but it *can*
        // filter on `creationDate` — which is exactly what "Add new only" needs.
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if settings.scanMode == .addNew, let since = newestImportedDate() {
            fetchOptions.predicate = NSPredicate(format: "creationDate > %@", since as NSDate)
        }

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        DispatchQueue.main.async {
            self.importProgress = "Scanning \(fetchResult.count) photos..."
        }

        // Collect every photo (date + identifier) that falls inside each country.
        var photosByCountry: [String: [(date: Date, id: String)]] = [:]
        var countriesByID: [String: Country] = [:]

        fetchResult.enumerateObjects { [weak self] asset, index, _ in
            guard let self = self else { return }

            if index % 200 == 0 {
                DispatchQueue.main.async {
                    self.importProgress = "Scanning photo \(index + 1)/\(fetchResult.count)..."
                }
            }

            guard let location = asset.location else { return }
            let mapPoint = MKMapPoint(location.coordinate)
            let cgPoint = CGPoint(x: mapPoint.x, y: mapPoint.y)

            for country in self.allCountries {
                guard let countryRect = self.countryBoundingRects[country.id],
                    countryRect.contains(mapPoint)
                else { continue }

                for path in self.countryPaths[country.id] ?? [] {
                    if path.contains(cgPoint) {
                        let date = asset.creationDate ?? Date()
                        photosByCountry[country.id, default: []].append(
                            (date, asset.localIdentifier))
                        countriesByID[country.id] = country
                        return
                    }
                }
            }
        }

        // Build merged trips and a derived status for each country.
        var proposed: [ProposedCountry] = []
        for (id, photos) in photosByCountry {
            guard let country = countriesByID[id] else { continue }

            let trips = makeTrips(from: photos, mergeGapDays: settings.mergeGapDays)
            guard !trips.isEmpty else { continue }

            var status: CountryStatus = .notVisited
            for trip in trips {
                let s = trip.impliedStatus(livedThresholdDays: settings.livedThresholdDays)
                if rank(s) > rank(status) { status = s }
            }

            proposed.append(
                ProposedCountry(
                    id: id, country: country, trips: trips,
                    proposedStatus: status, isHome: false))
        }

        // Optionally crown the most-present country as home.
        var warning: String?
        if settings.markHome,
            let homeIdx = proposed.indices.max(by: {
                proposed[$0].totalDistinctDays < proposed[$1].totalDistinctDays
            })
        {
            let existingHome = allCountries.first { $0.status == .living }
            if let existingHome, existingHome.id != proposed[homeIdx].id {
                // Respect a home the user set manually rather than overriding it.
                warning =
                    "\(existingHome.flagEmoji) \(existingHome.name) is already set as home — keeping it."
            } else {
                proposed[homeIdx].isHome = true
                proposed[homeIdx].proposedStatus = .living
                // You don't "visit" where you live: collapse every trip into a
                // single entry dated at the earliest photo, rather than emitting
                // hundreds of weekly visits.
                proposed[homeIdx].trips = collapsed(proposed[homeIdx].trips)
            }
        }

        proposed.sort { $0.totalDistinctDays > $1.totalDistinctDays }

        DispatchQueue.main.async {
            self.proposedCountries = proposed
            self.homeWarning = warning
            self.isImporting = false
            self.phase = .results
            self.importProgress =
                "Found \(proposed.count) countries across \(fetchResult.count) photos"
        }
    }

    /// Merge a set of trips into a single span (used for the home country).
    private func collapsed(_ trips: [ProposedTrip]) -> [ProposedTrip] {
        guard let first = trips.map(\.startDate).min(),
            let last = trips.map(\.endDate).max()
        else { return trips }
        return [
            ProposedTrip(
                startDate: first, endDate: last,
                distinctDays: trips.reduce(0) { $0 + $1.distinctDays },
                photoCount: trips.reduce(0) { $0 + $1.photoCount },
                photoIdentifiers: Array(
                    trips.flatMap(\.photoIdentifiers).prefix(maxStoredIdentifiers)))
        ]
    }

    /// The most recent imported visit date across all countries, for "Add new only".
    private func newestImportedDate() -> Date? {
        allCountries
            .flatMap { $0.visits }
            .filter { $0.isImported }
            .map { $0.date }
            .max()
    }

    /// Split a country's photos into trips separated by gaps larger than `mergeGapDays`.
    private func makeTrips(
        from photos: [(date: Date, id: String)], mergeGapDays: Int
    ) -> [ProposedTrip] {
        let calendar = Calendar.current
        guard !photos.isEmpty else { return [] }

        let sorted = photos.sorted { $0.date < $1.date }

        var trips: [ProposedTrip] = []
        var startDay = calendar.startOfDay(for: sorted[0].date)
        var previousDay = startDay
        var days: Set<Date> = []
        var photoCount = 0
        var ids: [String] = []

        func closeTrip() {
            trips.append(
                ProposedTrip(
                    startDate: startDay, endDate: previousDay,
                    distinctDays: days.count, photoCount: photoCount,
                    photoIdentifiers: ids))
        }

        for photo in sorted {
            let day = calendar.startOfDay(for: photo.date)
            let gap = calendar.dateComponents([.day], from: previousDay, to: day).day ?? 0
            if !days.isEmpty, gap > mergeGapDays {
                closeTrip()
                startDay = day
                days = []
                photoCount = 0
                ids = []
            }
            days.insert(day)
            photoCount += 1
            if ids.count < maxStoredIdentifiers { ids.append(photo.id) }
            previousDay = day
        }
        closeTrip()
        return trips
    }

    /// Apply the proposed visits and statuses to the model context.
    func applyImport(to modelContext: ModelContext, scanMode: ImportScanMode) {
        let calendar = Calendar.current

        // Overwrite clears the importer's own previous visits and statuses before
        // rebuilding, leaving manually-entered data untouched. Resetting imported
        // statuses here is what lets a country you no longer have photos from
        // (e.g. France) drop back to "not visited".
        if scanMode == .overwrite {
            for country in allCountries {
                // Key off the imported visits too (not just the flag) so statuses
                // imported by older builds, before the flag existed, also reset.
                let hadImportedVisits = country.visits.contains { $0.isImported }
                for visit in country.visits where visit.isImported {
                    modelContext.delete(visit)
                }
                if country.statusIsImported || hadImportedVisits {
                    country.status = .notVisited
                    country.statusIsImported = false
                }
            }
        }

        for proposed in proposedCountries {
            let country = proposed.country

            for trip in proposed.trips {
                let note = noteText(for: trip)

                // Fill-blanks / add-new skip a trip whose start day already exists.
                let existing = country.visits.first {
                    calendar.isDate($0.date, inSameDayAs: trip.startDate)
                }

                if let existing, scanMode != .overwrite {
                    if existing.isImported {
                        existing.notes = note
                        existing.photoIdentifiers = trip.photoIdentifiers
                    }
                    continue
                }

                let visit = Visit(
                    date: trip.startDate, notes: note, country: country, isImported: true)
                visit.photoIdentifiers = trip.photoIdentifiers
                modelContext.insert(visit)
                country.visits.append(visit)
            }

            // Only ever raise the status, so a manual `living`/`lived` is preserved.
            // Mark the status as imported only when we're not raising a status the
            // user set by hand, so a later Overwrite never clears their data.
            if rank(proposed.proposedStatus) > rank(country.status) {
                let wasManual = country.status != .notVisited && !country.statusIsImported
                country.status = proposed.proposedStatus
                if !wasManual { country.statusIsImported = true }
            }
        }

        proposedCountries = []
        showImporterSheet = false
        phase = .config
    }

    /// Human-readable note describing a trip.
    private func noteText(for trip: ProposedTrip) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let photos = "\(trip.photoCount) photo\(trip.photoCount == 1 ? "" : "s")"

        if calendarSameDay(trip.startDate, trip.endDate) {
            return "Imported · \(formatter.string(from: trip.startDate)) · \(photos)"
        }
        return
            "Imported · \(formatter.string(from: trip.startDate)) – \(formatter.string(from: trip.endDate)) · \(trip.durationDays) days · \(photos)"
    }

    private func calendarSameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    /// Cancel the import and close the sheet.
    func cancelImport() {
        isImporting = false
        proposedCountries = []
        homeWarning = nil
        showImporterSheet = false
        phase = .config
    }
}
