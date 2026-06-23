import AppIntents
import Foundation
import SwiftData

// MARK: - Country Status (AppEnum)

/// An `AppEnum` mirror of `CountryStatus` that Shortcuts and Siri can display.
/// "Not visited" is deliberately absent from the public cases — shortcuts that
/// mark a country always move it *into* a visited state.
enum CountryStatusOption: String, AppEnum {
    case crossed
    case visited
    case lived
    case living

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Status")

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .crossed: "Crossed",
        .visited: "Visited",
        .lived: "Lived",
        .living: "Living",
    ]

    /// Map back to the domain enum for persisting.
    var domainStatus: CountryStatus {
        CountryStatus(rawValue: rawValue) ?? .visited
    }
}

// MARK: - Continent Names (AppEnum)

/// The seven canonical continents for use as an intent parameter. Matching
/// `TravelStats.canonicalContinents` exactly so progress queries are consistent.
enum ContinentName: String, AppEnum {
    case africa = "Africa"
    case antarctica = "Antarctica"
    case asia = "Asia"
    case australiaOceania = "Australia and Oceania"
    case europe = "Europe"
    case northAmerica = "North America"
    case southAmerica = "South America"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Continent")

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .africa: "Africa",
        .antarctica: "Antarctica",
        .asia: "Asia",
        .australiaOceania: "Australia and Oceania",
        .europe: "Europe",
        .northAmerica: "North America",
        .southAmerica: "South America",
    ]
}

// MARK: - 1. Mark Country Status

/// Sets the travel status of a country. The primary action — "Mark Japan as visited",
/// "Mark France as lived", etc. Works everywhere Shortcuts and Siri run.
struct MarkCountryStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Country Status"
    static let description = IntentDescription(
        "Sets a country's travel status — visited, lived, crossed, or living.",
        categoryName: "Travel",
        searchKeywords: ["visit", "visited", "lived", "country", "mark"]
    )

    @Parameter(title: "Country")
    var country: CountryEntity

    @Parameter(title: "Status")
    var status: CountryStatusOption

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$country) as \(\.$status)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = ModelContext(WorldMap.sharedModelContainer)
        let targetID = country.id
        let descriptor = FetchDescriptor<Country>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let model = try context.fetch(descriptor).first else {
            throw Error.countryNotFound(id: country.id)
        }

        model.status = status.domainStatus
        model.statusIsImported = false
        try context.save()

        return .result(
            value:
                "\(country.flagEmoji) \(country.name) marked as \(status.domainStatus.label.lowercased())."
        )
    }

    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible {
        case countryNotFound(id: String)
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .countryNotFound(let id):
                "No country found with code \(id)."
            }
        }
    }
}

// MARK: - 2. Show Travel Stats

/// Opens the app to the Statistics dashboard — the achievements grid, continent
/// breakdown, and per‑year chart. The actual navigation is handled by
/// posts a notification that ContentView observes to navigate.
struct OpenTravelStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Travel Stats"
    static let description = IntentDescription(
        "Opens your travel dashboard with visited countries, achievements, and continent progress.",
        categoryName: "Travel"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .worldMapOpenStats, object: nil)
        return .result()
    }
}

// MARK: - 3. Show Country on Map

/// Opens the app and selects a specific country on the world map, centering the
/// camera on its bounding rect. Useful for "show me where I went in Japan".
struct OpenCountryMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Country on Map"
    static let description = IntentDescription(
        "Opens the world map and focuses on a specific country.",
        categoryName: "Travel"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Country")
    var country: CountryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$country) on the map")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .worldMapOpenCountry, object: country.id)
        return .result()
    }
}

// MARK: - 4. Get Visit Count

/// Returns the number of countries visited and the count across all statuses, plus
/// the flag‑strip summary. Designed for Siri — "Hey Siri, how many countries have
/// I visited?" — but equally useful as a Shortcuts action that feeds other
/// automations.
struct GetVisitCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Visit Count"
    static let description = IntentDescription(
        "Returns how many countries you've visited, along with a per‑status breakdown.",
        categoryName: "Travel",
        searchKeywords: ["visited", "countries", "count", "stats", "summary"]
    )

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = ModelContext(WorldMap.sharedModelContainer)
        let descriptor = FetchDescriptor<Country>()
        let stats = TravelStats(countries: try context.fetch(descriptor))

        guard stats.hasTravel else {
            return .result(
                value: "You haven't recorded any travels yet. 🌍 Open WorldMap to get started.")
        }

        let statusLines =
            CountryStatus.allCases
            .filter { $0.isVisited }
            .map { status in
                let count = stats.statusCounts[status] ?? 0
                return "• \(status.label): \(count)"
            }
            .joined(separator: "\n")

        return .result(
            value: """
                🌍 You've visited \(stats.visitedCountries) of \(stats.totalCountries) countries.

                \(statusLines)

                You've set foot on \(stats.visitedContinents) continent\(stats.visitedContinents == 1 ? "" : "s").
                """
        )
    }
}

