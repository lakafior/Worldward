import SwiftUI
import SwiftData
import MapKit

struct CountryPolygon: Identifiable {
    // Deterministic and status-dependent: stable across rebuilds for unchanged
    // countries, but changes the instant a country's status changes, so the Map
    // restyles only that polygon instead of reusing its cached overlay.
    let id: String
    let country: Country
    let polygon: MKPolygon
}

private struct CountryListSummary {
    let filteredCountries: [Country]
    let continents: [String]
    let visitYears: [Int]
    let visitedCount: Int
    let hasActiveFilters: Bool

    init(countries: [Country], searchText: String, filterVisited: Bool?, selectedContinent: String?, selectedYear: Int?) {
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

            guard trimmedSearch.isEmpty || country.name.localizedCaseInsensitiveContains(trimmedSearch) else { continue }
            guard filterVisited == nil || country.isVisited == filterVisited else { continue }
            guard selectedContinent == nil || country.continent == selectedContinent else { continue }

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
        self.hasActiveFilters = filterVisited != nil || selectedContinent != nil || selectedYear != nil
    }
}

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Country.continent), SortDescriptor(\Country.name)]) private var allCountries: [Country]
    
    @State private var searchText = ""
    @State private var selectedCountry: Country?
    @State private var showInspector = false
    @State private var showStats = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnHome = false

    // Filters
    @State private var filterVisited: Bool? = nil // nil = all, true = visited, false = unvisited
    @State private var selectedContinent: String? = nil
    @State private var selectedYear: Int? = nil
    
    // Geographic data
    @State private var countryPolygons: [String: [MKPolygon]] = [:]
    @State private var mapPolygons: [CountryPolygon] = []
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
                        Label("Filter", systemImage: countryList.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            
        } detail: {
            ZStack {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        ForEach(mapPolygons) { item in
                            MapPolygon(item.polygon)
                                .foregroundStyle(item.country.status.fillColor)
                                .stroke(item.country.status.strokeColor, lineWidth: 0.5)
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
                            
                            // A linear search on the main loop is fast enough when boundingMapRect is checked first.
                            for item in mapPolygons {
                                if item.polygon.boundingMapRect.contains(mapPoint) {
                                    let renderer = MKPolygonRenderer(polygon: item.polygon)
                                    let rendererPoint = renderer.point(for: mapPoint)
                                    if renderer.path.contains(rendererPoint) {
                                        selectedCountry = item.country
                                        break
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
                    ContentUnavailableView("Select a country", systemImage: "map", description: Text("Select a country from the list to see details."))
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
        .onChange(of: allCountries.map(\.status)) {
            // Fires on initial load and whenever any country's status changes,
            // keeping the map colors in sync in real time.
            rebuildMapPolygons()
        }
        .task {
            await loadGeoJSON()
        }
    }
    
    /// Rewraps the cached geometry into renderable polygons using each country's
    /// current status. Cheap (no GeoJSON decoding), so it is safe to call whenever
    /// a status changes — only the affected country's polygons get a new identity.
    private func rebuildMapPolygons() {
        guard !allCountries.isEmpty, !countryPolygons.isEmpty else { return }

        var results: [CountryPolygon] = []
        for country in allCountries {
            guard let polys = countryPolygons[country.id] else { continue }
            for (index, poly) in polys.enumerated() {
                results.append(CountryPolygon(
                    id: "\(country.id)#\(index)#\(country.status.rawValue)",
                    country: country,
                    polygon: poly
                ))
            }
        }
        self.mapPolygons = results
        focusOnHomeIfNeeded()
    }

    /// The padded map rectangle enclosing all of a country's polygons.
    private func mapRect(for country: Country) -> MKMapRect? {
        guard let polys = countryPolygons[country.id], !polys.isEmpty else { return nil }

        var rect = polys.first!.boundingMapRect
        for poly in polys.dropFirst() {
            rect = rect.union(poly.boundingMapRect)
        }
        // Add a small margin around the country outline
        let padding = rect.width * 0.2
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    /// On first load, open the map centered on the country the user lives in, if any.
    private func focusOnHomeIfNeeded() {
        guard !hasCenteredOnHome, !mapPolygons.isEmpty else { return }
        hasCenteredOnHome = true

        guard let home = allCountries.first(where: { $0.status == .living }),
              let rect = mapRect(for: home) else { return }
        cameraPosition = .rect(rect)
    }
    
    private func loadGeoJSON() async {
        // Decode the 14 MB GeoJSON in the background so the main thread stays responsive
        let extractedPolygons = await Task.detached(priority: .userInitiated) { () -> [String: [MKPolygon]] in
            var extracted: [String: [MKPolygon]] = [:]

            guard let geoUrl = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
                  let data = try? Data(contentsOf: geoUrl) else { return [:] }
            
            let decoder = MKGeoJSONDecoder()
            guard let features = try? decoder.decode(data) as? [MKGeoJSONFeature] else { return [:] }
            
            for feature in features {
                guard let propsData = feature.properties,
                      let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any],
                      let id = props["ISO3166-1-Alpha-2"] as? String else { continue }
                
                var featurePolygons: [MKPolygon] = []
                for geometry in feature.geometry {
                    if let polygon = geometry as? MKPolygon {
                        featurePolygons.append(polygon)
                    } else if let multiPolygon = geometry as? MKMultiPolygon {
                        featurePolygons.append(contentsOf: multiPolygon.polygons)
                    }
                }
                
                if extracted[id] != nil {
                    extracted[id]?.append(contentsOf: featurePolygons)
                } else {
                    extracted[id] = featurePolygons
                }
            }
            return extracted
        }.value
        
        self.countryPolygons = extractedPolygons
        self.isLoadingMapData = false
        rebuildMapPolygons()
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
                    DatePicker("Visit date",
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
