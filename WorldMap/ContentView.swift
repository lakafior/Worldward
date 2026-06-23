import MapKit
import Photos
import SwiftData
import SwiftUI

private struct CountryListSummary {
    let filteredCountries: [Country]
    let continents: [String]
    let visitYears: [Int]
    let visitedCount: Int
    let hasActiveFilters: Bool

    init(
        countries: [Country], searchText: String, filterVisited: Bool?, selectedContinent: String?,
        selectedYear: Int?
    ) {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        var filteredCountries: [Country] = []
        var continents = Set<String>()
        var visitYears = Set<Int>()
        var visitedCount = 0

        for country in countries {
            continents.insert(country.continent)

            if country.isVisited {
                visitedCount += 1
            }

            // Collect visit years from all visits
            for visit in country.visits {
                visitYears.insert(calendar.component(.year, from: visit.date))
            }
            // Also check legacy visitDate for backward compatibility
            if let visitDate = country.visitDate {
                visitYears.insert(calendar.component(.year, from: visitDate))
            }

            guard
                trimmedSearch.isEmpty
                    || country.name.localizedCaseInsensitiveContains(trimmedSearch)
            else { continue }
            guard filterVisited == nil || country.isVisited == filterVisited else { continue }
            guard selectedContinent == nil || country.continent == selectedContinent else {
                continue
            }

            if let selectedYear {
                // Check if any visit matches the selected year
                let hasMatchingVisit = country.visits.contains { visit in
                    calendar.component(.year, from: visit.date) == selectedYear
                }
                // Also check legacy visitDate for backward compatibility
                let legacyYearMatch =
                    country.visitDate.map {
                        calendar.component(.year, from: $0) == selectedYear
                    } ?? false

                guard hasMatchingVisit || legacyYearMatch else { continue }
            }

            filteredCountries.append(country)
        }

        self.filteredCountries = filteredCountries
        self.continents = continents.sorted()
        self.visitYears = visitYears.sorted(by: >)
        self.visitedCount = visitedCount
        self.hasActiveFilters =
            filterVisited != nil || selectedContinent != nil || selectedYear != nil
    }
}

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Country.continent), SortDescriptor(\Country.name)]) private
        var allCountries: [Country]

    @State private var searchText = ""
    @State private var selectedCountry: Country?
    @State private var detailCountry: Country?
    @State private var showStats = false
    @State private var showSettings = false
    @State private var showCountryList = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnHome = false
    @State private var expandedContinents: Set<String> = []

    @State private var photoImporter = PhotoImporter()
    @Environment(\.modelContext) private var modelContext

    // Filters
    @State private var filterVisited: Bool? = nil  // nil = all, true = visited, false = unvisited
    @State private var selectedContinent: String? = nil
    @State private var selectedYear: Int? = nil

    // Geographic data
    @State private var countryPolygons: [String: [MKPolygon]] = [:]
    @State private var countryPaths: [String: [CGPath]] = [:]
    @State private var countryBoundingRects: [String: MKMapRect] = [:]
    @State private var countryCentroids: [String: CLLocationCoordinate2D] = [:]
    @State private var isLoadingMapData = true
    @State private var mapLoadingMessage = "Loading map…"

    private var countryListSummary: CountryListSummary {
        CountryListSummary(
            countries: allCountries,
            searchText: searchText,
            filterVisited: filterVisited,
            selectedContinent: selectedContinent,
            selectedYear: selectedYear
        )
    }

    private var visibleCountries: [Country] {
        allCountries.filter { $0.isVisited || $0 == selectedCountry }
    }

    private var countriesGroupedByContinent: [String: [Country]] {
        Dictionary(grouping: countryListSummary.filteredCountries, by: { $0.continent })
    }

    private func initializeExpandedContinents() {
        if expandedContinents.isEmpty {
            expandedContinents = Set(countriesGroupedByContinent.keys)
        }
    }

    /// The interactive world map. Extracted so the body can withhold it (and the
    /// cost of bringing up MapKit) until the country geometry has loaded.
    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                ForEach(visibleCountries) { country in
                    CountryMapPolygons(
                        country: country,
                        status: country.status,
                        polygons: countryPolygons[country.id] ?? [])
                }
            }
            .mapStyle(.standard)
            .mapControls {
                // MapZoomStepper is macOS-only; iOS zooms via pinch gesture.
                #if os(macOS)
                    MapZoomStepper()
                #endif
                MapCompass()
            }
            .onTapGesture { location in
                if let coordinate = proxy.convert(location, from: .local) {
                    let mapPoint = MKMapPoint(coordinate)
                    let cgPoint = CGPoint(x: mapPoint.x, y: mapPoint.y)

                    // Optimized lookup: check country bounding rects first, then individual paths.
                    for country in allCountries {
                        guard let countryRect = countryBoundingRects[country.id],
                            countryRect.contains(mapPoint)
                        else { continue }

                        for path in countryPaths[country.id] ?? [] {
                            if path.contains(cgPoint) {
                                selectedCountry = country
                                return
                            }
                        }
                    }
                }
            }
            // Prevent CAMetalLayer zero-size warnings during sheet transitions.
            .frame(minWidth: 1, minHeight: 1)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Render only the splash while loading, so it paints on the first
                // frame without MapKit/Metal initialization competing for it. The
                // map is built once the geometry is ready.
                if isLoadingMapData {
                    MapLoadingView(message: mapLoadingMessage)
                        .transition(.opacity)
                } else {
                    mapView

                    MapLegend()
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .navigationTitle("World Map")
            #if os(macOS)
                .navigationSubtitle("Tap a country to see details")
            #endif
            .toolbar {
                #if !os(macOS)
                    // macOS reaches Settings through the app menu (⌘,) instead.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                #endif

                ToolbarItem {
                    Button {
                        showCountryList = true
                    } label: {
                        Label("Countries", systemImage: "plus")
                    }
                }

                ToolbarItem {
                    Button {
                        showStats = true
                    } label: {
                        Label("Statistics", systemImage: "chart.pie")
                    }
                }

                ToolbarItem {
                    Button {
                        detailCountry = selectedCountry
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .disabled(selectedCountry == nil)
                }

                ToolbarItem {
                    Button {
                        photoImporter.presentConfiguration()
                    } label: {
                        Label("Import from Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(!photoImporter.isReady || photoImporter.isImporting)
                }
            }
        }
        .onChange(of: selectedCountry) {
            if let country = selectedCountry {
                detailCountry = country

                // Center the map on the selected country
                if let rect = mapRect(for: country) {
                    withAnimation {
                        cameraPosition = .rect(rect)
                    }
                }
            }
        }
        .task {
            await loadGeoJSON()
        }
        .sheet(isPresented: $photoImporter.showImporterSheet) {
            ImportPreviewView(importer: photoImporter, modelContext: modelContext)
        }
        .sheet(isPresented: $showStats) {
            StatisticsView(countries: allCountries, centroids: countryCentroids)
        }
        .sheet(isPresented: $showCountryList) {
            CountryListSheet(
                allCountries: allCountries,
                searchText: $searchText,
                filterVisited: $filterVisited,
                selectedContinent: $selectedContinent,
                selectedYear: $selectedYear,
                expandedContinents: $expandedContinents,
                selectedCountry: $selectedCountry,
                isPresented: $showCountryList,
                onAppear: initializeExpandedContinents
            )
        }
        .sheet(item: $detailCountry) { country in
            CountryDetailSheet(country: country)
        }
        #if !os(macOS)
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
                }
            }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .worldMapOpenStats)) { _ in
            showStats = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .worldMapOpenCountry)) {
            notification in
            guard let id = notification.object as? String else { return }
            selectedCountry = allCountries.first { $0.id == id }
        }
    }

    /// The padded map rectangle enclosing all of a country's polygons.
    private func mapRect(for country: Country) -> MKMapRect? {
        guard let rect = countryBoundingRects[country.id] else { return nil }
        // Add a small margin around the country outline
        let padding = rect.width * 0.2
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    /// On first load, open the map centered on the country the user lives in, if any.
    private func focusOnHomeIfNeeded() {
        guard !hasCenteredOnHome, !allCountries.isEmpty, !countryPolygons.isEmpty else { return }
        hasCenteredOnHome = true

        guard let home = allCountries.first(where: { $0.status == .living }),
            let rect = mapRect(for: home)
        else { return }
        cameraPosition = .rect(rect)
    }

    private func loadGeoJSON() async {
        // Decide what database work is needed up front, on the main context, so the
        // background decode knows whether it must also produce seed metadata. The
        // store needs seeding when it's empty or holds stale ids from an old build.
        let existing = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
        let stale = WorldMap.hasStaleIDs(existing)
        let needsSeed = existing.isEmpty || stale

        // First run (or a reseed) pays the one-time decode, so say so rather than
        // leaving a bare spinner; warm launches just rebuild from the cache.
        mapLoadingMessage =
            (geoCacheExists() && !needsSeed)
            ? "Loading map…"
            : "Setting up your map…\nThis only happens once."

        // Build the simplified country geometry off the main thread, decoding the
        // 14 MB GeoJSON only when the cache is missing or the store still needs
        // seeding — and at most once. The same decode yields the seed metadata, so
        // the file is never parsed twice. Warm launches rebuild from the small
        // cached rings in well under a second, which keeps cold starts fast.
        let (extractedPolygons, extractedPaths, extractedRects, seeds) = await Task.detached(
            priority: .userInitiated
        ) {
            () -> (
                [String: [MKPolygon]], [String: [CGPath]], [String: MKMapRect], [CountrySeed]?
            ) in
            let fingerprint = geoFingerprint()

            // Cache is enough only when we don't also need seed metadata.
            if !needsSeed, let cached = loadGeoCache(fingerprint: fingerprint) {
                let geo = buildGeo(from: cached)
                return (geo.0, geo.1, geo.2, nil)
            }

            guard let decoded = decodeGeoJSON() else { return ([:], [:], [:], nil) }
            saveGeoCache(decoded.rings, fingerprint: fingerprint)
            let geo = buildGeo(from: decoded.rings)
            return (geo.0, geo.1, geo.2, decoded.seeds)
        }.value

        // Reconcile the database on the main actor — the only place SwiftData
        // models are touched. Seeding and reconciliation are mutually exclusive.
        if needsSeed {
            if let seeds { seedDatabase(seeds, wiping: stale ? existing : []) }
        } else {
            reconcileDatabase(existing)
        }

        self.countryPolygons = extractedPolygons
        self.countryPaths = extractedPaths
        self.countryBoundingRects = extractedRects
        // Derive a centroid per country from its bounding rect so the statistics
        // page can rank the nearest unvisited countries by real proximity.
        self.countryCentroids = extractedRects.mapValues { rect in
            MKMapPoint(
                x: rect.origin.x + rect.size.width / 2,
                y: rect.origin.y + rect.size.height / 2
            ).coordinate
        }
        withAnimation(.easeInOut(duration: 0.4)) {
            self.isLoadingMapData = false
        }

        // Hand the geographic data to the photo importer now that it's ready.
        // Re-fetch so the importer gets every seeded country even if the `@Query`
        // hasn't refreshed yet this run loop. Doing this here (rather than via
        // onChange) guarantees it runs exactly once, so the "Import from Photos"
        // button reliably enables.
        let seededCountries = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? allCountries
        photoImporter.configure(
            countryBoundingRects: extractedRects,
            countryPaths: extractedPaths,
            allCountries: seededCountries
        )

        focusOnHomeIfNeeded()
    }

    /// Seed an empty (or freshly wiped) store from decoded GeoJSON metadata. Drops
    /// any stale rows first, and skips non-countries the dataset ships without a
    /// real continent (reefs, military bases, disputed zones).
    private func seedDatabase(_ seeds: [CountrySeed], wiping stale: [Country]) {
        for country in stale {
            modelContext.delete(country)
        }
        for seed in seeds where Continents.byISO[seed.id] != nil {
            modelContext.insert(
                Country(
                    id: seed.id, iso3: seed.iso3, name: seed.name,
                    continent: Continents.name(for: seed.id)))
        }
        try? modelContext.save()
    }

    /// Reconcile an already-seeded store: drop non-countries an earlier seed stored
    /// and fix continents written by an older build. Idempotent and cheap.
    private func reconcileDatabase(_ existing: [Country]) {
        var changed = false
        for country in existing {
            if Continents.byISO[country.id] == nil {
                modelContext.delete(country)
                changed = true
                continue
            }
            let continent = Continents.name(for: country.id)
            if country.continent != continent {
                country.continent = continent
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }
}

struct CountryRow: View {
    let country: Country

    var body: some View {
        HStack {
            Text(country.flagEmoji)
            Text(country.name)
            Spacer()
            if country.status.isVisited {
                Image(systemName: country.status.symbolName)
                    .foregroundStyle(country.status.color)
            }
        }
    }
}

/// A subview that renders a single country's polygons. By isolating this into its
/// own view with a dependency on the `Country` object, SwiftUI can efficiently
/// observe changes to that specific country's status and redraw only these polygons.
struct CountryMapPolygons: MapContent {
    let country: Country
    let status: CountryStatus
    let polygons: [MKPolygon]

    var body: some MapContent {
        ForEach(polygons.indices, id: \.self) { index in
            MapPolygon(polygons[index])
                .foregroundStyle(status.fillColor)
                .stroke(status.strokeColor, lineWidth: 0.5)
        }
    }
}

/// The simplified exterior outline of a polygon, as map points. Applies
/// Douglas-Peucker with a tolerance proportional to the polygon's own size, so a
/// large country is thinned more aggressively than a small one while every
/// outline stays recognizable.
private nonisolated func simplifiedOutline(of polygon: MKPolygon) -> [MKMapPoint] {
    let count = polygon.pointCount
    let points = Array(UnsafeBufferPointer(start: polygon.points(), count: count))
    guard count > 2 else { return points }

    let rect = polygon.boundingMapRect
    let diagonal = (rect.width * rect.width + rect.height * rect.height).squareRoot()
    let tolerance = diagonal * 0.005
    return douglasPeucker(points, tolerance: tolerance)
}

/// Iterative Douglas-Peucker line simplification. Keeps the endpoints and any
/// vertex whose perpendicular distance from the current segment exceeds
/// `tolerance`. Iterative (explicit stack) to avoid deep recursion on the very
/// large rings that make this simplification worthwhile in the first place.
private nonisolated func douglasPeucker(_ points: [MKMapPoint], tolerance: Double) -> [MKMapPoint] {
    let n = points.count
    guard n > 2 else { return points }

    var keep = [Bool](repeating: false, count: n)
    keep[0] = true
    keep[n - 1] = true

    var stack: [(Int, Int)] = [(0, n - 1)]
    while let (first, last) = stack.popLast() {
        guard last > first + 1 else { continue }

        let start = points[first]
        let end = points[last]
        var maxDistance = 0.0
        var farthest = first

        for i in (first + 1)..<last {
            let distance = perpendicularDistance(points[i], from: start, to: end)
            if distance > maxDistance {
                maxDistance = distance
                farthest = i
            }
        }

        if maxDistance > tolerance {
            keep[farthest] = true
            stack.append((first, farthest))
            stack.append((farthest, last))
        }
    }

    return (0..<n).compactMap { keep[$0] ? points[$0] : nil }
}

/// Perpendicular distance from `point` to the infinite line through `a` and `b`.
private nonisolated func perpendicularDistance(
    _ point: MKMapPoint, from a: MKMapPoint, to b: MKMapPoint
) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let magnitude = (dx * dx + dy * dy).squareRoot()
    guard magnitude > 0 else {
        return ((point.x - a.x) * (point.x - a.x) + (point.y - a.y) * (point.y - a.y))
            .squareRoot()
    }
    let cross = abs((point.x - a.x) * dy - (point.y - a.y) * dx)
    return cross / magnitude
}

extension MKMapRect {
    /// Area in squared map points; a cheap proxy for comparing landmass sizes.
    fileprivate nonisolated var area: Double { width * height }
}

// MARK: - Geometry cache

/// On-disk cache of the simplified country outlines. Storing the decimated rings
/// (rather than the raw 14 MB GeoJSON) lets a cold launch skip both the decode
/// and the Douglas-Peucker pass. Bump `geoCacheVersion` whenever the simplification
/// changes; the bundled file's byte size is the fingerprint, so shipping new map
/// data automatically invalidates a stale cache.
private nonisolated let geoCacheVersion = 1

private nonisolated struct GeoRingCache: Codable {
    let version: Int
    let fingerprint: Int
    /// Country id → rings → flat `[x0, y0, x1, y1, …]` map-point coordinates.
    let rings: [String: [[Double]]]
}

/// Cheap fingerprint of the bundled GeoJSON: its byte size, read from the file's
/// metadata without loading the 14 MB into memory.
private nonisolated func geoFingerprint() -> Int {
    guard let url = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attrs[.size] as? Int
    else { return 0 }
    return size
}

private nonisolated func geoCacheURL() -> URL? {
    guard
        let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
    else { return nil }
    return dir.appendingPathComponent("WorldMapGeoCache.json")
}

/// Whether a cache file exists at all — a cheap check (no decode) used only to
/// pick the right loading message, not to validate the cache contents.
private nonisolated func geoCacheExists() -> Bool {
    guard let url = geoCacheURL() else { return false }
    return FileManager.default.fileExists(atPath: url.path)
}

/// The cached simplified rings, or `nil` if there's no cache, it's the wrong
/// version, or the bundled GeoJSON has changed since it was written.
private nonisolated func loadGeoCache(fingerprint: Int) -> [String: [[MKMapPoint]]]? {
    guard let url = geoCacheURL(),
        let data = try? Data(contentsOf: url),
        let cache = try? JSONDecoder().decode(GeoRingCache.self, from: data),
        cache.version == geoCacheVersion, cache.fingerprint == fingerprint
    else { return nil }

    return cache.rings.mapValues { ringList in
        ringList.map { flat -> [MKMapPoint] in
            var points: [MKMapPoint] = []
            points.reserveCapacity(flat.count / 2)
            var i = 0
            while i + 1 < flat.count {
                points.append(MKMapPoint(x: flat[i], y: flat[i + 1]))
                i += 2
            }
            return points
        }
    }
}

private nonisolated func saveGeoCache(_ rings: [String: [[MKMapPoint]]], fingerprint: Int) {
    let flatRings = rings.mapValues { ringList in
        ringList.map { points -> [Double] in
            var flat: [Double] = []
            flat.reserveCapacity(points.count * 2)
            for point in points {
                flat.append(point.x)
                flat.append(point.y)
            }
            return flat
        }
    }
    let cache = GeoRingCache(version: geoCacheVersion, fingerprint: fingerprint, rings: flatRings)
    guard let url = geoCacheURL(), let data = try? JSONEncoder().encode(cache) else { return }
    try? data.write(to: url, options: .atomic)
}

/// Decodes the bundled GeoJSON and produces the simplified exterior rings per
/// country. This is the expensive path, run only when the cache is missing or
/// stale. Mirrors the original two-pass build: collect raw exterior rings, then
/// drop insignificant islands and decimate the rest with Douglas-Peucker.
private nonisolated func decodeGeoJSON()
    -> (rings: [String: [[MKMapPoint]]], seeds: [CountrySeed])?
{
    guard let geoUrl = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
        let data = try? Data(contentsOf: geoUrl)
    else { return nil }

    let decoder = MKGeoJSONDecoder()
    guard let features = try? decoder.decode(data) as? [MKGeoJSONFeature] else { return nil }

    // Pass 1: collect each country's raw exterior-ring polygons and its seed
    // metadata (id/iso3/name) in the same sweep, so the database and the map are
    // both fed by this single decode. Interior holes are dropped here, since they
    // don't affect a flat country fill.
    var rawPolygons: [String: [MKPolygon]] = [:]
    var seedByID: [String: CountrySeed] = [:]
    for feature in features {
        guard let propsData = feature.properties,
            let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any],
            let rawID = props["ISO3166-1-Alpha-2"] as? String,
            let name = props["name"] as? String
        else { continue }

        guard let id = WorldMap.resolvedID(isoA2: rawID, name: name) else { continue }

        if seedByID[id] == nil {
            seedByID[id] = CountrySeed(
                id: id, iso3: props["ISO3166-1-Alpha-3"] as? String ?? "", name: name)
        }

        for geometry in feature.geometry {
            if let polygon = geometry as? MKPolygon {
                rawPolygons[id, default: []].append(
                    MKPolygon(points: polygon.points(), count: polygon.pointCount))
            } else if let multiPolygon = geometry as? MKMultiPolygon {
                for poly in multiPolygon.polygons {
                    rawPolygons[id, default: []].append(
                        MKPolygon(points: poly.points(), count: poly.pointCount))
                }
            }
        }
    }

    // Pass 2: for each country, drop insignificant islands and decimate the
    // remaining outlines. Archipelago nations (Canada, Norway, Indonesia…)
    // collapse from thousands of points down to a handful.
    var result: [String: [[MKMapPoint]]] = [:]
    for (id, countryPolygons) in rawPolygons {
        guard
            let largest = countryPolygons.max(by: {
                $0.boundingMapRect.area < $1.boundingMapRect.area
            })
        else { continue }

        // Keep the mainland plus any island at least 0.5% of its size.
        let minIslandArea = largest.boundingMapRect.area * 0.005

        var rings: [[MKMapPoint]] = []
        for polygon in countryPolygons {
            if polygon !== largest, polygon.boundingMapRect.area < minIslandArea { continue }
            let points = simplifiedOutline(of: polygon)
            guard points.count >= 3 else { continue }
            rings.append(points)
        }

        guard !rings.isEmpty else { continue }
        result[id] = rings
    }
    return (result, Array(seedByID.values))
}

