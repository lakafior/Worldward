import SwiftUI

/// A single gamification badge. Every achievement is derived on the fly from
/// `TravelStats` — nothing is persisted — so the grid always reflects the user's
/// current travels and recomputes instantly when a status changes.
struct Achievement: Identifiable {
    /// The group a badge belongs to, so the grid can be split into labelled
    /// sections rather than one long undifferentiated wall of tiles.
    enum Category: String, CaseIterable, Identifiable {
        case countries
        case continents
        case roots
        case log
        case mastery

        var id: String { rawValue }

        var title: String {
            switch self {
            case .countries: "Countries"
            case .continents: "Continents"
            case .roots: "Depth & Roots"
            case .log: "Travel Log"
            case .mastery: "Continent Mastery"
            }
        }
    }

    let id: String
    let category: Category
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let isUnlocked: Bool
    /// 0...1 progress toward unlocking. `1` once unlocked.
    let progress: Double
    /// Short progress label, e.g. "7 / 10".
    let progressLabel: String

    /// Builds the full ordered list of achievements for the given stats, grouped by
    /// `category`: country milestones, breadth across continents, depth/roots,
    /// the travel log, and finally a completion badge for every continent.
    static func all(for stats: TravelStats) -> [Achievement] {
        var achievements: [Achievement] = []

        // MARK: Countries — a classic escalating ladder. The tint deepens
        // sky → royal → indigo as the milestones get rarer.
        let countryMilestones: [(Int, String, String, String, Color)] = [
            (1, "First Steps", "Visit your first country", "figure.walk", .brandSky),
            (5, "Getting Around", "Visit 5 countries", "airplane", .brandSky),
            (10, "Seasoned Traveler", "Visit 10 countries", "suitcase.fill", .brandAzure),
            (25, "Globetrotter", "Visit 25 countries", "globe.americas.fill", .brandAzure),
            (50, "World Wanderer", "Visit 50 countries", "globe.europe.africa.fill", .brandRoyal),
            (75, "Voyager", "Visit 75 countries", "globe.asia.australia.fill", .brandRoyal),
            (100, "Centurion", "Visit 100 countries", "crown.fill", .brandRoyal),
            (150, "Cartographer", "Visit 150 countries", "map.fill", .brandIndigo),
        ]
        for (threshold, title, detail, symbol, tint) in countryMilestones {
            achievements.append(
                countMilestone(
                    id: "countries-\(threshold)", category: .countries, title: title,
                    detail: detail, symbol: symbol, tint: tint,
                    value: stats.visitedCountries, target: threshold))
        }

        // MARK: Continents — breadth across the globe.
        let continentMilestones: [(Int, String, String, String, Color)] = [
            (2, "Border Hopper", "Set foot on 2 continents", "globe", .brandTeal),
            (3, "Continental", "Set foot on 3 continents", "globe.americas.fill", .brandTeal),
            (5, "Globe Spanner", "Set foot on 5 continents", "globe.europe.africa.fill", .brandIndigo),
        ]
        for (threshold, title, detail, symbol, tint) in continentMilestones {
            achievements.append(
                countMilestone(
                    id: "continents-\(threshold)", category: .continents, title: title,
                    detail: detail, symbol: symbol, tint: tint,
                    value: stats.visitedContinents, target: threshold))
        }

        let continentsTouched = TravelStats.canonicalContinents.filter { name in
            (stats.continents.first { $0.name == name }?.visited ?? 0) > 0
        }.count
        achievements.append(
            Achievement(
                id: "continents-all", category: .continents, title: "Seven Summits",
                detail: "Set foot on every continent", symbol: "globe.desk.fill",
                tint: .brandIndigo, isUnlocked: continentsTouched == 7,
                progress: Double(continentsTouched) / 7,
                progressLabel: "\(continentsTouched) / 7"))

        // MARK: Depth & Roots — passing through, settling down, returning.
        let crossed = stats.statusCounts[.crossed] ?? 0
        achievements.append(
            Achievement(
                id: "crossed", category: .roots, title: "Passing Through",
                detail: "Cross through a country without stopping", symbol: "arrow.right.circle",
                tint: .brandSky, isUnlocked: crossed > 0, progress: crossed > 0 ? 1 : 0,
                progressLabel: crossed > 0 ? "Done" : "Locked"))

        let hasLived = (stats.statusCounts[.lived] ?? 0) + (stats.statusCounts[.living] ?? 0) > 0
        achievements.append(
            Achievement(
                id: "settled", category: .roots, title: "Put Down Roots",
                detail: "Mark a country as lived in", symbol: "house.fill",
                tint: .brandAzure, isUnlocked: hasLived, progress: hasLived ? 1 : 0,
                progressLabel: hasLived ? "Done" : "Locked"))

        let living = stats.statusCounts[.living] ?? 0
        achievements.append(
            Achievement(
                id: "home-base", category: .roots, title: "Home Base",
                detail: "Mark the country you live in now", symbol: "house.circle.fill",
                tint: .brandRoyal, isUnlocked: living > 0, progress: living > 0 ? 1 : 0,
                progressLabel: living > 0 ? "Done" : "Locked"))

        let mostVisits = stats.mostVisited?.count ?? 0
        achievements.append(
            countMilestone(
                id: "loyal-visitor", category: .roots, title: "Loyal Visitor",
                detail: "Return to one country 3 times", symbol: "arrow.triangle.2.circlepath",
                tint: .brandTeal, value: mostVisits, target: 3))
        achievements.append(
            countMilestone(
                id: "creature-of-habit", category: .roots, title: "Creature of Habit",
                detail: "Return to one country 5 times", symbol: "arrow.triangle.2.circlepath",
                tint: .brandIndigo, value: mostVisits, target: 5))

        // MARK: Travel Log — recording visits and traveling across the years.
        let visitMilestones: [(Int, String, String, Color)] = [
            (10, "Logbook", "Record 10 visits", .brandSky),
            (25, "Frequent Flyer", "Record 25 visits", .brandRoyal),
            (50, "Travel Diary", "Record 50 visits", .brandRoyal),
            (100, "Globe Logger", "Record 100 visits", .brandIndigo),
        ]
        for (threshold, title, detail, tint) in visitMilestones {
            achievements.append(
                countMilestone(
                    id: "visits-\(threshold)", category: .log, title: title, detail: detail,
                    symbol: "calendar", tint: tint, value: stats.totalVisits, target: threshold))
        }

        achievements.append(
            countMilestone(
                id: "active-years-3", category: .log, title: "Seasons of Travel",
                detail: "Travel in 3 different years", symbol: "clock.arrow.circlepath",
                tint: .brandTeal, value: stats.activeYears, target: 3))
        achievements.append(
            countMilestone(
                id: "active-years-5", category: .log, title: "Five-Year Journey",
                detail: "Travel in 5 different years", symbol: "clock.arrow.circlepath",
                tint: .brandIndigo, value: stats.activeYears, target: 5))
        achievements.append(
            countMilestone(
                id: "big-year", category: .log, title: "Big Year",
                detail: "Visit 10 countries in a single year", symbol: "flame.fill",
                tint: .brandRoyal, value: stats.busiestYear?.countries ?? 0, target: 10))

        // MARK: Continent Mastery — visit every country in a continent. Shown for
        // every continent (not just those started) so the goals are always visible.
        for continent in stats.continents where continent.total > 0 {
            achievements.append(
                Achievement(
                    id: "complete-\(continent.name)", category: .mastery,
                    title: "\(continent.name) Complete",
                    detail: "Visit every country in \(continent.name)",
                    symbol: "checkmark.seal.fill", tint: .brandTeal,
                    isUnlocked: continent.isComplete, progress: continent.fraction,
                    progressLabel: "\(continent.visited) / \(continent.total)"))
        }

        return achievements
    }

    /// Helper for the common "reach N of something" badge.
    private static func countMilestone(
        id: String, category: Category, title: String, detail: String, symbol: String,
        tint: Color, value: Int, target: Int
    ) -> Achievement {
        let unlocked = value >= target
        return Achievement(
            id: id, category: category, title: title, detail: detail, symbol: symbol,
            tint: tint, isUnlocked: unlocked,
            progress: target > 0 ? min(Double(value) / Double(target), 1) : 0,
            progressLabel: "\(min(value, target)) / \(target)")
    }
}
