/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - Conventions
//
// Everything in this file is *machine-facing*. That is a deliberate contract, and
// it is the opposite of what the AppIntents layer does:
//
//  • Enums travel as their raw values ("visited", "planning", "plane"), never as
//    `label` — a caller that switches on the value must not break when the app is
//    running in Japanese.
//  • Countries travel as ISO 3166-1 alpha-2 ids, with the stored English `name`
//    alongside for readability. Never `localizedName`.
//  • Dates travel as `Date`; the transport encodes them ISO-8601.
//  • Nothing here is ever shown to a person as-is. Phrasing is the caller's job —
//    which is exactly why the intents keep their `String(localized:)` copy and
//    this layer has none.

// MARK: - Read models

/// A trip in list form: enough to choose one and talk about it, without dragging
/// in its whole itinerary. `id` is the trip's `dedupID`.
nonisolated struct TripDTO: Codable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let notes: String
    /// ISO alpha-2 ids of the countries the itinerary touches, first-appearance order.
    let countries: [String]
    /// `"upcoming"`, `"underway"` or `"past"` — the raw form of `TripPhase`.
    let phase: String
    /// Days until departure; set only when `phase == "upcoming"`.
    let daysAway: Int?
    /// Day *n* of *m*; set only when `phase == "underway"`.
    let day: Int?
    let dayCount: Int?
    let stopCount: Int
    let packedCount: Int
    let packingTotal: Int
}

/// One itinerary stop. `id` is the stop's `dedupID`; `index` is its position in
/// `Trip.sortedStops`, handy for talking about "the third stop" but never a
/// handle — it shifts the moment anything is inserted or reordered.
nonisolated struct StopDTO: Codable, Sendable {
    let id: String
    let index: Int
    let title: String
    /// Short address line, when the stop came from a map search.
    let detail: String
    let note: String
    let date: Date?
    /// ISO alpha-2, or `nil` for a stop with no country resolved.
    let country: String?
    /// Raw `TransportMode`, or `nil` when the leg has no mode set.
    let transport: String?
    let transportDetail: String
    let latitude: Double?
    let longitude: Double?
    /// Nights implied by the gap to the next dated stop. Derived, never stored —
    /// see `ItineraryItem.stayDayCount` for why it can read long.
    let stayDays: Int?
}

/// One packing-list entry. `container` is the container's *name*, not an id:
/// containers are a catalog shared across every trip, and `PackingTemplateItem`
/// already stores them by name for the same portability reason.
nonisolated struct PackingItemDTO: Codable, Sendable {
    let id: String
    let title: String
    let quantity: Int
    let isPacked: Bool
    let container: String?
}

nonisolated struct LinkDTO: Codable, Sendable {
    let id: String
    let title: String
    let url: String
    /// `dedupID` of the stop this link is pinned to, or `nil` when trip-level.
    let stopID: String?
}

nonisolated struct ContactDTO: Codable, Sendable {
    let id: String
    let name: String
    /// Raw `ContactKind`: `"phone"`, `"whatsapp"`, `"email"`, `"other"`.
    let kind: String
    let value: String
    let stopID: String?
}

/// A trip with everything hanging off it — the shape `get_trip` returns, and what
/// a caller needs before it can reason about a journey in one pass.
nonisolated struct TripDetailDTO: Codable, Sendable {
    let trip: TripDTO
    let stops: [StopDTO]
    let packing: [PackingItemDTO]
    let links: [LinkDTO]
    let contacts: [ContactDTO]
    /// Names of attached files. The bytes are deliberately not exposed.
    let documents: [String]
}

nonisolated struct CountryDTO: Codable, Sendable {
    /// ISO 3166-1 alpha-2.
    let id: String
    /// Stored English name — stable across locales, unlike `localizedName`.
    let name: String
    /// English continent name, matching `Continent.rawValue`.
    let continent: String
    /// Raw `CountryStatus`.
    let status: String
    /// Raw `PlanStatus`.
    let plan: String
    let visitCount: Int
    let firstVisit: Date?
    let lastVisit: Date?
}

/// Bundled offline facts. Mirrors `CountryFacts`, with the driving side as its
/// raw value rather than a localized label.
nonisolated struct FactsDTO: Codable, Sendable {
    let country: String
    let currency: String
    let languages: [String]
    let plugTypes: [String]
    /// Raw `DrivingSide`.
    let drivingSide: String
    let emergencyNumber: String
}

nonisolated struct ContinentStatDTO: Codable, Sendable {
    let name: String
    let visited: Int
    let total: Int
}

nonisolated struct YearStatDTO: Codable, Sendable {
    let year: Int
    let visits: Int
    let countries: Int
}

/// The dashboard's numbers, flattened. Counts keyed by raw enum value so the
/// shape survives a new status case being added.
nonisolated struct StatsDTO: Codable, Sendable {
    let visitedCountries: Int
    let totalCountries: Int
    let visitedContinents: Int
    let totalContinents: Int
    let totalVisits: Int
    /// Raw `CountryStatus` → count.
    let statusCounts: [String: Int]
    /// Raw `PlanStatus` → count.
    let planCounts: [String: Int]
    let continents: [ContinentStatDTO]
    let years: [YearStatDTO]
    let firstVisit: Date?
    let lastVisit: Date?
}

