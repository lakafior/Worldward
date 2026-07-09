/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
            case .countries: String(localized: "Countries", comment: "Achievement category")
            case .continents: String(localized: "Continents", comment: "Achievement category")
            case .roots: String(localized: "Depth & Roots", comment: "Achievement category")
            case .log: String(localized: "Travel Log", comment: "Achievement category")
            case .mastery: String(localized: "Continent Mastery", comment: "Achievement category")
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
            (
                1, String(localized: "First Steps"),
                String(localized: "Visit your first country"), "figure.walk", .brandSky
            ),
            (
                5, String(localized: "Getting Around"),
                String(localized: "Visit 5 countries"), "airplane", .brandSky
            ),
            (
                10, String(localized: "Seasoned Traveler"),
                String(localized: "Visit 10 countries"), "suitcase.fill", .brandAzure
            ),
            (
                25, String(localized: "Globetrotter"),
                String(localized: "Visit 25 countries"), "globe.americas.fill", .brandAzure
            ),
            (
                50, String(localized: "World Wanderer"),
                String(localized: "Visit 50 countries"), "globe.europe.africa.fill", .brandRoyal
            ),
            (
                75, String(localized: "Voyager"),
                String(localized: "Visit 75 countries"), "globe.asia.australia.fill", .brandRoyal
            ),
            (
                100, String(localized: "Centurion"),
                String(localized: "Visit 100 countries"), "crown.fill", .brandRoyal
            ),
            (
                150, String(localized: "Cartographer"),
                String(localized: "Visit 150 countries"), "map.fill", .brandIndigo
            ),
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
            (
                2, String(localized: "Border Hopper"),
                String(localized: "Set foot on 2 continents"), "globe", .brandTeal
            ),
            (
                3, String(localized: "Continental"),
                String(localized: "Set foot on 3 continents"), "globe.americas.fill", .brandTeal
            ),
            (
                5, String(localized: "Globe Spanner"),
                String(localized: "Set foot on 5 continents"), "globe.europe.africa.fill",
                .brandIndigo
            ),
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
                id: "continents-all", category: .continents,
                title: String(localized: "Seven Summits"),
                detail: String(localized: "Set foot on every continent"),
                symbol: "globe.desk.fill",
                tint: .brandIndigo, isUnlocked: continentsTouched == 7,
                progress: Double(continentsTouched) / 7,
                progressLabel: "\(continentsTouched) / 7"))

        // MARK: Depth & Roots — passing through, settling down, returning.
        let done = String(localized: "Done", comment: "Achievement progress label: unlocked")
        let locked = String(localized: "Locked", comment: "Achievement progress label: locked")

        let crossed = stats.statusCounts[.crossed] ?? 0
        achievements.append(
            Achievement(
                id: "crossed", category: .roots, title: String(localized: "Passing Through"),
                detail: String(localized: "Cross through a country without stopping"),
                symbol: "arrow.right.circle",
                tint: .brandSky, isUnlocked: crossed > 0, progress: crossed > 0 ? 1 : 0,
                progressLabel: crossed > 0 ? done : locked))

        let hasLived = (stats.statusCounts[.lived] ?? 0) + (stats.statusCounts[.living] ?? 0) > 0
        achievements.append(
            Achievement(
                id: "settled", category: .roots, title: String(localized: "Put Down Roots"),
                detail: String(localized: "Mark a country as lived in"), symbol: "house.fill",
                tint: .brandAzure, isUnlocked: hasLived, progress: hasLived ? 1 : 0,
                progressLabel: hasLived ? done : locked))

        let living = stats.statusCounts[.living] ?? 0
        achievements.append(
            Achievement(
                id: "home-base", category: .roots, title: String(localized: "Home Base"),
                detail: String(localized: "Mark the country you live in now"),
                symbol: "house.circle.fill",
                tint: .brandRoyal, isUnlocked: living > 0, progress: living > 0 ? 1 : 0,
                progressLabel: living > 0 ? done : locked))

        let mostVisits = stats.mostVisited?.count ?? 0
        achievements.append(
            countMilestone(
                id: "loyal-visitor", category: .roots, title: String(localized: "Loyal Visitor"),
                detail: String(localized: "Return to one country 3 times"),
                symbol: "arrow.triangle.2.circlepath",
                tint: .brandTeal, value: mostVisits, target: 3))
        achievements.append(
            countMilestone(
                id: "creature-of-habit", category: .roots,
                title: String(localized: "Creature of Habit"),
                detail: String(localized: "Return to one country 5 times"),
                symbol: "arrow.triangle.2.circlepath",
                tint: .brandIndigo, value: mostVisits, target: 5))

        // MARK: Travel Log — recording visits and traveling across the years.
        let visitMilestones: [(Int, String, String, Color)] = [
            (10, String(localized: "Logbook"), String(localized: "Record 10 visits"), .brandSky),
            (
                25, String(localized: "Frequent Flyer"),
                String(localized: "Record 25 visits"), .brandRoyal
            ),
            (
                50, String(localized: "Travel Diary"),
                String(localized: "Record 50 visits"), .brandRoyal
            ),
            (
                100, String(localized: "Globe Logger"),
                String(localized: "Record 100 visits"), .brandIndigo
            ),
        ]
        for (threshold, title, detail, tint) in visitMilestones {
            achievements.append(
                countMilestone(
                    id: "visits-\(threshold)", category: .log, title: title, detail: detail,
                    symbol: "calendar", tint: tint, value: stats.totalVisits, target: threshold))
        }

        achievements.append(
            countMilestone(
                id: "active-years-3", category: .log, title: String(localized: "Seasons of Travel"),
                detail: String(localized: "Travel in 3 different years"),
                symbol: "clock.arrow.circlepath",
                tint: .brandTeal, value: stats.activeYears, target: 3))
        achievements.append(
            countMilestone(
                id: "active-years-5", category: .log, title: String(localized: "Five-Year Journey"),
                detail: String(localized: "Travel in 5 different years"),
                symbol: "clock.arrow.circlepath",
                tint: .brandIndigo, value: stats.activeYears, target: 5))
        achievements.append(
            countMilestone(
                id: "big-year", category: .log, title: String(localized: "Big Year"),
                detail: String(localized: "Visit 10 countries in a single year"),
                symbol: "flame.fill",
                tint: .brandRoyal, value: stats.busiestYear?.countries ?? 0, target: 10))

        // Streaks use the *longest* streak ever, not the live one, so a badge
        // once earned doesn't re-lock when a streak lapses with time.
        achievements.append(
            countMilestone(
                id: "streak-3", category: .log, title: String(localized: "On a Roll"),
                detail: String(localized: "Visit a new country 3 years in a row"),
                symbol: "laurel.leading",
                tint: .brandTeal, value: stats.longestNewCountryStreak, target: 3))
        achievements.append(
            countMilestone(
                id: "streak-5", category: .log, title: String(localized: "Unstoppable"),
                detail: String(localized: "Visit a new country 5 years in a row"),
                symbol: "laurel.leading",
                tint: .brandIndigo, value: stats.longestNewCountryStreak, target: 5))

        // MARK: Continent Mastery — visit every country in a continent. Shown for
        // every continent (not just those started) so the goals are always visible.
        for continent in stats.continents where continent.total > 0 {
            achievements.append(
                Achievement(
                    // The id keeps the English bucket name so already-persisted
                    // celebrated ids survive a device language change.
                    id: "complete-\(continent.name)", category: .mastery,
                    title: String(localized: "\(continent.displayName) Complete"),
                    detail: String(localized: "Visit every country in \(continent.displayName)"),
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
