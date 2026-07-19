/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import WidgetKit

/// A tiny, `Codable` summary of the traveller's world, written by the watch app
/// into the shared App Group container and read by the watch complications.
/// It mirrors the iPhone's `WidgetSnapshot` idea — keep the complication on a
/// plain-value snapshot rather than opening SwiftData/CloudKit inside the
/// extension — but carries only the handful of numbers a wrist complication can
/// actually show, so the geometry, flags, and tints the phone widgets need never
/// ship to the watch.
///
/// This file is a member of BOTH the watch app and the watch widget extension.
/// `nonisolated` so the `nonisolated` store (and the widget extension's timeline
/// provider) can encode/decode and compare it regardless of each target's
/// default actor isolation.
nonisolated struct WatchComplicationSnapshot: Codable, Hashable {
    var visitedCountries: Int = 0
    var totalCountries: Int = 195
    var visitedContinents: Int = 0
    var totalContinents: Int = 7

    /// The soonest upcoming trip, if any — its title and start/end so the
    /// complication can show a countdown (or an "underway" state mid-trip) and
    /// roll over on its own when one ends, even if the watch app hasn't run.
    var nextTripTitle: String = ""
    var nextTripStart: Date?
    var nextTripEnd: Date?

    /// Packing progress for the trip whose list the packing complication follows
    /// (the journey underway, else the soonest upcoming one with a list).
    var packedItems: Int = 0
    var totalPackingItems: Int = 0

    /// Share of the world's countries visited, `0...1`.
    var countryFraction: Double {
        totalCountries > 0 ? Double(visitedCountries) / Double(totalCountries) : 0
    }

    /// Share of this trip's packing list already packed, `0...1`.
    var packingFraction: Double {
        totalPackingItems > 0 ? Double(packedItems) / Double(totalPackingItems) : 0
    }

    /// Whole days until the next trip starts (0 once it's underway or today).
    var daysUntilNextTrip: Int? {
        guard let start = nextTripStart else { return nil }
        let days = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: start)).day ?? 0
        return max(0, days)
    }

    /// A friendly empty state for a fresh install or an unreadable container.
    static let placeholder = WatchComplicationSnapshot()

    /// A populated example for the complication gallery and Xcode previews.
    static let sample = WatchComplicationSnapshot(
        visitedCountries: 24, totalCountries: 195,
        visitedContinents: 4, totalContinents: 7,
        nextTripTitle: "Japan & Korea",
        nextTripStart: Date.now.addingTimeInterval(12 * 86_400),
        nextTripEnd: Date.now.addingTimeInterval(19 * 86_400),
        packedItems: 5, totalPackingItems: 12)
}

/// Reads and writes the shared `WatchComplicationSnapshot`. The watch app writes
/// after any change to its store; the complications read on every timeline
/// refresh. A missing container (App Group not provisioned) is ignored so the
/// watch app keeps working without complications.
enum WatchComplicationStore {
    /// Must match the `com.apple.security.application-groups` entitlement on both
    /// the watch app and the watch widget extension.
    nonisolated static let appGroupID = "group.net.smigi.worldward"

    private nonisolated static let fileName = "watch-complication.json"

    private nonisolated static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Persist the latest snapshot and ask WidgetKit to redraw. An unchanged
    /// snapshot is skipped (the app writes on every launch), preserving the
    /// system's complication-refresh budget.
    nonisolated static func write(_ snapshot: WatchComplicationSnapshot) {
        guard snapshot != read() else { return }
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The last snapshot the watch app wrote, or `.placeholder` if none.
    nonisolated static func read() -> WatchComplicationSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
        else { return .placeholder }
        return snapshot
    }
}
