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
        case .overwrite: "Overwrite"
        case .addNew: "Add new only"
        }
    }

    var detail: String {
        switch self {
        case .fillBlanks: "Keep everything and add visits that aren't already recorded."
        case .overwrite: "Replace previously imported visits; manual entries are kept."
        case .addNew: "Only scan photos newer than the latest imported visit."
        }
    }
}

/// User-tunable settings for a photo import run.
struct ImportSettings: Sendable {
    var scanMode: ImportScanMode = .fillBlanks
    /// Photos within this many days of each other belong to the same trip.
    var mergeGapDays: Int = 7
    /// A single trip lasting at least this many days promotes the country to `lived`.
    var livedThresholdDays: Int = 60
    /// When on, the country with the most days present is marked as home (`living`).
    var markHome: Bool = false
}

/// A single merged trip to one country, derived from a run of nearby photo dates.
struct ProposedTrip: Identifiable, Sendable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let distinctDays: Int
    let photoCount: Int
    /// Capped PhotoKit identifiers backing this trip (for thumbnails later).
    let photoIdentifiers: [String]

    /// Inclusive length of the stay in calendar days.
    nonisolated var durationDays: Int {
        (Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1
    }

    /// Status this trip alone would imply.
    nonisolated func impliedStatus(livedThresholdDays: Int) -> CountryStatus {
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

/// A cluster of photos that fell outside every country polygon — typically a
/// small island the map simplification dropped (Corfu, the Canaries, …) or a GPS
/// reading just offshore. Rather than guessing or silently discarding them, the
/// import surfaces each cluster so the user can assign it to a country, choosing
/// from the nearest few or, failing that, any country.
struct UnresolvedLocation: Identifiable {
    let id = UUID()
    let trips: [ProposedTrip]
    /// Nearby countries, nearest first — the picker's quick suggestions.
    let suggestedCountries: [Country]
    /// The country the user assigned, or `nil` while still unresolved (skipped).
    var assignedCountryID: String?

    var totalPhotos: Int { trips.reduce(0) { $0 + $1.photoCount } }
    var totalDistinctDays: Int { trips.reduce(0) { $0 + $1.distinctDays } }

    /// Status these photos would imply, taking the strongest across their trips.
    func proposedStatus(livedThresholdDays: Int) -> CountryStatus {
        var status: CountryStatus = .notVisited
        for trip in trips {
            let s = trip.impliedStatus(livedThresholdDays: livedThresholdDays)
            if (CountryStatus.allCases.firstIndex(of: s) ?? 0)
                > (CountryStatus.allCases.firstIndex(of: status) ?? 0)
            {
                status = s
            }
        }
        return status
    }
}

/// Drives the import sheet through its stages.
enum ImportPhase {
    case config
    case scanning
    case results
}

/// Handles importing visit data from Apple Photos based on location metadata.
/// Uses the existing country polygon data to map photo coordinates to countries.
///
/// The scan itself runs off the main actor on `Sendable` value types only — no
/// SwiftData model is ever touched from a background context. Coordinate matching
/// is done against country *ids*; the resulting ids are resolved back to `Country`
/// objects on the main actor in `finalizeScan`.
@MainActor
@Observable
class PhotoImporter {
    var phase: ImportPhase = .config
    var isImporting = false
    var importProgress: String = ""
    var proposedCountries: [ProposedCountry] = []
    /// Photo clusters that matched no country, awaiting a manual assignment.
    var unresolvedLocations: [UnresolvedLocation] = []
    var homeWarning: String?
    var showImporterSheet = false

    /// Settings of the most recent scan, kept so `applyImport` can derive a status
    /// for user-resolved locations with the same thresholds the scan used.
    private var lastSettings = ImportSettings()

    /// The full catalog, sorted by name — backs the picker's "any country" list.
    var pickableCountries: [Country] { allCountries.sorted { $0.name < $1.name } }

    /// Set once by `configure`. Snapshotted into each scan Task so the
    /// background scanner never touches the main-actor-bound stored properties.
    @ObservationIgnored private var countryBoundingRects: [String: MKMapRect] = [:]
    @ObservationIgnored private var countryPaths: [String: [CGPath]] = [:]
    @ObservationIgnored private var allCountries: [Country] = []

    /// Upper bound on photo identifiers stored per visit, so a long stay (or your
    /// home country) doesn't bloat the database with thousands of references.
    nonisolated private static let maxStoredIdentifiers = 30

    /// Whether the geographic data has been loaded and the importer is ready to run.
    var isReady: Bool { !countryBoundingRects.isEmpty }

    /// Status ordering used to ensure imports only ever raise a country's status.
    nonisolated private static func rank(_ status: CountryStatus) -> Int {
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
        unresolvedLocations = []
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
        unresolvedLocations = []
        homeWarning = nil
        lastSettings = settings

        // Computed on the main actor (reads SwiftData) before going off-main.
        let addNewSince = settings.scanMode == .addNew ? newestImportedDate() : nil
        // Snapshot the geometry into the Task so the background scan never reads
        // the main-actor-bound stored properties across an isolation boundary.
        let rects = countryBoundingRects
        let paths = countryPaths

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                isImporting = false
                phase = .config
                importProgress = "Photo access denied"
                return
            }

            importProgress = "Fetching photos..."
            // Runs off the main actor; returns only Sendable value types.
            let result = await scanPhotos(
                settings: settings, rects: rects, paths: paths,
                addNewSince: addNewSince,
                onProgress: { text in self.importProgress = text })

            finalizeScan(result, settings: settings)
        }
    }

    /// Outcome of an off-main photo scan, expressed purely in value types so no
    /// SwiftData model is touched off the main actor.
    private struct ScanResult: Sendable {
        struct Entry: Sendable {
            let id: String
            let trips: [ProposedTrip]
            let status: CountryStatus
            let totalDistinctDays: Int
        }
        /// A spatial cluster of photos that matched no country, with the ids of the
        /// nearest countries to offer as suggestions (nearest first).
        struct UnmatchedCluster: Sendable {
            let trips: [ProposedTrip]
            let suggestedCountryIDs: [String]
        }
        var entries: [Entry]
        var unmatched: [UnmatchedCluster]
        var homeCandidateID: String?
        var photoCount: Int
    }

    /// Fetch photos with location data and turn them into proposed trips, matching
    /// coordinates to countries by id. Runs entirely off the main actor over
    /// `Sendable` data — it reads only the immutable geographic dictionaries.
    nonisolated private func scanPhotos(
        settings: ImportSettings, rects: [String: MKMapRect], paths: [String: [CGPath]],
        addNewSince: Date?,
        onProgress: @MainActor @Sendable @escaping (String) -> Void
    ) async -> ScanResult {
        // PhotoKit can't filter on `location` in a fetch predicate, but it *can*
        // filter on `creationDate` — which is exactly what "Add new only" needs.
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if settings.scanMode == .addNew, let since = addNewSince {
            fetchOptions.predicate = NSPredicate(format: "creationDate > %@", since as NSDate)
        }

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let total = fetchResult.count
        Task { @MainActor in onProgress("Scanning \(total) photos...") }

        let countryIDs = Array(rects.keys)

        // Collect every photo (date + identifier) that falls inside each country.
        var photosByCountry: [String: [(date: Date, id: String)]] = [:]
        // Photos with a location that landed inside no country polygon.
        var unmatched: [(date: Date, point: MKMapPoint, id: String)] = []

        fetchResult.enumerateObjects { asset, index, _ in
            if index % 200 == 0 {
                Task { @MainActor in onProgress("Scanning photo \(index + 1)/\(total)...") }
            }

            guard let location = asset.location else { return }
            let mapPoint = MKMapPoint(location.coordinate)
            let cgPoint = CGPoint(x: mapPoint.x, y: mapPoint.y)
            let date = asset.creationDate ?? Date()

            for id in countryIDs {
                guard let countryRect = rects[id],
                    countryRect.contains(mapPoint)
                else { continue }

                for path in paths[id] ?? [] {
                    if path.contains(cgPoint) {
                        photosByCountry[id, default: []].append((date, asset.localIdentifier))
                        return
                    }
                }
            }

            // No polygon matched — keep it for the user to resolve manually.
            unmatched.append((date, mapPoint, asset.localIdentifier))
        }

        // Build merged trips and a derived status for each country.
        var entries: [ScanResult.Entry] = []
        for (id, photos) in photosByCountry {
            let trips = Self.makeTrips(from: photos, mergeGapDays: settings.mergeGapDays)
            guard !trips.isEmpty else { continue }

            var status: CountryStatus = .notVisited
            for trip in trips {
                let s = trip.impliedStatus(livedThresholdDays: settings.livedThresholdDays)
                if Self.rank(s) > Self.rank(status) { status = s }
            }

            entries.append(
                .init(
                    id: id, trips: trips, status: status,
                    totalDistinctDays: trips.reduce(0) { $0 + $1.distinctDays }))
        }

        // Turn unmatched photos into a handful of resolvable, suggestion-tagged
        // clusters rather than leaving them silently dropped.
        let unmatchedClusters = Self.clusterUnmatched(
            unmatched, mergeGapDays: settings.mergeGapDays, rects: rects)

        // The most-present country is the candidate for "home"; the existing-home
        // reconciliation needs SwiftData, so it happens on the main actor.
        let homeCandidateID =
            settings.markHome
            ? entries.max(by: { $0.totalDistinctDays < $1.totalDistinctDays })?.id
            : nil

        return ScanResult(
            entries: entries, unmatched: unmatchedClusters,
            homeCandidateID: homeCandidateID, photoCount: total)
    }

    /// Group photos that matched no country by spatial proximity, then tag each
    /// cluster with the nearest countries (nearest first) to suggest. Greedy
    /// single-pass clustering — cheap, and exact grouping doesn't matter since the
    /// user makes the final call.
    nonisolated private static func clusterUnmatched(
        _ photos: [(date: Date, point: MKMapPoint, id: String)],
        mergeGapDays: Int,
        rects: [String: MKMapRect]
    ) -> [ScanResult.UnmatchedCluster] {
        guard !photos.isEmpty else { return [] }

        // ~200 km at the equator, in projected map points. Generous on purpose:
        // over-merging just means one picker row for nearby spots.
        let threshold = MKMapPointsPerMeterAtLatitude(0) * 200_000
        let maxClusters = 30

        struct Cluster {
            var x: Double
            var y: Double
            var count: Int
            var photos: [(date: Date, id: String)]
        }
        var clusters: [Cluster] = []

        for photo in photos {
            // Nearest existing cluster within the radius (or any, once capped).
            var bestIndex = -1
            var bestDistance = Double.greatestFiniteMagnitude
            for index in clusters.indices {
                let dx = clusters[index].x - photo.point.x
                let dy = clusters[index].y - photo.point.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            if bestIndex >= 0, bestDistance <= threshold || clusters.count >= maxClusters {
                let n = Double(clusters[bestIndex].count)
                clusters[bestIndex].x = (clusters[bestIndex].x * n + photo.point.x) / (n + 1)
                clusters[bestIndex].y = (clusters[bestIndex].y * n + photo.point.y) / (n + 1)
                clusters[bestIndex].count += 1
                clusters[bestIndex].photos.append((photo.date, photo.id))
            } else {
                clusters.append(
                    Cluster(
                        x: photo.point.x, y: photo.point.y, count: 1,
                        photos: [(photo.date, photo.id)]))
            }
        }

        return clusters.compactMap { cluster in
            let trips = makeTrips(from: cluster.photos, mergeGapDays: mergeGapDays)
            guard !trips.isEmpty else { return nil }
            let center = MKMapPoint(x: cluster.x, y: cluster.y)
            let nearest = nearestCountryIDs(to: center, rects: rects, limit: 8)
            return ScanResult.UnmatchedCluster(trips: trips, suggestedCountryIDs: nearest)
        }
        // Most photos first, so the biggest gaps surface at the top.
        .sorted {
            $0.trips.reduce(0) { $0 + $1.photoCount } > $1.trips.reduce(0) { $0 + $1.photoCount }
        }
    }

    /// The `limit` countries whose bounding box is closest to `point`, nearest
    /// first. Distance is point-to-rectangle in projected map points (0 if inside).
    nonisolated private static func nearestCountryIDs(
        to point: MKMapPoint, rects: [String: MKMapRect], limit: Int
    ) -> [String] {
        rects
            .map { (id: $0.key, distance: distance(from: point, to: $0.value)) }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map(\.id)
    }

    /// Shortest distance from a point to a map rectangle, in map points.
    nonisolated private static func distance(from point: MKMapPoint, to rect: MKMapRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Resolve scanned ids back to `Country` objects and finish the run. Runs on
    /// the main actor, the only place SwiftData models may be touched.
    private func finalizeScan(_ result: ScanResult, settings: ImportSettings) {
        let byID = Dictionary(
            allCountries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var proposed: [ProposedCountry] = []
        for entry in result.entries {
            guard let country = byID[entry.id] else { continue }
            proposed.append(
                ProposedCountry(
                    id: entry.id, country: country, trips: entry.trips,
                    proposedStatus: entry.status, isHome: false))
        }

        // Optionally crown the most-present country as home.
        var warning: String?
        if settings.markHome, let homeID = result.homeCandidateID,
            let homeIdx = proposed.firstIndex(where: { $0.id == homeID })
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
                proposed[homeIdx].trips = Self.collapsed(proposed[homeIdx].trips)
            }
        }

        proposed.sort { $0.totalDistinctDays > $1.totalDistinctDays }

        // Resolve each unmatched cluster's suggestion ids back to `Country` objects.
        let unresolved: [UnresolvedLocation] = result.unmatched.map { cluster in
            let suggestions = cluster.suggestedCountryIDs.compactMap { byID[$0] }
            return UnresolvedLocation(trips: cluster.trips, suggestedCountries: suggestions)
        }

        proposedCountries = proposed
        unresolvedLocations = unresolved
        homeWarning = warning
        isImporting = false
        phase = .results
        importProgress = "Found \(proposed.count) countries across \(result.photoCount) photos"
    }

    /// Merge a set of trips into a single span (used for the home country).
    nonisolated private static func collapsed(_ trips: [ProposedTrip]) -> [ProposedTrip] {
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
    nonisolated private static func makeTrips(
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
            // Flush deletions before re-creating visits, so SwiftData's change
            // tracking doesn't conflate the old deleted objects with the new ones.
            try? modelContext.save()
        }

        for proposed in proposedCountries {
            apply(
                trips: proposed.trips, to: proposed.country,
                proposedStatus: proposed.proposedStatus, scanMode: scanMode, calendar: calendar,
                modelContext: modelContext)
        }

        // Fold in any unmatched clusters the user assigned to a country.
        let byID = Dictionary(
            allCountries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for location in unresolvedLocations {
            guard let id = location.assignedCountryID, let country = byID[id] else { continue }
            apply(
                trips: location.trips, to: country,
                proposedStatus: location.proposedStatus(
                    livedThresholdDays: lastSettings.livedThresholdDays),
                scanMode: scanMode, calendar: calendar, modelContext: modelContext)
        }

        proposedCountries = []
        unresolvedLocations = []
        showImporterSheet = false
        phase = .config
    }

    /// Add a set of trips as visits to one country and raise its status, honoring
    /// the scan mode. Shared by scan-matched countries and user-resolved clusters.
    private func apply(
        trips: [ProposedTrip], to country: Country, proposedStatus: CountryStatus,
        scanMode: ImportScanMode, calendar: Calendar, modelContext: ModelContext
    ) {
        for trip in trips {
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
        if Self.rank(proposedStatus) > Self.rank(country.status) {
            let wasManual = country.status != .notVisited && !country.statusIsImported
            country.status = proposedStatus
            if !wasManual { country.statusIsImported = true }
        }
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
        unresolvedLocations = []
        homeWarning = nil
        showImporterSheet = false
        phase = .config
    }
}
