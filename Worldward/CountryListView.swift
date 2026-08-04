/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

/// How the Been/Going lists are ordered.
enum CountrySort: CaseIterable, Identifiable {
    case name
    case recent
    var id: Self { self }
    var label: String {
        switch self {
        case .name: Str.List.sortName
        case .recent: Str.List.sortRecent
        }
    }
}

/// Pre-computed snapshot of the country list's filter/sort state, derived once
/// in its `init` so the list body can read it without recomputing on every render.
struct CountryListSummary {
    /// One continent's group in the by-name order, with its header already
    /// localized and its rows already sorted.
    struct ContinentSection: Identifiable {
        /// The stored (English) continent value — stable across languages, so
        /// `ForEach` identity survives a locale change.
        let id: String
        /// The localized header text.
        let title: String
        let countries: [Country]
    }

    /// A country paired with the keys the list sorts on. Both are costly to
    /// derive — `localizedName` is an ICU region lookup and `lastVisit` walks
    /// (and allocates for) the visits relationship — so they're computed once
    /// per country here rather than on every comparison inside a comparator.
    private struct SortableCountry {
        let country: Country
        let localizedName: String
        let lastVisit: Date?
    }

    let filteredCountries: [Country]
    /// The by-name order: continent sections, sorted by localized continent
    /// name, each holding its countries sorted by localized country name.
    let nameSections: [ContinentSection]
    /// The "Recent" order: flat, most recently visited first, countries with no
    /// recorded visit last and alphabetical among themselves.
    let recentlySorted: [Country]
    let continents: [String]
    let visitYears: [Int]
    let visitedCount: Int
    let hasActiveFilters: Bool

    /// Empty placeholder so the summary can be stored as `@State` and populated
    /// on first render via `rebuildSummary`. The list body checks `summaryReady`
    /// before reading it, so the empty state is never shown.
    init() {
        filteredCountries = []
        nameSections = []
        recentlySorted = []
        continents = []
        visitYears = []
        visitedCount = 0
        hasActiveFilters = false
    }

    init(
        countries: [Country], searchText: String, browseMode: BrowseMode,
        selectedContinent: String?, selectedYear: Int?
    ) {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        var kept: [SortableCountry] = []
        var continents = Set<String>()
        var visitYears = Set<Int>()
        var visitedCount = 0

        for country in countries {
            continents.insert(country.continent)

            if country.isVisited {
                visitedCount += 1
            }

            // One pass over the visits relationship feeds three consumers: the
            // year filter's menu options, that filter's own match, and the
            // "Recent" sort key. They used to walk it separately.
            var latestVisit: Date?
            var matchesSelectedYear = false
            for date in country.allVisitDates {
                let year = calendar.component(.year, from: date)
                visitYears.insert(year)
                if year == selectedYear { matchesSelectedYear = true }
                latestVisit = latestVisit.map { Swift.max($0, date) } ?? date
            }

            // Resolved once and reused for both the search match below and the
            // sort keys at the end — it's an ICU lookup, not a stored property.
            let localizedName = country.localizedName

            // Match the English name *and* the user's localized one: the list now
            // displays localized names, so typing "Allemagne" must find Germany.
            guard
                trimmedSearch.isEmpty
                    || country.name.localizedStandardContains(trimmedSearch)
                    || localizedName.localizedStandardContains(trimmedSearch)
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

            if browseMode == .been, selectedYear != nil {
                guard matchesSelectedYear else { continue }
            }

            kept.append(
                SortableCountry(
                    country: country, localizedName: localizedName, lastVisit: latestVisit))
        }

        self.filteredCountries = kept.map(\.country)
        self.continents = continents.sorted()
        self.visitYears = visitYears.sorted(by: >)
        self.visitedCount = visitedCount
        self.hasActiveFilters = selectedContinent != nil || selectedYear != nil

        // Both orders are built here, not in the view body: sorting on the
        // decorated keys keeps the ICU lookups and relationship walks at O(n)
        // instead of the O(n log n) a comparator would incur, and the result
        // survives every re-render until a filter dependency actually changes.
        // Building both (rather than only the active one) keeps `sortOrder` out
        // of the rebuild's dependencies, so flipping the sort stays instant.
        var byContinent: [String: [SortableCountry]] = [:]
        for item in kept {
            byContinent[item.country.continent, default: []].append(item)
        }
        self.nameSections =
            byContinent
            .map { continent, items in
                ContinentSection(
                    id: continent,
                    title: Continents.localizedName(for: continent),
                    countries: items
                        .sorted {
                            $0.localizedName.localizedStandardCompare($1.localizedName)
                                == .orderedAscending
                        }
                        .map(\.country)
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        self.recentlySorted =
            kept
            .sorted { lhs, rhs in
                switch (lhs.lastVisit, rhs.lastVisit) {
                case (let l?, let r?):
                    return l == r
                        ? lhs.localizedName.localizedStandardCompare(rhs.localizedName)
                            == .orderedAscending
                        : l > r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil):
                    return lhs.localizedName.localizedStandardCompare(rhs.localizedName)
                        == .orderedAscending
                }
            }
            .map(\.country)
    }
}

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

