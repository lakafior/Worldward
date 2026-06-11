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
                guard let visitDate = country.visitDate else { continue }
                guard calendar.component(.year, from: visitDate) == selectedYear else { continue }
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

    // Filters
    @State private var filterVisited: Bool? = nil  // nil = all, true = visited, false = unvisited
    @State private var selectedContinent: String? = nil
    @State private var selectedYear: Int? = nil

    // Geographic data
    @State private var countryPolygons: [String: [MKPolygon]] = [:]
    @State private var countryPaths: [String: [CGPath]] = [:]
    @State private var countryBoundingRects: [String: MKMapRect] = [:]
    @State private var isLoadingMapData = true

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
                }

                ForEach(countryList.filteredCountries) { country in
                    CountryRow(country: country)
                        .tag(country)
                }
            }
            .searchable(text: $searchText, prompt: "Search countries")
            .navigationTitle("Countries")
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
                                country: country, polygons: countryPolygons[country.id] ?? [])
                        }
                    }
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

            for feature in features {
                guard let propsData = feature.properties,
                    let props = try? JSONSerialization.jsonObject(with: propsData)
                        as? [String: Any],
                    let id = props["ISO3166-1-Alpha-2"] as? String
                else { continue }

                var featurePolygons: [MKPolygon] = []
                for geometry in feature.geometry {
                    if let polygon = geometry as? MKPolygon {
                        featurePolygons.append(polygon)
                    } else if let multiPolygon = geometry as? MKMultiPolygon {
                        featurePolygons.append(contentsOf: multiPolygon.polygons)
                    }
                }

                if !featurePolygons.isEmpty {
                    polys[id] = (polys[id] ?? []) + featurePolygons

                    // Generate CGPaths for fast hit testing
                    var featurePaths: [CGPath] = []
                    for polygon in featurePolygons {
                        let path = CGMutablePath()
                        let points = polygon.points()
                        if polygon.pointCount > 0 {
                            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
                            for i in 1..<polygon.pointCount {
                                path.addLine(to: CGPoint(x: points[i].x, y: points[i].y))
                            }
                            path.closeSubpath()
                        }
                        featurePaths.append(path)
                    }
                    paths[id] = (paths[id] ?? []) + featurePaths

                    // Calculate bounding rect
                    var rect = featurePolygons[0].boundingMapRect
                    for p in featurePolygons.dropFirst() {
                        rect = rect.union(p.boundingMapRect)
                    }

                    if let existingRect = rects[id] {
                        rects[id] = existingRect.union(rect)
                    } else {
                        rects[id] = rect
                    }
                }
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
    let polygons: [MKPolygon]

    var body: some MapContent {
        ForEach(polygons.indices, id: \.self) { index in
            MapPolygon(polygons[index])
                .foregroundStyle(country.status.fillColor)
                .stroke(country.status.strokeColor, lineWidth: 0.5)
        }
    }
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

                if country.status.isVisited {
                    DatePicker(
                        "Visit date",
                        selection: Binding(
                            get: { country.visitDate ?? Date() },
                            set: { country.visitDate = $0 }
                        ), displayedComponents: .date)

                    TextField("Notes", text: $country.notes, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
    }
}
