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

/// How the Been/Going lists are ordered.
enum CountrySort: String, CaseIterable, Identifiable {
    case name = "Name"
    case recent = "Recently visited"
    var id: String { rawValue }
}

private struct CountryListSummary {
    let filteredCountries: [Country]
    let continents: [String]
    let visitYears: [Int]
    let visitedCount: Int
    let hasActiveFilters: Bool

    init(
        countries: [Country], searchText: String, browseMode: BrowseMode,
        selectedContinent: String?, selectedYear: Int?
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

            // With no search term, restrict the list to the active workflow: Been
            // shows where you've been, Going shows your wishlist/planning. While
            // searching, both modes show every match so you can find any country to
            // add to your plans.
            if trimmedSearch.isEmpty {
                switch browseMode {
                case .been: guard country.isVisited else { continue }
                case .going: guard country.isPlanned else { continue }
                }
            }

            guard selectedContinent == nil || country.continent == selectedContinent else {
                continue
            }

            if browseMode == .been, let selectedYear {
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
        self.hasActiveFilters = selectedContinent != nil || selectedYear != nil
    }
}

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Country.continent), SortDescriptor(\Country.name)]) private
        var allCountries: [Country]

    @State private var searchText = ""
    @State private var selectedCountry: Country?
    @State private var detailCountry: Country?
    @State private var showStats = false
    @State private var showChat = false
    @State private var showLogVisits = false
    @State private var logVisitsText = ""
    @State private var intentRouter = IntentRouter.shared
    @State private var showSettings = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnHome = false
    /// The selected top-level tab (Map / Been / Going).
    @State private var selectedTab: AppTab = .map

    @State private var photoImporter = PhotoImporter()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(NotificationManager.enabledKey) private var notificationsEnabled = false

    // Filters
    @State private var selectedContinent: String? = nil
    @State private var selectedYear: Int? = nil

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
    @State private var isLoadingMapData = true
    @State private var mapLoadingMessage = "Loading map…"

    private var visibleCountries: [Country] {
        allCountries.filter { $0.isVisited || $0.isPlanned || $0 == selectedCountry }
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
            }
            .mapStyle(.standard)
            .mapControls {
                // MapZoomStepper is macOS-only; iOS zooms via pinch gesture.
                #if os(macOS)
                    MapZoomStepper()
                #endif
                MapCompass()
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

                        // Optimized lookup: reject by the country's full-extent hit rect
                        // first (covers every polygon, not just the mainland), then test
                        // individual paths.
                        for country in allCountries {
                            guard let countryRect = countryHitRects[country.id],
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

                MapLegend()
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
                    showChat = true
                } label: {
                    Label("Ask About Your Travels", systemImage: "sparkles")
                }
            }

            ToolbarItem {
                Button {
                    showStats = true
                } label: {
                    Label("Statistics", systemImage: "chart.pie")
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
        TabView(selection: $selectedTab) {
            Tab("Map", systemImage: "map", value: AppTab.map) {
                NavigationStack { mapContent }
            }
            Tab("Been", systemImage: "checkmark.seal", value: AppTab.been) {
                NavigationStack { countryList(.been) }
            }
            Tab("Going", systemImage: "airplane", value: AppTab.going) {
                NavigationStack {
                    GoingView(
                        allCountries: allCountries,
                        searchText: $searchText,
                        selectedContinent: $selectedContinent,
                        selectedYear: $selectedYear,
                        selectedCountry: $selectedCountry)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }

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
            .sheet(isPresented: $showStats) {
                StatisticsView(countries: allCountries, centroids: countryCentroids)
            }
            .sheet(isPresented: $showChat) {
                TravelChatView()
            }
            .sheet(isPresented: $showLogVisits) {
                LogVisitsView(initialText: logVisitsText)
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
            }
            // The "Mark where I am" Control Center control opens the app and leaves
            // a request in the App Group; pick it up whenever the app becomes active.
            // The second, delayed check covers the case where the opening intent
            // writes the request slightly after the app becomes active.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                checkControlRequest()
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    checkControlRequest()
                }
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
        showStats = true
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
    private func updateWidgetSnapshot() {
        let stats = TravelStats(countries: allCountries)
        WidgetSnapshotStore.write(
            WidgetSnapshot(
                visitedCountries: stats.visitedCountries,
                totalCountries: stats.totalCountries,
                visitedContinents: stats.visitedContinents,
                totalContinents: stats.totalContinents,
                flags: stats.visitedFlags,
                tints: stats.statusTints))
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

struct CountryRow: View {
    let country: Country

    var body: some View {
        HStack(spacing: 6) {
            Text(country.flagEmoji)
            Text(country.name)
            Spacer()
            if country.isPlanned {
                Image(systemName: country.planStatus.symbolName)
                    .foregroundStyle(country.planStatus.tint)
            }
            if country.status.isVisited {
                Image(systemName: country.status.symbolName)
                    .foregroundStyle(country.status.color)
            }
        }
        // Make the whole row tappable, not just the drawn content (the Spacer gap
        // wouldn't register taps under a plain button otherwise).
        .contentShape(Rectangle())
    }
}

/// A subview that renders a single country's polygons. By isolating this into its
/// own view with a dependency on the `Country` object, SwiftUI can efficiently
/// observe changes to that specific country's status and redraw only these polygons.
struct CountryMapPolygons: MapContent {
    let country: Country
    let status: CountryStatus
    let planStatus: PlanStatus
    let polygons: [MKPolygon]

    /// Fill shows where you've *been* (warm); a country that's only planned shows
    /// its blue plan fill instead.
    private var fillColor: Color {
        status.isVisited ? status.fillColor : planStatus.fillColor
    }

    /// A planned country gets a blue outline — thicker so it reads as a ring even
    /// over a warm fill (a country that's both visited and on your list).
    private var strokeColor: Color {
        planStatus.isPlanned ? planStatus.strokeColor : status.strokeColor
    }

    private var lineWidth: CGFloat { planStatus.isPlanned ? 1.2 : 0.5 }

    var body: some MapContent {
        ForEach(polygons.indices, id: \.self) { index in
            MapPolygon(polygons[index])
                .foregroundStyle(fillColor)
                .stroke(strokeColor, lineWidth: lineWidth)
        }
    }
}

extension MKMapRect {
    /// Area in squared map points; a cheap proxy for comparing landmass sizes.
    fileprivate nonisolated var area: Double { width * height }
}

// MARK: - Bundled geometry

/// Decodes the bundled `countries.wmgb` — the pre-simplified country outlines and
/// seed metadata produced once per release by `Tools/generate_geo.swift`. Because
/// the heavy GeoJSON decode and Douglas-Peucker simplification happen at build
/// time (not on-device), the app ships ~340 KB instead of a 14 MB GeoJSON and the
/// first launch is as fast as every later one — no download, no on-device decode.
///
/// Binary format ("WMGB" v1), little-endian — kept in sync with the writer in
/// `Tools/generate_geo.swift`:
///   magic 'WMGB' · UInt32 version · UInt32 country count, then per country:
///   UInt8-prefixed id · UInt8-prefixed iso3 · UInt16-prefixed name ·
///   UInt16 ring count, then per ring: UInt32 point count · point × (Float32 x, y).
private nonisolated func loadBundledGeo() -> (
    rings: [String: [[MKMapPoint]]], seeds: [CountrySeed]
)? {
    guard let url = Bundle.main.url(forResource: "countries", withExtension: "wmgb"),
        let data = try? Data(contentsOf: url)
    else { return nil }

    return data.withUnsafeBytes {
        (raw: UnsafeRawBufferPointer) -> (
            rings: [String: [[MKMapPoint]]], seeds: [CountrySeed]
        )? in
        var offset = 0
        let total = raw.count

        func need(_ count: Int) -> Bool { offset + count <= total }
        func readU8() -> UInt8? {
            guard need(1) else { return nil }
            defer { offset += 1 }
            return raw.load(fromByteOffset: offset, as: UInt8.self)
        }
        func readU16() -> UInt16? {
            guard need(2) else { return nil }
            defer { offset += 2 }
            return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
        func readU32() -> UInt32? {
            guard need(4) else { return nil }
            defer { offset += 4 }
            return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func readFloat() -> Float? {
            guard let bits = readU32() else { return nil }
            return Float(bitPattern: bits)
        }
        func readString(_ length: Int) -> String? {
            guard need(length) else { return nil }
            defer { offset += length }
            return String(
                bytes: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + length]),
                encoding: .utf8)
        }

        guard let m0 = readU8(), let m1 = readU8(), let m2 = readU8(), let m3 = readU8(),
            m0 == 0x57, m1 == 0x4D, m2 == 0x47, m3 == 0x42,  // "WMGB"
            let version = readU32(), version == 1,
            let count = readU32()
        else { return nil }

        var rings: [String: [[MKMapPoint]]] = [:]
        var seeds: [CountrySeed] = []
        rings.reserveCapacity(Int(count))
        seeds.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let idLen = readU8(), let id = readString(Int(idLen)),
                let iso3Len = readU8(), let iso3 = readString(Int(iso3Len)),
                let nameLen = readU16(), let name = readString(Int(nameLen)),
                let ringCount = readU16()
            else { return nil }

            var countryRings: [[MKMapPoint]] = []
            countryRings.reserveCapacity(Int(ringCount))
            for _ in 0..<ringCount {
                guard let pointCount = readU32() else { return nil }
                var points: [MKMapPoint] = []
                points.reserveCapacity(Int(pointCount))
                for _ in 0..<pointCount {
                    guard let x = readFloat(), let y = readFloat() else { return nil }
                    points.append(MKMapPoint(x: Double(x), y: Double(y)))
                }
                countryRings.append(points)
            }

            rings[id] = countryRings
            seeds.append(CountrySeed(id: id, iso3: iso3, name: name))
        }

        return (rings, seeds)
    }
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
) -> ([String: [MKPolygon]], [String: [CGPath]], [String: MKMapRect], [String: MKMapRect]) {
    var polys: [String: [MKPolygon]] = [:]
    var paths: [String: [CGPath]] = [:]
    var rects: [String: MKMapRect] = [:]
    var hitRects: [String: MKMapRect] = [:]

    for (id, ringList) in rings {
        var polygons: [MKPolygon] = []
        var cgPaths: [CGPath] = []
        var largestRect: MKMapRect?
        var unionRect: MKMapRect?

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
            unionRect = unionRect.map { $0.union(rect) } ?? rect
        }

        guard !polygons.isEmpty, let largestRect, let unionRect else { continue }
        polys[id] = polygons
        paths[id] = cgPaths
        // Bounding rect uses only the largest polygon, so selecting a country
        // zooms to its mainland rather than a far-flung territory.
        rects[id] = largestRect
        // Hit rect spans every polygon, so a tap on a detached part (an island, an
        // exclave like Alaska) still resolves to the country.
        hitRects[id] = unionRect
    }
    return (polys, paths, rects, hitRects)
}

/// Compact key explaining the warm "been" shades and the blue "going" shades.
struct MapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(CountryStatus.visitedCases) { status in
                swatch(color: status.color, label: status.label)
            }
            Divider().frame(maxWidth: 90)
            ForEach(PlanStatus.plannedCases) { plan in
                swatch(color: plan.color, label: plan.label)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func swatch(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.caption2)
        }
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

                Text("Worldward")
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

            Section("Plans") {
                Picker("List", selection: $country.planStatus) {
                    ForEach(PlanStatus.allCases) { plan in
                        Label(plan.label, systemImage: plan.symbolName)
                            .tag(plan)
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
        // Advertise the country on screen so Siri and Apple Intelligence can
        // answer questions about it ("have I been here?"). Keyed on the stable
        // ISO id; the entity is rebuilt in the closure from the live model.
        .userActivity(CountryEntity.viewingActivityType, element: country.id) { _, activity in
            let entity = CountryEntity(from: country)
            activity.title = "Viewing \(entity.flagEmoji) \(entity.name)"
            activity.appEntityIdentifier = EntityIdentifier(for: entity)
        }
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

// MARK: - Country List

/// A full-screen, grouped country list backing the **Been** and **Going** tabs.
/// Filtered to the tab's `browseMode` (Been = visited, Going = wishlist/planning);
/// tapping a row opens that country's detail via `selectedCountry`. Searching
/// matches across every country so you can still find any one to open.
struct CountryListView: View {
    let allCountries: [Country]
    let browseMode: BrowseMode

    @Binding var searchText: String
    @Binding var selectedContinent: String?
    @Binding var selectedYear: Int?
    @Binding var selectedCountry: Country?

    @State private var sortOrder: CountrySort = .name

    private var summary: CountryListSummary {
        CountryListSummary(
            countries: allCountries,
            searchText: searchText,
            browseMode: browseMode,
            selectedContinent: selectedContinent,
            selectedYear: selectedYear
        )
    }

    private var countriesGroupedByContinent: [String: [Country]] {
        Dictionary(grouping: summary.filteredCountries, by: { $0.continent })
    }

    /// Filtered countries ordered by most recent visit (newest first); countries
    /// with no recorded visit fall to the bottom, then alphabetically.
    private var recentlySorted: [Country] {
        summary.filteredCountries.sorted { lhs, rhs in
            switch (lastVisit(lhs), lastVisit(rhs)) {
            case (let l?, let r?): return l == r ? lhs.name < rhs.name : l > r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.name < rhs.name
            }
        }
    }

    private var count: Int { summary.filteredCountries.count }

    /// The most recent visit date for a country, including the legacy `visitDate`.
    private func lastVisit(_ country: Country) -> Date? {
        var dates = country.visits.map(\.date)
        if let legacy = country.visitDate { dates.append(legacy) }
        return dates.max()
    }

    var body: some View {
        Group {
            if allCountries.isEmpty {
                ProgressView()
            } else if summary.filteredCountries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .searchable(text: $searchText, prompt: "Search countries")
        .navigationTitle(browseMode == .been ? "Been" : "Going")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { sortAndFilterMenu }
    }

    private var list: some View {
        List {
            Section {
                Text("\(count) \(count == 1 ? "country" : "countries")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Name keeps the familiar by-continent grouping; recency is a flat,
            // global order where continent sections wouldn't make sense.
            if sortOrder == .name {
                ForEach(countriesGroupedByContinent.keys.sorted(), id: \.self) { continent in
                    Section(continent) {
                        ForEach(countriesGroupedByContinent[continent] ?? []) { country in
                            row(country)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(recentlySorted) { country in
                        row(country)
                    }
                }
            }
        }
    }

    private func row(_ country: Country) -> some View {
        Button {
            selectedCountry = country
        } label: {
            CountryRow(country: country)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var emptyState: some View {
        if browseMode == .been {
            ContentUnavailableView(
                "No countries yet",
                systemImage: "map",
                description: Text("Tap a country on the Map to mark where you've been."))
        } else {
            ContentUnavailableView(
                "Nothing planned yet",
                systemImage: "airplane",
                description: Text("Find a country on the Map and add it to your wishlist."))
        }
    }

    @ToolbarContentBuilder private var sortAndFilterMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(CountrySort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }

                Section("Continent") {
                    Button("All") { selectedContinent = nil }
                    ForEach(summary.continents, id: \.self) { continent in
                        Button(continent) { selectedContinent = continent }
                    }
                }

                if browseMode == .been, !summary.visitYears.isEmpty {
                    Section("Visit year") {
                        Button("All years") { selectedYear = nil }
                        ForEach(summary.visitYears, id: \.self) { year in
                            Button(String(year)) { selectedYear = year }
                        }
                    }
                }
            } label: {
                Label(
                    "Sort & Filter",
                    systemImage: summary.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
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

// MARK: - Location Status Sheet

/// A compact sheet that appears after the "Mark Location" toolbar button resolves
/// the current country. Shows the flag, name, and a status picker.
private struct LocationStatusSheet: View {
    @Bindable var country: Country
    @Binding var status: CountryStatusOption
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Text(country.flagEmoji)
                            .font(.largeTitle)
                        VStack(alignment: .leading) {
                            Text(country.name)
                                .font(.headline)
                            Text(country.continent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Travel Status") {
                    Picker("Status", selection: $status) {
                        ForEach(CountryStatusOption.allCases) { option in
                            HStack {
                                Image(
                                    systemName: option.domainStatus.symbolName
                                )
                                .foregroundStyle(option.domainStatus.tint)
                                Text(option.domainStatus.label)
                            }
                            .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Mark Location")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark", action: onConfirm)
                }
            }
        }
    }
}
