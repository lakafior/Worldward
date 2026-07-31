/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Configuration

/// A trip as the widget's configuration picker needs it. Distinct from the app's
/// `TripEntity` on purpose: that one's query reaches into
/// `Worldward.sharedModelContainer`, and a widget's entity query runs in the
/// *extension*, which has no SwiftData at all. This one reads the same App Group
/// snapshot the widget draws from, so configuring a widget never wakes the store.
///
/// Both key on `Trip.dedupID`, so a widget configured here and a shortcut
/// configured there name the same trip.
struct WidgetTripEntity: AppEntity {
    let id: String
    let title: String
    let flags: String
    let dateRange: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trip")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(flags.isEmpty ? "✈️" : flags) \(title)",
            subtitle: "\(dateRange)")
    }

    static let defaultQuery = WidgetTripQuery()

    /// Build from a snapshot row, formatting the span the way `Trip.dateRangeText`
    /// does — a single day when the trip starts and ends together.
    init(_ trip: TripDetailSnapshot.Trip) {
        self.id = trip.id
        self.title = trip.title.isEmpty ? String(localized: "Untitled Trip") : trip.title
        self.flags = trip.flags
        let calendar = Calendar.current
        if calendar.isDate(trip.startDate, inSameDayAs: trip.endDate) {
            self.dateRange = trip.startDate.formatted(.dateTime.day().month(.abbreviated))
        } else {
            self.dateRange =
                "\(trip.startDate.formatted(.dateTime.day().month(.abbreviated))) – \(trip.endDate.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }
}

/// Offers the snapshot's trips — upcoming and underway, soonest first, which is
/// the order the writer already put them in.
struct WidgetTripQuery: EntityQuery {
    func entities(for identifiers: [WidgetTripEntity.ID]) async throws -> [WidgetTripEntity] {
        TripDetailSnapshotStore.read().trips
            .filter { identifiers.contains($0.id) }
            .map(WidgetTripEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetTripEntity] {
        TripDetailSnapshotStore.read().trips.map(WidgetTripEntity.init)
    }
}

/// Which trip the widget follows. The parameter is optional and left unset by
/// default: an unconfigured widget tracks whichever trip is soonest, so it shows
/// something useful the moment it's dropped on the home screen, and only stops
/// moving once someone deliberately pins a trip.
struct SelectTripIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Trip"
    static let description = IntentDescription("Choose which trip the widget follows.")

    @Parameter(title: "Trip")
    var trip: WidgetTripEntity?

    init() {}
    init(trip: WidgetTripEntity?) { self.trip = trip }
}

// MARK: - Timeline

/// One entry: the chosen trip (already resolved), plus the theme to wear.
struct TripWidgetEntry: TimelineEntry {
    let date: Date
    let trip: TripDetailSnapshot.Trip?
    let appTheme: String
}

/// Resolves the configured trip against the shared snapshot, falling back to the
/// soonest current trip — which also covers a configured trip that has since
/// ended or been deleted, so a pinned widget degrades to the next journey rather
/// than going blank.
///
/// Reloads at midnight like `PackingProvider`: the view labels stops relative to
/// "today", so the day rolling over changes what it should say even though no
/// data did.
struct TripWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TripWidgetEntry {
        TripWidgetEntry(date: .now, trip: TripDetailSnapshot.sample.trips.first, appTheme: "system")
    }

    func snapshot(for configuration: SelectTripIntent, in context: Context) async -> TripWidgetEntry
    {
        if context.isPreview {
            return TripWidgetEntry(
                date: .now, trip: TripDetailSnapshot.sample.trips.first, appTheme: "system")
        }
        return entry(for: configuration, at: .now)
    }

    func timeline(for configuration: SelectTripIntent, in context: Context) async -> Timeline<
        TripWidgetEntry
    > {
        let now = Date.now
        let entry = entry(for: configuration, at: now)
        let calendar = Calendar.current
        let nextMidnight =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        // Nothing to show and nothing scheduled to change that — wait for the
        // app's own reload rather than burning budget on a daily redraw.
        let policy: TimelineReloadPolicy = entry.trip == nil ? .never : .after(nextMidnight)
        return Timeline(entries: [entry], policy: policy)
    }

    private func entry(for configuration: SelectTripIntent, at date: Date) -> TripWidgetEntry {
        let snapshot = TripDetailSnapshotStore.read()
        let current = snapshot.trips.filter { $0.isCurrent(asOf: date) }
        let chosen =
            configuration.trip.flatMap { selected in
                current.first { $0.id == selected.id }
            } ?? current.first
        return TripWidgetEntry(date: date, trip: chosen, appTheme: snapshot.appTheme)
    }
}

