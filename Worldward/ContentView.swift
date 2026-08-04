/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import EventKit
import MapKit
import Photos
import SwiftData
import SwiftUI

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
        case .standard: String(localized: "Standard", comment: "Map style")
        case .hybrid: String(localized: "Hybrid", comment: "Map style")
        case .imagery: String(localized: "Satellite", comment: "Map style")
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

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Country.continent), SortDescriptor(\Country.name)]) private
        var allCountries: [Country]

    // Trips and visits are deliberately *not* queried here: `StoreWatchers`
    // owns those queries (and the change signatures over them), so a packing
    // tick or visit edit invalidates that tiny hidden view instead of this
    // whole scene.

    @State private var searchText = ""
    @State private var selectedCountry: Country?
    @State private var detailCountry: Country?
    @State private var showAchievements = false
    /// The achievement-unlock toast currently on screen, if any. A newer unlock
    /// replaces it (and restarts the auto-dismiss timer via `.task(id:)`).
    @State private var celebration: AchievementCelebration?
    @State private var showLogVisits = false
    @State private var logVisitsText = ""
    @State private var intentRouter = IntentRouter.shared
    @State private var showSettings = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnHome = false
    /// The selected top-level tab (Map / Been / Going). iOS only.
    @State private var selectedTab: AppTab = .map
    #if os(macOS)
        /// The in-window destinations pushed over the map (Your Travels, Chat).
        /// Published to the Go menu via `focusedSceneValue` in `macRoot`.
        @State private var macPath: [MacDestination] = []
        /// Which list the macOS sidebar shows (Been or Going).
        @State private var sidebarMode: BrowseMode = .been
        /// Presents the map toolbar's "Add ▸ From List…" country picker, which
        /// stands in for `CountryListView`'s own "+" on macOS (see that file).
        @State private var showAddCountryPicker = false
    #endif
    /// The trip shown in the macOS detail column. Mutually exclusive with
    /// `selectedCountry` so the trailing pane always has one unambiguous
    /// subject. Unused on iOS, where trips open as a sheet instead.
    @State private var selectedTrip: Trip?
    /// The trip whose itinerary route is drawn on the map, set via the trip
    /// editor's "View Route on Map" button. Cleared from the on-map chip.
    @State private var mapTrip: Trip?
    /// Cached subset of `allCountries` that should appear on the map, or `nil`
    /// before the first rebuild. Optional (rather than "empty means unbuilt") so
    /// a user with a legitimately empty visible set doesn't re-filter all 250+
    /// rows on every SwiftUI body evaluation.
    @State private var visibleCountryCache: [Country]? = nil

    @State private var photoImporter = PhotoImporter()
    /// A `.wwtrip` file opened from outside (AirDrop, Files, Mail), held for
    /// the add-or-update confirm sheet. See `TripFileTransfer.swift`.
    @State private var receivedTripFile: ReceivedTripFile?
    @State private var tripFileError: String?
    /// In-flight debounce for the EventKit syncs — see `scheduleEventKitSync()`.
    @State private var eventKitSyncDebounce: Task<Void, Never>?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Opens a trip contact's `tel:`/`wa.me`/`mailto:` action when the trip
    /// widget's contact chip is tapped (see `consumePendingContactAction`).
    @Environment(\.openURL) private var openURL
    /// Camera fly-tos and the toast's slide-in are real motion; with Reduce
    /// Motion on they become instant jumps / plain fades.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The map filter bar marks its selection by fill color alone; with
    /// Differentiate Without Color on it gains a checkmark.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
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
    /// Why the last "From Current Location" attempt failed, shown in an alert.
    /// Without it a denial or geocode failure just stopped the spinner silently.
    @State private var locationError: String?
    /// Set when the Control Center "Mark where I am" control opened the app; held
    /// until the catalog is ready so a cold launch still resolves.
    @State private var pendingMarkHere = false

    // Geographic data
    @State private var countryPolygons: [String: [MKPolygon]] = [:]
    /// Minor islands per country (below 0.5% of the mainland's size), drawn only
    /// when the camera is zoomed in — see `WorldMapView.mapPolygons(for:)`.
    @State private var countryDetailPolygons: [String: [MKPolygon]] = [:]
    /// `true` once the live map has been revealed from behind `MapLaunchPreview`.
    @State private var mapRevealed = false
    /// Status/plan ranks for `MapLaunchPreview`, built once during the data load.
    @State private var launchTints: [String: Int] = [:]
    @State private var countryPaths: [String: [CGPath]] = [:]
    /// Per-country rect of the *largest* polygon only — used to zoom to a country's
    /// mainland rather than a far-flung territory.
    @State private var countryBoundingRects: [String: MKMapRect] = [:]
    /// Per-country rect spanning *all* of a country's polygons — used as the tap
    /// hit-test pre-filter so detached parts (Alaska, Greek islands, the Indonesian
    /// archipelago) are still selectable.
    @State private var countryHitRects: [String: MKMapRect] = [:]
    @State private var countryCentroids: [String: CLLocationCoordinate2D] = [:]
    /// Spatial index for map hit-testing, built once alongside the geometry.
    @State private var hitTestIndex: GeoGridIndex? = nil
    @State private var isLoadingMapData = true
    @State private var mapLoadingMessage = String(
        localized: "Loading map…", comment: "First-launch splash while country geometry is built")

    /// The subset of countries to render on the map. Uses a cached array that is
    /// rebuilt when the catalog or selection changes, avoiding a full filter of
    /// all 250+ rows on every body evaluation.
    private var visibleCountries: [Country] {
        let base =
            visibleCountryCache
            ?? allCountries.filter { $0.isVisited || $0.isPlanned || $0 == selectedCountry }
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
        return allCountries.filter {
            $0.name.localizedStandardContains(term)
                || $0.localizedName.localizedStandardContains(term)
        }
        .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    /// The interactive world map. Extracted into `WorldMapView` (and diffed via
    /// its `Equatable` conformance) so high-frequency state in this view —
    /// search keystrokes, sheet flags, the achievement toast — no longer
    /// re-evaluates the Map content builder.
    private var mapView: some View {
        WorldMapView(
            allCountries: allCountries,
            visibleCountries: visibleCountries,
            polygons: countryPolygons,
            detailPolygons: countryDetailPolygons,
            paths: countryPaths,
            boundingRects: countryBoundingRects,
            hitRects: countryHitRects,
            centroids: countryCentroids,
            hitTestIndex: hitTestIndex,
            mapStyle: mapStyle,
            mapTrip: mapTrip,
            selectedCountry: $selectedCountry,
            cameraPosition: $cameraPosition,
            onFirstLive: handleMapBecameLive
        )
        .equatable()
    }

    /// The map has delivered its first camera callback: timestamp MapKit
    /// readiness in the DEBUG launch log, give the first tiles a beat to render
    /// behind the launch preview, then crossfade it away.
    private func handleMapBecameLive() {
        LaunchClock.mark("map: first camera callback (live)")
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            LaunchClock.mark("map: revealing")
            withAnimation(.easeInOut(duration: 0.8)) { mapRevealed = true }
        }
    }

    /// The map (with its toolbar), shared by both platforms. On iOS it's the root
    /// of a `NavigationStack`; on macOS it's the detail pane of a split view.
    private var mapContent: some View {
        ZStack {
            // Build the map immediately, even though the splash covers it, so
            // MapKit's one-time costs — Metal setup and the tile download for
            // the initial camera — run concurrently with the catalog/geometry
            // load instead of starting only after the splash clears. On a cold
            // first launch the tile fetch dominates, and this overlaps it fully;
            // the overlays fill in when the geometry lands.
            mapView

            // Between the data load and MapKit's first render, cover the map
            // with an instant Canvas drawing of the user's world — so a cold
            // start shows *their map* in well under a second while tiles
            // download behind it. Never traps input: by the time anything is
            // tappable underneath, the reveal is already under way.
            if !isLoadingMapData && !mapRevealed {
                MapLaunchPreview(tints: launchTints, isDark: mapStyle.isDark)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if isLoadingMapData {
                MapLoadingView(message: mapLoadingMessage)
                    .transition(.opacity)
            } else if mapRevealed {
                MapLegend(isDark: mapStyle.isDark)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                if let trip = mapTrip, trip.modelContext != nil {
                    tripRouteChip(trip)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                }
            }
        }
        #if os(macOS)
            .navigationSubtitle("Click a country to see its details")
        #endif
        .toolbar {
            // On macOS the map filter is a native segmented control in the
            // toolbar; iOS keeps the floating capsule bar (see mapFilterBar).
            #if os(macOS)
                ToolbarItem {
                    Picker("Filter", selection: $mapFilter) {
                        ForEach(MapFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Button {
                        push(.travels)
                    } label: {
                        Label("Your Travels", systemImage: "chart.pie")
                    }
                }
                ToolbarItem {
                    Button {
                        push(.chat)
                    } label: {
                        Label("Ask About Your Travels", systemImage: "sparkles")
                    }
                }
            #endif
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

                    // macOS has no separate "+" in the sidebar list (see
                    // `CountryListView`), so the quick pick-by-name flow folds
                    // in here instead of sitting in its own toolbar button.
                    #if os(macOS)
                        Divider()

                        Button {
                            showAddCountryPicker = true
                        } label: {
                            Label("From List…", systemImage: "list.bullet")
                        }

                        // Same reasoning as "From List…": the Trips tab's own
                        // "+" (see `TripsListView`) would otherwise sit right
                        // next to this one in the unified window toolbar.
                        Divider()

                        Button {
                            addTrip()
                        } label: {
                            Label("New Trip", systemImage: "suitcase")
                        }
                    #endif
                } label: {
                    if isLocating {
                        ProgressView()
                    } else {
                        Label("Add", systemImage: "plus")
                    }
                }
            }

            // macOS reaches Achievements inside Your Travels (Go ▸ ⌘2).
            #if !os(macOS)
                ToolbarItem {
                    Button {
                        showAchievements = true
                    } label: {
                        Label("Achievements", systemImage: "trophy")
                    }
                }
            #endif
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
                                    "\(country.flagEmoji) \(country.localizedName)", systemImage: "mappin")
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
                            selectedCountry: $selectedCountry,
                            selectedTrip: $selectedTrip)
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }

    #if os(macOS)
        /// The macOS root: a two-column split. The sidebar holds the actual data —
        /// a Been/Going switch over the country lists and trips — and the map owns
        /// the detail column permanently. "Your Travels" and Chat push over the
        /// map on a navigation stack (no auxiliary windows), and the selected
        /// country or trip appears in a trailing inspector.
        private var macRoot: some View {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            } detail: {
                NavigationStack(path: $macPath) {
                    mapContent
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
                                        "\(country.flagEmoji) \(country.localizedName)",
                                        systemImage: "mappin")
                                }
                            }
                        }
                        // Attached to the map (not the stack) so a pushed
                        // destination gets the full width; popping back restores
                        // the inspector because the selection binding still holds.
                        .inspector(isPresented: inspectorPresented) {
                            inspectorContent
                                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                        }
                        .navigationDestination(for: MacDestination.self) { destination in
                            switch destination {
                            case .travels:
                                TravelsDashboardView()
                            case .chat:
                                TravelChatView()
                            }
                        }
                }
            }
            // Lets the Go menu (⌘2 / ⌘4) push the in-window destinations.
            .focusedSceneValue(\.macDestinations, $macPath)
            // Lets the View ▸ Filter menu commands drive the map filter.
            .focusedSceneValue(\.mapFilter, $mapFilter)
        }

        /// The sidebar: a segmented Been/Going switch over the country lists and
        /// trips, so the column carries real content instead of four static rows.
        private var sidebar: some View {
            VStack(spacing: 0) {
                Picker("Show", selection: $sidebarMode) {
                    Text(Str.Tab.been).tag(BrowseMode.been)
                    Text(Str.Tab.going).tag(BrowseMode.going)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Group {
                    switch sidebarMode {
                    case .been:
                        countryList(.been)
                    case .going:
                        GoingView(
                            allCountries: allCountries,
                            centroids: countryCentroids,
                            searchText: $searchText,
                            selectedContinent: $selectedContinent,
                            selectedYear: $selectedYear,
                            selectedCountry: $selectedCountry,
                            selectedTrip: $selectedTrip)
                    }
                }
                // Fills the column so the picker stays pinned to the top even
                // when the list shows a compact empty state.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        /// Whether the trailing inspector is showing. Closing it (the ✕ in the
        /// inspector header) clears whichever selection was populating it.
        private var inspectorPresented: Binding<Bool> {
            Binding(
                get: { selectedTrip != nil || selectedCountry != nil },
                set: { shown in
                    if !shown {
                        selectedTrip = nil
                        selectedCountry = nil
                    }
                })
        }

        /// The inspector: the selected trip or country under a title/close
        /// header. Trips take precedence — selecting one clears the country and
        /// vice-versa (see the `onChange` pair in `body`).
        @ViewBuilder private var inspectorContent: some View {
            if let trip = selectedTrip {
                inspectorPane(
                    title: trip.title.isEmpty ? String(localized: "Trip") : trip.title,
                    subtitle: nil
                ) {
                    TripDetailView(trip: trip, allCountries: allCountries)
                }
            } else if let country = selectedCountry {
                inspectorPane(
                    title: country.localizedName,
                    subtitle: Continents.localizedName(for: country.continent)) {
                    CountryDetailView(country: country)
                }
            }
        }

        /// Wraps inspector content with a header naming the subject and an
        /// explicit close button (inspectors have no built-in dismiss control).
        private func inspectorPane(
            title: String, subtitle: String?, @ViewBuilder content: () -> some View
        ) -> some View {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        inspectorPresented.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Close details")
                    .accessibilityLabel(Text("Close details"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                content()
            }
        }

        /// Pushes an in-window destination over the map, unless it's already on top.
        private func push(_ destination: MacDestination) {
            if macPath.last != destination { macPath.append(destination) }
        }

        /// Quick-add a country picked from "Add ▸ From List…": mirrors
        /// `CountryListView.addCountry`, using whichever list the sidebar is
        /// currently showing to decide visited vs. wishlist.
        private func addCountryFromList(_ country: Country) {
            switch sidebarMode {
            case .been:
                country.status = .visited
            case .going:
                if country.planStatus == .none { country.planStatus = .wishlist }
            }
            try? modelContext.save()
        }

        /// Starts a new trip from "Add ▸ New Trip": mirrors
        /// `TripsListView.addTrip`, opening it straight in the inspector the
        /// way selecting a trip row would.
        private func addTrip() {
            let trip = Trip.newUpcoming(title: "New Trip")
            modelContext.insert(trip)
            selectedTrip = trip
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
            // Publishes the country polygon geometry (empty until the GeoJSON
            // loads) so the trip photo suggestions can match photo locations
            // to the trip's countries without parameter-threading it through
            // the Going tab and the macOS inspector.
            .environment(\.countryPaths, countryPaths)
            // The achievement-unlock toast floats over whichever tab is
            // frontmost. `.task(id:)` restarts the auto-dismiss timer whenever
            // a newer unlock replaces the toast mid-display.
            .overlay(alignment: .top) {
                if let celebration {
                    AchievementToastView(celebration: celebration) {
                        withAnimation(.easeOut(duration: 0.25)) { self.celebration = nil }
                        openAchievements()
                    }
                    .task(id: celebration) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.3)) { self.celebration = nil }
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity))
                }
            }
            .sensoryFeedback(.success, trigger: celebration) { _, new in new != nil }
            // The store-wide change signatures (catalog, trips, achievements)
            // live in this invisible child so their O(store) hashes — and the
            // trip/visit queries feeding them — don't run on every render of
            // (or invalidate) this whole scene.
            .background(
                StoreWatchers(
                    allCountries: allCountries,
                    onCatalogChanged: {
                        updateWidgetSnapshot()
                        rebuildVisibleCache()
                    },
                    onTripsChanged: {
                        updateWidgetSnapshot()
                        scheduleEventKitSync()
                    },
                    onAchievementsChanged: celebrateNewAchievements
                )
                .equatable()
            )
            // Same trick, different signal: CloudKit's mirroring events, so a
            // sync that dies mid-session is recorded rather than lost.
            .background(CloudSyncWatcher())
            .onChange(of: selectedCountry) {
                // The selected country is part of the visible set even when
                // unvisited/unplanned, so selection changes rebuild the cache too.
                rebuildVisibleCache()
                if let country = selectedCountry {
                    detailCountry = country
                    // A country selection claims the macOS detail column.
                    selectedTrip = nil

                    // Center the map on the selected country
                    if let rect = mapRect(for: country) {
                        withAnimation(reduceMotion ? nil : .default) {
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
            #if os(macOS)
                .sheet(isPresented: $showAddCountryPicker) {
                    CountryPickerSheet(allCountries: allCountries) { country in
                        addCountryFromList(country)
                    }
                }
            #endif
            // iOS opens the country detail as a sheet; macOS shows it in the split
            // view's trailing detail column (see `countryDetailColumn`).
            #if os(iOS)
                // Closing the sheet also clears the selection, so tapping the
                // *same* country again is a real change to `selectedCountry` and
                // re-presents the sheet. Without this the selection stuck, and only
                // tapping a different country and coming back reopened detail.
                // macOS is unaffected — it shows detail in the split view's column,
                // not this sheet.
                .sheet(item: $detailCountry, onDismiss: { selectedCountry = nil }) { country in
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
            .alert(
                "Current Location",
                isPresented: Binding(
                    get: { locationError != nil }, set: { if !$0 { locationError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(locationError ?? "")
            }
            .onOpenURL(perform: handleIncomingURL)
            .task {
                #if DEBUG
                    applyScreenshotRouting()
                #endif
            }
            .sheet(item: $receivedTripFile) { received in
                TripFileImportSheet(record: received.trip)
            }
            .alert(
                "Received Trip",
                isPresented: Binding(
                    get: { tripFileError != nil }, set: { if !$0 { tripFileError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(tripFileError ?? "")
            }
            .onChange(of: intentRouter.pendingLogVisitsText) { consumePendingLogVisits() }
            .onChange(of: intentRouter.pendingOpenStats) { consumePendingOpenStats() }
            .onChange(of: intentRouter.pendingOpenPhotoImporter) { consumePendingOpenPhotoImporter() }
            .onChange(of: intentRouter.pendingOpenCountryID) { consumePendingOpenCountry() }
            .onChange(of: intentRouter.pendingSearchText) { consumePendingSearch() }
            .onChange(of: intentRouter.pendingMapTrip) { consumePendingMapTrip() }
            .onChange(of: intentRouter.pendingOpenTripID) {
                consumePendingOpenTrip()
                consumePendingContactAction()
            }
            // The catalog arrives after `loadGeoJSON`; re-try a pending country
            // selection once it does, so a cold-launched intent still resolves.
            // The count also changes as iCloud syncs rows in, so collapse any
            // duplicates that arrive from another device that seeded offline.
            // Cache rebuilds are handled by the `catalogKey` change above, which
            // fires for count changes too.
            .onChange(of: allCountries.count) {
                consumePendingOpenCountry()
                consumePendingMarkHere()
                deduplicateCountries()
                #if DEBUG
                    applyScreenshotRouting()
                #endif
            }
            // The reverse of the clearing above: a trip selection claims the
            // macOS detail column from the country. Setting the other side to
            // nil can't loop — each handler only acts on a non-nil value.
            .onChange(of: selectedTrip) {
                if selectedTrip != nil { selectedCountry = nil }
            }
            // No `mapFilter` handler here on purpose: the cache holds the
            // *unfiltered* visible set (visited / planned / selected) and
            // `visibleCountries` narrows it per filter on read, so rebuilding on
            // a filter change only recomputed the identical array.
            // The "Mark where I am" Control Center control writes a request to the
            // App Group's UserDefaults before opening the app (the OpenIntent runs
            // first), so it's always present when .active fires. If it somehow misses,
            // the flag persists and is picked up on the next foreground cycle.
            // Backgrounding rebuilds the reminder schedule, so trips created or
            // edited this session get their start reminders without a relaunch.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    checkControlRequest()
                    consumePendingPackingToggles()
                    // Catch up with Reminders and Calendar: pulls ticks made
                    // in the Reminders app / Siri / Watch while we weren't
                    // running, restores calendar events edited elsewhere, and
                    // retires lists/events past their cleanup windows.
                    scheduleEventKitSync()
                case .background:
                    Task { await rescheduleNotifications() }
                default:
                    break
                }
            }
            // Edits made in the Reminders / Calendar apps while Worldward is
            // frontmost (e.g. iPad Split View, macOS). Our own writes fire
            // this too; the follow-up pass finds nothing changed and writes
            // nothing, so the loop dies out.
            .onReceive(
                NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            ) { _ in
                scheduleEventKitSync()
            }
            .onAppear {
                // Cold launch: an intent may have set these before the view existed.
                consumePendingLogVisits()
                consumePendingOpenStats()
                consumePendingOpenCountry()
                consumePendingSearch()
                consumePendingOpenPhotoImporter()
                consumePendingOpenTrip()
                consumePendingContactAction()
                checkControlRequest()
            }
    }

    /// Debounced entry to the EventKit syncs (Reminders + Calendar): rapid
    /// edits and bursts of `EKEventStoreChanged` notifications collapse into a
    /// single pass two seconds after the last trigger. No-ops (without
    /// touching EventKit at all) while both sync settings are off; each engine
    /// also self-no-ops when its own toggle is off.
    private func scheduleEventKitSync() {
        guard ReminderSync.isEnabled || CalendarSync.isEnabled else { return }
        eventKitSyncDebounce?.cancel()
        eventKitSyncDebounce = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await ReminderSync.syncAll(context: modelContext)
            await CalendarSync.syncAll(context: modelContext)
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
                let isSelected = mapFilter == filter
                Button {
                    mapFilter = filter
                } label: {
                    HStack(spacing: 4) {
                        // The selection is otherwise fill-color only.
                        if differentiateWithoutColor && isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(filter.label)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(isSelected ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .transition(.opacity)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// The floating banner naming the trip whose route is on the map, with a
    /// button to clear it.
    private func tripRouteChip(_ trip: Trip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(Color.brand)
            Text(trip.title.isEmpty ? String(localized: "Trip route") : trip.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Button {
                mapTrip = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Hide route"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Switches to the Map tab and frames the camera around the trip's stops,
    /// with the route drawn via `mapTrip`. The minimum padding keeps a sensible
    /// zoom when the trip has a single stop (a zero-size rect otherwise).
    private func showTripOnMap(_ trip: Trip) {
        selectedCountry = nil
        showMap()
        mapTrip = trip

        let points = TripRouteContent.routePoints(for: trip, centroids: countryCentroids)
        guard !points.isEmpty else { return }
        var rect = MKMapRect.null
        for point in points {
            rect = rect.union(MKMapRect(origin: MKMapPoint(point.coordinate), size: MKMapSize()))
        }
        let padded = rect.insetBy(
            dx: -max(rect.width * 0.25, 2_000_000),
            dy: -max(rect.height * 0.25, 2_000_000))
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
            cameraPosition = .rect(padded)
        }
    }

    /// Draws the route of a trip the trip editor asked to see, then clears the
    /// request so it's consumed exactly once. Safe to call repeatedly.
    private func consumePendingMapTrip() {
        guard let trip = intentRouter.pendingMapTrip else { return }
        intentRouter.pendingMapTrip = nil
        showTripOnMap(trip)
    }

    /// Routes `OpenTripIntent` to the trip's details. On macOS the trip fills the
    /// window inspector directly; on iOS the Going tab comes forward and its trips
    /// list opens the sheet (and clears the id — see `TripsListView`), which also
    /// covers the cold-launch case where the list mounts after this runs.
    private func consumePendingOpenTrip() {
        guard let id = intentRouter.pendingOpenTripID else { return }
        #if os(macOS)
            let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
            // Leave the id pending if the store hasn't loaded the trip yet; the
            // `onChange`/`onAppear` hooks retry once it has.
            guard let trip = trips.first(where: { $0.dedupID == id }) else { return }
            intentRouter.pendingOpenTripID = nil
            macPath.removeAll()
            selectedTrip = trip
        #else
            selectedTab = .going
        #endif
    }

    /// Everything the app is opened *with*: a `.wwtrip` file, or a `worldward://`
    /// deep link from the trip widget. Split by scheme so each handler stays
    /// about one thing.
    private func handleIncomingURL(_ url: URL) {
        if url.scheme?.lowercased() == "worldward" {
            handleWidgetLink(url)
        } else {
            handleOpenedFile(url)
        }
    }

    /// Routes a tap on the trip widget. `worldward://trip?id=…` opens the trip;
    /// adding `&contact=…` also fires that contact's action once the store has
    /// loaded. Both ids are `dedupID`s and both are held pending, so a cold
    /// launch resolves them as soon as `@Query` populates — the same hand-off
    /// `OpenTripIntent` uses.
    private func handleWidgetLink(_ url: URL) {
        guard url.host == "trip",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let tripID = items.first(where: { $0.name == "id" })?.value, !tripID.isEmpty
        else { return }
        intentRouter.pendingOpenTripID = tripID
        intentRouter.pendingContactActionID = items.first { $0.name == "contact" }?.value
        consumePendingOpenTrip()
        consumePendingContactAction()
    }

    /// Dials (or messages, or mails) the contact a widget chip named. The widget
    /// hands over only a `dedupID` — the number stays in the store — so the
    /// lookup happens here, and `ContactKind.actionURL` turns the value into
    /// something the system can open. iOS confirms the call itself, so this
    /// stays one tap without being a call placed behind the user's back.
    ///
    /// Leaves the id pending while the store is still empty (cold launch, or
    /// iCloud mid-sync) and clears it once trips exist — a contact that has been
    /// deleted since resolves to nothing rather than lingering all session.
    private func consumePendingContactAction() {
        guard let id = intentRouter.pendingContactActionID else { return }
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        guard !trips.isEmpty else { return }
        intentRouter.pendingContactActionID = nil
        let contact = trips.lazy
            .flatMap { $0.sortedContacts }
            .first { $0.dedupID == id }
        guard let action = contact?.actionURL else { return }
        openURL(action)
    }

    /// Handles a `.wwtrip` file opened from outside the app (AirDrop's "Open
    /// with Worldward", Files, a Mail attachment): decodes it and raises the
    /// add-or-update confirm sheet. Nothing touches the store until the user
    /// confirms there.
    private func handleOpenedFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "wwtrip" else { return }
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try TravelDataTransfer.decodeTripFile(Data(contentsOf: url))
            receivedTripFile = ReceivedTripFile(trip: file.trip)
        } catch {
            tripFileError = String(
                localized: "Couldn't read the trip file.",
                comment: "Alert when an opened .wwtrip file fails to parse")
        }
    }

    /// Brings the map to the front: pops any pushed destination on macOS, or
    /// switches to the Map tab on iOS.
    private func showMap() {
        #if os(macOS)
            macPath.removeAll()
        #else
            selectedTab = .map
        #endif
    }

    /// Fly the map to a country's bounding rect and select it.
    private func flyTo(country: Country) {
        mapSearchText = ""
        showMap()
        if let rect = mapRect(for: country) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
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

    /// Presents the stats dashboard if an intent requested it. On macOS the
    /// dashboard (stats + achievements) pushes over the map in the main window.
    private func consumePendingOpenStats() {
        guard intentRouter.pendingOpenStats else { return }
        intentRouter.pendingOpenStats = false
        #if os(macOS)
            macPath = [.travels]
        #else
            showAchievements = true
        #endif
    }

    /// Presents the photo importer's configuration if the macOS "Add ▸ From
    /// Photos…" menu command requested it.
    private func consumePendingOpenPhotoImporter() {
        guard intentRouter.pendingOpenPhotoImporter else { return }
        intentRouter.pendingOpenPhotoImporter = false
        photoImporter.presentConfiguration()
    }

    /// Selects a country an intent requested. Waits for the catalog to load
    /// before clearing the request, so a cold-launched intent isn't dropped.
    #if DEBUG
        /// Drive the app to the screen named by `-screen` for App Store screenshot
        /// automation. Idempotent: runs on first appear and again once the catalog
        /// loads (so `countryDetail` resolves its country). Deeper screens hand off
        /// to `ScreenshotDirector`, which their owning child views observe.
        private func applyScreenshotRouting() {
            guard ScreenshotSupport.isActive, let screen = ScreenshotSupport.screen else { return }
            #if os(macOS)
                // macOS has its own navigation model (split-view sidebar + a
                // pushed `macPath` destination + a trailing inspector) — reusing
                // the iOS tab/sheet state here would show iOS-style UI floating
                // inside the Mac window instead of the app's real layout.
                switch screen {
                case .map:
                    macPath.removeAll()
                case .been:
                    sidebarMode = .been
                    macPath.removeAll()
                case .going:
                    sidebarMode = .going
                    macPath.removeAll()
                case .countryDetail:
                    sidebarMode = .been
                    selectedCountry = allCountries.first { $0.id == ScreenshotSupport.demoCountryID }
                case .achievements, .stats, .wrapped, .share:
                    // TravelsDashboardView is the single native destination for
                    // both stats and achievements; it switches its own segment
                    // when capturing `.achievements` (see StatisticsView.swift).
                    macPath = [.travels]
                case .trip, .packing:
                    // TripsListView (inside the Going sidebar) sets `selectedTrip`
                    // itself once its own trips query is populated.
                    sidebarMode = .going
                case .now:
                    // watchOS-only screen; nothing to route to here.
                    break
                }
            #else
                switch screen {
                case .map:
                    selectedTab = .map
                case .been:
                    selectedTab = .been
                case .going:
                    selectedTab = .going
                case .countryDetail:
                    selectedTab = .been
                    detailCountry = allCountries.first { $0.id == ScreenshotSupport.demoCountryID }
                case .achievements:
                    selectedTab = .map
                    showAchievements = true
                case .stats, .wrapped, .share:
                    // CountryListView opens the Statistics sheet; StatisticsView then
                    // presents Wrapped / Share itself.
                    selectedTab = .been
                case .trip, .packing:
                    // TripsView opens the trip editor; it scrolls to packing when asked.
                    selectedTab = .going
                case .now:
                    // watchOS-only screen; nothing to route to here.
                    break
                }
            #endif
        }
    #endif

    private func consumePendingOpenCountry() {
        guard let id = intentRouter.pendingOpenCountryID, !allCountries.isEmpty else { return }
        intentRouter.pendingOpenCountryID = nil
        showMap()
        selectedCountry = allCountries.first { $0.id == id }
    }

    /// Applies a search term an intent requested by switching to the Been tab (its
    /// list searches across every country) and seeding the search field.
    private func consumePendingSearch() {
        guard let term = intentRouter.pendingSearchText else { return }
        intentRouter.pendingSearchText = nil
        searchText = term
        #if os(macOS)
            sidebarMode = .been
        #else
            selectedTab = .been
        #endif
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
    /// a status picker. Called from the toolbar button. Failures (denied access,
    /// no fix, no matching country) surface in an alert rather than silently
    /// stopping the spinner.
    private func markCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }

        let isoCode: String?
        do {
            isoCode = try await LocationService.currentISOCountryCode()
        } catch {
            locationError = error.localizedDescription
            return
        }
        guard let isoCode else {
            locationError = String(
                localized: "Could not determine your current country from your location.")
            return
        }
        guard
            let country = allCountries.first(where: {
                $0.id == isoCode || $0.iso3 == isoCode
            })
        else {
            locationError = String(
                localized: "Your current country (\(isoCode)) isn't in the Worldward catalog.")
            return
        }

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
        LaunchClock.mark("loadGeoJSON: start")
        // Decide what database work is needed up front, on the main context, so the
        // background build knows whether it must also produce seed metadata. The
        // store needs seeding when it's empty or holds stale ids from an old build.
        let existing = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
        LaunchClock.mark("loadGeoJSON: fetched \(existing.count) countries")
        let stale = Worldward.hasStaleIDs(existing)
        let needsSeed = existing.isEmpty || stale

        // First run seeds the database, so say so rather than leaving a bare
        // spinner; later launches just rebuild the drawable geometry.
        mapLoadingMessage =
            needsSeed
            ? "Setting up your map…\nThis only happens once."
            : "Loading map…"

        // Decode the bundled country geometry. The binary format (~675 KB) is a
        // fast synchronous parse — the heavy GeoJSON decode and Douglas-Peucker
        // simplification were already done at build time in Tools/generate_geo.swift,
        // so this is cheap on every launch including the first.
        guard let bundled = loadBundledGeo() else { return }
        LaunchClock.mark("loadGeoJSON: geometry decoded")

        // Copy the bundled outline into the shared App Group container on a
        // background task so the widget extension (which can't read the bundle)
        // can draw the map. Re-copies only when the file changes between releases.
        Task(priority: .background) { @concurrent in
            WorldMapStore.cacheFromAppBundle()
        }

        // Build MapKit display types on the main actor (MKPolygon, CGPath are not
        // Sendable and must be constructed on the actor that owns them).
        let geo = buildGeo(from: bundled.rings)
        let extractedPolygons = geo.polys
        let extractedDetailPolygons = geo.detailPolys
        let extractedPaths = geo.paths
        let extractedRects = geo.rects
        let extractedHitRects = geo.hitRects
        let seeds = bundled.seeds
        LaunchClock.mark("loadGeoJSON: polygons built")

        // Reconcile the database on the main actor — the only place SwiftData
        // models are touched. Seeding and reconciliation are mutually exclusive.
        if needsSeed {
            if !seeds.isEmpty { seedDatabase(seeds, wiping: stale ? existing : []) }
        } else {
            reconcileDatabase(existing, seeds: seeds)
        }
        LaunchClock.mark(needsSeed ? "loadGeoJSON: seeded" : "loadGeoJSON: reconciled")

        // Collapse any duplicate rows iCloud may have produced (two devices that
        // both seeded offline). Cheap and idempotent on a clean store.
        deduplicateCountries()
        LaunchClock.mark("loadGeoJSON: deduplicated")

        // One-shot: unfold any legacy nested itinerary places (pre-flatten stores)
        // into sibling stops. Guarded to a no-op once the store has been drained.
        TravelDataTransfer.flattenLegacyPlaces(in: modelContext)
        LaunchClock.mark("loadGeoJSON: flattened places")

        self.countryPolygons = extractedPolygons
        self.countryDetailPolygons = extractedDetailPolygons
        self.countryPaths = extractedPaths
        self.countryBoundingRects = extractedRects
        self.countryHitRects = extractedHitRects
        self.hitTestIndex = GeoGridIndex(rects: extractedHitRects)
        // Derive a centroid per country from its bounding rect so the statistics
        // page can rank the nearest unvisited countries by real proximity.
        self.countryCentroids = extractedRects.mapValues { rect in
            MKMapPoint(
                x: rect.origin.x + rect.size.width / 2,
                y: rect.origin.y + rect.size.height / 2
            ).coordinate
        }
        // Re-fetch (rather than trust `allCountries`) so the launch preview, the
        // photo importer, and Spotlight all see every seeded country even if the
        // `@Query` hasn't refreshed yet this run loop.
        let seededCountries = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? allCountries

        // Ranks for the launch map preview, mirroring the live map's fill rules:
        // a visited status wins; a country that's only planned shows its blue.
        var tints: [String: Int] = [:]
        for country in seededCountries {
            if country.status.isVisited {
                tints[country.id] = CountryStatus.allCases.firstIndex(of: country.status) ?? 0
            } else if country.planStatus != .none {
                tints[country.id] = country.planStatus == .wishlist ? 5 : 6
            }
        }
        launchTints = tints

        withAnimation(.easeInOut(duration: 0.4)) {
            self.isLoadingMapData = false
        }
        LaunchClock.mark("loadGeoJSON: splash cleared")

        #if DEBUG
            // Re-apply screenshot routing now the map splash is gone, so sheet-based
            // screens (achievements, country detail) present over the loaded map
            // rather than being dropped during the loading overlay.
            applyScreenshotRouting()
        #endif

        // The map geometry has now been cached into the App Group (inside the
        // detached task above). Rewrite the snapshot so the reload it triggers
        // happens *after* the geometry file exists — the map widget then finds it
        // on its next refresh and fills in.
        updateWidgetSnapshot()
        LaunchClock.mark("loadGeoJSON: widget snapshot written")

        // Hand the geographic data to the photo importer now that it's ready.
        // Doing this here (rather than via onChange) guarantees it runs exactly
        // once, so the "Import from Photos" button reliably enables.
        photoImporter.configure(
            countryBoundingRects: extractedHitRects,
            countryPaths: extractedPaths,
            allCountries: seededCountries
        )
        LaunchClock.mark("loadGeoJSON: photo importer configured")

        // Publish the catalog to Spotlight (and Apple Intelligence) once it's
        // settled. Gated internally, so this is a no-op on warm launches.
        Task { await CountrySpotlightIndexer.indexIfNeeded(seededCountries) }

        focusOnHomeIfNeeded()

        // Refresh local travel reminders from the freshly loaded catalog. A no-op
        // when the user hasn't enabled reminders (off by default — see SettingsView).
        LaunchClock.mark("loadGeoJSON: rescheduling reminders")
        await rescheduleNotifications()
        LaunchClock.mark("loadGeoJSON: done")
    }

    /// Rebuilds the reminder schedule from the store. Trips must be included:
    /// `reschedule` rebuilds from scratch, so omitting them (as an earlier build
    /// did on launch) silently wiped trip-start reminders. Called after the
    /// catalog loads and again whenever the app backgrounds, so trips created or
    /// edited this session are covered too.
    private func rescheduleNotifications() async {
        let countries = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        await NotificationManager.reschedule(
            enabled: notificationsEnabled, countries: countries, trips: trips)
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

    /// Diffs the current badge set against the persisted one and toasts anything
    /// newly earned. Skipped while the catalog is empty (cold launch before the
    /// store loads) so the persisted set can't be wiped and every badge then
    /// "re-earned" in one giant toast when the rows arrive.
    private func celebrateNewAchievements() {
        guard !allCountries.isEmpty else { return }
        #if DEBUG
            // Screenshot runs seed dozens of visits at once; the celebration toast
            // would cover the UI. Suppress it while capturing.
            if ScreenshotSupport.isActive { return }
        #endif
        let achievements = Achievement.all(for: TravelStats(countries: allCountries))
        let newlyUnlocked = AchievementUnlocks.consumeNewlyUnlocked(from: achievements)
        guard let toast = AchievementCelebration(newlyUnlocked: newlyUnlocked) else { return }
        withAnimation(.spring(duration: 0.5)) { celebration = toast }
    }

    /// Opens the achievements grid: the sheet on iOS, or the in-window Your
    /// Travels dashboard on macOS (which hosts the achievements page).
    private func openAchievements() {
        #if os(macOS)
            push(.travels)
        #else
            showAchievements = true
        #endif
    }

    /// Recompute the travel summary and hand it to the shared App Group store,
    /// which redraws the widgets. Delegates to the same helper the mutating
    /// intents use (see WorldwardIntents.swift) so both paths build the snapshot
    /// identically.
    private func updateWidgetSnapshot() {
        // Fold in any toggles made on the packing widget first, so the snapshot
        // about to be written can't clobber them with stale model state (a cold
        // launch writes the snapshot before the scenePhase handler runs).
        consumePendingPackingToggles()
        // Fetched on demand (rather than via `@Query`) so trip edits don't
        // invalidate this whole scene; `StoreWatchers` decides when to call.
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        refreshWidgetSnapshot(countries: allCountries, trips: trips)
        // Keep trips searchable in Spotlight (and reasoned over by Apple
        // Intelligence). Gated internally on a content signature, so this is a
        // no-op unless a trip was actually added, edited, or removed.
        Task { await TripSpotlightIndexer.indexIfNeeded(trips) }
    }

    /// Applies packing-list toggles made on the widget to the model. Ids that no
    /// longer resolve (item deleted, possibly on another device) are dropped. A
    /// real change saves, which bumps `tripsKey` and rewrites the snapshot from
    /// the model as the new truth. Safe to call on every activation.
    private func consumePendingPackingToggles() {
        let toggles = PackingToggleStore.consume()
        guard !toggles.isEmpty else { return }
        // Packing lists are tiny (tens of rows), so fetch-all beats building a
        // per-id predicate.
        let items = (try? modelContext.fetch(FetchDescriptor<PackingItem>())) ?? []
        var changed = false
        for item in items {
            if let packed = toggles[item.dedupID], item.isPacked != packed {
                item.isPacked = packed
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }

    /// Fold a duplicate country's user data into the row that will survive
    /// de-duplication. Visits are re-parented; a real status wins over
    /// `.notVisited` and a hand-set status wins over an imported one; notes are
    /// combined when they differ; the legacy `visitDate` fills in if missing.
    private func merge(_ loser: Country, into winner: Country) {
        for visit in Array(loser.visits ?? []) {
            visit.country = winner
        }

        // Trip stops pointing at the loser would be nullified by its deletion
        // (losing their flag and map route), so re-point them at the winner.
        for item in Array(loser.itineraryItems ?? []) {
            item.country = winner
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

        // A wishlist/planning mark set on the other device lives on the loser;
        // without this it would vanish with the row.
        if winner.planStatus == .none { winner.planStatus = loser.planStatus }
    }
}
