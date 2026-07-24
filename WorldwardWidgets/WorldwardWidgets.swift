/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

/// A single entry carrying the latest travel snapshot. The widgets share it
/// because they read the same data; only their presentation differs.
struct WorldwardEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Reads the shared snapshot the app maintains. The app calls
/// `WidgetCenter.reloadAllTimelines()` whenever the catalog changes, so a single
/// entry is enough — there's nothing time-based to schedule.
struct WorldwardProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorldwardEntry {
        WorldwardEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WorldwardEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : WidgetSnapshotStore.read()
        completion(WorldwardEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorldwardEntry>) -> Void)
    {
        let entry = WorldwardEntry(date: .now, snapshot: WidgetSnapshotStore.read())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Shared style

/// The map's warm gold-to-orange palette (mirrors `CountryStatus` visited→living),
/// redefined here so the extension stays self-contained.
private let brandGradient = LinearGradient(
    colors: [Color(red: 1.00, green: 0.72, blue: 0.20), Color(red: 0.84, green: 0.30, blue: 0.05)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// A darker variant of the gradient for dark mode, so the widget stays readable
/// without washing out.
private let darkBrandGradient = LinearGradient(
    colors: [Color(red: 0.70, green: 0.50, blue: 0.14), Color(red: 0.59, green: 0.21, blue: 0.04)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// Applies the brand gradient as the widget background, honoring the app's theme
/// preference: "light"/"dark" force a variant, and "system" follows the actual
/// system color scheme (which a bare function couldn't read — it needs the
/// environment, hence a modifier). Internal (not private) because the packing
/// widget in its own file wears the same background.
struct ThemedGradientBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let theme: String

    private var gradient: LinearGradient {
        switch theme {
        case "dark": darkBrandGradient
        case "light": brandGradient
        default: colorScheme == .dark ? darkBrandGradient : brandGradient
        }
    }

    func body(content: Content) -> some View {
        content.containerBackground(for: .widget) { gradient }
    }
}

// MARK: - Travel Snapshot

/// Headline figures: countries visited, continents reached, and share of the
/// world. Small shows the numbers; medium adds a strip of recent flags.
struct TravelSnapshotView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Text("\(snapshot.visitedCountries)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("countries")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text(
                    "\(snapshot.visitedContinents) of \(snapshot.totalContinents) continents · \(snapshot.fraction.formatted(.percent)) of the world"
                )
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if family != .systemSmall {
                FlagCloud(flags: snapshot.flags, limit: 12)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Flags Visited

/// A grid of the flags of every visited country, with the count overlaid.
struct FlagStripView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var limit: Int { family == .systemSmall ? 16 : 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(snapshot.visitedCountries)")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text("flags collected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            FlagCloud(flags: snapshot.flags, limit: limit)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Wraps flag emoji into a grid. Falls back to a gentle prompt when nothing has
/// been visited yet.
private struct FlagCloud: View {
    let flags: [String]
    let limit: Int

    var body: some View {
        if flags.isEmpty {
            Text("Start marking the places you've been ✈️")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let shown = Array(flags.prefix(limit))
            let remainder = flags.count - shown.count
            let columns = [GridItem(.adaptive(minimum: 22), spacing: 2)]
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, flag in
                    Text(flag).font(.system(size: 20))
                }
                if remainder > 0 {
                    Text("+\(remainder)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - World Map

private let oceanGradient = LinearGradient(
    colors: [Color(red: 0.07, green: 0.15, blue: 0.25), Color(red: 0.03, green: 0.08, blue: 0.15)],
    startPoint: .top, endPoint: .bottom)

/// A flat world map tinted by where you've been, over a deep-ocean background.
/// The drawing itself lives in the shared `WorldMapCanvas` so the share card can
/// reuse it.
struct MiniMapView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WorldMapCanvas(tints: snapshot.tints)
                .overlay {
                    // No geometry cached yet — e.g. the app hasn't run since install.
                    if WorldMapStore.shared == nil {
                        Image(systemName: "globe")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

            Text("\(snapshot.visitedCountries) countries")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(8)
        }
    }
}

// MARK: - Upcoming Trip

/// Like `WorldwardProvider`, but a countdown is time-based: the entry must be
/// re-rendered at each midnight so "in N days" ticks over without the app
/// running. With no trip to count down to there's nothing scheduled — the next
/// snapshot write reloads the timeline anyway.
struct UpcomingTripProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorldwardEntry {
        WorldwardEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WorldwardEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : WidgetSnapshotStore.read()
        completion(WorldwardEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorldwardEntry>) -> Void)
    {
        let entry = WorldwardEntry(date: .now, snapshot: WidgetSnapshotStore.read())
        let policy: TimelineReloadPolicy
        if entry.snapshot.upcomingTrips.isEmpty {
            policy = .never
        } else {
            let calendar = Calendar.current
            let nextMidnight = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: entry.date))
            policy = .after(nextMidnight ?? entry.date.addingTimeInterval(86_400))
        }
        completion(Timeline(entries: [entry], policy: policy))
    }
}

/// Counts down to the next planned trip — "🇯🇵 🇰🇷 Japan & Korea · in 12 days".
/// Small shows flags, title, and the countdown; medium adds the date range and
/// a big day count. Trips the snapshot stored that have since ended are skipped
/// at render, so the widget rolls over on its own (see `UpcomingTrip`).
struct UpcomingTripView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WorldwardEntry

    private var trip: WidgetSnapshot.UpcomingTrip? {
        entry.snapshot.upcomingTrips.first { $0.endDate >= entry.date }
    }

    var body: some View {
        if let trip {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(trip.flags.isEmpty ? "✈️" : trip.flags)
                        .font(.title3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(trip.title.isEmpty ? "Next trip" : trip.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if daysToGo(trip) <= 0 {
                        Text("Traveling now ✈️")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        // The system formatter localizes the whole phrase
                        // ("in 12 days", "tomorrow") for free.
                        Text(countdown(days: daysToGo(trip)))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if family != .systemSmall {
                        Text(dateRange(trip))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if family != .systemSmall {
                    VStack(spacing: 0) {
                        if daysToGo(trip) > 0 {
                            Text("\(daysToGo(trip))")
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                            if daysToGo(trip) == 1 {
                                Text("day").font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            } else {
                                Text("days").font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        } else {
                            Image(systemName: "airplane.departure")
                                .font(.system(size: 40))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "airplane.departure")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Text("No trips planned")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Plan your next adventure in Worldward.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Whole days from the entry's day to the trip's start day; 0 on departure
    /// day, negative once underway.
    private func daysToGo(_ trip: WidgetSnapshot.UpcomingTrip) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: entry.date),
            to: calendar.startOfDay(for: trip.startDate)
        ).day ?? 0
    }

    private func countdown(days: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named  // "tomorrow", not "in 1 day"
        return formatter.localizedString(from: DateComponents(day: days))
    }

    private func dateRange(_ trip: WidgetSnapshot.UpcomingTrip) -> String {
        let start = trip.startDate.formatted(date: .abbreviated, time: .omitted)
        let end = trip.endDate.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }
}

// MARK: - Widgets

struct TravelSnapshotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardTravelSnapshot", provider: WorldwardProvider()) {
            entry in
            TravelSnapshotView(snapshot: entry.snapshot)
                .modifier(ThemedGradientBackground(theme: entry.snapshot.appTheme))
        }
        .configurationDisplayName("Travel Snapshot")
        .description("Countries visited, continents reached, and your share of the world.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FlagStripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardFlagStrip", provider: WorldwardProvider()) { entry in
            FlagStripView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .modifier(ForceColorScheme(theme: entry.snapshot.appTheme))
        }
        .configurationDisplayName("Flags Visited")
        .description("A grid of the flags of every country you've visited.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UpcomingTripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardUpcomingTrip", provider: UpcomingTripProvider()) {
            entry in
            UpcomingTripView(entry: entry)
                .modifier(ThemedGradientBackground(theme: entry.snapshot.appTheme))
        }
        .configurationDisplayName("Upcoming Trip")
        .description("A countdown to your next planned trip.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MiniMapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardMiniMap", provider: WorldwardProvider()) { entry in
            MiniMapView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { oceanGradient }
        }
        .configurationDisplayName("World Map")
        .description("A map of the world, tinted by the countries you've visited.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Lock Screen accessories

// Accessory families exist only on iOS/watchOS — they're unavailable on macOS and
// visionOS, so the whole accessory widget is gated to iOS to keep the extension
// compiling for every platform it ships on.
#if os(iOS)

    /// A glanceable travel summary for the Lock Screen. Accessory widgets render in
    /// a monochrome "vibrant" mode, so this leans on counts, a gauge, and SF Symbols
    /// rather than the colour flags/map the home-screen widgets use.
    struct AccessoryView: View {
        @Environment(\.widgetFamily) private var family
        let snapshot: WidgetSnapshot

        var body: some View {
            switch family {
            case .accessoryInline:
                // Sits next to the clock: one symbol + one line of text.
                Label("\(snapshot.visitedCountries) countries", systemImage: "globe")

            case .accessoryCircular:
                // A ring of "share of the world" with the country count in the centre.
                Gauge(value: snapshot.fraction) {
                    Image(systemName: "globe")
                } currentValueLabel: {
                    Text("\(snapshot.visitedCountries)")
                }
                .gaugeStyle(.accessoryCircular)

            case .accessoryRectangular:
                HStack(spacing: 10) {
                    Gauge(value: snapshot.fraction) {
                        Text(snapshot.fraction.formatted(.percent))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(snapshot.visitedCountries) countries")
                            .font(.headline)
                            .widgetAccentable()
                        Text(
                            "\(snapshot.visitedContinents) of \(snapshot.totalContinents) continents"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

            default:
                EmptyView()
            }
        }
    }

    struct AccessoryWidget: Widget {
        var body: some WidgetConfiguration {
            StaticConfiguration(kind: "WorldwardAccessory", provider: WorldwardProvider()) {
                entry in
                AccessoryView(snapshot: entry.snapshot)
                    .containerBackground(for: .widget) { Color.clear }
            }
            .configurationDisplayName("Travel Progress")
            .description("Your country count and share of the world, on the Lock Screen.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
        }
    }

    // MARK: - Next-trip accessory

    /// A glanceable countdown to the next trip for the Lock Screen. Reuses
    /// `UpcomingTripProvider` so it re-renders at midnight and rolls over to the
    /// following journey on its own. Monochrome, so it leans on SF Symbols and the
    /// day count rather than the home-screen widget's flags.
    struct NextTripAccessoryView: View {
        @Environment(\.widgetFamily) private var family
        let entry: WorldwardEntry

        private var trip: WidgetSnapshot.UpcomingTrip? {
            entry.snapshot.upcomingTrips.first { $0.endDate >= entry.date }
        }

        /// Whole days from today to the trip's start; 0 on departure day, negative
        /// once underway.
        private func daysToGo(_ trip: WidgetSnapshot.UpcomingTrip) -> Int {
            let calendar = Calendar.current
            return calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: entry.date),
                to: calendar.startOfDay(for: trip.startDate)
            ).day ?? 0
        }

        private func shortCountdown(_ days: Int) -> String {
            if days <= 0 { return String(localized: "now") }
            if days == 1 { return String(localized: "tomorrow") }
            return String(localized: "in \(days)d")
        }

        var body: some View {
            switch family {
            case .accessoryInline:
                if let trip {
                    let days = daysToGo(trip)
                    Label(
                        days <= 0
                            ? String(localized: "\(tripName(trip)) now")
                            : String(localized: "\(tripName(trip)) \(shortCountdown(days))"),
                        systemImage: "airplane.departure")
                } else {
                    Label("No trips planned", systemImage: "airplane")
                }

            case .accessoryCircular:
                if let trip {
                    let days = daysToGo(trip)
                    VStack(spacing: 0) {
                        Image(systemName: "airplane.departure").font(.caption2)
                        if days <= 0 {
                            Image(systemName: "suitcase.fill").font(.caption)
                        } else {
                            Text("\(days)")
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .minimumScaleFactor(0.5)
                            Text("days").font(.system(size: 8))
                        }
                    }
                } else {
                    Image(systemName: "airplane").font(.title3).widgetAccentable()
                }

            case .accessoryRectangular:
                if let trip {
                    let days = daysToGo(trip)
                    VStack(alignment: .leading, spacing: 1) {
                        Label(tripName(trip), systemImage: "airplane.departure")
                            .font(.headline)
                            .widgetAccentable()
                            .lineLimit(1)
                        Text(
                            days <= 0
                                ? String(localized: "Traveling now")
                                : String(localized: "\(shortCountdown(days).capitalized) · \(dateRange(trip))")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("No trips planned", systemImage: "airplane")
                            .font(.headline)
                            .widgetAccentable()
                        Text("Plan one in Worldward.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

            default:
                EmptyView()
            }
        }

        private func tripName(_ trip: WidgetSnapshot.UpcomingTrip) -> String {
            trip.title.isEmpty ? String(localized: "Next trip") : trip.title
        }

        private func dateRange(_ trip: WidgetSnapshot.UpcomingTrip) -> String {
            let start = trip.startDate.formatted(date: .abbreviated, time: .omitted)
            let end = trip.endDate.formatted(date: .abbreviated, time: .omitted)
            return start == end ? start : "\(start) – \(end)"
        }
    }

    struct NextTripAccessoryWidget: Widget {
        var body: some WidgetConfiguration {
            StaticConfiguration(kind: "WorldwardNextTripAccessory", provider: UpcomingTripProvider())
            { entry in
                NextTripAccessoryView(entry: entry)
                    .containerBackground(for: .widget) { Color.clear }
            }
            .configurationDisplayName("Next Trip Countdown")
            .description("A countdown to your next trip, on the Lock Screen.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
        }
    }

#endif

// MARK: - Control Center

// Controls are iOS-only. The control's action is `MarkHereOpenIntent` (an
// `OpenIntent` in the shared file, so it belongs to both targets) — that's what
// lets the button launch the app, which then resolves the location and shows the
// status picker.
#if os(iOS)

    struct MarkHereControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: "net.smigi.worldward.markhere") {
                ControlWidgetButton(action: MarkHereOpenIntent()) {
                    Label("Mark where I am", systemImage: "mappin.and.ellipse")
                }
            }
            .displayName("Mark where I am")
            .description("Mark your current country as visited in Worldward.")
        }
    }

#endif

// MARK: - Helpers

/// Forces a specific color scheme on its content when `theme` is "light" or
/// "dark"; leaves it to the system when `theme` is "system" (the default).
private struct ForceColorScheme: ViewModifier {
    let theme: String

    func body(content: Content) -> some View {
        if theme == "dark" {
            content.environment(\.colorScheme, .dark)
        } else if theme == "light" {
            content.environment(\.colorScheme, .light)
        } else {
            content
        }
    }
}

// MARK: - Previews

#Preview("Snapshot", as: .systemMedium) {
    TravelSnapshotWidget()
} timeline: {
    WorldwardEntry(date: .now, snapshot: .sample)
    WorldwardEntry(date: .now, snapshot: .placeholder)
}

#Preview("Flags", as: .systemMedium) {
    FlagStripWidget()
} timeline: {
    WorldwardEntry(date: .now, snapshot: .sample)
}

#Preview("Map", as: .systemMedium) {
    MiniMapWidget()
} timeline: {
    WorldwardEntry(date: .now, snapshot: .sample)
}

#Preview("Upcoming Trip", as: .systemMedium) {
    UpcomingTripWidget()
} timeline: {
    WorldwardEntry(date: .now, snapshot: .sample)
    WorldwardEntry(date: .now, snapshot: .placeholder)
}

#if os(iOS)
    #Preview("Lock Screen", as: .accessoryRectangular) {
        AccessoryWidget()
    } timeline: {
        WorldwardEntry(date: .now, snapshot: .sample)
    }
#endif
