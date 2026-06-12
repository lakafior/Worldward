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
    var centroids: [String: CLLocationCoordinate2D] = [:]

    @Environment(\.dismiss) private var dismiss

    @State private var selectedYear: Int?
    @State private var summaryImage: Image?

    private var stats: TravelStats { TravelStats(countries: countries) }

    private var selectedYearStat: TravelStats.YearStat? {
        let stats = stats
        if let selectedYear { return stats.years.first { $0.year == selectedYear } }
        return stats.busiestYear ?? stats.years.last
    }

    var body: some View {
        let stats = stats

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HeroSection(stats: stats)

                    AchievementsSection(achievements: Achievement.all(for: stats))

                    StatCardsSection(stats: stats)

                    if stats.years.contains(where: { $0.countries > 0 }) {
                        YearChartSection(years: stats.years)
                    }

                    ContinentSection(continents: stats.continents)

                    let suggestions = nearestUnvisited(countries: countries, centroids: centroids)
                    if !suggestions.isEmpty {
                        NextClosestSection(suggestions: suggestions)
                    }

                    if let yearStat = selectedYearStat {
                        YearInReviewSection(
                            stats: stats,
                            years: stats.years,
                            selectedYear: Binding(
                                get: { yearStat.year },
                                set: { selectedYear = $0 }),
                            yearStat: yearStat)
                    }
                }
                .padding()
            }
            .navigationTitle("Your Travels")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Menu {
                        if let summaryImage {
                            ShareLink(
                                item: summaryImage,
                                preview: SharePreview(
                                    "My WorldMap travels", image: summaryImage)
                            ) {
                                Label("Share Image", systemImage: "photo")
                            }
                        }
                        ShareLink(item: stats.shareText) {
                            Label("Share Text", systemImage: "text.quote")
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 520)
        .onAppear {
            summaryImage = renderShareImage(ShareCard(stats: stats))
        }
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
                        .foregroundStyle(.orange)
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
        VStack(alignment: .leading, spacing: 12) {
            let unlocked = achievements.filter(\.isUnlocked).count
            SectionHeader(
                title: "Achievements", trailing: "\(unlocked) / \(achievements.count)")

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(achievements) { achievement in
                    AchievementBadge(achievement: achievement)
                }
            }
        }
    }
}

private struct AchievementBadge: View {
    let achievement: Achievement

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(achievement.isUnlocked
                        ? achievement.tint.opacity(0.2) : Color.gray.opacity(0.12))
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

            if achievement.isUnlocked {
                Text("Unlocked")
                    .font(.caption2)
                    .foregroundStyle(achievement.tint)
            } else {
                ProgressView(value: achievement.progress)
                    .tint(achievement.tint)
                Text(achievement.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .opacity(achievement.isUnlocked ? 1 : 0.85)
        .help(achievement.detail)
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
                symbol: "calendar", tint: .blue)
            StatCard(
                title: "Years traveling", value: "\(stats.activeYears)",
                symbol: "clock.arrow.circlepath", tint: .teal)
            if let most = stats.mostVisited {
                StatCard(
                    title: "Most visited", value: "\(most.flag) ×\(most.count)",
                    symbol: "star.fill", tint: .orange)
            }
            if let busiest = stats.busiestYear, busiest.countries > 0 {
                StatCard(
                    title: "Busiest year",
                    value: "\(busiest.year) · \(busiest.countries)",
                    symbol: "flame.fill", tint: .red)
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
                    y: .value("Countries", year.countries))
                .foregroundStyle(.orange.gradient)
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
                    Text("\(yearStat.countries) "
                        + (yearStat.countries == 1 ? "country" : "countries"))
                        .font(.title2.bold())
                    Text("\(yearStat.visits) recorded "
                        + (yearStat.visits == 1 ? "visit" : "visits"))
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
                    .tint(.orange)
                Text(String(format: "%.0f%%", percent))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
