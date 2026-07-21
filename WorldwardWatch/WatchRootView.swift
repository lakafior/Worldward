/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

/// The watch app's three glance pages: Now / Been / Trips.
///
/// Splitting the root apart is what stops the app being a blank screen. The trip
/// list is empty whenever nothing is planned, but "Been" has content from the
/// moment a single country is marked on the iPhone — and `Country`/`Visit` were
/// already in the watch's CloudKit schema, so the data has been on the wrist all
/// along, just never shown.
struct WatchRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trip.startDate) private var trips: [Trip]
    @Query private var countries: [Country]

    /// `TravelStats` walks every country and its visits, and the continent
    /// grouping sorts and localizes every visited name — both far too heavy for
    /// `body`, which SwiftUI re-evaluates freely. They are computed on change and
    /// cached here instead, the same discipline as the `CountryListView` re-sort
    /// fix. `nil` only for the instant before the first `.task` lands.
    @State private var stats: TravelStats?
    @State private var groups: [WatchContinentGroup] = []

    var body: some View {
        TabView {
            WatchNowView(stats: stats, trips: trips)
            WatchBeenView(stats: stats, groups: groups)
            WatchTripsView(trips: trips)
        }
        .tint(.brand)
        // Once on appear (covers a cold launch after CloudKit has hydrated) and
        // again whenever the mirror delivers a change. This also keeps the
        // watch-face complications in step; packing check-offs refresh from the
        // row itself, and `write` skips no-ops, so this is cheap.
        .task { refresh() }
        .onChange(of: storeSignature) { refresh() }
    }

    private func refresh() {
        stats = TravelStats(countries: countries)
        groups = WatchContinentGroup.grouped(countries)
        WatchComplicationRefresh.run(context: modelContext)
    }

    /// A cheap fingerprint of everything the caches depend on, so the expensive
    /// recompute runs only when the store actually changed. Visit counts are
    /// deliberately left out: reaching `country.visits` would fault the
    /// relationship for every visited country on each `body` pass, and the one
    /// thing that tracks visits directly — the "Recent" list — is its own
    /// self-updating `@Query`.
    private var storeSignature: Int {
        var hasher = Hasher()
        hasher.combine(countries.count)
        hasher.combine(trips.count)
        for country in countries where country.isVisited {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
        }
        return hasher.finalize()
    }
}

/// A circular progress gauge with its number and caption inside — the shape a
/// wrist reads fastest.
struct WatchRing: View {
    let fraction: Double
    let value: String
    let caption: String
    var tint: Color = .brand
    var diameter: CGFloat = 88

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: 8)
            Circle()
                // A hair of trim so a traveller at zero still sees a cap rather
                // than an empty ring that reads as "not loaded".
                .trim(from: 0, to: max(0.008, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(value)
                    .font(.title3)
                    .bold()
                    .monospacedDigit()
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(value)
    }
}
