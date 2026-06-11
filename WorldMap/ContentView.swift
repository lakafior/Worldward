import SwiftUI
import SwiftData
import MapKit

struct CountryPolygon: Identifiable {
    let id = UUID()
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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Country.continent), SortDescriptor(\Country.name)]) private var allCountries: [Country]
    
    @State private var searchText = ""
    @State private var selectedCountry: Country?
    @State private var showInspector = false
    @State private var showStats = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    
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
                                .foregroundStyle(item.country.isVisited ? .green.opacity(0.5) : .clear)
                                .stroke(item.country.isVisited ? .green : .gray.opacity(0.2), lineWidth: 0.5)
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
                if let polys = countryPolygons[country.id], !polys.isEmpty {
                    var mapRect = polys.first!.boundingMapRect
                    for poly in polys.dropFirst() {
                        mapRect = mapRect.union(poly.boundingMapRect)
                    }
                    // Add a small margin around the country outline
                    let padding = mapRect.width * 0.2
                    let paddedRect = mapRect.insetBy(dx: -padding, dy: -padding)
                    
                    withAnimation {
                        cameraPosition = .rect(paddedRect)
                    }
                }
            }
        }
        .onChange(of: allCountries) { _, _ in
            updateMapPolygons()
        }
        .task {
            await loadGeoJSON()
        }
    }
    
    private func updateMapPolygons() {
        // Generate polygons once both source lists are loaded and mapPolygons is empty
        guard !allCountries.isEmpty, !countryPolygons.isEmpty, mapPolygons.isEmpty else { return }
        
        var results: [CountryPolygon] = []
        for country in allCountries {
            if let polys = countryPolygons[country.id] {
                for poly in polys {
                    results.append(CountryPolygon(country: country, polygon: poly))
                }
            }
        }
        self.mapPolygons = results
    }
    
    private func loadGeoJSON() async {
        // Decode the 14 MB GeoJSON in the background so the main thread stays responsive
        let extractedPolygons = await Task.detached(priority: .userInitiated) { () -> [String: [MKPolygon]] in
            var extracted: [String: [MKPolygon]] = [:]
            
            let geoJSONPath = "/Volumes/wew/Git/WorldMap/WorldMap/countries.geojson"
            let geoUrl = Bundle.main.url(forResource: "countries", withExtension: "geojson") ?? URL(fileURLWithPath: geoJSONPath)
            
            guard let data = try? Data(contentsOf: geoUrl) else { return [:] }
            
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
        updateMapPolygons()
    }
}

struct CountryRow: View {
    let country: Country

    var body: some View {
        HStack {
            Text(country.flagEmoji)
            Text(country.name)
            Spacer()
            if country.isVisited {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
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
                
                Toggle("Visited", isOn: $country.isVisited)
                    .toggleStyle(.switch)
                
                if country.isVisited {
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

struct StatisticsView: View {
    var countries: [Country]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Travel Statistics")
                .font(.title2)
                .bold()
                .padding(.bottom, 4)
            
            // Overall
            let visited = countries.filter { $0.isVisited }.count
            let total = countries.count
            let percent = total > 0 ? Double(visited) / Double(total) * 100 : 0
            
            StatRow(title: "Visited countries", value: "\(visited) / \(total)", percent: percent)
            
            // Continents overall
            let allContinents = Set(countries.map { $0.continent })
            let visitedContinents = Set(countries.filter { $0.isVisited }.map { $0.continent })
            let contPercent = allContinents.count > 0 ? Double(visitedContinents.count) / Double(allContinents.count) * 100 : 0
            
            StatRow(title: "Visited continents", value: "\(visitedContinents.count) / \(allContinents.count)", percent: contPercent)
            
            Divider()
            
            // By continent
            Text("By continent")
                .font(.headline)
            
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(allContinents.sorted(), id: \.self) { continent in
                        let cCountries = countries.filter { $0.continent == continent }
                        let cVisited = cCountries.filter { $0.isVisited }.count
                        let cTotal = cCountries.count
                        let cPercent = cTotal > 0 ? Double(cVisited) / Double(cTotal) * 100 : 0
                        
                        StatRow(title: continent, value: "\(cVisited) / \(cTotal)", percent: cPercent)
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding()
        .frame(width: 350, height: 450)
    }
}

struct StatRow: View {
    var title: String
    var value: String
    var percent: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
            HStack {
                ProgressView(value: percent, total: 100)
                    .tint(.green)
                Text(String(format: "%.1f%%", percent))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 45, alignment: .trailing)
            }
        }
    }
}