/// One country's seed metadata, parsed from the GeoJSON alongside its geometry.
struct CountrySeed: Sendable {
    let id: String
    let iso3: String
    let name: String
}

/// Rebuilds the drawable polygons, hit-test paths, and per-country bounding rects
/// from simplified rings. Shared by both the cache and fresh-decode paths so the
/// map and tap targets are identical whichever produced the rings.
private nonisolated func buildGeo(
    from rings: [String: [[MKMapPoint]]]
) -> ([String: [MKPolygon]], [String: [CGPath]], [String: MKMapRect]) {
    var polys: [String: [MKPolygon]] = [:]
    var paths: [String: [CGPath]] = [:]
    var rects: [String: MKMapRect] = [:]

    for (id, ringList) in rings {
        var polygons: [MKPolygon] = []
        var cgPaths: [CGPath] = []
        var largestRect: MKMapRect?

        for points in ringList {
            guard points.count >= 3 else { continue }

            let polygon = MKPolygon(points: points, count: points.count)
            polygons.append(polygon)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()
            cgPaths.append(path)

            let rect = polygon.boundingMapRect
            if largestRect == nil || rect.area > largestRect!.area { largestRect = rect }
        }

        guard !polygons.isEmpty, let largestRect else { continue }
        polys[id] = polygons
        paths[id] = cgPaths
        // Bounding rect uses only the largest polygon, so selecting a country
        // zooms to its mainland rather than a far-flung territory.
        rects[id] = largestRect
    }
    return (polys, paths, rects)
}

