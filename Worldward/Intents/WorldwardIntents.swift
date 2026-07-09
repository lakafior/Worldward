/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import Foundation
import SwiftData
import SwiftUI

// MARK: - Country Status (AppEnum)

/// An `AppEnum` mirror of `CountryStatus` that Shortcuts and Siri can display.
/// "Not visited" is deliberately absent from the public cases — shortcuts that
/// mark a country always move it *into* a visited state.
enum CountryStatusOption: String, AppEnum, Identifiable {
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

    var id: String { rawValue }
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

// MARK: - Widget refresh

/// Recomputes the widget snapshot from the store. Called by every intent that
/// mutates travel data: intents can run via Siri/Shortcuts without `ContentView`
/// ever existing, so without this the widgets stay stale until the next app
/// launch. `WidgetSnapshotStore.write` skips unchanged snapshots, so calling it
/// after every mutation is cheap. Also reused by `ContentView` so both paths
/// build the snapshot identically.
@MainActor
func refreshWidgetSnapshot(countries: [Country], trips: [Trip]) {
    let stats = TravelStats(countries: countries)
    let theme = UserDefaults.standard.string(forKey: "appTheme") ?? "system"
    let now = Date()
    // Up to three upcoming trips, soonest first, so the widget can roll over to
    // the next journey on its own when one ends (see WidgetSnapshot.UpcomingTrip).
    let upcoming = trips
        .filter { $0.isUpcoming(asOf: now) }
        .sorted { $0.startDate < $1.startDate }
        .prefix(3)
        .map {
            WidgetSnapshot.UpcomingTrip(
                title: $0.title, flags: $0.flags,
                startDate: $0.startDate, endDate: $0.endDate)
        }
    WidgetSnapshotStore.write(
        WidgetSnapshot(
            visitedCountries: stats.visitedCountries,
            totalCountries: stats.totalCountries,
            visitedContinents: stats.visitedContinents,
            totalContinents: stats.totalContinents,
            flags: stats.visitedFlags,
            tints: stats.statusTints,
            appTheme: theme,
            upcomingTrips: Array(upcoming)))
}

/// Convenience for intents, which fetch from their own short-lived context.
@MainActor
private func refreshWidgetSnapshot(using context: ModelContext) {
    let countries = (try? context.fetch(FetchDescriptor<Country>())) ?? []
    let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
    refreshWidgetSnapshot(countries: countries, trips: trips)
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

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = ModelContext(Worldward.sharedModelContainer)
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
        refreshWidgetSnapshot(using: context)

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
/// breakdown, and per‑year chart. Navigation is handled by `ContentView`, which
/// observes `IntentRouter` and presents the dashboard.
struct OpenTravelStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Travel Stats"
    static let description = IntentDescription(
        "Opens your travel dashboard with visited countries, achievements, and continent progress.",
        categoryName: "Travel"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingOpenStats = true
        return .result()
    }
}

// MARK: - 3. Show Country on Map

// ── macOS 27+ only ────────────────────────────────────────────────
// Re‑enable when MACOSX_DEPLOYMENT_TARGET ≥ 27.0:
//
// @AppIntent(schema: .system.open)
// struct OpenCountryMapIntent: OpenIntent {
//     @Parameter(title: "Country")
//     var target: CountryEntity
//
//     @MainActor
//     func perform() async throws -> some IntentResult {
//         IntentRouter.shared.pendingOpenCountryID = target.id
//         return .result()
//     }
// }
// ──────────────────────────────────────────────────────────────────

// MARK: - 3b. Search Countries (system.search schema)

// ── macOS 27+ only ────────────────────────────────────────────────
// Re‑enable when MACOSX_DEPLOYMENT_TARGET ≥ 27.0:
//
// @AppIntent(schema: .system.searchInApp)
// struct SearchCountriesIntent: ShowInAppSearchResultsIntent {
//     static let searchScopes: [StringSearchScope] = [.general]
//
//     @Parameter(title: "Search")
//     var criteria: StringSearchCriteria
//
//     @MainActor
//     func perform() async throws -> some IntentResult {
//         IntentRouter.shared.pendingSearchText = criteria.term
//         return .result()
//     }
// }
// ──────────────────────────────────────────────────────────────────

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

    @MainActor
    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView
    {
        let context = ModelContext(Worldward.sharedModelContainer)
        let stats = TravelStats(countries: try context.fetch(FetchDescriptor<Country>()))

        guard stats.hasTravel else {
            let message = "You haven't recorded any travels yet. Open Worldward to get started. 🌍"
            return .result(
                value: message,
                dialog: IntentDialog("\(message)"),
                view: Text("🌍 No travels logged yet").font(.headline).padding())
        }

        let statuses = CountryStatus.visitedCases.compactMap {
            status -> (label: String, count: Int, color: Color)? in
            let count = stats.statusCounts[status] ?? 0
            return count > 0 ? (status.label, count, status.tint) : nil
        }

        let value =
            "You've visited \(stats.visitedCountries) of \(stats.totalCountries) countries "
            + "across \(stats.visitedContinents) continent\(stats.visitedContinents == 1 ? "" : "s")."

        let dialog = IntentDialog(full: "🌍 \(value)", supporting: "Here's your travel summary.")

        let snippet = VisitCountSnippet(
            visited: stats.visitedCountries,
            total: stats.totalCountries,
            continents: stats.visitedContinents,
            statuses: statuses,
            flags: stats.visitedFlags)

        return .result(value: value, dialog: dialog, view: snippet)
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

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = ModelContext(Worldward.sharedModelContainer)
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
        refreshWidgetSnapshot(using: context)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return .result(
            value:
                "📅 Visit to \(country.flagEmoji) \(country.name) logged on \(formatter.string(from: visitDate))."
        )
    }
}

