/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import FoundationModels
import SwiftData

// MARK: - Travel Intelligence Service

/// On-device, conversational travel assistant built on the Foundation Models
/// framework. It answers free-form questions about the user's own travels —
/// "which European countries haven't I been to?", "what was my busiest year?",
/// "when did I go to Japan?" — by letting the on-device model call tools that
/// read the live SwiftData store. Nothing leaves the device and no third-party
/// dependency is involved; if Apple Intelligence is unavailable the UI degrades
/// gracefully (see `availability`).
@MainActor
@Observable
final class TravelIntelligence {

    /// One step of the conversation surface. The view renders from this.
    enum Phase: Equatable {
        case idle
        case thinking
        /// The model is producing text; the payload is the answer so far.
        case streaming(String)
        case answered(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// The model backing the assistant. Re-read for availability each time the
    /// sheet appears, since the user can toggle Apple Intelligence in Settings.
    private let model = SystemLanguageModel.default

    /// Lazily created so the (cheap) session — and its tool wiring — only spins
    /// up once the user actually asks something, and is reused across follow-up
    /// questions so the model keeps conversational context.
    private var session: LanguageModelSession?

    /// The SwiftData container the tools read from. Defaults to the app's shared
    /// store; injectable for previews and tests.
    private let container: ModelContainer

    init(container: ModelContainer? = nil) {
        self.container = container ?? Worldward.sharedModelContainer
    }

    /// Whether the on-device model is ready to use right now.
    var availability: SystemLanguageModel.Availability { model.availability }

    var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    /// A handful of starter questions shown as tappable chips. Localized so they
    /// display in the user's language; the chat translates the tapped question back
    /// to English for the model.
    static let suggestions = [
        String(localized: "How many countries have I visited?", comment: "Chat starter question"),
        String(
            localized: "Which European countries haven't I been to?",
            comment: "Chat starter question"),
        String(localized: "What was my busiest travel year?", comment: "Chat starter question"),
        String(localized: "When's my next trip?", comment: "Chat starter question"),
        String(localized: "Where have I lived?", comment: "Chat starter question"),
    ]

    /// Sends a question to the model and publishes the answer through `phase`.
    /// Reuses the session for follow-ups; a thrown error surfaces as `.failed`.
    func ask(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        let session = activeSession()
        phase = .thinking
        do {
            // Stream snapshots so the answer appears token-by-token. While the
            // model is calling tools the snapshots are empty, so "Thinking…"
            // stays up until the first real text arrives.
            var latest = ""
            for try await snapshot in session.streamResponse(to: question) {
                latest = snapshot.content
                if !latest.isEmpty { phase = .streaming(latest) }
            }
            phase = .answered(latest.isEmpty ? "I couldn't find an answer to that." : latest)
        } catch let error as LanguageModelSession.ToolCallError {
            phase = .failed(
                "I couldn't read your travel data: \(error.underlyingError.localizedDescription)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Clears the conversation and drops the session so the next question starts
    /// from a blank transcript.
    func reset() {
        session = nil
        phase = .idle
    }

    // MARK: - Private

    private func activeSession() -> LanguageModelSession {
        if let session { return session }
        let tools: [any Tool] = [
            TravelSummaryTool(),
            CountriesTool(),
            ContinentProgressTool(),
            TripsTool(),
        ]
        let session = LanguageModelSession(tools: tools) {
            """
            You are Worldward's travel assistant. You help the user understand \
            their own travel: which countries they have visited, when, and how \
            far along they are on each continent — and the trips they have \
            planned, including dates, itineraries, and packing.
            """
            """
            Always call a tool to get real data before answering. Never invent \
            country names, trip details, counts, or dates, and never rely on your \
            own geographic knowledge for the user's records — the tools are the \
            only source of truth. Use getTrips for anything about upcoming or \
            past trips, itineraries, or packing.
            """
            """
            Keep answers short and friendly. Show country flag emoji when you \
            list countries. If the user has no relevant travels or trips, say so \
            plainly and encourage them to start logging visits or planning a trip.
            """
        }
        self.session = session
        return session
    }
}

// MARK: - Shared data access

/// Loads every country from the main actor, creating a short-lived `ModelContext`.
/// Tools run off the main actor (`Tool.call` is `@concurrent`), but their private
/// `@MainActor` helpers handle the fetch here.
private func fetchCountries() throws -> [Country] {
    let context = ModelContext(Worldward.sharedModelContainer)
    return try context.fetch(FetchDescriptor<Country>())
}

/// Loads every trip from the main actor, creating a short-lived `ModelContext`.
/// Mirrors `fetchCountries` for the trip-aware tool.
private func fetchTrips() throws -> [Trip] {
    let context = ModelContext(Worldward.sharedModelContainer)
    return try context.fetch(FetchDescriptor<Trip>())
}

/// Formats a country's recorded visit dates as a short, human-readable phrase,
/// e.g. "Mar 2023, Aug 2024", or an empty string when no dates are recorded.
private func visitDatesPhrase(for country: Country) -> String {
    var dates = (country.visits ?? []).map(\.date)
    if let legacy = country.visitDate { dates.append(legacy) }
    guard !dates.isEmpty else { return "" }

    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return dates.sorted().map(formatter.string(from:)).joined(separator: ", ")
}

// MARK: - Tool 1: Overall summary

/// Returns the user's headline travel figures: how many countries across how
/// many continents, the per-status breakdown, busiest/active years, and the
/// span of recorded visits. Use for "how many countries", "summary", "stats".
private struct TravelSummaryTool: Tool {
    let name = "getTravelSummary"
    let description =
        "Returns the user's overall travel totals: visited country count, "
        + "continents reached, per-status counts, busiest year, and visit date range."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        try await summarize()
    }

    @MainActor private func summarize() throws -> String {
        let countries = try fetchCountries()
        let stats = TravelStats(countries: countries)

        guard stats.hasTravel else {
            return "The user has not recorded any visited countries yet."
        }

        var lines: [String] = []
        lines.append(
            "Visited \(stats.visitedCountries) of \(stats.totalCountries) countries "
                + "across \(stats.visitedContinents) of \(stats.totalContinents) continents.")

        let statusLines = CountryStatus.visitedCases.compactMap { status -> String? in
            let count = stats.statusCounts[status] ?? 0
            return count > 0 ? "\(status.label): \(count)" : nil
        }
        if !statusLines.isEmpty {
            lines.append("By status — " + statusLines.joined(separator: ", ") + ".")
        }

        if let busiest = stats.busiestYear, busiest.countries > 0 {
            lines.append(
                "Busiest year: \(busiest.year) with \(busiest.countries) countries "
                    + "and \(busiest.visits) visits.")
        }
        lines.append("Active travel years: \(stats.activeYears).")

        if let most = stats.mostVisited {
            lines.append("Most-visited country: \(most.flag) \(most.name) (\(most.count) visits).")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Tool 2: Country lookup

/// Flexible list query over the user's countries. Filters by continent, by
/// visited/unvisited, and/or by a specific status, and reports each match with
/// its flag, status, and recorded visit dates. Use for "where have I been in
/// Asia", "where have I lived", "when did I visit Japan".
private struct CountriesTool: Tool {
    let name = "getCountries"
    let description =
        "Lists the user's countries with flag, travel status, and visit dates. "
        + "Optionally filter by continent, by whether they were visited, or by a "
        + "specific status (crossed, visited, lived, living)."

    @Generable
    struct Arguments {
        @Guide(
            description: "Continent to filter by, e.g. 'Europe' or 'Asia'. Omit for all continents."
        )
        var continent: String?

        @Guide(
            description:
                "When true, return only countries the user has visited; when false, only unvisited ones."
        )
        var visitedOnly: Bool?

        @Guide(
            description:
                "Filter to one status exactly: 'crossed', 'visited', 'lived', or 'living'. Omit for any status."
        )
        var status: String?
    }

    func call(arguments: Arguments) async throws -> String {
        try await list(arguments)
    }

    @MainActor private func list(_ arguments: Arguments) throws -> String {
        var countries = try fetchCountries()

        if let continent = arguments.continent?.trimmingCharacters(in: .whitespaces),
            !continent.isEmpty
        {
            countries = countries.filter {
                $0.continent.localizedCaseInsensitiveContains(continent)
            }
        }

        if let visitedOnly = arguments.visitedOnly {
            countries = countries.filter { $0.isVisited == visitedOnly }
        }

        if let status = arguments.status?.trimmingCharacters(in: .whitespaces).lowercased(),
            let match = CountryStatus(rawValue: status)
        {
            countries = countries.filter { $0.status == match }
        }

        guard !countries.isEmpty else {
            return "No countries match that filter."
        }

        // Visited countries first, then alphabetical, capped so a broad query
        // (e.g. every unvisited country) can't overflow the context window.
        let sorted = countries.sorted { lhs, rhs in
            lhs.isVisited != rhs.isVisited ? lhs.isVisited : lhs.name < rhs.name
        }
        let cap = 80
        let shown = sorted.prefix(cap)

        let lines = shown.map { country -> String in
            let dates = visitDatesPhrase(for: country)
            let datePart = dates.isEmpty ? "" : " — visited \(dates)"
            return "\(country.flagEmoji) \(country.name) (\(country.status.label))\(datePart)"
        }

        var result = "\(countries.count) matching countries:\n" + lines.joined(separator: "\n")
        if countries.count > cap {
            result += "\n…and \(countries.count - cap) more not shown."
        }
        return result
    }
}

// MARK: - Tool 3: Continent progress

/// Reports completion for one continent: visited / total / percentage, plus the
/// names of the countries still unvisited there. Use for "how much of Europe
/// have I seen", "which African countries are left".
private struct ContinentProgressTool: Tool {
    let name = "getContinentProgress"
    let description =
        "Returns how complete a single continent is: visited count, total count, "
        + "percentage, and the list of countries there the user has not visited yet."

    @Generable
    struct Arguments {
        @Guide(
            description:
                "The continent to report on, e.g. 'Europe', 'Asia', 'Africa', 'North America', 'South America', 'Australia and Oceania', 'Antarctica'."
        )
        var continent: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await progress(arguments)
    }

    @MainActor private func progress(_ arguments: Arguments) throws -> String {
        let query = arguments.continent.trimmingCharacters(in: .whitespaces)
        let all = try fetchCountries()
        let countries = all.filter { $0.continent.localizedCaseInsensitiveContains(query) }

        guard !countries.isEmpty else {
            return "No countries found for continent '\(query)'."
        }

        let visited = countries.filter(\.isVisited)
        let remaining = countries.filter { !$0.isVisited }
        let pct = Int((Double(visited.count) / Double(countries.count) * 100).rounded())

        var result =
            "\(countries.first?.continent ?? query): \(visited.count) of "
            + "\(countries.count) visited (\(pct)%)."

        if remaining.isEmpty {
            result += "\nEvery country on this continent has been visited. 🎉"
        } else {
            let cap = 60
            let names = remaining.sorted { $0.name < $1.name }.prefix(cap)
                .map { "\($0.flagEmoji) \($0.name)" }
            result += "\nStill unvisited:\n" + names.joined(separator: ", ")
            if remaining.count > cap {
                result += " …and \(remaining.count - cap) more."
            }
        }
        return result
    }
}

// MARK: - Tool 4: Trips

/// Reports the user's planned and recent trips: dates, where each trip is relative
/// to today (upcoming / underway / past), the countries it touches, packing
/// progress, and the dated itinerary stops. Use for "when's my next trip", "what's
/// on my itinerary", "what do I still need to pack", "where am I going".
private struct TripsTool: Tool {
    let name = "getTrips"
    let description =
        "Returns the user's trips with their dates, whether each is upcoming, "
        + "underway, or past, the countries visited, packing progress, and the "
        + "dated itinerary stops. Use for any question about planned or recent "
        + "trips, itineraries, or packing."

    @Generable
    struct Arguments {
        @Guide(
            description:
                "When true, include finished (past) trips too; when false or omitted, only upcoming and in-progress trips."
        )
        var includePast: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        try await summarize(includePast: arguments.includePast ?? false)
    }

    @MainActor private func summarize(includePast: Bool) throws -> String {
        let now = Date()
        let all = try fetchTrips()
        let upcoming = all.filter { $0.endDate >= now }.sorted { $0.startDate < $1.startDate }
        let past = all.filter { $0.endDate < now }.sorted { $0.startDate > $1.startDate }
        let trips = includePast ? upcoming + past : upcoming

        guard !trips.isEmpty else {
            return includePast
                ? "The user has not planned any trips yet."
                : "The user has no upcoming or in-progress trips. They may have past trips — call again with includePast set to true to see them."
        }

        // Cap so a long trip history can't overflow the context window.
        let cap = 8
        let shown = trips.prefix(cap)

        let blocks = shown.map { trip -> String in
            let name = trip.title.isEmpty ? "Untitled trip" : trip.title
            let flags = trip.flags.isEmpty ? "" : " \(trip.flags)"
            var lines: [String] = ["\(name)\(flags) — \(trip.dateRangeText)"]

            switch trip.phase(asOf: now) {
            case .upcoming(let daysAway):
                lines.append(daysAway == 0 ? "Status: starts today" : "Status: in \(daysAway) day(s)")
            case .underway(let day, let total):
                lines.append("Status: underway, day \(day) of \(total)")
            case .past(let daysAgo):
                lines.append("Status: ended \(daysAgo) day(s) ago")
            }

            let packingTotal = (trip.packing ?? []).count
            if packingTotal > 0 {
                lines.append("Packing: \(trip.packedCount) of \(packingTotal) packed")
            }

            let stops = trip.sortedStops
            if !stops.isEmpty {
                let stopLines = stops.prefix(12).map { stop -> String in
                    let flag = stop.country?.flagEmoji ?? "📍"
                    var line = "  - \(flag) \(stop.displayTitle)"
                    if let date = stop.date {
                        line += " (\(date.formatted(date: .abbreviated, time: .omitted)))"
                    }
                    if let mode = stop.transport { line += " \(mode.emoji)" }
                    return line
                }
                lines.append("Itinerary:")
                lines.append(contentsOf: stopLines)
                if stops.count > 12 { lines.append("  …and \(stops.count - 12) more stops") }
            }

            return lines.joined(separator: "\n")
        }

        var result = "\(trips.count) trip(s):\n\n" + blocks.joined(separator: "\n\n")
        if trips.count > cap {
            result += "\n\n…and \(trips.count - cap) more not shown."
        }
        return result
    }
}
