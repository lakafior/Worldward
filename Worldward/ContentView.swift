import AppIntents
import MapKit
import Photos
import SwiftData
import SwiftUI

/// Whether the country list is showing where you've **been** or where you're
/// **going** (your wishlist/planning). Drives the segmented control and which
/// countries the list shows when not searching.
enum BrowseMode: String, CaseIterable, Identifiable {
    case been = "Been"
    case going = "Going"
    var id: String { rawValue }
}

/// The app's three top-level tabs.
enum AppTab: Hashable {
    case map, been, going
}

/// Which countries to show on the map. `all` shows every visited/planned country;
/// `visited` hides planned-only countries; `planning` hides visited-only countries.
enum MapFilter: String, CaseIterable, Identifiable {
    case all
    case visited
    case planning
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: Str.Map.filterAll
        case .visited: Str.Map.filterVisited
        case .planning: Str.Map.filterPlanning
        }
    }
}

/// The available MapKit map styles. Persisted via @AppStorage.
enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case imagery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .hybrid: "Hybrid"
        case .imagery: "Satellite"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: "map"
        case .hybrid: "map.fill"
        case .imagery: "globe"
        }
    }

    /// The MapKit map style this option maps to.
    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard
        case .hybrid: .hybrid
        case .imagery: .imagery
        }
    }

    /// `true` for dark-background styles where the legend needs more contrast.
    var isDark: Bool { self != .standard }
}

/// A grid-based spatial index for map hit-testing. Matches the same grid
/// convention used by `SpatialIndex` in PhotoImporter, so a tap only tests
/// the 5-15 countries whose bounding rect overlaps the tapped cell.
struct WorldHitTestIndex: Sendable {
    private let cols: Int
    private let rows: Int
    private let world = MKMapRect.world
    private var cells: [Int: [String]] = [:]

    init(rects: [String: MKMapRect], cols: Int = 36, rows: Int = 18) {
        self.cols = cols
        self.rows = rows
        for (id, rect) in rects {
            let minCol = max(0, Int((rect.minX / world.width) * Double(cols)))
            let maxCol = min(cols - 1, Int((rect.maxX / world.width) * Double(cols)))
            let minRow = max(0, Int((rect.minY / world.height) * Double(rows)))
            let maxRow = min(rows - 1, Int((rect.maxY / world.height) * Double(rows)))
            for col in minCol...maxCol {
                for row in minRow...maxRow {
                    cells[row * cols + col, default: []].append(id)
                }
            }
        }
    }

