import Charts
import MapKit
import SwiftUI

/// Full-page travel dashboard: a gamified summary of everywhere the user has been.
/// Presented as a sheet from the map toolbar. All figures derive from a single
/// `TravelStats` pass; nothing here is persisted.
struct StatisticsView: View {
    let countries: [Country]
    /// Country centroids (id → coordinate) used for the "next closest" suggestions.
    /// Empty until the map's GeoJSON has finished loading, in which case that
    /// section is simply hidden.
    let centroids: [String: CLLocationCoordinate2D]

    @Environment(\.dismiss) private var dismiss

    @State private var selectedYear: Int?
    @State private var showShareSheet = false
    @State private var insights = TravelInsights()

    /// Computed once per view instance. `TravelStats` is a full O(n) pass, and the
    /// body, the year picker, and the share-image render all read it — recomputing
    /// it as a stored `let` instead of a computed property avoids repeating that work.
    private let stats: TravelStats

    init(countries: [Country], centroids: [String: CLLocationCoordinate2D] = [:]) {
        self.countries = countries
        self.centroids = centroids
        self.stats = TravelStats(countries: countries)
    }

    private var selectedYearStat: TravelStats.YearStat? {
        if let selectedYear { return stats.years.first { $0.year == selectedYear } }
        return stats.busiestYear ?? stats.years.last
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HeroSection(stats: stats)

                    AchievementsSection(achievements: Achievement.all(for: stats))

                    TimelineSection(countries: countries)

                    StatCardsSection(stats: stats)

                    if stats.hasPlans {
                        PlansSection(stats: stats)
                    }

                    if stats.years.contains(where: { $0.countries > 0 }) {
                        YearChartSection(years: stats.years)
                    }

                    ContinentSection(continents: stats.continents)

                    let suggestions = nearestUnvisited(countries: countries, centroids: centroids)
                    if !suggestions.isEmpty {
                        NextClosestSection(suggestions: suggestions)

                        if insights.isAvailable {
                            SmartSuggestionsSection(insights: insights, candidates: suggestions)
                        }
                    }

                    if let yearStat = selectedYearStat {
                        YearInReviewSection(
                            stats: stats,
                            years: stats.years,
                            selectedYear: Binding(
                                get: { yearStat.year },
                                set: { selectedYear = $0 }),
                            yearStat: yearStat)

                        if insights.isAvailable {
                            AIRecapSection(insights: insights, stats: stats, yearStat: yearStat)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Your Travels")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(macOS)
                    ToolbarItem(placement: .cancellationAction) { shareButton }
                #else
                    ToolbarItem(placement: .topBarLeading) { shareButton }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 520)
        .sheet(isPresented: $showShareSheet) {
            ShareCustomizationView(stats: stats, tints: stats.statusTints)
        }
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

// MARK: - Achievements

private struct AchievementsSection: View {
    let achievements: [Achievement]

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            let unlocked = achievements.filter(\.isUnlocked).count
            SectionHeader(
                title: "Achievements", trailing: "\(unlocked) / \(achievements.count)")

            // Split into labelled groups so the wall of badges reads as themed
            // collections (Countries, Continents, …) rather than one long grid.
            ForEach(Achievement.Category.allCases) { category in
                let group = achievements.filter { $0.category == category }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(category.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(group.filter(\.isUnlocked).count) / \(group.count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group) { achievement in
                                AchievementBadge(achievement: achievement)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AchievementBadge: View {
    let achievement: Achievement

    /// Drives the tap-to-reveal description. macOS users get the same text on
    /// hover via `.help`, but a touch device has no hover, so tapping a badge
    /// surfaces it in a popover.
    @State private var showingDetail = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(
                        achievement.isUnlocked
                            ? achievement.tint.opacity(0.2) : Color.gray.opacity(0.12)
                    )
                    .frame(width: 56, height: 56)
                Image(systemName: achievement.symbol)
                    .font(.title2)
                    .foregroundStyle(
                        achievement.isUnlocked ? achievement.tint : Color.secondary)
            }
            .overlay(alignment: .bottomTrailing) {
                if achievement.isUnlocked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white, achievement.tint)
                }
            }

            Text(achievement.title)
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)

            // Every badge shares this footer — a progress bar (full once unlocked)
            // plus one status line — so locked and unlocked tiles have identical
            // height and the grid stays even across all columns.
            ProgressView(value: achievement.progress)
                .tint(achievement.tint)
            Text(achievement.isUnlocked ? "Unlocked" : achievement.progressLabel)
                .font(.caption2)
                .foregroundStyle(achievement.isUnlocked ? achievement.tint : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .opacity(achievement.isUnlocked ? 1 : 0.85)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(achievement.detail)
        .onTapGesture { showingDetail = true }
        // A touch device has no hover tooltip, so reveal the description on tap.
        .popover(isPresented: $showingDetail) {
            AchievementDetailPopover(achievement: achievement)
                .presentationCompactAdaptation(.popover)
        }
        // Read as one element to VoiceOver, with the description as the hint.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(achievement.title), "
                + (achievement.isUnlocked ? "unlocked" : "locked, \(achievement.progressLabel)")
        )
        .accessibilityHint(achievement.detail)
    }
}

/// The small bubble shown when a badge is tapped — the only way to read a badge's
/// description on a touch device, where there's no hover tooltip.
private struct AchievementDetailPopover: View {
    let achievement: Achievement

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: achievement.symbol)
                    .font(.title3)
                    .foregroundStyle(achievement.isUnlocked ? achievement.tint : Color.secondary)
                Text(achievement.title)
                    .font(.headline)
            }