/// Compact key explaining the green shades shown on the map.
struct MapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(CountryStatus.visitedCases) { status in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(status.color)
                        .frame(width: 12, height: 12)
                    Text(status.label)
                        .font(.caption2)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Full-screen launch splash shown while the country geometry is being built.
/// A branded, opaque cover (rather than a bare spinner over an empty gray map)
/// makes the one-time first-run setup read as deliberate progress, not a freeze.
struct MapLoadingView: View {
    let message: String

    var body: some View {
        ZStack {
            // Matches the app icon's blue gradient (Display P3) to keep launch and
            // home screen in one color scheme.
            LinearGradient(
                colors: [
                    Color(.displayP3, red: 0.52287, green: 0.80649, blue: 0.98183),
                    Color(.displayP3, red: 0.16138, green: 0.35032, blue: 0.83176),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)

                Text("WorldMap")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.white)
                    .controlSize(.large)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CountryDetailView: View {
    @Bindable var country: Country
    @Environment(\.modelContext) private var modelContext
    @State private var newVisitDate = Date()
    @State private var newVisitNotes = ""
    @State private var showingAddVisit = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("\(country.flagEmoji) \(country.name)")
                        .font(.largeTitle)
                        .bold()
                    Text(country.continent)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical)

                Picker("Status", selection: $country.status) {
                    ForEach(CountryStatus.allCases) { status in
                        Label(status.label, systemImage: status.symbolName)
                            .tag(status)
                    }
                }
            }

            if country.status.isVisited {
                Section("Visits") {
                    if country.visits.isEmpty {
                        ContentUnavailableView(
                            "No visits yet",
                            systemImage: "calendar",
                            description: Text("Add your first visit to this country")
                        )
                    } else {
                        ForEach(country.visits.sorted { $0.date > $1.date }) { visit in
                            VisitRow(visit: visit) { delete(visit) }
                        }
                        .onDelete(perform: deleteVisits)
                    }

                    if showingAddVisit {
                        DatePicker("Date", selection: $newVisitDate, displayedComponents: .date)
                        TextField("Notes", text: $newVisitNotes, axis: .vertical)
                            .lineLimit(3...5)

                        HStack {
                            Spacer()
                            Button("Cancel") {
                                showingAddVisit = false
                                newVisitDate = Date()
                                newVisitNotes = ""
                            }
                            Button("Add Visit") {
                                addVisit()
                            }
                        }
                    } else {
                        Button("Add Visit") {
                            showingAddVisit = true
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    private func addVisit() {
        let visit = Visit(date: newVisitDate, notes: newVisitNotes, country: country)
        country.visits.append(visit)

        showingAddVisit = false
        newVisitDate = Date()
        newVisitNotes = ""
    }

    /// Delete a single visit (used by the row's trash button).
    private func delete(_ visit: Visit) {
        modelContext.delete(visit)
    }

    /// Delete via swipe, matching the same date-sorted order shown in the list.
    private func deleteVisits(at offsets: IndexSet) {
        let sorted = country.visits.sorted { $0.date > $1.date }
        for index in offsets {
            modelContext.delete(sorted[index])
        }
    }
}

struct VisitRow: View {
    @Bindable var visit: Visit
    let onDelete: () -> Void
    @State private var isEditing = false
    @State private var editDate: Date
    @State private var editNotes: String

    init(visit: Visit, onDelete: @escaping () -> Void) {
        self.visit = visit
        self.onDelete = onDelete
        _editDate = State(initialValue: visit.date)
        _editNotes = State(initialValue: visit.notes)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("Date", selection: $editDate, displayedComponents: .date)
                TextField("Notes", text: $editNotes, axis: .vertical)
                    .lineLimit(3...5)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        isEditing = false
                    }
                    Button("Save") {
                        visit.date = editDate
                        visit.notes = editNotes
                        isEditing = false
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(visit.date, style: .date)
                            .font(.subheadline)
                            .monospacedDigit()

                        if !visit.notes.isEmpty {
                            Text(visit.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: { isEditing = true }) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }

                if !visit.photoIdentifiers.isEmpty {
                    VisitPhotosView(identifiers: visit.photoIdentifiers)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Country List Sheet

/// A bottom sheet that presents the full country list with search and filters.
/// Tapping a country selects it on the map and dismisses the sheet.
private struct CountryListSheet: View {
    let allCountries: [Country]

    @Binding var searchText: String
    @Binding var filterVisited: Bool?
    @Binding var selectedContinent: String?
    @Binding var selectedYear: Int?
    @Binding var expandedContinents: Set<String>
    @Binding var selectedCountry: Country?
    @Binding var isPresented: Bool

    let onAppear: () -> Void

    private var summary: CountryListSummary {
        CountryListSummary(
            countries: allCountries,
            searchText: searchText,
            filterVisited: filterVisited,
            selectedContinent: selectedContinent,
            selectedYear: selectedYear
        )
    }

    private var countriesGroupedByContinent: [String: [Country]] {
        Dictionary(grouping: summary.filteredCountries, by: { $0.continent })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Visited countries: \(summary.visitedCount) / \(allCountries.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if allCountries.isEmpty {
                    Text("Preparing database...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(countriesGroupedByContinent.keys.sorted(), id: \.self) { continent in
                        let countries = countriesGroupedByContinent[continent] ?? []
                        let isExpanded = Binding(
                            get: { expandedContinents.contains(continent) },
                            set: { newValue in
                                if newValue {
                                    expandedContinents.insert(continent)
                                } else {
                                    expandedContinents.remove(continent)
                                }
                            }
                        )

                        DisclosureGroup(isExpanded: isExpanded) {
                            ForEach(countries) { country in
                                Button {
                                    selectedCountry = country
                                    isPresented = false
                                } label: {
                                    CountryRow(country: country)
                                }
                            }
                        } label: {
                            Text(continent)
                                .font(.headline)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search countries")
            .navigationTitle("Countries")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Section("Status") {
                            Button("All") { filterVisited = nil }
                            Button("Visited") { filterVisited = true }
                            Button("Unvisited") { filterVisited = false }
                        }

                        Section("Continent") {
                            Button("All") { selectedContinent = nil }
                            ForEach(summary.continents, id: \.self) { continent in
                                Button(continent) { selectedContinent = continent }
                            }
                        }

                        if !summary.visitYears.isEmpty {
                            Section("Visit year") {
                                Button("All years") { selectedYear = nil }
                                ForEach(summary.visitYears, id: \.self) { year in
                                    Button(String(year)) { selectedYear = year }
                                }
                            }
                        }
                    } label: {
                        Label(
                            "Filter",
                            systemImage: summary.hasActiveFilters
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .onAppear {
                onAppear()
            }
        }
    }
}

// MARK: - Country Detail Sheet

/// A sheet that wraps CountryDetailView so the map doesn't resize and Metal
/// doesn't need to re-acquire drawables. iOS-native sheet avoids the black
/// rendering artifacts that the inspector produces when overlaid on a Map.
private struct CountryDetailSheet: View {
    @Bindable var country: Country
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CountryDetailView(country: country)
                .navigationTitle(country.name)
                #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
