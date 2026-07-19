/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

/// Root screen: upcoming trips soonest first, or — when nothing has synced — a
/// hint that trips are planned on the iPhone with iCloud sync on.
struct WatchRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trip.startDate) private var trips: [Trip]

    /// Trips that haven't finished yet, soonest first (query order).
    private var upcoming: [Trip] { trips.filter { $0.isUpcoming(asOf: Date()) } }

    var body: some View {
        NavigationStack {
            Group {
                if upcoming.isEmpty {
                    ContentUnavailableView {
                        Label(Str.Watch.emptyTitle, systemImage: "airplane.departure")
                    } description: {
                        Text(Str.Watch.emptyMessage)
                    }
                } else {
                    List(upcoming) { trip in
                        NavigationLink(value: trip) { WatchTripRow(trip: trip) }
                    }
                    .navigationDestination(for: Trip.self) { WatchTripView(trip: $0) }
                }
            }
            .navigationTitle(Str.Trip.tabTrips)
        }
        .tint(.brand)
        // Keep the watch-face complications in step with the store: once on
        // appear (covers a cold launch after CloudKit has hydrated) and again
        // when trips are added or removed. Packing check-offs refresh from the
        // row itself. `write` skips no-ops, so this is cheap.
        .task { WatchComplicationRefresh.run(context: modelContext) }
        .onChange(of: trips.count) { WatchComplicationRefresh.run(context: modelContext) }
    }
}

/// One trip in the root list: title, flags + dates, and packing progress.
private struct WatchTripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(trip.title.isEmpty ? Str.Trip.untitled : trip.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 4) {
                if !trip.flags.isEmpty { Text(trip.flags) }
                Text(dateRange)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.footnote)
            if let total = trip.packing?.count, total > 0 {
                ProgressView(value: Double(trip.packedCount), total: Double(total))
                    .tint(.brand)
            }
        }
    }

    private var dateRange: String {
        let start = trip.startDate.formatted(.dateTime.day().month())
        let end = trip.endDate.formatted(.dateTime.day().month())
        return start == end ? start : "\(start) – \(end)"
    }
}

/// One trip: its itinerary (today's stop highlighted) and its packing list
/// grouped by container, each row a tap-to-toggle check-off.
struct WatchTripView: View {
    let trip: Trip

    var body: some View {
        List {
            let stops = trip.sortedStops
            if !stops.isEmpty {
                Section(Str.Trip.itineraryLabel) {
                    ForEach(stops) { stop in WatchStopRow(stop: stop) }
                }
            }
            // Mirrors `Trip.markdownSummary`: one flat "Packing" section until
            // items are actually filed into containers.
            let groups = trip.packingGroups
            let useContainerNames = groups.contains { $0.container != nil }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in WatchPackingRow(item: item) }
                } header: {
                    HStack {
                        Text(
                            useContainerNames
                                ? (group.container?.name ?? Str.Trip.packingOther)
                                : Str.Trip.packing)
                        Spacer()
                        Text("\(group.items.filter(\.isPacked).count)/\(group.items.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(trip.title.isEmpty ? Str.Trip.untitled : trip.title)
    }
}

/// An itinerary stop: flag and title, the date (highlighted when it's today),
/// and its places-to-see.
private struct WatchStopRow: View {
    let stop: ItineraryItem

    var body: some View {
        let isToday = stop.date.map { Calendar.current.isDateInToday($0) } ?? false
        VStack(alignment: .leading, spacing: 2) {
            Text("\(stop.country?.flagEmoji ?? "📍") \(stop.displayTitle)")
            if let date = stop.date {
                Text(isToday ? Str.Watch.today : date.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote)
                    .bold(isToday)
                    .foregroundStyle(isToday ? Color.brand : Color.secondary)
            }
            ForEach(stop.sortedPlaces) { place in
                Text("📍 \(place.title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A packing row: the whole row toggles the item, and each toggle also ships a
/// delta to the iPhone so both screens stay live (see `PackingDeltaSync`).
private struct WatchPackingRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: PackingItem

    var body: some View {
        Button {
            item.isPacked.toggle()
            PackingDeltaSync.send(dedupID: item.dedupID, isPacked: item.isPacked)
            // Reflect the new packing progress on the watch face right away.
            WatchComplicationRefresh.run(context: modelContext)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.isPacked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isPacked ? .green : .secondary)
                Text(item.title)
                    .strikethrough(item.isPacked)
                    .foregroundStyle(item.isPacked ? .secondary : .primary)
                if item.quantity > 1 {
                    Text("×\(item.quantity)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Reads as a switch: "Sunscreen, on/off" — same as the iPhone row.
        .accessibilityLabel(item.title)
        .accessibilityValue(
            item.isPacked
                ? Text("Packed", comment: "Accessibility value: packing item is checked off")
                : Text("Not packed", comment: "Accessibility value: packing item still open"))
        .accessibilityAddTraits(.isToggle)
    }
}