// MARK: - Intent Router

/// A tiny app-wide hand-off point for intents that open the app and need to pass
/// data to the UI. A notification is lost when an intent cold-launches the app
/// (it fires before any view subscribes), so intents stash values here instead;
/// the view both observes changes (warm launch) and reads any pending value when
/// it appears (cold launch), guaranteeing the value is never missed.
@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()
    private init() {}

    /// Free-text trip description awaiting the log-visits sheet, set by
    /// `LogVisitsFromDescriptionIntent`. The view clears it once consumed.
    var pendingLogVisitsText: String?

    /// Set by `OpenTravelStatsIntent` to request the stats dashboard.
    var pendingOpenStats = false

    /// ISO alpha-2 id of a country to select on the map, set by
    /// `OpenCountryMapIntent`. Held until the catalog is loaded so a cold launch
    /// can still resolve it once `@Query` populates.
    var pendingOpenCountryID: String?

    /// A search term to apply to the country list, set by `SearchCountriesIntent`.
    var pendingSearchText: String?

    /// A trip whose itinerary should be drawn on the map, set by the trip
    /// editor's "View Route on Map" button — which may live in a sheet several
    /// presentation layers away from the map. Not an intent, but the same
    /// hand-off problem, so it travels the same way.
    var pendingMapTrip: Trip?
}

// MARK: - 5b. Log Visits from a Description

/// Captures a free-text description ("I went to Japan and Korea last spring"),
/// opens the app, and hands the text to the log-visits sheet, which parses it
/// on-device with Apple Intelligence and lets the user confirm before saving.
/// Going through a confirmation step (rather than writing directly) keeps a
/// misheard or misparsed phrase from silently creating wrong visits.
struct LogVisitsFromDescriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Visits from a Description"
    static let description = IntentDescription(
        "Describe a trip in your own words and Worldward extracts the countries and dates for you to confirm.",
        categoryName: "Travel",
        searchKeywords: ["log", "describe", "trip", "dictate", "visits", "ai"]
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Description", requestValueDialog: "What trip would you like to log?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log visits from \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingLogVisitsText = text
        return .result()
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

    @MainActor
    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView
    {
        let context = ModelContext(Worldward.sharedModelContainer)
        let continentName = continent.rawValue
        let descriptor = FetchDescriptor<Country>(
            predicate: #Predicate { $0.continent == continentName }
        )
        let countries = try context.fetch(descriptor)

        let visitedCountries = countries.filter { $0.isVisited }
        let visited = visitedCountries.count
        let total = countries.count
        // Rounded (not truncated), matching the ContinentProgressTool's math.
        let pct = total > 0 ? Int((Double(visited) / Double(total) * 100).rounded()) : 0

        let value = "\(continent.rawValue): \(visited) of \(total) countries visited (\(pct)%)."
        let dialog = IntentDialog(
            full: "\(value)", supporting: "Here's your progress in \(continent.rawValue).")

        let snippet = ContinentProgressSnippet(
            continent: continent.rawValue,
            visited: visited,
            total: total,
            flags: visitedCountries.map(\.flagEmoji))

        return .result(value: value, dialog: dialog, view: snippet)
    }
}

// MARK: - 7. Mark Current Location

/// Resolves the device's current location to a country and sets its travel status.
/// Designed for "Mark where I am as visited" — no manual country picker needed.
struct MarkCurrentLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Current Location"
    static let description = IntentDescription(
        "Detects your current country and marks it with the chosen travel status.",
        categoryName: "Travel",
        searchKeywords: ["current", "location", "here", "gps", "mark"]
    )

    @Parameter(title: "Status")
    var status: CountryStatusOption

    static var parameterSummary: some ParameterSummary {
        Summary("Mark where I am as \(\.$status)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let isoCode = try await LocationService.currentISOCountryCode() else {
            throw Error.couldNotDetermineCountry
        }

        let context = ModelContext(Worldward.sharedModelContainer)
        let descriptor = FetchDescriptor<Country>(
            predicate: #Predicate {
                $0.id == isoCode || $0.iso3 == isoCode
            }
        )
        guard let model = try context.fetch(descriptor).first else {
            throw Error.countryNotInCatalog(code: isoCode)
        }

        model.status = status.domainStatus
        model.statusIsImported = false
        try context.save()
        refreshWidgetSnapshot(using: context)

        return .result(
            value:
                "\(model.flagEmoji) \(model.name) marked as \(status.domainStatus.label.lowercased())."
        )
    }

    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible {
        case couldNotDetermineCountry
        case countryNotInCatalog(code: String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .couldNotDetermineCountry:
                "Could not determine your current country from your location."
            case .countryNotInCatalog(let code):
                "Country code \(code) was found but is not in the Worldward catalog."
            }
        }
    }
}

// MARK: - Shortcuts Provider

/// Registers every intent with the system and promotes the most useful ones to
/// the Shortcuts app and Siri. Intents not listed here are still available in
/// Shortcuts under "Worldward" but won't appear as first‑class suggestions.
struct WorldwardShortcuts: AppShortcutsProvider {
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
            intent: LogVisitsFromDescriptionIntent(),
            phrases: [
                "Log a trip in \(.applicationName)",
                "Describe my travels to \(.applicationName)",
                "Log visits from a description in \(.applicationName)",
            ],
            shortTitle: "Log from Description",
            systemImageName: "text.bubble"
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

        AppShortcut(
            intent: MarkCurrentLocationIntent(),
            phrases: [
                "Mark where I am in \(.applicationName)",
                "Record my current location with \(.applicationName)",
            ],
            shortTitle: "Mark Location",
            systemImageName: "location.fill"
        )
    }
}
