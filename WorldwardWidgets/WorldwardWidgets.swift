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
