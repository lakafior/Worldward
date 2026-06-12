import SwiftUI

/// A single gamification badge. Every achievement is derived on the fly from
/// `TravelStats` — nothing is persisted — so the grid always reflects the user's
/// current travels and recomputes instantly when a status changes.
struct Achievement: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let isUnlocked: Bool
    /// 0...1 progress toward unlocking. `1` once unlocked.
    let progress: Double
    /// Short progress label, e.g. "7 / 10".
    let progressLabel: String

    /// Builds the full ordered list of achievements for the given stats. Country
    /// milestones come first, then breadth (continents), then depth (home, visits),
    /// then a completion badge for each continent the user has started exploring.
    static func all(for stats: TravelStats) -> [Achievement] {
        var achievements: [Achievement] = []

        // Country-count milestones: a classic escalating ladder.
        let countryMilestones: [(Int, String, String, String)] = [
            (1, "First Steps", "Visit your first country", "figure.walk"),
            (5, "Getting Around", "Visit 5 countries", "airplane"),
            (10, "Seasoned Traveler", "Visit 10 countries", "suitcase.fill"),
            (25, "Globetrotter", "Visit 25 countries", "globe.americas.fill"),
            (50, "World Wanderer", "Visit 50 countries", "globe.europe.africa.fill"),
            (100, "Centurion", "Visit 100 countries", "crown.fill"),
        ]
        for (threshold, title, detail, symbol) in countryMilestones {
            achievements.append(
                countMilestone(
                    id: "countries-\(threshold)", title: title, detail: detail,
                    symbol: symbol, tint: .orange,
                    value: stats.visitedCountries, target: threshold))
        }

        // Breadth: spreading across the globe.
        achievements.append(
            countMilestone(
                id: "continents-3", title: "Continental",
                detail: "Set foot on 3 continents", symbol: "globe", tint: .teal,
                value: stats.visitedContinents, target: 3))

        let everyContinent = TravelStats.canonicalContinents.allSatisfy { name in
            (stats.continents.first { $0.name == name }?.visited ?? 0) > 0
        }
        let continentsTouched = TravelStats.canonicalContinents.filter { name in
            (stats.continents.first { $0.name == name }?.visited ?? 0) > 0
        }.count
        achievements.append(
            Achievement(
                id: "continents-all", title: "Seven Summits",
                detail: "Set foot on every continent", symbol: "globe.desk.fill",
                tint: .purple, isUnlocked: everyContinent,
                progress: Double(continentsTouched) / 7,
                progressLabel: "\(continentsTouched) / 7"))

        // Depth: putting down roots.
        let hasLived = (stats.statusCounts[.lived] ?? 0) + (stats.statusCounts[.living] ?? 0) > 0
        achievements.append(
            Achievement(
                id: "settled", title: "Put Down Roots",
                detail: "Mark a country as lived in", symbol: "house.fill",
                tint: .brown, isUnlocked: hasLived, progress: hasLived ? 1 : 0,
                progressLabel: hasLived ? "Done" : "Locked"))

        // Frequency: keeping a travel log.
        achievements.append(
            countMilestone(
                id: "visits-25", title: "Frequent Flyer",
                detail: "Record 25 visits", symbol: "calendar", tint: .blue,
                value: stats.totalVisits, target: 25))

        // Per-continent completion, only for continents already started so the grid
        // stays relevant rather than listing every untouched region.
        for continent in stats.continents where continent.visited > 0 && continent.total > 0 {
            achievements.append(
                Achievement(
                    id: "complete-\(continent.name)",
                    title: "\(continent.name) Complete",
                    detail: "Visit every country in \(continent.name)",
                    symbol: "checkmark.seal.fill", tint: .green,
                    isUnlocked: continent.isComplete, progress: continent.fraction,
                    progressLabel: "\(continent.visited) / \(continent.total)"))
        }

        return achievements
    }

    /// Helper for the common "reach N of something" badge.
    private static func countMilestone(
        id: String, title: String, detail: String, symbol: String, tint: Color,
        value: Int, target: Int
    ) -> Achievement {
        let unlocked = value >= target
        return Achievement(
            id: id, title: title, detail: detail, symbol: symbol, tint: tint,
            isUnlocked: unlocked,
            progress: target > 0 ? min(Double(value) / Double(target), 1) : 0,
            progressLabel: "\(min(value, target)) / \(target)")
    }
}
