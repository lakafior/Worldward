/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

/// A single entry carrying the shared packing snapshot.
struct PackingEntry: TimelineEntry {
    let date: Date
    let snapshot: PackingSnapshot
}

/// Reads the packing snapshot both sides maintain: the app rewrites it from the
/// model, and `TogglePackingItemIntent` rewrites it optimistically on a tap
/// (WidgetKit reloads this timeline by itself after the intent runs). A midnight
/// reload lets the widget retire the list on its own the day the trip ends, even
/// if the app isn't launched for weeks — mirroring `UpcomingTripProvider`.
struct PackingProvider: TimelineProvider {
    func placeholder(in context: Context) -> PackingEntry {
        PackingEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (PackingEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : PackingSnapshotStore.read()
        completion(PackingEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PackingEntry>) -> Void) {
        let entry = PackingEntry(date: .now, snapshot: PackingSnapshotStore.read())
        let policy: TimelineReloadPolicy
        if entry.snapshot.items.isEmpty {
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

// MARK: - View

/// The trip's packing list with tappable checkmarks. Unpacked items float to the
/// top so the next thing to grab is always visible; packed ones sink below with
/// a strikethrough, still tappable to undo. Rows beyond what the family fits
/// collapse into a "+n more" line.
struct PackingListView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PackingEntry

    /// The snapshot's trip is still worth showing — there is a list and the
    /// journey hasn't ended. A finished trip's list retires at render, the same
    /// way `UpcomingTripView` skips ended trips.
    private var isCurrent: Bool {
        !entry.snapshot.items.isEmpty && entry.snapshot.tripEndDate >= entry.date
    }

    /// Unpacked first (in list order), then packed.
    private var ordered: [PackingSnapshot.Item] {
        let items = entry.snapshot.items
        return items.filter { !$0.isPacked } + items.filter(\.isPacked)
    }

    private var rowLimit: Int { family == .systemLarge ? 10 : 4 }

    var body: some View {
        if isCurrent {
            list
        } else {
            emptyState
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    entry.snapshot.tripTitle.isEmpty
                        ? String(localized: "Packing") : entry.snapshot.tripTitle
                )
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(entry.snapshot.packedCount) of \(entry.snapshot.items.count) packed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText())
                    .invalidatableContent()
            }

            ProgressView(
                value: Double(entry.snapshot.packedCount), total: Double(entry.snapshot.items.count)
            )
            .tint(.white)
            .invalidatableContent()

            if entry.snapshot.packedCount == entry.snapshot.items.count {
                Text("All packed! ✅")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = Array(ordered.prefix(rowLimit))
                let remainder = ordered.count - shown.count
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.id) { item in
                        PackingRow(item: item)
                    }
                    if remainder > 0 {
                        Text("+\(remainder) more")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.leading, 26)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "suitcase")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            Text("No packing list")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Add items to your next trip in Worldward.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// One tappable row. The whole row is the button — a bare 18-pt circle is a
/// cruel tap target on a widget. `invalidatableContent` greys the row for the
/// beat between the tap and the intent's snapshot rewrite.
private struct PackingRow: View {
    let item: PackingSnapshot.Item

    var body: some View {
        Button(intent: TogglePackingItemIntent(itemID: item.id, packed: !item.isPacked)) {
            HStack(spacing: 8) {
                Image(systemName: item.isPacked ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(item.isPacked ? .white.opacity(0.7) : .white)
                Text(item.title)
                    .font(.subheadline)
                    .strikethrough(item.isPacked)
                    .foregroundStyle(item.isPacked ? .white.opacity(0.6) : .white)
                    .lineLimit(1)
                if item.quantity > 1 {
                    Text("×\(item.quantity)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .invalidatableContent()
    }
}

// MARK: - Widget

struct PackingListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PackingSnapshotStore.widgetKind, provider: PackingProvider()) {
            entry in
            PackingListView(entry: entry)
                .modifier(ThemedGradientBackground(theme: entry.snapshot.appTheme))
        }
        .configurationDisplayName("Packing List")
        .description("Check items off your next trip's packing list.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Previews

#Preview("Packing", as: .systemMedium) {
    PackingListWidget()
} timeline: {
    PackingEntry(date: .now, snapshot: .sample)
    PackingEntry(date: .now, snapshot: .empty)
}

#Preview("Packing Large", as: .systemLarge) {
    PackingListWidget()
} timeline: {
    PackingEntry(date: .now, snapshot: .sample)
}