// MARK: - Deep links

/// URLs the widget hands back to the app, matching what `ContentView` parses.
/// Built here rather than shared because they're three lines and the app only
/// ever reads them — a shared builder would couple both targets to a shape
/// neither needs to agree on beyond these two forms.
enum TripWidgetLink {
    /// Opens the trip in the Going tab.
    static func trip(_ id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "worldward"
        components.host = "trip"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    /// Opens the trip *and* asks the app to place the call / open the message or
    /// mail composer for one contact. The number never travels — only its id.
    static func contact(trip tripID: String, contact contactID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "worldward"
        components.host = "trip"
        components.queryItems = [
            URLQueryItem(name: "id", value: tripID),
            URLQueryItem(name: "contact", value: contactID),
        ]
        return components.url
    }
}

// MARK: - View

/// "What's happening now on this trip" — not the whole trip. Three bands:
///
/// * a header (flags, title, and how far off the trip is),
/// * the stop you're on and the ones after it, each with its transport line,
/// * a row of chips: contacts first, then documents and links as counts.
///
/// Contacts lead the chip row because "who do I call" is the question a home
/// screen can actually answer in one tap; a booking PDF is something you go
/// looking for. Nothing here scrolls, so everything is capped and the overflow
/// is honest about itself.
struct TripWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TripWidgetEntry

    private var stopLimit: Int { family == .systemLarge ? 3 : 1 }

    var body: some View {
        if let trip = entry.trip {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
                header(trip)

                let stops = visibleStops(of: trip)
                if stops.isEmpty {
                    Text("No stops planned yet")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 4) {
                        ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                            StopRow(stop: stop, isCurrent: index == 0, now: entry.date)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }

                Spacer(minLength: 0)
                ChipRow(trip: trip)
            }
            // Tapping anywhere that isn't a chip opens the trip itself.
            .widgetURL(TripWidgetLink.trip(trip.id))
        } else {
            emptyState
        }
    }

    private func header(_ trip: TripDetailSnapshot.Trip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(trip.flags.isEmpty ? "✈️" : trip.flags)
                .font(.subheadline)
                .lineLimit(1)
            Text(trip.title.isEmpty ? String(localized: "Trip") : trip.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(status(of: trip))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "map")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            Text("No trip to show")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Plan a trip in Worldward, then pick it here.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The stop you're on, then the ones ahead of it.
    ///
    /// Chosen at render, not at write, so the list advances on its own between
    /// app launches. "The stop you're on" is the last dated stop that has already
    /// started — you're still in Kyoto on the day you arrived and the day after,
    /// until Osaka's date comes round. A trip with no dated stops at all falls
    /// back to itinerary order, which is the only signal it has.
    private func visibleStops(of trip: TripDetailSnapshot.Trip) -> [TripDetailSnapshot.Stop] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: entry.date)
        let dated = trip.stops.filter { $0.date != nil }
        guard !dated.isEmpty else { return Array(trip.stops.prefix(stopLimit)) }

        let started = dated.filter { calendar.startOfDay(for: $0.date!) <= today }
        let ahead = dated.filter { calendar.startOfDay(for: $0.date!) > today }
        // Before departure there's no current stop, so the first one ahead leads.
        let rows = (started.suffix(1) + ahead)
        return Array(rows.prefix(stopLimit))
    }

    /// "in 3 days" before departure, "day 2 of 9" once underway.
    ///
    /// The countdown goes through `RelativeDateTimeFormatter` — the same way
    /// `UpcomingTripView` does it — rather than a `"in %lld days"` catalog key.
    /// A flat key can't carry plural rules, and several of the app's languages
    /// need three or four forms depending on the number; the formatter has them
    /// all, and gives "tomorrow" and "today" for free.
    private func status(of trip: TripDetailSnapshot.Trip) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: entry.date)
        let start = calendar.startOfDay(for: trip.startDate)
        let daysToGo = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        if daysToGo >= 0 { return Self.relative(days: daysToGo) }

        let end = calendar.startOfDay(for: trip.endDate)
        let day = -daysToGo + 1
        let total = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return String(
            localized: "day \(day) of \(total)",
            comment: "Trip widget: progress through a trip that's underway")
    }

    /// "today", "tomorrow", "in 5 days" — localized, with correct plurals.
    static func relative(days: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named  // "tomorrow", not "in 1 day"
        return formatter.localizedString(from: DateComponents(day: days))
    }
}

