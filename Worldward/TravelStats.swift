import Foundation
import MapKit
import SwiftUI

/// Every travel statistic the app shows, derived in a single pass over the user's
/// countries. A pure value type so it can be computed off the view and reused by
/// the achievements grid, the year-in-review, and the shareable card without
/// recomputing or touching SwiftData on a background thread.
struct TravelStats {
    /// One continent's visited/total tally.
    struct ContinentStat: Identifiable {
        let name: String
        let visited: Int
        let total: Int
        var id: String { name }
        var fraction: Double { total > 0 ? Double(visited) / Double(total) : 0 }
        var isComplete: Bool { total > 0 && visited == total }
    }

    /// One year's travel summary, used by the per-year chart and year-in-review.
    struct YearStat: Identifiable {
        let year: Int
        let countries: Int
        let visits: Int
        var id: Int { year }
    }

    let totalCountries: Int
    let visitedCountries: Int
    let statusCounts: [CountryStatus: Int]

    let totalContinents: Int
    let visitedContinents: Int
    let continents: [ContinentStat]

    let totalVisits: Int
    let years: [YearStat]                       // sorted ascending by year
    let countryIDsByYear: [Int: Set<String>]    // year -> visited country ids

    let mostVisited: (name: String, flag: String, count: Int)?
    let firstVisitDate: Date?
    let lastVisitDate: Date?

    /// Flag emoji of every visited country, ordered strongest bond first then by
    /// name — used for the flag strip on the dashboard.
    let visitedFlags: [String]

    /// Every visited country as `(flag, name)`, sorted alphabetically — the
    /// checklist listed in the share card and the share text. Listing the actual
    /// countries is the whole point of the app, so both shares lead with it.
    let visitedList: [(flag: String, name: String)]

    /// Maps a country id to its `(flag, name)` for visited countries, so a year's
    /// country set can be turned into a labelled list.
    private let labelByID: [String: (flag: String, name: String)]

    /// The seven canonical continents, used for the "every continent" achievement.
    static let canonicalContinents = [
        "Europe", "Asia", "Africa", "North America",
        "South America", "Australia and Oceania", "Antarctica",
    ]

    init(countries: [Country]) {
        let calendar = Calendar.current

        var visited = 0
        var statusCounts: [CountryStatus: Int] = [:]
        var buckets: [String: (visited: Int, total: Int)] = [:]
        var visitsByYear: [Int: Int] = [:]
        var countryIDsByYear: [Int: Set<String>] = [:]
        var totalVisits = 0
        var firstDate: Date?
        var lastDate: Date?

        var best: (name: String, flag: String, count: Int)?
        var flagged: [(status: CountryStatus, name: String, flag: String)] = []
        var labels: [String: (flag: String, name: String)] = [:]

        for country in countries {
            let status = country.status
            statusCounts[status, default: 0] += 1

            var bucket = buckets[country.continent, default: (0, 0)]
            bucket.total += 1

            if status.isVisited {
                visited += 1
                bucket.visited += 1
                flagged.append((status, country.name, country.flagEmoji))
                labels[country.id] = (country.flagEmoji, country.name)
            }
            buckets[country.continent] = bucket

            // Gather every dated visit, including the legacy single `visitDate`.
            var dates = country.visits.map(\.date)
            if let legacy = country.visitDate { dates.append(legacy) }

            for date in dates {
                let year = calendar.component(.year, from: date)
                visitsByYear[year, default: 0] += 1
                countryIDsByYear[year, default: []].insert(country.id)
                totalVisits += 1
                if firstDate == nil || date < firstDate! { firstDate = date }
                if lastDate == nil || date > lastDate! { lastDate = date }
            }

            let count = max(country.visits.count, country.visitDate != nil ? 1 : 0)
            if status.isVisited, count > 0, count > (best?.count ?? 0) {
                best = (country.name, country.flagEmoji, count)
            }
        }

        let continents = buckets
            .map { ContinentStat(name: $0.key, visited: $0.value.visited, total: $0.value.total) }
            .sorted { $0.name < $1.name }

        let years = Set(Array(visitsByYear.keys) + Array(countryIDsByYear.keys))
            .sorted()
            .map { year in
                YearStat(
                    year: year,
                    countries: countryIDsByYear[year]?.count ?? 0,
                    visits: visitsByYear[year] ?? 0)
            }

        self.totalCountries = countries.count
        self.visitedCountries = visited
        self.statusCounts = statusCounts
        self.totalContinents = continents.count
        self.visitedContinents = continents.lazy.filter { $0.visited > 0 }.count
        self.continents = continents
        self.totalVisits = totalVisits
        self.years = years
        self.countryIDsByYear = countryIDsByYear
        self.mostVisited = best
        self.firstVisitDate = firstDate
        self.lastVisitDate = lastDate

        let rank: (CountryStatus) -> Int = { status in
            CountryStatus.allCases.firstIndex(of: status) ?? 0
        }
        self.visitedFlags = flagged
            .sorted { lhs, rhs in
                rank(lhs.status) != rank(rhs.status)
                    ? rank(lhs.status) > rank(rhs.status)
                    : lhs.name < rhs.name
            }
            .map(\.flag)

        self.labelByID = labels
        self.visitedList = flagged
            .sorted { $0.name < $1.name }
            .map { (flag: $0.flag, name: $0.name) }
    }

    /// The visited countries recorded in a given calendar year, as `(flag, name)`
    /// sorted alphabetically.
    func countries(inYear year: Int) -> [(flag: String, name: String)] {
        (countryIDsByYear[year] ?? [])
            .compactMap { labelByID[$0] }
            .sorted { $0.name < $1.name }
    }

    /// Count of distinct calendar years that have at least one recorded visit.
    var activeYears: Int { years.filter { $0.visits > 0 }.count }

    /// The year with the most countries visited, if any travel is recorded.
    var busiestYear: YearStat? { years.max { $0.countries < $1.countries } }

    /// `true` when at least one country has been visited.
    var hasTravel: Bool { visitedCountries > 0 }

    /// A friendly summary for sharing as plain text, leading with the headline
    /// figures and then listing every country visited.
    var shareText: String {
        guard hasTravel else { return "Just getting started exploring the world with Worldward 🌍" }
        let continentWord = visitedContinents == 1 ? "continent" : "continents"
        let list = visitedList.map { "\($0.flag) \($0.name)" }.joined(separator: ", ")
        return """
            🌍 I've visited \(visitedCountries) countries across \(visitedContinents) \(continentWord), tracked with Worldward:
            \(list)
            """
    }
}

/// The unvisited countries closest to anywhere the user has already been, nearest
/// first. Uses each country's centroid (derived from its map bounding rect) so the
/// suggestion reflects real geographic proximity rather than alphabetical order.
func nearestUnvisited(
    countries: [Country],
    centroids: [String: CLLocationCoordinate2D],
    limit: Int = 5
) -> [(country: Country, distanceKM: Double)] {
    let visitedPoints = countries
        .filter { $0.isVisited }
        .compactMap { centroids[$0.id].map(MKMapPoint.init) }
    guard !visitedPoints.isEmpty else { return [] }

    var scored: [(country: Country, distanceKM: Double)] = []
    for country in countries where !country.isVisited {
        guard let coordinate = centroids[country.id] else { continue }
        let point = MKMapPoint(coordinate)
        let nearest = visitedPoints.map { point.distance(to: $0) }.min() ?? .greatestFiniteMagnitude
        scored.append((country, nearest / 1000))
    }

    return Array(scored.sorted { $0.distanceKM < $1.distanceKM }.prefix(limit))
}