            Text(achievement.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if achievement.isUnlocked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(achievement.tint)
                    Text("Unlocked")
                        .foregroundStyle(achievement.tint)
                } else {
                    ProgressView(value: achievement.progress)
                        .tint(achievement.tint)
                    Text(achievement.progressLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(.medium))
        }
        .padding()
        .frame(width: 240)
    }
}

// MARK: - Stat cards

private struct StatCardsSection: View {
    let stats: TravelStats

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatCard(
                title: "Recorded visits", value: "\(stats.totalVisits)",
                symbol: "calendar", tint: .brandRoyal)
            StatCard(
                title: "Years traveling", value: "\(stats.activeYears)",
                symbol: "clock.arrow.circlepath", tint: .brandTeal)
            if let most = stats.mostVisited {
                StatCard(
                    title: "Most visited", value: "\(most.flag) ×\(most.count)",
                    symbol: "star.fill", tint: .brandAzure)
            }
            if let busiest = stats.busiestYear, busiest.countries > 0 {
                StatCard(
                    title: "Busiest year",
                    value: "\(busiest.year) · \(busiest.countries)",
                    symbol: "flame.fill", tint: .brandIndigo)
            }
        }
    }
}

/// The "Going" counterpart to the visited stat cards: how many countries are on
/// your wishlist and how many you're actively planning, in the blue plan scale.
private struct PlansSection: View {
    let stats: TravelStats

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "On your list", trailing: "\(stats.plannedCount)")
            LazyVGrid(columns: columns, spacing: 12) {
                StatCard(
                    title: "Wishlist", value: "\(stats.wishlistCount)",
                    symbol: PlanStatus.wishlist.symbolName, tint: PlanStatus.wishlist.color)
                StatCard(
                    title: "Planning", value: "\(stats.planningCount)",
                    symbol: PlanStatus.planning.symbolName, tint: PlanStatus.planning.color)
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
            SectionHeader(title: "Countries per year")

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

// MARK: - Continents

private struct ContinentSection: View {
    let continents: [TravelStats.ContinentStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "By continent")

            VStack(spacing: 12) {
                ForEach(continents) { continent in
                    StatRow(
                        title: continent.isComplete
                            ? "\(continent.name) ✓" : continent.name,
                        value: "\(continent.visited) / \(continent.total)",
                        percent: continent.fraction * 100)
                }
            }
        }
    }
}

// MARK: - Next closest

private struct NextClosestSection: View {
    let suggestions: [(country: Country, distanceKM: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Closest unvisited")

            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.country.id) {
                    index, item in
                    HStack {
                        Text(item.country.flagEmoji)
                        Text(item.country.name)
                        Spacer()
                        Text("\(Int(item.distanceKM.rounded())) km away")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 8)
                    if index < suggestions.count - 1 { Divider() }
                }
            }
            .padding(.horizontal)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
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

