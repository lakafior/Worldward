import MapKit
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
    @State private var showInspector = false
    @State private var showStats = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnHome = false
    @State private var expandedContinents: Set<String> = []

    // Filters
    @State private var filterVisited: Bool? = nil  // nil = all, true = visited, false = unvisited
    @State private var selectedContinent: String? = nil
    @State private var selectedYear: Int? = nil

    // Geographic data
    @State private var countryPolygons: [String: [MKPolygon]] = [:]
    @State private var countryPaths: [String: [CGPath]] = [:]
    @State private var countryBoundingRects: [String: MKMapRect] = [:]
    @State private var isLoadingMapData = true
    @State private var mapUpdateTrigger = UUID()

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

    var body: some View {
        NavigationSplitView {
            let countryList = countryListSummary

            List(selection: $selectedCountry) {
                Section(header: Text("Statistics")) {
                    Text("Visited countries: \(countryList.visitedCount) / \(allCountries.count)")
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
                                CountryRow(country: country)
                                    .tag(country)
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
            .onAppear {
                initializeExpandedContinents()
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        Section("Status") {
                            Button("All") { filterVisited = nil }
                            Button("Visited") { filterVisited = true }
                            Button("Unvisited") { filterVisited = false }
                        }

                        Section("Continent") {
                            Button("All") { selectedContinent = nil }
                            ForEach(countryList.continents, id: \.self) { continent in
                                Button(continent) { selectedContinent = continent }
                            }
                        }

                        if !countryList.visitYears.isEmpty {
                            Section("Visit year") {
                                Button("All years") { selectedYear = nil }
                                ForEach(countryList.visitYears, id: \.self) { year in
                                    Button(String(year)) { selectedYear = year }
                                }
                            }
                        }
                    } label: {
                        Label(
                            "Filter",
                            systemImage: countryList.hasActiveFilters
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                    }
                }
            }

        } detail: {
            ZStack {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        ForEach(visibleCountries) { country in
                            CountryMapPolygons(
                                country: country,
                                status: country.status,
                                polygons: countryPolygons[country.id] ?? [])
                        }
                    }
                    .id(mapUpdateTrigger)
                    .mapStyle(.standard)
                    .mapControls {
                        MapZoomStepper()
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
                }

                if isLoadingMapData {
                    VStack {
                        ProgressView()
                            .padding(.bottom, 5)
                        Text("Loading map data...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                } else {
                    MapLegend()
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .navigationTitle("World Map")
            .inspector(isPresented: $showInspector) {
                if let country = selectedCountry {
                    CountryDetailView(country: country)
                } else {
                    ContentUnavailableView(
                        "Select a country", systemImage: "map",
                        description: Text("Select a country from the list to see details."))
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showStats.toggle()
                    } label: {
                        Label("Statistics", systemImage: "chart.pie")
                    }
                    .popover(isPresented: $showStats, arrowEdge: .bottom) {
                        StatisticsView(countries: allCountries)
                    }

                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .disabled(selectedCountry == nil)
                }
            }
        }
        .onChange(of: selectedCountry) {
            if let country = selectedCountry {
                showInspector = true

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
        // Decode the 14 MB GeoJSON in the background so the main thread stays responsive
        let (extractedPolygons, extractedPaths, extractedRects) = await Task.detached(
            priority: .userInitiated
        ) {
            () -> ([String: [MKPolygon]], [String: [CGPath]], [String: MKMapRect]) in
            var polys: [String: [MKPolygon]] = [:]
            var paths: [String: [CGPath]] = [:]
            var rects: [String: MKMapRect] = [:]

            guard let geoUrl = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
                let data = try? Data(contentsOf: geoUrl)
            else { return ([:], [:], [:]) }

            let decoder = MKGeoJSONDecoder()
            guard let features = try? decoder.decode(data) as? [MKGeoJSONFeature] else {
                return ([:], [:], [:])
            }

            // Pass 1: collect each country's raw exterior-ring polygons. Interior
            // holes are dropped here, since they don't affect a flat country fill.
            var rawPolygons: [String: [MKPolygon]] = [:]
            for feature in features {
                guard let propsData = feature.properties,
                    let props = try? JSONSerialization.jsonObject(with: propsData)
                        as? [String: Any],
                    let rawID = props["ISO3166-1-Alpha-2"] as? String,
                    let name = props["name"] as? String
                else { continue }

                guard let id = WorldMap.resolvedID(isoA2: rawID, name: name) else { continue }

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
            // remaining outlines with Douglas-Peucker. Archipelago nations (Canada,
            // Norway, Indonesia…) collapse from thousands of rings/points down to a
            // handful — which is what keeps Metal from choking when many countries
            // are colored at once. Hit-test paths are built from the same simplified
            // points so tapping still matches what's drawn.
            for (id, countryPolygons) in rawPolygons {
                guard
                    let largest = countryPolygons.max(by: {
                        $0.boundingMapRect.area < $1.boundingMapRect.area
                    })
                else { continue }

                // Keep the mainland plus any island at least 0.5% of its size.
                let minIslandArea = largest.boundingMapRect.area * 0.005

                var simplifiedPolygons: [MKPolygon] = []
                var simplifiedPaths: [CGPath] = []
                for polygon in countryPolygons {
                    if polygon !== largest, polygon.boundingMapRect.area < minIslandArea {
                        continue
                    }

                    let points = simplifiedOutline(of: polygon)
                    guard points.count >= 3 else { continue }

                    simplifiedPolygons.append(MKPolygon(points: points, count: points.count))

                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: points[0].x, y: points[0].y))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x, y: point.y))
                    }
                    path.closeSubpath()
                    simplifiedPaths.append(path)
                }

                guard !simplifiedPolygons.isEmpty else { continue }
                polys[id] = simplifiedPolygons
                paths[id] = simplifiedPaths
                // Bounding rect uses only the largest polygon, so selecting a country
                // zooms to its mainland rather than a far-flung territory.
                rects[id] = largest.boundingMapRect
            }
            return (polys, paths, rects)
        }.value

        self.countryPolygons = extractedPolygons
        self.countryPaths = extractedPaths
        self.countryBoundingRects = extractedRects
        self.isLoadingMapData = false
        focusOnHomeIfNeeded()
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


struct CountryDetailView: View {
    @Bindable var country: Country
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
                        ForEach(country.visits) { visit in
                            VisitRow(visit: visit)
                        }
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
}

struct VisitRow: View {
    @Bindable var visit: Visit
    @State private var isEditing = false
    @State private var editDate: Date
    @State private var editNotes: String

    init(visit: Visit) {
        self.visit = visit
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
            }
            .padding(.vertical, 4)
        }
    }
}

