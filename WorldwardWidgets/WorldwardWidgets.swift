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

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorldwardEntry>) -> Void) {
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

// MARK: - Travel Snapshot

/// Headline figures: countries visited, continents reached, and share of the
/// world. Small shows the numbers; medium adds a strip of recent flags.
struct TravelSnapshotView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var percent: Int { Int((snapshot.fraction * 100).rounded()) }

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
                Text("\(snapshot.visitedContinents) of \(snapshot.totalContinents) continents · \(percent)% of the world")
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

// MARK: - Widgets

struct TravelSnapshotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WorldwardTravelSnapshot", provider: WorldwardProvider()) { entry in
            TravelSnapshotView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { brandGradient }
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
        }
        .configurationDisplayName("Flags Visited")
        .description("A grid of the flags of every country you've visited.")
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

        private var percent: Int { Int((snapshot.fraction * 100).rounded()) }

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
                        Text("\(percent)%")
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
                EmptyView()
            }
        }
    }

    struct AccessoryWidget: Widget {
        var body: some WidgetConfiguration {
            StaticConfiguration(kind: "WorldwardAccessory", provider: WorldwardProvider()) { entry in
                AccessoryView(snapshot: entry.snapshot)
                    .containerBackground(for: .widget) { Color.clear }
            }
            .configurationDisplayName("Travel Progress")
            .description("Your country count and share of the world, on the Lock Screen.")
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

#if os(iOS)
    #Preview("Lock Screen", as: .accessoryRectangular) {
        AccessoryWidget()
    } timeline: {
        WorldwardEntry(date: .now, snapshot: .sample)
    }
#endif
