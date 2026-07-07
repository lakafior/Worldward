import Charts
import MapKit
import SwiftData
import SwiftUI
import Translation

/// Full-page travel dashboard: stats, timeline, and recaps for countries you've
/// visited. Presented as a sheet from the **Been** tab toolbar. All figures
/// derive from a single `TravelStats` pass; nothing here is persisted.
struct StatisticsView: View {
    let countries: [Country]

    @Environment(\.dismiss) private var dismiss

    @State private var selectedYear: Int?
    @State private var showShareSheet = false
    /// The year being shared as a year-in-review card, or `nil` when none.
    @State private var shareCardYear: TravelStats.YearStat?
    @State private var insights = TravelInsights()

    /// Computed once per view instance. `TravelStats` is a full O(n) pass, and the
    /// body, the year picker, and the share-image render all read it — recomputing
    /// it as a stored `let` instead of a computed property avoids repeating that work.
    private let stats: TravelStats

    init(countries: [Country]) {
        self.countries = countries
        self.stats = TravelStats(countries: countries)
    }

    private var selectedYearStat: TravelStats.YearStat? {
        if let selectedYear { return stats.years.first { $0.year == selectedYear } }
        return stats.busiestYear ?? stats.years.last
    }

    var body: some View {
        dashboard
        .sheet(isPresented: $showShareSheet) {
            ShareCustomizationView(stats: stats, tints: stats.statusTints)
        }
        .sheet(item: $shareCardYear) { year in
            ShareCustomizationView(stats: stats, tints: yearTints(for: year.year), year: year)
        }
    }