nonisolated struct TemplateDTO: Codable, Sendable {
    let name: String
    let itemCount: Int
}

// MARK: - Write results
//
// Every operation that *replaces* existing state reports what it replaced. With
// no UndoManager in the app (see `Worldward.swift` — SwiftData FB13659086), this
// is the reversibility story: a caller that got it wrong has the old value in
// hand and can put it back with the same call.

nonisolated struct CountryChangeDTO: Codable, Sendable {
    let country: CountryDTO
    let previousStatus: String
    let previousPlan: String
}

nonisolated struct VisitResultDTO: Codable, Sendable {
    let country: CountryDTO
    let visitDate: Date
    /// `true` when logging this visit promoted an untouched country to "visited".
    let statusPromoted: Bool
}

nonisolated struct TripNotesChangeDTO: Codable, Sendable {
    let trip: TripDTO
    let previousNotes: String
}

// MARK: - Inputs

nonisolated enum TripScope: String, Codable, Sendable, CaseIterable {
    /// Hasn't finished yet — matches `Trip.isUpcoming(asOf:)`, so a journey
    /// underway counts as upcoming.
    case upcoming
    case past
    case all
}

/// How a text write combines with what's already stored.
nonisolated enum TextMode: String, Codable, Sendable, CaseIterable {
    case replace
    /// Appended after a blank line, so Markdown headings keep working.
    case append
}

nonisolated struct CreateTripInput: Codable, Sendable {
    let title: String
    let startDate: Date
    let endDate: Date
    let notes: String?
}

nonisolated struct StopInput: Codable, Sendable {
    let title: String
    /// ISO alpha-2, a country name, or an ISO-3 code — resolved leniently.
    let country: String?
    let date: Date?
    let detail: String?
    let note: String?
    /// Raw `TransportMode`.
    let transport: String?
    let transportDetail: String?
    let latitude: Double?
    let longitude: Double?
}

nonisolated struct PackingItemInput: Codable, Sendable {
    let title: String
    let quantity: Int?
    /// Container name. Resolved against the shared catalog, created when unknown.
    let container: String?
}

/// One-shot trip construction — the composite that exists so building a journey
/// is a single atomic write instead of a conversation. Either the whole trip
/// lands or nothing does.
nonisolated struct PlanTripInput: Codable, Sendable {
    let title: String
    let startDate: Date
    let endDate: Date
    let notes: String?
    let stops: [StopInput]?
    let packing: [PackingItemInput]?
    /// Name of a saved `PackingTemplate` to apply before `packing` is added.
    let packingTemplate: String?
    /// Marks every country the itinerary touches as `.planning`. Defaults to
    /// `true` — it's what makes the map light up when a trip is planned.
    let markCountriesPlanning: Bool?
}

// MARK: - Errors

/// Failures the API reports. Each case renders to a sentence that names the fix,
/// because the consumer is a model that will retry: "no such country" strands it,
/// "no such country; use an ISO alpha-2 code like 'ES'" does not.
nonisolated enum APIError: Swift.Error, Sendable {
    case tripNotFound(String)
    case noUpcomingTrip
    case countryNotFound(String)
    case ambiguousCountry(String, candidates: [String])
    case stopNotFound(String)
    case packingItemNotFound(String)
    case templateNotFound(String, available: [String])
    case badValue(field: String, value: String, allowed: [String])
    case invalidDateRange
    case emptyValue(field: String)

    var agentDescription: String {
        switch self {
        case .tripNotFound(let id):
            "No trip with id '\(id)'. Call list_trips for current ids."
        case .noUpcomingTrip:
            "There are no upcoming trips. Create one with create_trip or plan_trip first."
        case .countryNotFound(let token):
            """
            No country matches '\(token)'. Use an ISO 3166-1 alpha-2 code \
            (e.g. 'ES' for Spain) or the country's English name.
            """
        case .ambiguousCountry(let token, let candidates):
            """
            '\(token)' matches more than one country: \
            \(candidates.joined(separator: ", ")). Use an ISO alpha-2 code instead.
            """
        case .stopNotFound(let id):
            "No itinerary stop with id '\(id)'. Call get_trip for current stop ids."
        case .packingItemNotFound(let id):
            "No packing item with id '\(id)'. Call get_trip for current item ids."
        case .templateNotFound(let name, let available):
            available.isEmpty
                ? "No packing template named '\(name)'. No templates are saved yet."
                : """
                No packing template named '\(name)'. Available: \
                \(available.joined(separator: ", ")).
                """
        case .badValue(let field, let value, let allowed):
            "'\(value)' is not a valid \(field). Allowed values: \(allowed.joined(separator: ", "))."
        case .invalidDateRange:
            "endDate must be on or after startDate."
        case .emptyValue(let field):
            "\(field) must not be empty."
        }
    }
}