    @Environment(\.modelContext) private var modelContext

    @State private var sortOrder: CountrySort = .name
    /// Cached filter/sort summary recomputed only when dependencies change,
    /// avoiding a full iteration of all countries + their visits on every render.
    @State private var summary = CountryListSummary()
    /// Sheet for quick-adding a country from the list toolbar.
    @State private var showAddCountry = false
    /// Sheets for Been-only toolbar features.
    @State private var showStatistics = false
    @State private var showTravelChat = false

    /// `true` once the summary has been initialized. Avoids flashing empty states
    /// when the view first appears before `rebuildSummary` fires via `onAppear`.
    @State private var summaryReady = false

    // Grouping and both sort orders live on `summary` (rebuilt only when a
    // filter dependency changes), so nothing here re-derives them per render.

    private var count: Int { summary.filteredCountries.count }

    /// A cheap signature of everything the cached summary derives from. Statuses,
    /// plans, and visits all change without the row count changing (map/detail
    /// edits beside this list on macOS and iPad, intents, photo imports), so
    /// watching `allCountries.count` alone would leave the list membership stale.
    /// Visit *dates* feed the hash too — editing a date in place changes the
    /// year filter and "Recent" order without changing any count.
    private var catalogKey: Int {
        var hasher = Hasher()
        for country in allCountries {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
            hasher.combine(country.planStatusRaw)
            for visit in (country.visits ?? []) {
                hasher.combine(visit.date)
            }
        }
        return hasher.finalize()
    }

    var body: some View {
        Group {
            if allCountries.isEmpty {
                ProgressView()
            } else if summaryReady && summary.filteredCountries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        // Active filters as dismissible chips, so the state the funnel icon only
        // hints at is visible — and clearable — in one tap. Attached outside the
        // list so the chips survive a filter that empties it.
        .safeAreaInset(edge: .top, spacing: 0) { activeFilterChips }
        // macOS anchors the search field inside the sidebar itself: the map's
        // toolbar search already owns the window toolbar's search slot, and
        // AppKit crashes on a second toolbar search item in the same window.
        #if os(macOS)
            .searchable(text: $searchText, placement: .sidebar, prompt: Str.List.searchPlaceholder)
        #else
            .searchable(text: $searchText, prompt: Str.List.searchPlaceholder)
        #endif
        .navigationTitle(browseMode == .been ? Str.Tab.been : Str.Tab.going)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // macOS reaches Statistics and Chat from the map toolbar and the Go
            // menu (⌘2 / ⌘4) — they push over the map in the main window, so the
            // sidebar list doesn't duplicate them.
            #if !os(macOS)
                if browseMode == .been {
                    ToolbarItem {
                        Button {
                            showTravelChat = true
                        } label: {
                            Label("Ask About Your Travels", systemImage: "sparkles")
                        }
                    }
                    ToolbarItem {
                        Button {
                            showStatistics = true
                        } label: {
                            Label("Statistics", systemImage: "chart.pie")
                        }
                    }
                }
            #endif
            // macOS folds this into the map toolbar's "Add" menu instead (see
            // `ContentView`), so the unified window toolbar doesn't show two
            // unrelated "+" buttons side by side.
            #if !os(macOS)
                ToolbarItem {
                    Button {
                        showAddCountry = true
                    } label: {
                        Label(Str.List.addButton, systemImage: "plus")
                    }
                }
            #endif
            sortAndFilterMenu
        }
        .sheet(isPresented: $showAddCountry) {
            CountryPickerSheet(allCountries: allCountries) { country in
                addCountry(country)
            }
        }
        .sheet(isPresented: $showStatistics) {
            StatisticsView(countries: allCountries)
        }
        .sheet(isPresented: $showTravelChat) {
            TravelChatView()
        }
        // Pull-to-refresh asks iCloud to catch up, then rebuilds the summary so
        // anything that arrived — or was already sitting in the store, unnoticed
        // because no `@Query` change fired — shows up straight away.
        .refreshable {
            await CloudSyncStatus.shared.sync(modelContext)
            rebuildSummary()
        }
        .onAppear { rebuildSummary() }
        .task {
            #if DEBUG
                // Screenshot capture: the Statistics sheet is the gateway to the
                // stats, Wrapped and share-card screens. Been list only. macOS
                // excluded — there, ContentView pushes the native
                // TravelsDashboardView via `macPath` instead of this sheet.
                #if !os(macOS)
                    if browseMode == .been, ScreenshotSupport.needsStatistics {
                        showStatistics = true
                    }
                #endif
            #endif
        }
        .onChange(of: searchText) { rebuildSummary() }
        .onChange(of: selectedContinent) { rebuildSummary() }
        .onChange(of: selectedYear) { rebuildSummary() }
        // Covers count changes and any status/plan/visit edit made elsewhere
        // (map detail column, intents, photo import) while this list is visible.
        .onChange(of: catalogKey) { rebuildSummary() }
    }