                ForEach(groupedByYear.indices, id: \.self) { sectionIndex in
                    let group = groupedByYear[sectionIndex]

                    VStack(alignment: .leading, spacing: 0) {
                        // Year header with count
                        HStack(spacing: 6) {
                            Text(String(group.year))
                                .font(.title3.weight(.bold))
                            Text(
                                "\(group.visits.count) \(group.visits.count == 1 ? "visit" : "visits")"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)

                        // Timeline line + entries
                        ForEach(group.visits.indices, id: \.self) { index in
                            TimelineEntryRow(
                                visit: group.visits[index],
                                isLast: index == group.visits.count - 1
                            )
                        }

                        if sectionIndex < groupedByYear.count - 1 {
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
            SectionHeader(title: "Travel Timeline")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Year in review")
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
                        "\(yearStat.countries) "
                            + (yearStat.countries == 1 ? "country" : "countries")
                    )
                    .font(.title2.bold())
                    Text(
                        "\(yearStat.visits) recorded "
                            + (yearStat.visits == 1 ? "visit" : "visits")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Smart suggestions (Apple Intelligence)

/// Opt-in next-destination picks with a one-line rationale, generated on-device
/// from the closest-unvisited candidates. The model only phrases and ranks — the
/// candidate set and flags come from real data, so it can't invent a country.
private struct SmartSuggestionsSection: View {
    let insights: TravelInsights
    let candidates: [(country: Country, distanceKM: Double)]

    @State private var picks: [ResolvedPick] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private struct ResolvedPick: Identifiable {
        let id: String
        let flag: String
        let name: String
        let reason: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Suggested for you")

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Thinking about where to go next…")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if picks.isEmpty {
                Button(action: generate) {
                    Label("Suggest with Apple Intelligence", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
            }

            if !picks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                        HStack(alignment: .top, spacing: 10) {
                            Text(pick.flag)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pick.name).fontWeight(.medium)
                                Text(pick.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        if index < picks.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                Button("Suggest again", action: generate)
                    .font(.caption)
                    .disabled(isLoading)
            }
        }
    }

    private func generate() {
        isLoading = true
        errorMessage = nil
        let top = Array(candidates.prefix(8))
        let descriptions = top.map { item in
            "\(item.country.name) (\(item.country.continent), ~\(Int(item.distanceKM.rounded())) km away)"
        }
        Task {
            defer { isLoading = false }
            do {
                let raw = try await insights.suggestDestinations(candidates: descriptions)
                picks = raw.compactMap { pick in
                    guard let match = top.first(where: { matches(pick.country, $0.country.name) })
                    else { return nil }
                    return ResolvedPick(
                        id: match.country.id, flag: match.country.flagEmoji,
                        name: match.country.name, reason: pick.reason)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Loose name match so a model paraphrase still resolves to a candidate.
    private func matches(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveContains(b) || b.localizedCaseInsensitiveContains(a)
    }
}

// MARK: - AI year recap (Apple Intelligence)

/// Opt-in, on-device prose recap of the selected year. Regenerated per year; the
/// model phrases facts already computed by `TravelStats` and never adds figures.
private struct AIRecapSection: View {
    let insights: TravelInsights
    let stats: TravelStats
    let yearStat: TravelStats.YearStat

    @State private var recap = ""
    @State private var generatedYear: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// The shown recap is valid only for the year it was generated for.
    private var hasCurrentRecap: Bool {
        !recap.isEmpty && generatedYear == yearStat.year
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "AI recap")

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Writing your \(String(yearStat.year)) recap…")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if hasCurrentRecap {
                Text(recap)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                Button("Rewrite", action: generate)
                    .font(.caption)
            } else {
                Button(action: generate) {
                    Label("Write \(String(yearStat.year)) recap", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
            }
        }
    }

    private func generate() {
        isLoading = true
        errorMessage = nil
        let year = yearStat.year
        let countries = stats.countries(inYear: year).map { "\($0.flag) \($0.name)" }
        let visits = yearStat.visits
        Task {
            defer { isLoading = false }
            do {
                recap = try await insights.yearInReview(
                    year: year, countries: countries, visits: visits)
                generatedYear = year
            } catch {
                errorMessage = error.localizedDescription
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
                Text(String(format: "%.0f%%", percent))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
