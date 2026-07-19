/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import WidgetKit

// MARK: - Timeline

/// A single entry carrying the latest snapshot. The watch app calls
/// `WidgetCenter.reloadAllTimelines()` whenever its store changes, so one entry
/// is enough — there's nothing time-based to schedule beyond the day rollover,
/// which the countdown re-evaluates from `Date()` each render.
struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot
}

/// Reads the shared snapshot the watch app maintains through the App Group.
struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(
        in context: Context, completion: @escaping (WatchComplicationEntry) -> Void
    ) {
        let snapshot = context.isPreview ? .sample : WatchComplicationStore.read()
        completion(WatchComplicationEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(
        in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void
    ) {
        // One entry now, plus a refresh at the next midnight so the trip
        // countdown ticks down on its own if the app never runs.
        let entry = WatchComplicationEntry(date: .now, snapshot: WatchComplicationStore.read())
        let nextMidnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }
}

// MARK: - Countries visited

/// Countries visited: a ring of "share of the world" with the count in the
/// centre. Mirrors the iPhone Lock Screen accessory design (see `AccessoryView`).
struct CountriesComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardWatchCountries", provider: WatchComplicationProvider()) {
            entry in
            CountriesView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(Text("Countries Visited", comment: "Watch complication name"))
        .description(
            Text(
                "Your country count and share of the world.",
                comment: "Watch complication description"))
        .supportedFamilies([
            .accessoryCircular, .accessoryInline, .accessoryRectangular, .accessoryCorner,
        ])
    }
}

private struct CountriesView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchComplicationSnapshot

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(
                "\(snapshot.visitedCountries) countries",
                systemImage: "globe")

        case .accessoryCircular:
            Gauge(value: snapshot.countryFraction) {
                Image(systemName: "globe")
            } currentValueLabel: {
                Text("\(snapshot.visitedCountries)")
            }
            .gaugeStyle(.accessoryCircular)

        case .accessoryCorner:
            Text("\(snapshot.visitedCountries)")
                .font(.title2)
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: snapshot.countryFraction) {
                        Text("countries", comment: "Watch corner complication gauge label")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                }

        case .accessoryRectangular:
            HStack(spacing: 10) {
                Gauge(value: snapshot.countryFraction) {
                    Text(snapshot.countryFraction.formatted(.percent))
                }
                .gaugeStyle(.accessoryCircularCapacity)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(snapshot.visitedCountries) countries")
                        .font(.headline)
                        .widgetAccentable()
                    Text("\(snapshot.visitedContinents) of \(snapshot.totalContinents) continents")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        default:
            Text("\(snapshot.visitedCountries)")
        }
    }
}

// MARK: - Next trip countdown

/// Days until the next trip — or "Today"/"Underway" once it's here — with the
/// trip's title on the roomier families.
struct NextTripComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardWatchNextTrip", provider: WatchComplicationProvider()) {
            entry in
            NextTripView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(Text("Next Trip", comment: "Watch complication name"))
        .description(
            Text("A countdown to your next journey.", comment: "Watch complication description"))
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

private struct NextTripView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchComplicationSnapshot

    /// Whether the next trip is already underway (started, not yet ended).
    private var isUnderway: Bool {
        guard let start = snapshot.nextTripStart, let end = snapshot.nextTripEnd else {
            return false
        }
        let now = Date()
        return start <= now && now <= end
    }

    /// Short countdown token for the tight circular / inline families.
    private var countdownText: Text {
        guard snapshot.nextTripStart != nil else {
            return Text("None", comment: "Watch complication: no upcoming trip")
        }
        if isUnderway { return Text("Now", comment: "Watch complication: trip is underway") }
        guard let days = snapshot.daysUntilNextTrip else {
            return Text("None", comment: "Watch complication: no upcoming trip")
        }
        if days == 0 { return Text("Today", comment: "Watch complication: trip starts today") }
        return Text("\(days)d", comment: "Watch complication: days until trip, e.g. 12d")
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if snapshot.nextTripStart == nil {
                Label {
                    Text("No upcoming trip", comment: "Watch complication inline: no trip")
                } icon: {
                    Image(systemName: "airplane")
                }
            } else {
                Label {
                    Text("\(snapshot.nextTripTitle) · ") + countdownText
                } icon: {
                    Image(systemName: "airplane")
                }
            }

        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "airplane.departure")
                    .font(.caption)
                countdownText
                    .font(.headline)
                    .minimumScaleFactor(0.6)
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label {
                    Text("Next trip", comment: "Watch complication rectangular header")
                } icon: {
                    Image(systemName: "airplane.departure")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .widgetAccentable()
                if snapshot.nextTripStart == nil {
                    Text("None planned", comment: "Watch complication: no trip planned")
                        .font(.headline)
                } else {
                    Text(snapshot.nextTripTitle).font(.headline).lineLimit(1)
                    countdownText.font(.caption).foregroundStyle(.secondary)
                }
            }

        default:
            countdownText
        }
    }
}

// MARK: - Packing progress

/// How much of the active trip's packing list is done.
struct PackingComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardWatchPacking", provider: WatchComplicationProvider()) {
            entry in
            PackingView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(Text("Packing Progress", comment: "Watch complication name"))
        .description(
            Text(
                "How much of your trip's packing list is done.",
                comment: "Watch complication description"))
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

private struct PackingView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchComplicationSnapshot

    private var hasList: Bool { snapshot.totalPackingItems > 0 }

    var body: some View {
        switch family {
        case .accessoryInline:
            if hasList {
                Label {
                    Text(
                        "\(snapshot.packedItems)/\(snapshot.totalPackingItems) packed",
                        comment: "Watch complication inline: packed count")
                } icon: {
                    Image(systemName: "bag")
                }
            } else {
                Label {
                    Text("Nothing to pack", comment: "Watch complication: no packing list")
                } icon: {
                    Image(systemName: "bag")
                }
            }

        case .accessoryCircular:
            Gauge(value: snapshot.packingFraction) {
                Image(systemName: "bag.fill")
            } currentValueLabel: {
                Text(hasList ? "\(snapshot.packedItems)" : "–")
            }
            .gaugeStyle(.accessoryCircular)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label {
                    Text("Packing", comment: "Watch complication rectangular header")
                } icon: {
                    Image(systemName: "bag.fill")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .widgetAccentable()
                if hasList {
                    Text("\(snapshot.packedItems) / \(snapshot.totalPackingItems)")
                        .font(.headline)
                    Gauge(value: snapshot.packingFraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                } else {
                    Text("Nothing to pack", comment: "Watch complication: no packing list")
                        .font(.headline)
                }
            }

        default:
            Text(hasList ? "\(snapshot.packedItems)/\(snapshot.totalPackingItems)" : "–")
        }
    }
}

// MARK: - Previews

#Preview("Countries", as: .accessoryCircular) {
    CountriesComplication()
} timeline: {
    WatchComplicationEntry(date: .now, snapshot: .sample)
    WatchComplicationEntry(date: .now, snapshot: .placeholder)
}

#Preview("Next trip", as: .accessoryRectangular) {
    NextTripComplication()
} timeline: {
    WatchComplicationEntry(date: .now, snapshot: .sample)
}

#Preview("Packing", as: .accessoryCircular) {
    PackingComplication()
} timeline: {
    WatchComplicationEntry(date: .now, snapshot: .sample)
}