    /// Country ids whose bounding rect spans the grid cell containing `point`.
    func candidates(for point: MKMapPoint) -> [String] {
        let col = min(cols - 1, max(0, Int((point.x / world.width) * Double(cols))))
        let row = min(rows - 1, max(0, Int((point.y / world.height) * Double(rows))))
        return cells[row * cols + col] ?? []
    }
}

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Country.continent), SortDescriptor(\Country.name)]) private
        var allCountries: [Country]

    @State private var searchText = ""
    @State private var selectedCountry: Country?
    @State private var detailCountry: Country?
    @State private var showAchievements = false
    @State private var showLogVisits = false
    @State private var logVisitsText = ""
    @State private var intentRouter = IntentRouter.shared
    @State private var showSettings = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnHome = false
    /// The selected top-level tab (Map / Been / Going).
    @State private var selectedTab: AppTab = .map
    /// Cached subset of `allCountries` that should appear on the map.
    /// Rebuilt via `onChange(of: allCountries.count)` so we don't filter all 250+
    /// rows on every SwiftUI body evaluation.
    @State private var visibleCountryCache: [Country] = []

    @State private var photoImporter = PhotoImporter()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Opens the auxiliary macOS windows (achievements, etc.). Unused on iOS.
    @Environment(\.openWindow) private var openWindow
    @AppStorage(NotificationManager.enabledKey) private var notificationsEnabled = false

    // Map search & filters
    @State private var mapSearchText = ""
    @State private var selectedContinent: String? = nil
    @State private var selectedYear: Int? = nil
    @State private var mapFilter: MapFilter = .all
    @AppStorage("mapStyle") private var mapStyle: MapStyleOption = .standard

    // Current-location marking
    @State private var isLocating = false
    @State private var locationCountry: Country?
    @State private var showLocationPicker = false
    @State private var locationStatus: CountryStatusOption = .visited
    /// Set when the Control Center "Mark where I am" control opened the app; held
    /// until the catalog is ready so a cold launch still resolves.
    @State private var pendingMarkHere = false

    // Geographic data
    @State private var countryPolygons: [String: [MKPolygon]] = [:]
    @State private var countryPaths: [String: [CGPath]] = [:]
    /// Per-country rect of the *largest* polygon only — used to zoom to a country's
    /// mainland rather than a far-flung territory.
    @State private var countryBoundingRects: [String: MKMapRect] = [:]
    /// Per-country rect spanning *all* of a country's polygons — used as the tap
    /// hit-test pre-filter so detached parts (Alaska, Greek islands, the Indonesian
    /// archipelago) are still selectable.
    @State private var countryHitRects: [String: MKMapRect] = [:]
    @State private var countryCentroids: [String: CLLocationCoordinate2D] = [:]
    /// Spatial index for map hit-testing: divides the world into a grid so a tap
    /// only tests countries whose bounding rect overlaps the tapped cell (typically
    /// 5-15 candidates instead of all ~250). Built once alongside the geometry.
    @State private var hitTestIndex: WorldHitTestIndex? = nil
    @State private var isLoadingMapData = true
    @State private var mapLoadingMessage = "Loading map…"

    /// The subset of countries to render on the map. Uses a cached array that is
    /// rebuilt when the catalog or selection changes, avoiding a full filter of
    /// all 250+ rows on every body evaluation.
    private var visibleCountries: [Country] {
        let base =
            visibleCountryCache.isEmpty
            ? allCountries.filter { $0.isVisited || $0.isPlanned || $0 == selectedCountry }
            : visibleCountryCache
        switch mapFilter {
        case .all: return base
        case .visited: return base.filter { $0.isVisited }
        case .planning: return base.filter { $0.isPlanned }
        }
    }

    /// Countries matching the map search text, used for search suggestions.
    private var mapSearchResults: [Country] {
        let term = mapSearchText.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [] }
        return allCountries.filter { $0.name.localizedStandardContains(term) }
            .sorted { $0.name < $1.name }
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
                        planStatus: country.planStatus,
                        polygons: countryPolygons[country.id] ?? [])
                }

                if let sel = selectedCountry {
                    if let centroid = countryCentroids[sel.id] {
                        Annotation(sel.name, coordinate: centroid, anchor: .bottom) {
                            Text(sel.flagEmoji)
                                .font(.title)
                                .padding(4)
                                .background(
                                    .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .mapStyle(mapStyle.mapStyle)
            .mapControls {
                // MapZoomStepper is macOS-only; iOS zooms via pinch gesture.
                #if os(macOS)
                    MapZoomStepper()
                #endif
                MapCompass()
                MapScaleView()
            }
            // Use `simultaneousGesture` rather than `.onTapGesture`: attaching a
            // plain tap recognizer directly to `Map` competes with MapKit's own
            // pan/pinch recognizers, which intermittently swallows taps and turns
            // drags into zooms. A simultaneous SpatialTapGesture runs alongside the
            // map's gestures instead of fighting them for each touch.
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    if let coordinate = proxy.convert(event.location, from: .local) {
                        let mapPoint = MKMapPoint(coordinate)
                        let cgPoint = CGPoint(x: mapPoint.x, y: mapPoint.y)

                        // Optimized lookup: use the spatial grid index to only test
                        // countries whose bounding rect overlaps the tapped cell
                        // (typically 5-15 candidates instead of all ~250),
                        // then hit-test individual paths.
                        let candidates =
                            hitTestIndex?.candidates(for: mapPoint) ?? allCountries.map(\.id)
                        for id in candidates {
                            guard let countryRect = countryHitRects[id],
                                countryRect.contains(mapPoint)
                            else { continue }

                            for path in countryPaths[id] ?? [] {
                                if path.contains(cgPoint) {
                                    if let country = allCountries.first(where: { $0.id == id }) {
                                        selectedCountry = country
                                        // Animate the map to center on the tapped country.
                                        if let rect = countryBoundingRects[id] {
                                            withAnimation(.easeInOut(duration: 0.4)) {
                                                cameraPosition = .region(MKCoordinateRegion(rect))
                                            }
                                        }
                                    }
                                    return
                                }
                            }
                        }
                    }
                }
            )
            // Prevent CAMetalLayer zero-size warnings during sheet transitions.
            .frame(minWidth: 1, minHeight: 1)
        }
    }

    /// The map (with its toolbar), shared by both platforms. On iOS it's the root
    /// of a `NavigationStack`; on macOS it's the detail pane of a split view.
    private var mapContent: some View {
        ZStack {
            // Render only the splash while loading, so it paints on the first
            // frame without MapKit/Metal initialization competing for it. The
            // map is built once the geometry is ready.
            if isLoadingMapData {
                MapLoadingView(message: mapLoadingMessage)
                    .transition(.opacity)
            } else {
                mapView

                MapLegend(isDark: mapStyle.isDark)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
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
                Menu {
                    Button {
                        Task { await markCurrentLocation() }
                    } label: {
                        Label("From Current Location", systemImage: "location.fill.viewfinder")
                    }
                    .disabled(isLocating || isLoadingMapData)

                    Button {
                        photoImporter.presentConfiguration()
                    } label: {
                        Label("From Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(!photoImporter.isReady || photoImporter.isImporting)

                    Button {
                        logVisitsText = ""
                        showLogVisits = true
                    } label: {
                        Label("From Description", systemImage: "text.bubble")
                    }
                } label: {
                    if isLocating {
                        ProgressView()
                    } else {
                        Label("Add", systemImage: "plus")
                    }
                }
            }

            ToolbarItem {
                Button {
                    #if os(macOS)
                        openWindow(id: "achievements")
                    #else
                        showAchievements = true
                    #endif
                } label: {
                    Label("Achievements", systemImage: "trophy")
                }
            }
        }
    }

    /// The root layout: a sidebar + map split on macOS (so the full country list
    /// is always visible), and the map alone on iOS (the list arrives as a sheet).
    /// Map / Been / Going as a Liquid Glass tab bar (bottom bar on iPhone, sidebar
    /// on iPad & Mac via `.sidebarAdaptable`). The map is the hero; the two lists
    /// are your history and your plans. Discovery/adding happens on the Map (tap a
    /// country → set its status or plan), so the lists stay curated collections.
    @ViewBuilder private var rootView: some View {
        #if os(macOS)
            macRoot
        #else
            TabView(selection: $selectedTab) {
                Tab("Map", systemImage: "map", value: AppTab.map) {
                    NavigationStack {
                        mapContent
                            .safeAreaInset(edge: .bottom) {
                                mapFilterBar
                            }
                    }
                    .searchable(
                        text: $mapSearchText, placement: .toolbar, prompt: "Find a country…"
                    )
                    .onSubmit(of: .search, flyToFirstSearchResult)
                    .searchSuggestions {
                        ForEach(mapSearchResults.prefix(8)) { country in
                            Button {
                                flyTo(country: country)
                            } label: {
                                Label(
                                    "\(country.flagEmoji) \(country.name)", systemImage: "mappin")
                            }
                        }
                    }
                }
                Tab("Been", systemImage: "checkmark.seal", value: AppTab.been) {
                    NavigationStack { countryList(.been) }
                }
                Tab("Going", systemImage: "airplane", value: AppTab.going) {
                    NavigationStack {
                        GoingView(
                            allCountries: allCountries,
                            centroids: countryCentroids,
                            searchText: $searchText,
                            selectedContinent: $selectedContinent,
                            selectedYear: $selectedYear,
                            selectedCountry: $selectedCountry)
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }

    #if os(macOS)
        /// The macOS root: a three-column split — a source-list sidebar of the
        /// top-level sections, the selected section's surface in the middle, and the
        /// selected country's detail on the right (replacing the iPhone detail sheet).
        private var macRoot: some View {
            NavigationSplitView {
                List(selection: $selectedTab) {
                    Label("Map", systemImage: "map").tag(AppTab.map)
                    Label("Been", systemImage: "checkmark.seal").tag(AppTab.been)
                    Label("Going", systemImage: "airplane").tag(AppTab.going)
                }
                .navigationTitle("Worldward")
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            } content: {
                sectionContent
                    .navigationSplitViewColumnWidth(min: 360, ideal: 540)
            } detail: {
                countryDetailColumn
            }
        }

        /// The middle column: whichever top-level section the sidebar selects.
        @ViewBuilder private var sectionContent: some View {
            switch selectedTab {
            case .map:
                mapContent
                    .safeAreaInset(edge: .bottom) { mapFilterBar }
                    .searchable(
                        text: $mapSearchText, placement: .toolbar, prompt: "Find a country…"
                    )
                    .onSubmit(of: .search, flyToFirstSearchResult)
                    .searchSuggestions {
                        ForEach(mapSearchResults.prefix(8)) { country in
                            Button {
                                flyTo(country: country)
                            } label: {
                                Label(
                                    "\(country.flagEmoji) \(country.name)", systemImage: "mappin")
                            }
                        }
                    }
            case .been:
                countryList(.been)
            case .going:
                GoingView(
                    allCountries: allCountries,
                    centroids: countryCentroids,
                    searchText: $searchText,
                    selectedContinent: $selectedContinent,
                    selectedYear: $selectedYear,
                    selectedCountry: $selectedCountry)
            }
        }

        /// The trailing detail column: the selected country, or a placeholder.
        @ViewBuilder private var countryDetailColumn: some View {
            if let country = selectedCountry {
                CountryDetailView(country: country)
                    .navigationTitle(country.name)
                    .navigationSubtitle(country.continent)
            } else {
                ContentUnavailableView(
                    "No Country Selected",
                    systemImage: "globe",
                    description: Text(
                        "Pick a country on the map or in a list to see its details.")
                )
            }
        }
    #endif

    private func countryList(_ mode: BrowseMode) -> some View {
        CountryListView(
            allCountries: allCountries,
            browseMode: mode,
            searchText: $searchText,
            selectedContinent: $selectedContinent,
            selectedYear: $selectedYear,
            selectedCountry: $selectedCountry
        )
    }

    var body: some View {
        rootView
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
            .sheet(isPresented: $showAchievements) {
                AchievementsView(countries: allCountries)
            }
            .sheet(isPresented: $showLogVisits) {
                LogVisitsView(initialText: logVisitsText)
            }
            // iOS opens the country detail as a sheet; macOS shows it in the split
            // view's trailing detail column (see `countryDetailColumn`).
            #if os(iOS)
                .sheet(item: $detailCountry) { country in
                    CountryDetailSheet(country: country)
                }
            #endif
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
            .sheet(isPresented: $showLocationPicker) {
                if let country = locationCountry {
                    LocationStatusSheet(
                        country: country,
                        status: $locationStatus,
                        onConfirm: { applyLocationStatus() },
                        onCancel: { showLocationPicker = false }
                    )
                }
            }
            .onChange(of: intentRouter.pendingLogVisitsText) { consumePendingLogVisits() }
            .onChange(of: intentRouter.pendingOpenStats) { consumePendingOpenStats() }
            .onChange(of: intentRouter.pendingOpenCountryID) { consumePendingOpenCountry() }
            .onChange(of: intentRouter.pendingSearchText) { consumePendingSearch() }
            // The catalog arrives after `loadGeoJSON`; re-try a pending country
            // selection once it does, so a cold-launched intent still resolves.
            // The count also changes as iCloud syncs rows in, so collapse any
            // duplicates that arrive from another device that seeded offline.
            .onChange(of: allCountries.count) {
                consumePendingOpenCountry()
                consumePendingMarkHere()
                deduplicateCountries()
                rebuildVisibleCache()
            }
            .onChange(of: selectedCountry) {
                rebuildVisibleCache()
            }
            .onChange(of: mapFilter) {
                rebuildVisibleCache()
            }
            // The "Mark where I am" Control Center control writes a request to the
            // App Group's UserDefaults before opening the app (the OpenIntent runs
            // first), so it's always present when .active fires. If it somehow misses,
            // the flag persists and is picked up on the next foreground cycle.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                checkControlRequest()
            }
            // Keep the Home/Lock Screen widgets in sync. `widgetSnapshotKey`
            // changes whenever a country is added, removed, or its status edited
            // (by hand, by an intent, or by the photo importer); `initial` also
            // writes once on launch so a fresh install populates the widget.
            .onChange(of: widgetSnapshotKey, initial: true) { updateWidgetSnapshot() }
            .onAppear {
                // Cold launch: an intent may have set these before the view existed.
                consumePendingLogVisits()
                consumePendingOpenStats()
                consumePendingOpenCountry()
                consumePendingSearch()
                checkControlRequest()
            }
    }

    /// Rebuild the cached visible-country set so the map view doesn't have to
    /// filter all 250+ rows on every body evaluation.
    private func rebuildVisibleCache() {
        visibleCountryCache = allCountries.filter {
            $0.isVisited || $0.isPlanned || $0 == selectedCountry
        }
    }

    // MARK: - Map Search & Filters

    /// The filter bar shown at the bottom of the map.
    @ViewBuilder private var mapFilterBar: some View {
        HStack(spacing: 4) {
            ForEach(MapFilter.allCases) { filter in
                Button {
                    mapFilter = filter
                } label: {
                    Text(filter.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            mapFilter == filter
                                ? Color.accentColor : Color.gray.opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(mapFilter == filter ? .white : .primary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Fly the map to a country's bounding rect and select it.
    private func flyTo(country: Country) {
        mapSearchText = ""
        selectedTab = .map
        if let rect = mapRect(for: country) {
            withAnimation(.easeInOut(duration: 0.5)) {
                cameraPosition = .rect(rect)
            }
        }
        selectedCountry = country
    }

    /// Fly to the first search result (for keyboard submit).
    private func flyToFirstSearchResult() {
        guard let first = mapSearchResults.first else { return }
        flyTo(country: first)
    }

    /// The padded map rectangle enclosing all of a country's polygons.
    private func mapRect(for country: Country) -> MKMapRect? {
        guard let rect = countryBoundingRects[country.id] else { return nil }
        // Add a small margin around the country outline
        let padding = rect.width * 0.2
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    /// Presents the log-visits sheet with any text an intent left pending, then
    /// clears it so it's consumed exactly once. Safe to call repeatedly.
    private func consumePendingLogVisits() {
        guard let text = intentRouter.pendingLogVisitsText else { return }
        intentRouter.pendingLogVisitsText = nil
        logVisitsText = text
        showLogVisits = true
    }

    /// Presents the stats dashboard if an intent requested it.
    private func consumePendingOpenStats() {
        guard intentRouter.pendingOpenStats else { return }
        intentRouter.pendingOpenStats = false
        showAchievements = true
    }

    /// Selects a country an intent requested. Waits for the catalog to load
    /// before clearing the request, so a cold-launched intent isn't dropped.
    private func consumePendingOpenCountry() {
        guard let id = intentRouter.pendingOpenCountryID, !allCountries.isEmpty else { return }
        intentRouter.pendingOpenCountryID = nil
        selectedTab = .map
        selectedCountry = allCountries.first { $0.id == id }
    }

    /// Applies a search term an intent requested by switching to the Been tab (its
    /// list searches across every country) and seeding the search field.
    private func consumePendingSearch() {
        guard let term = intentRouter.pendingSearchText else { return }
        intentRouter.pendingSearchText = nil
        searchText = term
        selectedTab = .been
    }

    /// Picks up a pending "Mark where I am" request left by the Control Center
    /// control, then tries to act on it. Safe to call on every activation.
    private func checkControlRequest() {
        if WidgetActionStore.consumeMarkHere() { pendingMarkHere = true }
        consumePendingMarkHere()
    }

    /// Runs the current-location flow once the catalog is loaded. Retried from the
    /// `allCountries.count` change so a cold launch from the control still resolves.
    private func consumePendingMarkHere() {
        guard pendingMarkHere, !allCountries.isEmpty else { return }
        pendingMarkHere = false
        Task { await markCurrentLocation() }
    }

    /// Requests the user's location, reverse‑geocodes it to a country, and presents
    /// a status picker. Called from the toolbar button.
    private func markCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }

        guard let isoCode = try? await LocationService.currentISOCountryCode() else { return }
        guard
            let country = allCountries.first(where: {
                $0.id == isoCode || $0.iso3 == isoCode
            })
        else { return }

        locationCountry = country
        locationStatus = .visited
        showLocationPicker = true
    }

    /// Persists the user's chosen status and dismisses the location picker.
    private func applyLocationStatus() {
        guard let country = locationCountry else { return }
        country.status = locationStatus.domainStatus
        country.statusIsImported = false
        showLocationPicker = false
        locationCountry = nil
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
        // background build knows whether it must also produce seed metadata. The
        // store needs seeding when it's empty or holds stale ids from an old build.
        let existing = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
        let stale = Worldward.hasStaleIDs(existing)
        let needsSeed = existing.isEmpty || stale

        // First run seeds the database, so say so rather than leaving a bare
        // spinner; later launches just rebuild the drawable geometry.
        mapLoadingMessage =
            needsSeed
            ? "Setting up your map…\nThis only happens once."
            : "Loading map…"

        // Decode the bundled country geometry. The binary format (~340 KB) is a
        // fast synchronous parse — the heavy GeoJSON decode and Douglas-Peucker
        // simplification were already done at build time in Tools/generate_geo.swift,
        // so this is cheap on every launch including the first.
        guard let bundled = loadBundledGeo() else { return }

        // Copy the bundled outline into the shared App Group container on a
        // background task so the widget extension (which can't read the bundle)
        // can draw the map. Re-copies only when the file changes between releases.
        Task.detached(priority: .background) {
            WorldMapStore.cacheFromAppBundle()
        }

        // Build MapKit display types on the main actor (MKPolygon, CGPath are not
        // Sendable and must be constructed on the actor that owns them).
        let geo = buildGeo(from: bundled.rings)
        let extractedPolygons = geo.0
        let extractedPaths = geo.1
        let extractedRects = geo.2
        let extractedHitRects = geo.3
        let seeds = bundled.seeds

        // Reconcile the database on the main actor — the only place SwiftData
        // models are touched. Seeding and reconciliation are mutually exclusive.
        if needsSeed {
            if !seeds.isEmpty { seedDatabase(seeds, wiping: stale ? existing : []) }
        } else {
            reconcileDatabase(existing, seeds: seeds)
        }

        // Collapse any duplicate rows iCloud may have produced (two devices that
        // both seeded offline). Cheap and idempotent on a clean store.
        deduplicateCountries()

        self.countryPolygons = extractedPolygons
        self.countryPaths = extractedPaths
        self.countryBoundingRects = extractedRects
        self.countryHitRects = extractedHitRects
        self.hitTestIndex = WorldHitTestIndex(rects: extractedHitRects)
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

        // The map geometry has now been cached into the App Group (inside the
        // detached task above). Rewrite the snapshot so the reload it triggers
        // happens *after* the geometry file exists — the map widget then finds it
        // on its next refresh and fills in.
        updateWidgetSnapshot()

        // Hand the geographic data to the photo importer now that it's ready.
        // Re-fetch so the importer gets every seeded country even if the `@Query`
        // hasn't refreshed yet this run loop. Doing this here (rather than via
        // onChange) guarantees it runs exactly once, so the "Import from Photos"
        // button reliably enables.
        let seededCountries = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? allCountries
        photoImporter.configure(
            countryBoundingRects: extractedHitRects,
            countryPaths: extractedPaths,
            allCountries: seededCountries
        )

        // Publish the catalog to Spotlight (and Apple Intelligence) once it's
        // settled. Gated internally, so this is a no-op on warm launches.
        Task { await CountrySpotlightIndexer.indexIfNeeded(seededCountries) }

        focusOnHomeIfNeeded()

        // Refresh local travel reminders from the freshly loaded catalog. A no-op
        // when the user hasn't enabled reminders (off by default — see SettingsView).
        await NotificationManager.reschedule(
            enabled: notificationsEnabled, countries: seededCountries)
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

    /// Reconcile an already-seeded store: drop non-countries an earlier seed stored,
    /// fix continents written by an older build, and add any catalog country the
    /// store is missing (e.g. an ISO code a later build started recognising, like
    /// Taiwan) so existing installs gain it without a full wipe-and-reseed.
    /// Idempotent and cheap.
    private func reconcileDatabase(_ existing: [Country], seeds: [CountrySeed]) {
        var changed = false
        var presentIDs = Set<String>()
        for country in existing {
            if Continents.byISO[country.id] == nil {
                modelContext.delete(country)
                changed = true
                continue
            }
            presentIDs.insert(country.id)
            let continent = Continents.name(for: country.id)
            if country.continent != continent {
                country.continent = continent
                changed = true
            }
        }
        for seed in seeds where Continents.byISO[seed.id] != nil && !presentIDs.contains(seed.id) {
            modelContext.insert(
                Country(
                    id: seed.id, iso3: seed.iso3, name: seed.name,
                    continent: Continents.name(for: seed.id)))
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    /// Merge duplicate `Country` rows that share an ISO id into a single row.
    ///
    /// CloudKit can't enforce a unique `id`, so if two devices each seed the
    /// catalog while offline, syncing leaves two rows per country. For each id
    /// this keeps the row with the smallest `dedupID` — a deterministic choice
    /// every device makes identically once synced, so they converge on the same
    /// winner rather than each deleting a different copy. User data from the
    /// losing rows (status, visits, notes) is folded into the winner first so
    /// nothing entered on either device is lost.
    private func deduplicateCountries() {
        let all = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
        let groups = Dictionary(grouping: all, by: \.id)

        var changed = false
        for (_, rows) in groups where rows.count > 1 {
            let ordered = rows.sorted { $0.dedupID < $1.dedupID }
            let winner = ordered[0]
            for loser in ordered.dropFirst() {
                merge(loser, into: winner)
                modelContext.delete(loser)
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }

    /// A cheap signature of every country's id and status. Recomputed each render
    /// (≈250 hashes, negligible) and watched by `onChange` so the widget snapshot
    /// is rewritten only when something the widgets show actually changes.
    private var widgetSnapshotKey: Int {
        var hasher = Hasher()
        for country in allCountries {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
        }
        return hasher.finalize()
    }

    /// Recompute the travel summary and hand it to the shared App Group store,
    /// which redraws the widgets. Reuses `TravelStats` so the figures always match
    /// the dashboard.
    @AppStorage("appTheme") private var widgetAppTheme: AppTheme = .system
    private func updateWidgetSnapshot() {
        let stats = TravelStats(countries: allCountries)
        WidgetSnapshotStore.write(
            WidgetSnapshot(
                visitedCountries: stats.visitedCountries,
                totalCountries: stats.totalCountries,
                visitedContinents: stats.visitedContinents,
                totalContinents: stats.totalContinents,
                flags: stats.visitedFlags,
                tints: stats.statusTints,
                appTheme: widgetAppTheme.rawValue))
    }

    /// Fold a duplicate country's user data into the row that will survive
    /// de-duplication. Visits are re-parented; a real status wins over
    /// `.notVisited` and a hand-set status wins over an imported one; notes are
    /// combined when they differ; the legacy `visitDate` fills in if missing.
    private func merge(_ loser: Country, into winner: Country) {
        for visit in Array(loser.visits) {
            visit.country = winner
        }

        if winner.status == .notVisited && loser.status != .notVisited {
            winner.status = loser.status
            winner.statusIsImported = loser.statusIsImported
        } else if winner.status != .notVisited && loser.status != .notVisited
            && winner.statusIsImported && !loser.statusIsImported
        {
            // Prefer the hand-set status over an imported one.
            winner.status = loser.status
            winner.statusIsImported = false
        }

        if winner.notes.isEmpty {
            winner.notes = loser.notes
        } else if !loser.notes.isEmpty && !winner.notes.contains(loser.notes) {
            winner.notes += "\n" + loser.notes
        }

        if winner.visitDate == nil { winner.visitDate = loser.visitDate }
    }
}
