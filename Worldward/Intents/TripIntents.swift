/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import Foundation
import SwiftData
import SwiftUI

// MARK: - Shared trip resolution

/// The trip an "add to my packing list" / "how's my packing" style intent should
/// act on when the user doesn't name one: the journey underway, else the soonest
/// upcoming trip. This is exactly the rule the packing widget uses
/// (`refreshWidgetSnapshot`), so voice, widget, and app all agree on "the current
/// trip". Past trips are never chosen — there's nothing left to pack for them.
@MainActor
func currentOrNextTrip(in context: ModelContext) -> Trip? {
    let now = Date()
    return (try? context.fetch(FetchDescriptor<Trip>()))?
        .filter { $0.isUpcoming(asOf: now) }
        .sorted { $0.startDate < $1.startDate }
        .first
}

/// Resolves an optional `TripEntity` parameter to a live `Trip`: the named trip if
/// the user picked one, otherwise the current/next trip. Returns `nil` only when
/// there's genuinely no trip to act on.
@MainActor
func resolveTrip(_ entity: TripEntity?, in context: ModelContext) -> Trip? {
    if let id = entity?.id {
        return (try? context.fetch(FetchDescriptor<Trip>()))?.first { $0.dedupID == id }
    }
    return currentOrNextTrip(in: context)
}

/// Raised when an intent needs a trip but the user has none planned.
enum TripIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noUpcomingTrip

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noUpcomingTrip:
            "You don't have an upcoming trip yet. Plan one in Worldward first."
        }
    }
}

// MARK: - 1. Next Trip

/// Answers "when's my next trip?" — the flagship trip Siri phrase. Reports the
/// countdown to the soonest upcoming journey, or that a trip is underway, with a
/// glanceable snippet. No parameters, so it runs hands-free.
struct GetNextTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Next Trip"
    static let description = IntentDescription(
        "Shows your next planned trip and how many days until it starts.",
        categoryName: "Trips",
        searchKeywords: ["trip", "next", "upcoming", "countdown", "when", "travel"]
    )

    @MainActor
    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView
    {
        let context = ModelContext(Worldward.sharedModelContainer)
        guard let trip = currentOrNextTrip(in: context) else {
            let message = String(
                localized: "You don't have any upcoming trips. Plan your next adventure in Worldward. ✈️")
            return .result(
                value: message,
                dialog: IntentDialog("\(message)"),
                view: Text("✈️ No upcoming trips").font(.headline).padding())
        }

        let name = trip.title.isEmpty ? String(localized: "your next trip") : trip.title
        let value: String
        switch trip.phase() {
        case .upcoming(let daysAway):
            value =
                daysAway == 0
                ? String(localized: "\(name) starts today! (\(trip.dateRangeText))")
                : String(
                    localized:
                        "\(name) starts in \(daysAway) day\(daysAway == 1 ? "" : "s") — \(trip.dateRangeText).")
        case .underway(let day, let total):
            value = String(
                localized: "You're on \(name) now — day \(day) of \(total). ✈️")
        case .past:
            // currentOrNextTrip never returns a finished trip, so this is unreachable.
            value = String(localized: "\(name) — \(trip.dateRangeText).")
        }

        let snippet = NextTripSnippet(
            title: name,
            flags: trip.flags,
            phase: trip.phase(),
            dateRange: trip.dateRangeText)

        return .result(
            value: value,
            dialog: IntentDialog(full: "✈️ \(value)", supporting: "Here's your next trip."),
            view: snippet)
    }
}

// MARK: - 2. Add Packing Item

/// Adds an item to a trip's packing list by voice — "add sunscreen to my packing
/// list". Defaults to the current/next trip, with an optional trip override, and
/// refreshes the packing widget so the new item shows up immediately.
struct AddPackingItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Packing Item"
    static let description = IntentDescription(
        "Adds an item to a trip's packing list.",
        categoryName: "Trips",
        searchKeywords: ["pack", "packing", "add", "item", "list", "trip"]
    )

    @Parameter(title: "Item", requestValueDialog: "What should I add to your packing list?")
    var item: String

    @Parameter(title: "Quantity", default: 1, inclusiveRange: (1, 99))
    var quantity: Int

    @Parameter(title: "Trip")
    var trip: TripEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to the packing list for \(\.$trip)") {
            \.$quantity
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let title = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw $item.needsValueError() }

        let context = ModelContext(Worldward.sharedModelContainer)
        guard let target = resolveTrip(trip, in: context) else {
            throw TripIntentError.noUpcomingTrip
        }

        // Append after the last ungrouped item so the new one lands at the bottom
        // of the list rather than colliding with an existing order.
        let maxOrder = (target.packing ?? []).map(\.order).max() ?? -1
        let newItem = PackingItem(
            title: title, quantity: max(1, quantity), order: maxOrder + 1, trip: target)
        context.insert(newItem)
        try context.save()
        refreshWidgetSnapshot(using: context)

        let tripName = target.title.isEmpty ? String(localized: "your trip") : target.title
        let countSuffix = quantity > 1 ? " ×\(quantity)" : ""
        return .result(
            value: String(localized: "Added \(title)\(countSuffix) to \(tripName)'s packing list. 🧳"))
    }
}

// MARK: - 3. Packing Progress

/// Answers "how much have I packed?" — the packed/total count for a trip, with a
/// progress snippet. Defaults to the current/next trip, with an optional override.
struct GetPackingProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Packing Progress"
    static let description = IntentDescription(
        "Shows how much of a trip's packing list is done.",
        categoryName: "Trips",
        searchKeywords: ["pack", "packing", "progress", "ready", "trip", "how many"]
    )

    @Parameter(title: "Trip")
    var trip: TripEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get packing progress for \(\.$trip)")
    }

    @MainActor
    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView
    {
        let context = ModelContext(Worldward.sharedModelContainer)
        guard let target = resolveTrip(trip, in: context) else {
            throw TripIntentError.noUpcomingTrip
        }

        let total = (target.packing ?? []).count
        let packed = target.packedCount
        let name = target.title.isEmpty ? String(localized: "your trip") : target.title

        guard total > 0 else {
            let message = String(
                localized: "\(name) has no packing list yet. Add items in Worldward.")
            return .result(
                value: message,
                dialog: IntentDialog("\(message)"),
                view: Text("🧳 No packing list yet").font(.headline).padding())
        }

        let value =
            packed == total
            ? String(localized: "All packed for \(name) — \(total) of \(total) done! ✅")
            : String(localized: "\(packed) of \(total) packed for \(name).")

        let snippet = PackingProgressSnippet(
            title: name, flags: target.flags, packed: packed, total: total)

        return .result(
            value: value,
            dialog: IntentDialog(full: "🧳 \(value)", supporting: "Here's your packing progress."),
            view: snippet)
    }
}

// MARK: - 4. Open Trip

/// Opens the app to a specific trip's details. "Show my Japan trip" — the trip is
/// resolved by the shared `TripEntity`, and the app navigates the Going tab to it
/// via `IntentRouter` (a notification would be lost on a cold launch).
struct OpenTripIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Trip"
    static let description = IntentDescription(
        "Opens a trip's itinerary and packing list in Worldward.",
        categoryName: "Trips"
    )

    @Parameter(title: "Trip")
    var target: TripEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingOpenTripID = target.id
        return .result()
    }
}