    /// Quick-add a country: in Been mode, mark as visited; in Going mode,
    /// add to the wishlist so it shows up immediately.
    private func addCountry(_ country: Country) {
        switch browseMode {
        case .been:
            country.status = .visited
        case .going:
            if country.planStatus == .none { country.planStatus = .wishlist }
        }
        try? modelContext.save()
        rebuildSummary()
    }

    /// Recompute the cached summary from the current filter/sort state.
    private func rebuildSummary() {
        summary = CountryListSummary(
            countries: allCountries,
            searchText: searchText,
            browseMode: browseMode,
            selectedContinent: selectedContinent,
            selectedYear: selectedYear
        )
        summaryReady = true
    }

    private var list: some View {
        List {
            Section {
                Text("^[\(count) country](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Name keeps the familiar by-continent grouping; recency is a flat,
            // global order where continent sections wouldn't make sense.
            if sortOrder == .name {
                ForEach(summary.nameSections) { section in
                    Section(section.title) {
                        ForEach(section.countries) { country in
                            row(country)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(summary.recentlySorted) { country in
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
    }

    /// One dismissible chip per active filter (continent, visit year).
    @ViewBuilder private var activeFilterChips: some View {
        if summary.hasActiveFilters {
            HStack(spacing: 8) {
                if let selectedContinent {
                    filterChip(selectedContinent) { self.selectedContinent = nil }
                }
                if let selectedYear {
                    filterChip(String(selectedYear)) { self.selectedYear = nil }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func filterChip(_ label: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.brand.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.brand)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Clear filter: \(label)"))
    }

    @ViewBuilder private var emptyState: some View {
        if browseMode == .been {
            ContentUnavailableView(
                Str.List.emptyBeen,
                systemImage: "map",
                description: Text("Tap a country on the Map to mark where you've been."))
        } else {
            ContentUnavailableView(
                Str.List.emptyGoing,
                systemImage: "airplane",
                description: Text("Find a country on the Map and add it to your wishlist."))
        }
    }

    @ToolbarContentBuilder private var sortAndFilterMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker(Str.List.sortLabel, selection: $sortOrder) {
                    ForEach(CountrySort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                }

                Section(Str.List.continentSection) {
                    Button(Str.List.continentAll) { selectedContinent = nil }
                    ForEach(summary.continents, id: \.self) { continent in
                        Button(continent) { selectedContinent = continent }
                    }
                }

                if browseMode == .been, !summary.visitYears.isEmpty {
                    Section(Str.List.visitYearSection) {
                        Button(Str.List.visitYearAll) { selectedYear = nil }
                        ForEach(summary.visitYears, id: \.self) { year in
                            Button(String(year)) { selectedYear = year }
                        }
                    }
                }
            } label: {
                Label(
                    Str.List.sortFilterLabel,
                    systemImage: summary.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
            }
        }
    }
}