// MARK: - 5. Log a Visit

/// Records a visit to a country with an optional date. Falls back to the current
/// date when none is provided — the common "just got here" case.
struct LogVisitIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Visit"
    static let description = IntentDescription(
        "Records a visit to a country, optionally on a specific date.",
        categoryName: "Travel",
        searchKeywords: ["visit", "log", "record", "country", "date"]
    )

    @Parameter(title: "Country")
    var country: CountryEntity

    @Parameter(title: "Date of Visit")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Log a visit to \(\.$country)") {
            \.$date
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = ModelContext(WorldMap.sharedModelContainer)
        let targetID = country.id
        let descriptor = FetchDescriptor<Country>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let model = try context.fetch(descriptor).first else {
            throw MarkCountryStatusIntent.Error.countryNotFound(id: country.id)
        }

        let visitDate = date ?? Date()
        let visit = Visit(date: visitDate, notes: "", country: model, isImported: false)
        context.insert(visit)

        // If the country was unvisited, bump it to "visited".
        if model.status == .notVisited {
            model.status = .visited
            model.statusIsImported = false
        }

        try context.save()

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return .result(
            value:
                "📅 Visit to \(country.flagEmoji) \(country.name) logged on \(formatter.string(from: visitDate))."
        )
    }
}

// MARK: - 6. Continent Progress

/// Returns visited / total and percentage for a given continent. Designed for Siri
/// ("What's my progress in Europe?") and widget‑style shortcuts.
struct GetContinentProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Continent Progress"
    static let description = IntentDescription(
        "Shows how many countries you've visited in a specific continent.",
        categoryName: "Travel",
        searchKeywords: ["continent", "progress", "visited", "percentage", "europe", "asia"]
    )

    @Parameter(title: "Continent")
    var continent: ContinentName

    static var parameterSummary: some ParameterSummary {
        Summary("My progress in \(\.$continent)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = ModelContext(WorldMap.sharedModelContainer)
        let continentName = continent.rawValue
        let descriptor = FetchDescriptor<Country>(
            predicate: #Predicate { $0.continent == continentName }
        )
        let countries = try context.fetch(descriptor)

        let visited = countries.count { $0.isVisited }
        let total = countries.count
        let pct = total > 0 ? Int(Double(visited) / Double(total) * 100) : 0

        let visitedFlags =
            countries
            .filter { $0.isVisited }
            .map { $0.flagEmoji }
            .joined(separator: " ")

        return .result(
            value: """
                \(continent.rawValue): \(visited) of \(total) countries visited (\(pct)%).
                \(visitedFlags)
                """
        )
    }
}

// MARK: - Shortcuts Provider

/// Registers every intent with the system and promotes the most useful ones to
/// the Shortcuts app and Siri. Intents not listed here are still available in
/// Shortcuts under "WorldMap" but won't appear as first‑class suggestions.
struct WorldMapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MarkCountryStatusIntent(),
            phrases: [
                "Mark \(\.$country) in \(.applicationName)",
                "Set travel status for \(\.$country) with \(.applicationName)",
                "Flag \(\.$country) with \(.applicationName)",
            ],
            shortTitle: "Mark Country",
            systemImageName: "flag.checkered"
        )

        AppShortcut(
            intent: GetVisitCountIntent(),
            phrases: [
                "How many countries have I visited in \(.applicationName)?",
                "Show my travel count from \(.applicationName)",
                "What's my country count in \(.applicationName)?",
            ],
            shortTitle: "Visit Count",
            systemImageName: "globe"
        )

        AppShortcut(
            intent: LogVisitIntent(),
            phrases: [
                "Log a visit to \(\.$country) in \(.applicationName)",
                "Record a trip to \(\.$country) with \(.applicationName)",
            ],
            shortTitle: "Log Visit",
            systemImageName: "calendar.badge.plus"
        )

        AppShortcut(
            intent: GetContinentProgressIntent(),
            phrases: [
                "My progress in \(\.$continent) from \(.applicationName)",
                "How much of \(\.$continent) have I seen in \(.applicationName)?",
            ],
            shortTitle: "Continent Progress",
            systemImageName: "map"
        )
    }
}