    /// macOS shows the dashboard inside the main window's navigation stack (via
    /// `TravelsDashboardView`), so it must not nest another stack; the iOS sheet
    /// brings its own with a Done button.
    @ViewBuilder private var dashboard: some View {
        #if os(macOS)
            scrollContent
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { shareButton }
                }
        #else
            NavigationStack {
                scrollContent
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { shareButton }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .frame(minWidth: 380, minHeight: 520)
        #endif
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TimelineSection(countries: countries)

                StatCardsSection(stats: stats)

                if stats.years.contains(where: { $0.countries > 0 }) {
                    YearChartSection(years: stats.years)
                }

                // A single point isn't a line; the cumulative chart appears once
                // there's a second year to draw toward.
                if stats.cumulativeCountries.count > 1 {
                    CumulativeChartSection(points: stats.cumulativeCountries)
                }

                ContinentSection(continents: stats.continents)

                if let yearStat = selectedYearStat {
                    YearInReviewSection(
                        stats: stats,
                        years: stats.years,
                        selectedYear: Binding(
                            get: { yearStat.year },
                            set: { selectedYear = $0 }),
                        yearStat: yearStat,
                        onShare: { shareCardYear = yearStat })
                }
            }
            .padding()
        }
        .navigationTitle("Your Travels")
    }

    /// Map tints restricted to the countries recorded in `year`, so the year
    /// card's map highlights that year's travels rather than the all-time
    /// footprint.
    private func yearTints(for year: Int) -> [String: Int] {
        let ids = stats.countryIDsByYear[year] ?? []
        return stats.statusTints.filter { ids.contains($0.key) }
    }

    private var shareButton: some View {
        Menu {
            Button {
                showShareSheet = true
            } label: {
                Label("Share Image Card", systemImage: "photo")
            }

            ShareLink(item: csvString, subject: Text("Worldward Travel Data")) {
                Label("Export CSV", systemImage: "tablecells")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(!stats.hasTravel)
    }

    /// A CSV representation of every visited country and its visits.
    private var csvString: String {
        var lines = ["Country,Status,Date,Notes"]
        for country in countries where country.isVisited {
            let name = csvEscape(country.name)
            let status = csvEscape(country.status.label)
            if country.visits.isEmpty {
                lines.append("\(name),\(status),,")
            }
            for visit in country.visits.sorted(by: { $0.date < $1.date }) {
                let date = visit.date.formatted(date: .numeric, time: .omitted)
                let notes = csvEscape(visit.notes)
                lines.append("\(name),\(status),\(date),\(notes)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Escapes a string for CSV (wraps in quotes if it contains a comma or newline).
    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

// MARK: - Hero

private struct HeroSection: View {
    let stats: TravelStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if stats.hasTravel {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(stats.visitedCountries)")
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .foregroundStyle(.brandGradient)
                    VStack(alignment: .leading) {
                        Text("of \(stats.totalCountries) countries")
                            .font(.headline)
                        Text("\(stats.visitedContinents) of \(stats.totalContinents) continents")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if !stats.visitedFlags.isEmpty {
                    Text(stats.visitedFlags.prefix(60).joined(separator: " "))
                        .font(.title3)
                        .lineLimit(3)
                }
            } else {
                ContentUnavailableView(
                    "No travels yet",
                    systemImage: "globe",
                    description: Text(
                        "Mark countries as visited or import from Photos to start earning achievements."
                    ))
            }
        }
    }
}

// MARK: - Stat cards

private struct StatCardsSection: View {
    let stats: TravelStats

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatCard(
                title: String(localized: "Recorded visits"), value: "\(stats.totalVisits)",
                symbol: "calendar", tint: .brandRoyal)
            StatCard(
                title: String(localized: "Years traveling"), value: "\(stats.activeYears)",
                symbol: "clock.arrow.circlepath", tint: .brandTeal)
            if let most = stats.mostVisited {
                StatCard(
                    title: String(localized: "Most visited"), value: "\(most.flag) ×\(most.count)",
                    symbol: "star.fill", tint: .brandAzure)
            }
            if let busiest = stats.busiestYear, busiest.countries > 0 {
                StatCard(
                    title: String(localized: "Busiest year"),
                    value: "\(busiest.year) · \(busiest.countries)",
                    symbol: "flame.fill", tint: .brandIndigo)
            }
            // A one-year "streak" is just travel; the card earns its spot once
            // there are consecutive years to brag about.
            if stats.newCountryStreak >= 2 {
                StatCard(
                    title: String(
                        localized: "New country streak",
                        comment: "Stat card: consecutive years with a first-time country"),
                    value: String(
                        localized: "\(stats.newCountryStreak) years running",
                        comment: "Stat card value: length of the new-country streak"),
                    symbol: "laurel.leading", tint: .brandSky)
            }
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Year chart

private struct YearChartSection: View {
    let years: [TravelStats.YearStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Countries per year"))

            Chart(years) { year in
                BarMark(
                    x: .value("Year", String(year.year)),
                    y: .value("Countries", year.countries)
                )
                .foregroundStyle(Color.brand.gradient)
                .cornerRadius(4)
            }
            .frame(height: 200)
        }
    }
}

// MARK: - Cumulative chart

/// The countries-over-time line: cumulative distinct countries by year, so the
/// footprint's growth reads at a glance. Categorical year labels match the
/// per-year bar chart above it (and avoid "2,024"-style number formatting).
private struct CumulativeChartSection: View {
    let points: [TravelStats.CumulativeStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: String(
                    localized: "Countries over time",
                    comment: "Chart section header: cumulative countries by year"))

            Chart(points) { point in
                AreaMark(
                    x: .value("Year", String(point.year)),
                    y: .value("Countries", point.total)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.brand.opacity(0.3), Color.brand.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Year", String(point.year)),
                    y: .value("Countries", point.total)
                )
                .foregroundStyle(Color.brand)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(height: 200)
        }
    }
}

// MARK: - Continents

private struct ContinentSection: View {
    let continents: [TravelStats.ContinentStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "By continent"))

            VStack(spacing: 12) {
                ForEach(continents) { continent in
                    StatRow(
                        title: continent.isComplete
                            ? "\(continent.displayName) ✓" : continent.displayName,
                        value: "\(continent.visited) / \(continent.total)",
                        percent: continent.fraction * 100)
                }
            }
        }
    }
}

// MARK: - Timeline

/// A chronological list of every recorded visit across all countries, grouped
/// by year. Each entry shows the flag, country name, date, notes, and photo
/// thumbnails — a browsable travel history embedded in the statistics view.
private struct TimelineSection: View {
    let countries: [Country]

    /// All visits across every country, sorted newest-first.
    private var allVisits: [Visit] {
        countries
            .flatMap(\.visits)
            .sorted { $0.date > $1.date }
    }

    /// Visits grouped by year, descending.
    private var groupedByYear: [(year: Int, visits: [Visit])] {
        let grouped = Dictionary(grouping: allVisits) { visit in
            Calendar.current.component(.year, from: visit.date)
        }
        return grouped.keys
            .sorted(by: >)
            .map { year in
                (year: year, visits: grouped[year]!.sorted { $0.date > $1.date })
            }
    }

    @ViewBuilder var body: some View {
        if allVisits.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                TimelineHeader()

                // Keyed on stable identity (year / model id) rather than array
                // indices, so deleting a visit elsewhere can't mis-animate rows.
                ForEach(groupedByYear, id: \.year) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        // Year header with count
                        HStack(spacing: 6) {
                            Text(String(group.year))
                                .font(.title3.weight(.bold))
                            Text(
                                "\(group.visits.count) \(group.visits.count == 1 ? String(localized: "visit") : String(localized: "visits"))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)

                        // Timeline line + entries
                        ForEach(group.visits, id: \.persistentModelID) { visit in
                            TimelineEntryRow(
                                visit: visit,
                                isLast: visit.persistentModelID
                                    == group.visits.last?.persistentModelID
                            )
                        }

                        if group.year != groupedByYear.last?.year {
                            Divider()
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The small header above the timeline.
private struct TimelineHeader: View {
    var body: some View {
        HStack {
            SectionHeader(title: String(localized: "Travel Timeline"))
            Spacer()
        }
    }
}

/// A single row in the timeline: a dot on the left, then flag + country + date + notes.
private struct TimelineEntryRow: View {
    let visit: Visit
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timeline dot + line
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                if !isLast {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(visit.country?.flagEmoji ?? "🏳️")
                        .font(.title3)
                    Text(visit.country?.name ?? "Unknown")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(visit.date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if !visit.notes.isEmpty {
                    Text(visit.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !visit.photoIdentifiers.isEmpty {
                    VisitPhotosView(identifiers: visit.photoIdentifiers)
                        .frame(height: 44)
                }
            }
            .padding(.bottom, isLast ? 0 : 8)
        }
    }
}

// MARK: - Year in review

private struct YearInReviewSection: View {
    let stats: TravelStats
    let years: [TravelStats.YearStat]
    @Binding var selectedYear: Int
    let yearStat: TravelStats.YearStat
    /// Opens the year-in-review share card for `yearStat`.
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: String(localized: "Year in review"))
                Spacer()
                Picker("Year", selection: $selectedYear) {
                    ForEach(years.filter { $0.countries > 0 }.reversed()) { year in
                        Text(String(year.year)).tag(year.year)
                    }
                }
                .labelsHidden()
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In \(String(yearStat.year)) you visited")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(yearStat.countries) \(yearStat.countries == 1 ? String(localized: "country") : String(localized: "countries"))"
                    )
                    .font(.title2.bold())
                    Text(
                        "\(yearStat.visits) recorded \(yearStat.visits == 1 ? String(localized: "visit") : String(localized: "visits"))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            if yearStat.countries > 0 {
                Button(action: onShare) {
                    Label("Share This Year", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(.brand)
            }
        }
    }
}

// MARK: - Shared pieces

private struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.bold())
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A labelled progress row, reused by the continent breakdown.
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
                    .tint(.brand)
                Text((percent / 100).formatted(.percent))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

#if os(macOS)
    /// The in-window "Your Travels" destination: statistics and achievements in
    /// one dashboard, pushed over the map on the main window's navigation stack
    /// (replacing the old auxiliary Statistics window and Achievements sidebar
    /// section). Queries the catalog itself so pushing it needs no payload.
    struct TravelsDashboardView: View {
        @Query(sort: \Country.name) private var countries: [Country]

        private enum Page: String, CaseIterable {
            case statistics, achievements
        }
        @State private var page: Page = .statistics

        var body: some View {
            Group {
                switch page {
                case .statistics:
                    StatisticsView(countries: countries)
                case .achievements:
                    AchievementsView(countries: countries)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $page) {
                        Text("Statistics").tag(Page.statistics)
                        Text("Achievements").tag(Page.achievements)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }
#endif
