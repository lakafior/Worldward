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
    let filteredCountries: [Country]
    let continents: [String]
    let visitYears: [Int]
    let visitedCount: Int
    let hasActiveFilters: Bool

    /// Empty placeholder so the summary can be stored as `@State` and populated
    /// on first render via `rebuildSummary`. The list body checks `summaryReady`
    /// before reading it, so the empty state is never shown.
    init() {
        filteredCountries = []
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
                    || country.name.localizedStandardContains(trimmedSearch)
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

    /// `true` once the summary has been initialized. Avoids flashing empty states
    /// when the view first appears before `rebuildSummary` fires via `onAppear`.
    @State private var summaryReady = false

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
            } else if summaryReady && summary.filteredCountries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .searchable(text: $searchText, prompt: Str.List.searchPlaceholder)
        .navigationTitle(browseMode == .been ? Str.Tab.been : Str.Tab.going)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Button {
                    showAddCountry = true
                } label: {
                    Label(Str.List.addButton, systemImage: "plus")
                }
            }
            sortAndFilterMenu
        }
        .sheet(isPresented: $showAddCountry) {
            CountryPickerSheet(allCountries: allCountries) { country in
                addCountry(country)
            }
        }
        .onAppear { rebuildSummary() }
        .onChange(of: searchText) { rebuildSummary() }
        .onChange(of: selectedContinent) { rebuildSummary() }
        .onChange(of: selectedYear) { rebuildSummary() }
        .onChange(of: allCountries.count) { rebuildSummary() }
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