/// One stop: where, when, and how you get there. The current stop is marked with
/// a filled pin and full-strength text; the ones ahead recede, so the eye lands
/// on now without reading a word.
private struct StopRow: View {
    @Environment(\.widgetFamily) private var family
    let stop: TripDetailSnapshot.Stop
    let isCurrent: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isCurrent ? "mappin.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.55))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(stop.title.isEmpty ? String(localized: "Stop") : stop.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.8))
                        .lineLimit(1)
                    if let label = dateLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                // The location line is context; on medium there's only room for
                // one subordinate line and the transport detail wins it.
                if !stop.detail.isEmpty, family == .systemLarge {
                    Text(stop.detail)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                if !stop.transportDetail.isEmpty || !stop.transportSymbol.isEmpty {
                    HStack(spacing: 4) {
                        if !stop.transportSymbol.isEmpty {
                            Image(systemName: stop.transportSymbol)
                                .font(.caption2)
                        }
                        if !stop.transportDetail.isEmpty {
                            Text(stop.transportDetail)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white.opacity(isCurrent ? 0.95 : 0.75))
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "Today", "Tomorrow", else "Fri 14 Mar". Computed at render so it stays
    /// correct without the app rewriting the snapshot — the day rolling over is
    /// exactly what the provider's midnight reload is for.
    ///
    /// The two near days borrow `RelativeDateTimeFormatter`'s wording (see
    /// `TripWidgetView.relative`) and capitalize it for the locale, so no new
    /// catalog key is needed for a phrase Foundation already knows in every
    /// language the app ships.
    private var dateLabel: String? {
        guard let date = stop.date else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days == 0 || days == 1 {
            return TripWidgetView.relative(days: days).localizedCapitalized
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// The bottom band: a chip per contact, then counts for documents and links.
///
/// A contact chip carries a name and an icon and nothing else — the number lives
/// in the app, and tapping hands the app the contact's id to dial. Documents and
/// links are counts with no preview: they say "there are three of these, they're
/// in the app", which is all a locked screen should say about them.
private struct ChipRow: View {
    @Environment(\.widgetFamily) private var family
    let trip: TripDetailSnapshot.Trip

    /// Medium fits two chips beside the counts before names start truncating.
    private var contactLimit: Int { family == .systemLarge ? 3 : 2 }

    private var hasCounts: Bool { trip.documentCount > 0 || trip.linkCount > 0 }

    var body: some View {
        if !trip.contacts.isEmpty || hasCounts {
            HStack(spacing: 6) {
                ForEach(trip.contacts.prefix(contactLimit)) { contact in
                    ContactChip(tripID: trip.id, contact: contact)
                }
                if trip.documentCount > 0 {
                    CountChip(
                        symbol: "doc.fill", count: trip.documentCount, tripID: trip.id)
                }
                if trip.linkCount > 0 {
                    CountChip(symbol: "link", count: trip.linkCount, tripID: trip.id)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A tappable contact. `Link` rather than `Button(intent:)` because the work
/// happens in the app — it holds the number and the dialer — and a link is the
/// cheapest way to get there.
private struct ContactChip: View {
    let tripID: String
    let contact: TripDetailSnapshot.Contact

    var body: some View {
        if let url = TripWidgetLink.contact(trip: tripID, contact: contact.id) {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Image(systemName: contact.symbolName)
                        .font(.caption2)
                    Text(contact.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.22), in: Capsule())
            }
        }
    }
}

/// "3 documents" as an icon and a number. Opens the trip, where the real list is.
private struct CountChip: View {
    let symbol: String
    let count: Int
    let tripID: String

    var body: some View {
        if let url = TripWidgetLink.trip(tripID) {
            Link(destination: url) {
                HStack(spacing: 3) {
                    Image(systemName: symbol)
                        .font(.caption2)
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(.white.opacity(0.14), in: Capsule())
            }
        }
    }
}

// MARK: - Widget

struct TripWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: TripDetailSnapshotStore.widgetKind,
            intent: SelectTripIntent.self,
            provider: TripWidgetProvider()
        ) { entry in
            TripWidgetView(entry: entry)
                .modifier(ThemedGradientBackground(theme: entry.appTheme))
        }
        .configurationDisplayName("Trip")
        .description("Where you are on a trip, what's next, and who to call.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
