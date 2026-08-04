/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreLocation
import Foundation
import SwiftData

/// Which sections a shared trip file carries — the control a group organizer
/// wants over the Markdown/PDF they hand out. `nonisolated`/`Sendable` (plain
/// `Int` raw value) so the exporters can read it off the main actor, and so it
/// round-trips through `@AppStorage` as a single integer.
nonisolated struct TripExportOptions: OptionSet, Sendable {
    let rawValue: Int

    static let itinerary = TripExportOptions(rawValue: 1 << 0)
    static let packing = TripExportOptions(rawValue: 1 << 1)
    static let notes = TripExportOptions(rawValue: 1 << 2)
    static let attachments = TripExportOptions(rawValue: 1 << 3)
    /// Contacts carry phone numbers, so they get their own switch rather than
    /// riding along with `.attachments` the way links do. Anyone upgrading has a
    /// stored raw value without this bit, which is deliberate: a shared file
    /// never starts carrying numbers until it's asked for.
    static let contacts = TripExportOptions(rawValue: 1 << 4)

    static let all: TripExportOptions = [
        .itinerary, .packing, .notes, .attachments, .contacts,
    ]
}

/// Where "now" falls relative to a trip. Purely derived from the trip's dates
/// on each read — nothing about it is stored, so it can never go stale.
enum TripPhase: Equatable {
    /// Days until departure; `0` means the trip starts today.
    case upcoming(daysAway: Int)
    /// The 1-based day within the trip, and the trip's total length in days.
    case underway(day: Int, of: Int)
    /// Days since the trip ended; `0` means it ended today.
    case past(daysAgo: Int)
}

/// A planned journey — the heart of the "Going" workflow. A trip is multi-country
/// *through its itinerary*: it owns an ordered list of stops, each optionally tied
/// to a country, so the trip's countries are simply the distinct countries across
/// those stops. It also owns a packing list. CloudKit-safe: every stored property
/// has a default and all relationships are to-one / one-to-many (no many-to-many).
@Model
final class Trip {
    var title: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    var notes: String = ""

    /// Per-row token for CloudKit de-duplication, mirroring `Country.dedupID`.
    var dedupID: String = UUID().uuidString

    /// Identifier of the Apple Reminders list mirroring this trip's packing
    /// list, or empty when none exists (sync off, list not yet created, or the
    /// list was retired after the trip ended).
    var reminderListID: String = ""

    /// Comma-joined identifiers of every reminder the sync engine has paired
    /// with a packing item. This is what disambiguates an unpaired reminder
    /// during reconciliation: known → its local item was deleted, so the
    /// reminder goes too; unknown → the user added it in Reminders, so it's
    /// imported.
    var reminderKnownIDs: String = ""

    /// Identifier of this trip's all-day "banner" event in the app-owned
    /// Worldward calendar, or empty when calendar sync is off (or the trip's
    /// events were retired). See `CalendarSync`.
    var calendarEventID: String = ""

    /// Comma-joined identifiers of every event calendar sync has created for
    /// this trip (banner + stops). A known id with no live stop behind it means
    /// the stop was deleted here, so its event is removed on the next pass.
    var calendarKnownIDs: String = ""

    /// CloudKit requires all relationships to be optional types.
    @Relationship(deleteRule: .cascade, inverse: \ItineraryItem.trip)
    var itinerary: [ItineraryItem]?

    @Relationship(deleteRule: .cascade, inverse: \PackingItem.trip)
    var packing: [PackingItem]?

    @Relationship(deleteRule: .cascade, inverse: \TripAttachment.trip)
    var attachments: [TripAttachment]?

    @Relationship(deleteRule: .cascade, inverse: \TripLink.trip)
    var links: [TripLink]?

    @Relationship(deleteRule: .cascade, inverse: \TripContact.trip)
    var contacts: [TripContact]?

    init(
        title: String = "", startDate: Date = Date(), endDate: Date = Date(), notes: String = ""
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
    }

    /// A brand-new trip a month out, lasting a week — so it opens in "Upcoming"
    /// rather than dropping straight into Past Trips, which the plain `Date()`
    /// default did the moment the day turned over. Import and demo flows build
    /// `Trip` directly with their own real dates instead. `Date()` stays the raw
    /// model default because CloudKit requires every stored property to have one.
    static func newUpcoming(title: String = "") -> Trip {
        let calendar = Calendar.current
        let start =
            calendar.date(byAdding: .month, value: 1, to: calendar.startOfDay(for: Date()))
            ?? Date()
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return Trip(title: title, startDate: start, endDate: end)
    }

    /// Stops in their user-defined order.
    var sortedStops: [ItineraryItem] {
        (itinerary ?? []).sorted { $0.order < $1.order }
    }

    /// Gives every stop a `dedupID`, returning `true` when it had to assign any.
    /// Stops created before the field existed carry `""` (see `ItineraryItem.dedupID`);
    /// this is the lazy backfill, called only by the paths that hand stop ids out.
    /// The caller saves — a read path that assigned ids must persist them, or the
    /// ids it just returned won't match the ones it hands out next time.
    @discardableResult
    func assignStopIDs() -> Bool {
        var assigned = false
        for stop in itinerary ?? [] where stop.dedupID.isEmpty {
            stop.dedupID = UUID().uuidString
            assigned = true
        }
        return assigned
    }

    /// Attachments in the order they were added.
    var sortedAttachments: [TripAttachment] {
        (attachments ?? []).sorted { $0.order < $1.order }
    }

    /// Trip-level documents — attachments not tied to any one stop (insurance,
    /// passport scan, a group itinerary PDF). Files linked to a stop show under
    /// that stop instead. In first-added order.
    var documents: [TripAttachment] {
        sortedAttachments.filter { $0.item == nil }
    }

    /// Links in the order they were added.
    var sortedLinks: [TripLink] {
        (links ?? []).sorted { $0.order < $1.order }
    }

    /// Trip-level links — not tied to any one stop (hotel booking page, the
    /// public-transport timetable for the whole trip). Stop links read under
    /// their stop instead. Mirrors `documents`.
    var tripLinks: [TripLink] {
        sortedLinks.filter { $0.item == nil }
    }

    /// Contacts in the order they were added.
    var sortedContacts: [TripContact] {
        (contacts ?? []).sorted { $0.order < $1.order }
    }

    /// Trip-level contacts — reachable for the whole trip rather than tied to one
    /// stop (the travel-insurance emergency line, a tour operator). Stop contacts
    /// read under their stop instead. Mirrors `tripLinks`.
    var tripContacts: [TripContact] {
        sortedContacts.filter { $0.item == nil }
    }

    /// The distinct countries this trip touches, in first-appearance (stop) order.
    var countries: [Country] {
        var seen = Set<String>()
        var result: [Country] = []
        for stop in sortedStops {
            guard let country = stop.country, !seen.contains(country.id) else { continue }
            seen.insert(country.id)
            result.append(country)
        }
        return result
    }

    /// Flag emoji for the trip's countries, joined for compact display.
    var flags: String { countries.map(\.flagEmoji).joined(separator: " ") }

    /// `true` while the trip hasn't finished yet (ends on or after `now`).
    func isUpcoming(asOf now: Date) -> Bool { endDate >= now }

    /// The trip's date span, as one line ("12 Mar – 20 Mar", or a single date
    /// for a day trip).
    var dateRangeText: String {
        let start = startDate.formatted(date: .abbreviated, time: .omitted)
        let end = endDate.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }

    /// Where today sits relative to the trip. Compared on *calendar day*
    /// boundaries rather than exact instants, so a trip starting later today
    /// reads as "today" and not "in 6 hours".
    func phase(asOf now: Date = Date(), calendar: Calendar = .current) -> TripPhase {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: max(endDate, startDate))
        func days(_ from: Date, _ to: Date) -> Int {
            calendar.dateComponents([.day], from: from, to: to).day ?? 0
        }
        if today < start { return .upcoming(daysAway: days(today, start)) }
        if today > end { return .past(daysAgo: days(end, today)) }
        return .underway(day: days(start, today) + 1, of: days(start, end) + 1)
    }

    /// Items already ticked off the packing list.
    var packedCount: Int { (packing ?? []).filter(\.isPacked).count }

    /// The packing list grouped by container — containers in their `sortOrder`,
    /// then the ungrouped items last. Containers with no items are omitted (they
    /// still live in the shared catalog and remain selectable).
    var packingGroups: [PackingGroup] {
        var containers: [PackingContainer] = []
        var seen = Set<PersistentIdentifier>()
        for item in packing ?? [] {
            guard let container = item.container, !seen.contains(container.persistentModelID)
            else { continue }
            seen.insert(container.persistentModelID)
            containers.append(container)
        }
        containers.sort { $0.sortOrder < $1.sortOrder }

        var groups = containers.map { container in
            PackingGroup(
                container: container,
                items: (packing ?? []).filter {
                    $0.container?.persistentModelID == container.persistentModelID
                }.sorted { $0.order < $1.order })
        }
        let ungrouped = (packing ?? []).filter { $0.container == nil }.sorted { $0.order < $1.order }
        if !ungrouped.isEmpty { groups.append(PackingGroup(container: nil, items: ungrouped)) }
        return groups
    }

    /// The trip as Markdown, carrying only the sections `options` selects — for
    /// the system share sheet (Apple Notes, Messages, Mail) or pasting into any
    /// Markdown editor. Pass `.all` for everything; the export sheet narrows it
    /// down so an organizer can hand out exactly what a group needs.
    func markdown(options: TripExportOptions) -> String {
        let name = title.isEmpty ? Str.Trip.untitled : title
        let start = startDate.formatted(date: .abbreviated, time: .omitted)
        let end = endDate.formatted(date: .abbreviated, time: .omitted)
        let dateLine = start == end ? start : "\(start) – \(end)"

        var lines: [String] = ["# \(name)"]
        let header = [flags.isEmpty ? nil : flags, dateLine]
            .compactMap { $0 }
            .joined(separator: " · ")
        if !header.isEmpty { lines.append(header) }

        let stops = sortedStops
        if options.contains(.itinerary), !stops.isEmpty {
            lines.append("")
            lines.append("## \(Str.Trip.itineraryLabel)")
            // Flat list: each stop is its own numbered line (places are stops
            // now), with its country flag, optional date, note and address line.
            for (index, stop) in stops.enumerated() {
                let flag = stop.country?.flagEmoji ?? "📍"
                var line = "\(index + 1). \(flag) \(stop.displayTitle)"
                if let date = stop.date {
                    line += " — \(date.formatted(date: .abbreviated, time: .omitted))"
                }
                lines.append(line)
                if !stop.detail.isEmpty { lines.append("   \(stop.detail)") }
                // How the traveler gets to this stop reads right under it, ahead
                // of the free note — it's the first thing you check for a leg.
                if let mode = stop.transport {
                    var travel = "   \(mode.emoji) \(mode.label)"
                    if !stop.transportDetail.isEmpty { travel += " — \(stop.transportDetail)" }
                    lines.append(travel)
                }
                if !stop.note.isEmpty { lines.append("   \(stop.note)") }
                // A file or link the user pinned to *this* stop reads under it,
                // where they put it — not lumped into a trip-wide list at the end.
                // Both are "reference material", so they ride the same option.
                if options.contains(.attachments) {
                    for attachment in stop.sortedAttachments {
                        var fileLine = "   - 📎 \(attachment.filename)"
                        if !attachment.caption.isEmpty { fileLine += " — \(attachment.caption)" }
                        lines.append(fileLine)
                    }
                    for link in stop.sortedLinks where link.resolvedURL != nil {
                        lines.append("   - 🔗 [\(link.displayTitle)](\(link.url))")
                    }
                }
                if options.contains(.contacts) {
                    for contact in stop.sortedContacts {
                        lines.append("   - \(Self.markdownContact(contact))")
                    }
                }
            }
        }

        if options.contains(.packing), !(packing ?? []).isEmpty {
            lines.append("")
            lines.append("## \(Str.Trip.packing)")
            let groups = packingGroups
            // Only break the list into sub-headings once items are actually
            // filed into containers; a single ungrouped list stays flat.
            let useHeadings = groups.contains { $0.container != nil }
            for group in groups {
                if useHeadings {
                    lines.append("")
                    lines.append("### \(group.container?.name ?? Str.Trip.packingOther)")
                }
                for item in group.items {
                    let count = item.quantity > 1 ? " ×\(item.quantity)" : ""
                    lines.append("- [\(item.isPacked ? "x" : " ")] \(item.title)\(count)")
                }
            }
        }

        if options.contains(.notes), !notes.isEmpty {
            lines.append("")
            lines.append("## \(Str.Trip.notesLabel)")
            lines.append(notes)
        }

        // Only trip-level documents here (per-stop files already read under their
        // stop above). Markdown is text, so files are listed by name + caption;
        // the PDF export embeds image and PDF attachments as pages.
        let tripDocuments = documents
        if options.contains(.attachments), !tripDocuments.isEmpty {
            lines.append("")
            lines.append("## \(Str.Trip.attachmentsLabel)")
            for attachment in tripDocuments {
                var line = "- \(attachment.filename)"
                if !attachment.caption.isEmpty { line += " — \(attachment.caption)" }
                lines.append(line)
            }
        }

        // Trip-level links (booking pages, timetables) — reference material like
        // the documents above, so gated on the same option.
        let links = tripLinks.filter { $0.resolvedURL != nil }
        if options.contains(.attachments), !links.isEmpty {
            lines.append("")
            lines.append("## \(Str.Trip.linksLabel)")
            for link in links {
                lines.append("- [\(link.displayTitle)](\(link.url))")
            }
        }

        let contacts = tripContacts
        if options.contains(.contacts), !contacts.isEmpty {
            lines.append("")
            lines.append("## \(Str.Trip.contactsLabel)")
            for contact in contacts {
                lines.append("- \(Self.markdownContact(contact))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// One contact as a Markdown list entry. The value becomes a `tel:`/`mailto:`
    /// link where the kind supports it, so the number stays tappable in whatever
    /// app opens the exported file — the whole reason contacts are their own
    /// model. `.other` (and anything unparseable) degrades to plain text.
    private static func markdownContact(_ contact: TripContact) -> String {
        let kind = contact.contactKind
        var line = "\(kind.emoji) \(contact.displayName)"
        guard !contact.value.isEmpty else { return line }
        if let action = contact.actionURL {
            line += " — [\(contact.value)](\(action.absoluteString))"
        } else if contact.displayName != contact.value {
            line += " — \(contact.value)"
        }
        return line
    }
}

/// How the traveler reaches a stop — an optional, lightweight attribute on each
/// itinerary stop ("how I get *to* this place"). Persisted as a raw `String`
/// (like `CountryStatus`/`PlanStatus`) so it migrates without schema versioning.
/// `nonisolated`/`Sendable` so the model's nonisolated helpers and the exporters
/// can read it off the main actor.
nonisolated enum TransportMode: String, CaseIterable, Identifiable, Sendable {
    case plane, train, bus, car, ferry, walk, other

    var id: String { rawValue }

    /// SF Symbol for the mode, shown in the stop editor's picker.
    var symbolName: String {
        switch self {
        case .plane: "airplane"
        case .train: "train.side.front.car"
        case .bus: "bus.fill"
        case .car: "car.fill"
        case .ferry: "ferry.fill"
        case .walk: "figure.walk"
        case .other: "signpost.right.fill"
        }
    }

    /// A plain emoji for text contexts (Markdown/PDF export) where SF Symbols
    /// don't render.
    var emoji: String {
        switch self {
        case .plane: "✈️"
        case .train: "🚆"
        case .bus: "🚌"
        case .car: "🚗"
        case .ferry: "⛴️"
        case .walk: "🚶"
        case .other: "🧭"
        }
    }

    var label: String {
        switch self {
        case .plane: String(localized: "Plane", comment: "Transport mode")
        case .train: String(localized: "Train", comment: "Transport mode")
        case .bus: String(localized: "Bus", comment: "Transport mode")
        case .car: String(localized: "Car", comment: "Transport mode")
        case .ferry: String(localized: "Ferry", comment: "Transport mode")
        case .walk: String(localized: "Walk", comment: "Transport mode")
        case .other: String(localized: "Other", comment: "Transport mode")
        }
    }
}

/// One stop in a trip's itinerary: a place — optionally a country — with an
/// optional date and note. `order` holds the user's manual arrangement.
@Model
final class ItineraryItem {
    var title: String = ""
    var note: String = ""
    var date: Date?
    var order: Int = 0
    var country: Country?
    var trip: Trip?

    /// A short, human-readable location line (e.g. "Rue de Rivoli, Paris") when
    /// this stop is a specific place picked from MapKit search. Empty for a plain
    /// country stop or a hand-typed one. Merged up from `StopPlace` as part of
    /// collapsing the itinerary to a single flat unit — a stop can now *be* a
    /// place, rather than owning a separate list of them.
    var detail: String = ""
    /// The stop's map coordinate when it came from search, kept so it can be
    /// reopened in Apple Maps and drawn on the trip route. Merged up from
    /// `StopPlace`.
    var latitude: Double?
    var longitude: Double?

    /// How the traveler gets *to* this stop (raw `TransportMode`, empty = none)
    /// and the free-form details that go with it — flight number, bus line,
    /// rental company, times, confirmation codes. Deliberately one text field
    /// rather than many typed ones: the traveler writes "IB1234 · dep 14:30 · arr
    /// 17:05" however suits the leg. Boarding passes ride along as this stop's
    /// `attachments`.
    var transportMode: String = ""
    var transportDetail: String = ""

    /// Per-row token for CloudKit de-duplication, mirroring `Trip.dedupID` — and
    /// the stable handle anything outside the app uses to name a stop, which is
    /// why it arrived later than the other models' tokens: until the automation
    /// API, nothing ever had to point at one stop across a process boundary.
    ///
    /// Defaults to `""`, *not* to a fresh UUID: lightweight migration applies one
    /// default value to every existing row, so a `UUID()` default would hand every
    /// stop already in the store the same token. `Trip.assignStopIDs()` fills the
    /// blanks in the first time something needs them, costing nothing at launch.
    var dedupID: String = ""

    /// Identifier of this stop's event in the app-owned Worldward calendar, or
    /// empty when calendar sync is off or the stop has no date. See `CalendarSync`.
    var calendarEventID: String = ""

    /// CloudKit requires all relationships to be optional types.
    @Relationship(deleteRule: .cascade, inverse: \StopPlace.stop)
    var places: [StopPlace]?

    /// Files attached to *this stop* — a museum ticket on the museum stop, a
    /// booking on the hotel stop. `.nullify` (not `.cascade`) so deleting the
    /// stop keeps the file, demoting it to a trip-level document rather than
    /// destroying it. An attachment with no `item` is exactly such a document.
    @Relationship(deleteRule: .nullify, inverse: \TripAttachment.item)
    var attachments: [TripAttachment]?

    /// Web links pinned to *this stop* — a specific bus timetable, a museum's
    /// ticket page. `.nullify` mirrors `attachments`: deleting the stop demotes
    /// the link to a trip-level link rather than destroying it.
    @Relationship(deleteRule: .nullify, inverse: \TripLink.item)
    var links: [TripLink]?

    /// People to reach about *this stop* — the hotel's front desk, the guide for
    /// a booked tour. `.nullify` mirrors `links`: deleting the stop demotes the
    /// contact to a trip-level one rather than losing the number.
    @Relationship(deleteRule: .nullify, inverse: \TripContact.item)
    var contacts: [TripContact]?

    init(
        title: String = "", note: String = "", date: Date? = nil, order: Int = 0,
        country: Country? = nil, trip: Trip? = nil,
        detail: String = "", latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.title = title
        self.note = note
        self.date = date
        self.order = order
        self.country = country
        self.trip = trip
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
    }

    /// A friendly label: the stop's title, else its country's name, else "Stop".
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let country { return country.localizedName }
        return "Stop"
    }

    /// The stop's transport as a typed value, or `nil` when none is set. Setting
    /// it writes through to the raw `transportMode` string.
    var transport: TransportMode? {
        get { TransportMode(rawValue: transportMode) }
        set { transportMode = newValue?.rawValue ?? "" }
    }

    /// How long the traveler stays at this stop, inferred from the gap to the next
    /// dated stop (chronologically), or the trip's end date for the final one.
    /// `nil` when the stop has no date, there's nothing to measure against, or the
    /// span is zero — so the row can simply omit the "N days" hint. This is a
    /// *display hint*, not a stored duration: it assumes you stay until the next
    /// stop, so an excursion that loops back to a base reads long. Deliberately
    /// cheaper than a second stored end-date — no schema change, no CloudKit
    /// redeploy, just the dates already on the itinerary.
    var stayDayCount: Int? {
        guard let start = date, let trip else { return nil }
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        // The next stop *in time* — the earliest dated stop that starts after this
        // one — regardless of how the list is currently sorted or grouped.
        let nextStart = trip.sortedStops
            .compactMap(\.date)
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 > startDay }
            .min()
        let end = nextStart ?? calendar.startOfDay(for: trip.endDate)
        let days = calendar.dateComponents([.day], from: startDay, to: end).day ?? 0
        return days > 0 ? days : nil
    }

    /// The stop's places-to-see in the order they were added.
    var sortedPlaces: [StopPlace] {
        (places ?? []).sorted { $0.order < $1.order }
    }

    /// Files attached to this stop, in the order they were added.
    var sortedAttachments: [TripAttachment] {
        (attachments ?? []).sorted { $0.order < $1.order }
    }

    /// Links pinned to this stop, in the order they were added.
    var sortedLinks: [TripLink] {
        (links ?? []).sorted { $0.order < $1.order }
    }

    /// Contacts pinned to this stop, in the order they were added.
    var sortedContacts: [TripContact] {
        (contacts ?? []).sorted { $0.order < $1.order }
    }

    /// The stop's map coordinate, or `nil` when it wasn't picked from search.
    /// Mirrors `StopPlace.coordinate`.
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A specific sight to see within an itinerary stop — a museum, landmark,
/// viewpoint… — usually picked from MapKit search. The coordinate is kept (when
/// the place came from search) so it can be reopened in Apple Maps later.
/// CloudKit-safe: defaults on every property and a to-one back to its stop.
@Model
final class StopPlace {
    var title: String = ""
    /// A short, human-readable location line from the search result
    /// (e.g. "Rue de Rivoli, Paris"). Empty for hand-typed places.
    var detail: String = ""
    var latitude: Double?
    var longitude: Double?
    var order: Int = 0
    var stop: ItineraryItem?

    init(
        title: String = "", detail: String = "", latitude: Double? = nil,
        longitude: Double? = nil, order: Int = 0, stop: ItineraryItem? = nil
    ) {
        self.title = title
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
        self.order = order
        self.stop = stop
    }

    /// The place's map coordinate, or `nil` when it wasn't picked from search.
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A single checkable entry on a trip's packing list, optionally filed into a
/// `PackingContainer` (a bag/case) so the list can be grouped by where each item
/// goes. `container` is optional — an unfiled item is simply "ungrouped".
@Model
final class PackingItem {
    var title: String = ""
    var isPacked: Bool = false
    /// How many to pack — a first-class field so it can be edited and counted,
    /// rather than baked into the title text.
    var quantity: Int = 1
    /// Manual ordering within a container, for drag-to-reorder. Not globally
    /// unique; only compared among items in the same container.
    var order: Int = 0
    /// Stable identity for CloudKit de-duplication (mirroring `Trip.dedupID`) and
    /// for the packing widget, whose toggle intent must name an item across
    /// process boundaries where `PersistentIdentifier` doesn't travel.
    var dedupID: String = UUID().uuidString
    /// Identifier of this item's mirrored reminder in Apple Reminders, or empty
    /// when the item isn't (yet) synced.
    var reminderID: String = ""
    /// When the sync engine last wrote this item's state to Reminders. Compared
    /// against the reminder's `lastModifiedDate` to decide which side changed —
    /// nil (never synced) behaves as the distant past.
    var reminderSyncedAt: Date?
    var trip: Trip?
    var container: PackingContainer?

    init(
        title: String = "", isPacked: Bool = false, quantity: Int = 1, order: Int = 0,
        trip: Trip? = nil, container: PackingContainer? = nil
    ) {
        self.title = title
        self.isPacked = isPacked
        self.quantity = quantity
        self.order = order
        self.trip = trip
        self.container = container
    }
}

/// A reusable place to pack things into — a bag, case or pouch. Containers are a
/// catalog *shared across every trip*: once you've made "Travel case" it can be
/// picked on any trip, and the on-device assistant sorts items into the ones you
/// already have. CloudKit-safe: defaults on every property, a one-to-many to its
/// items, and `.nullify` so deleting a container just ungroups its items.
@Model
final class PackingContainer {
    var name: String = ""
    /// SF Symbol shown beside the container in the grouped list.
    var symbolName: String = "bag.fill"
    /// User-facing ordering of the groups.
    var sortOrder: Int = 0

    /// Per-row token for CloudKit de-duplication, mirroring `Country.dedupID`.
    var dedupID: String = UUID().uuidString

    /// CloudKit requires all relationships to be optional types.
    @Relationship(deleteRule: .nullify, inverse: \PackingItem.container)
    var items: [PackingItem]?

    init(name: String = "", symbolName: String = "bag.fill", sortOrder: Int = 0) {
        self.name = name
        self.symbolName = symbolName
        self.sortOrder = sortOrder
    }
}

/// A saved, reusable packing list — a named bundle of items the user can apply
/// to any trip. Items store their container by *name* rather than a relationship,
/// so a template stays portable even as the shared container catalog changes.
/// CloudKit-safe: defaults on every property and a `.cascade` one-to-many.
@Model
final class PackingTemplate {
    var name: String = ""

    /// Per-row token for CloudKit de-duplication, mirroring `Country.dedupID`.
    var dedupID: String = UUID().uuidString

    /// CloudKit requires all relationships to be optional types.
    @Relationship(deleteRule: .cascade, inverse: \PackingTemplateItem.template)
    var items: [PackingTemplateItem]?

    init(name: String = "") {
        self.name = name
    }
}

/// One entry in a `PackingTemplate`: a title, a quantity, and the *name* of the
/// container it belongs in (empty means ungrouped). The name is resolved to a
/// real `PackingContainer` only when the template is applied to a trip.
@Model
final class PackingTemplateItem {
    var title: String = ""
    var quantity: Int = 1
    var order: Int = 0
    var containerName: String = ""
    var template: PackingTemplate?

    init(
        title: String = "", quantity: Int = 1, order: Int = 0, containerName: String = "",
        template: PackingTemplate? = nil
    ) {
        self.title = title
        self.quantity = quantity
        self.order = order
        self.containerName = containerName
        self.template = template
    }
}

/// A file attached to a trip — a ticket PDF, a booking confirmation, a
/// boarding-pass image. `.externalStorage` keeps the bytes as a file beside the
/// store rather than inside SQLite rows, and maps to a `CKAsset` once CloudKit
/// sync is enabled — which is also how the blob dodges CloudKit's ~1 MB
/// per-record limit. `byteCount` mirrors `data.count` so list rows can show a
/// size without faulting the whole blob in. CloudKit-safe: defaults on every
/// property, to-one relationship, dedup token.
@Model
final class TripAttachment {
    var filename: String = ""
    @Attribute(.externalStorage) var data: Data = Data()
    var byteCount: Int = 0
    var order: Int = 0

    /// A short, user-written description of what the file is ("Louvre e-ticket",
    /// "Hotel booking"). The filename answers "which file"; this answers "what
    /// for". Empty when the user hasn't added one.
    var caption: String = ""

    /// Per-row token for CloudKit de-duplication, mirroring `Trip.dedupID`.
    var dedupID: String = UUID().uuidString

    var trip: Trip?

    /// The itinerary stop this file belongs to, or `nil` for a trip-level
    /// document (insurance, passport scan) that isn't tied to one place. This is
    /// the relation attachments used to lack entirely — it's what lets a ticket
    /// live under the stop it's for, and drives where the file renders in both
    /// the editor and the export.
    var item: ItineraryItem?

    init(
        filename: String = "", data: Data = Data(), order: Int = 0, trip: Trip? = nil,
        caption: String = "", item: ItineraryItem? = nil
    ) {
        self.filename = filename
        self.data = data
        self.byteCount = data.count
        self.order = order
        self.trip = trip
        self.caption = caption
        self.item = item
    }
}

/// A saved web link on a trip — a hotel booking page, a public-transport
/// timetable, a car-rental confirmation. Trip-level (loose logistics) when `item`
/// is nil, else pinned to one stop. Mirrors `TripAttachment`'s dual trip/item
/// ownership, but holds a URL string instead of a file blob. CloudKit-safe:
/// defaults on every property, to-one relationships, dedup token.
@Model
final class TripLink {
    var title: String = ""
    var url: String = ""
    var order: Int = 0

    /// Per-row token for CloudKit de-duplication, mirroring `Trip.dedupID`.
    var dedupID: String = UUID().uuidString

    var trip: Trip?

    /// The itinerary stop this link belongs to, or `nil` for a trip-level link.
    var item: ItineraryItem?

    init(
        title: String = "", url: String = "", order: Int = 0, trip: Trip? = nil,
        item: ItineraryItem? = nil
    ) {
        self.title = title
        self.url = url
        self.order = order
        self.trip = trip
        self.item = item
    }

    /// The link as an openable `URL`, or `nil` when the field is empty/unparseable.
    /// A bare "example.com" is upgraded to `https://` so a hand-typed link still
    /// opens.
    var resolvedURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = URL(string: trimmed), parsed.scheme != nil { return parsed }
        return URL(string: "https://\(trimmed)")
    }

    /// What to show as the link's label: its title, else the raw URL.
    var displayTitle: String { title.isEmpty ? url : title }
}

/// How to reach a contact — decides its icon and what tapping the row does.
/// Persisted as a raw `String` on `TripContact`, matching `TransportMode` and the
/// status enums, so a value written by a newer version degrades to `.other`
/// instead of failing to decode.
nonisolated enum ContactKind: String, CaseIterable, Identifiable, Sendable {
    case phone, whatsapp, email, other

    var id: String { rawValue }

    /// SF Symbol for the kind, shown in the contact row and its picker.
    var symbolName: String {
        switch self {
        case .phone: "phone.fill"
        case .whatsapp: "message.fill"
        case .email: "envelope.fill"
        case .other: "person.crop.circle"
        }
    }

    /// A plain emoji for text contexts (Markdown/PDF export) where SF Symbols
    /// don't render.
    var emoji: String {
        switch self {
        case .phone: "📞"
        case .whatsapp: "💬"
        case .email: "✉️"
        case .other: "👤"
        }
    }

    var label: String {
        switch self {
        case .phone: String(localized: "Phone", comment: "Contact kind")
        case .whatsapp: String(localized: "WhatsApp", comment: "Contact kind")
        case .email: String(localized: "Email", comment: "Contact kind")
        case .other: String(localized: "Other", comment: "Contact kind")
        }
    }

    /// Placeholder for the value field, so the expected shape is clear before
    /// anything is typed.
    var valuePrompt: String {
        switch self {
        case .phone, .whatsapp:
            String(localized: "Phone number", comment: "Contact value placeholder")
        case .email:
            String(localized: "Email address", comment: "Contact value placeholder")
        case .other:
            String(localized: "Details", comment: "Contact value placeholder")
        }
    }

    /// The value turned into something the system can open — a dialer, WhatsApp,
    /// or a mail composer. `nil` for `.other` (free-form, nothing to launch) and
    /// for values with no usable characters, which is what hides the action
    /// button on a half-typed row.
    func actionURL(for value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch self {
        case .phone:
            let digits = trimmed.filter(\.isNumber)
            guard !digits.isEmpty else { return nil }
            // "+" is the one non-digit `tel:` accepts across dialers; the spaces,
            // parens and dashes people type are dropped.
            return URL(string: trimmed.hasPrefix("+") ? "tel:+\(digits)" : "tel:\(digits)")
        case .whatsapp:
            // wa.me takes digits only — no "+", no spaces, no punctuation.
            let digits = trimmed.filter(\.isNumber)
            return digits.isEmpty ? nil : URL(string: "https://wa.me/\(digits)")
        case .email:
            guard trimmed.contains("@"), !trimmed.contains(" ") else { return nil }
            return URL(string: "mailto:\(trimmed)")
        case .other:
            return nil
        }
    }
}

/// A person or desk to reach on a trip — the hotel's front desk, the car-rental
/// WhatsApp, an insurer's emergency line. Trip-level (reachable throughout) when
/// `item` is nil, else pinned to one stop. Mirrors `TripLink`'s dual trip/item
/// ownership, holding a number or address instead of a URL. It's its own model
/// rather than free text in the notes so each row carries a real tap-to-call
/// action. CloudKit-safe: defaults on every property, to-one relationships,
/// dedup token.
@Model
final class TripContact {
    /// Who this is — "Hotel Ibis front desk", "Ola (car rental)".
    var name: String = ""

    /// The number or address exactly as typed. Kept verbatim so it reads back the
    /// way it was written; `ContactKind.actionURL` does the normalising.
    var value: String = ""

    /// `ContactKind.rawValue`. Raw so an unrecognised value degrades gracefully.
    var kind: String = ContactKind.phone.rawValue

    var order: Int = 0

    /// Per-row token for CloudKit de-duplication, mirroring `Trip.dedupID`.
    var dedupID: String = UUID().uuidString

    var trip: Trip?

    /// The itinerary stop this contact belongs to, or `nil` for a trip-level one.
    var item: ItineraryItem?

    init(
        name: String = "", value: String = "", kind: ContactKind = .phone, order: Int = 0,
        trip: Trip? = nil, item: ItineraryItem? = nil
    ) {
        self.name = name
        self.value = value
        self.kind = kind.rawValue
        self.order = order
        self.trip = trip
        self.item = item
    }

    /// The kind as a typed value, falling back to `.other` for anything
    /// unrecognised. Setting it writes through to the raw `kind` string.
    var contactKind: ContactKind {
        get { ContactKind(rawValue: kind) ?? .other }
        set { kind = newValue.rawValue }
    }

    /// What tapping this contact opens, or `nil` when there's nothing to launch.
    var actionURL: URL? { contactKind.actionURL(for: value) }

    /// What to show as the contact's label: its name, else the raw value.
    var displayName: String { name.isEmpty ? value : name }
}

/// One rendered group of a trip's packing list: a container (or `nil` for the
/// ungrouped "Other" bucket) and the items filed under it. `Identifiable` so the
/// grouped UI can `ForEach` over it. `nonisolated` so the `Trip` model's
/// nonisolated computed properties can build and read it (the project defaults to
/// `@MainActor` isolation).
nonisolated struct PackingGroup: Identifiable {
    let container: PackingContainer?
    let items: [PackingItem]

    var id: String { container?.dedupID ?? "ungrouped" }
}

/// One `#`-delimited chunk of a trip's notes — a heading and the text beneath it.
///
/// Notes remain a single Markdown string on `Trip`: this is a *view over* that
/// string, never a stored shape. Nothing here touches the schema or CloudKit,
/// and the Markdown/PDF exports keep rendering the very same headings they
/// always did — a section boundary and a heading are the same character.
///
/// Splitting is deliberately strict: only a line starting `"# "` opens a
/// section. `##`/`###` stay inside a body as sub-headings, and so does a
/// fully-bold line — `TripPDFRenderer.headingText` also reads that as a heading,
/// and it's how `TripPlanner.suggestNotes` marks its country headings, so
/// splitting on it would burst a generated note into a dozen sections.
///
/// `parse` and `serialize` are exact inverses: serializing a parse gives back
/// the original string byte for byte, blank lines and all. That's what lets the
/// editor hand out one field per section without ever rewriting what the user
/// wrote.
nonisolated struct NoteSection: Identifiable, Equatable, Sendable {
    let id = UUID()

    /// The heading text, or `nil` for the lead chunk before the first `#` line —
    /// which is the whole of any note written before sections existed.
    var title: String?

    /// The lines beneath the heading, kept verbatim (blank ones included) so the
    /// round trip stays lossless.
    var bodyLines: [String]

    var body: String {
        get { bodyLines.joined(separator: "\n") }
        set { bodyLines = newValue.components(separatedBy: "\n") }
    }

    /// `true` when the section holds nothing but whitespace — used to hide the
    /// empty lead field on a note that opens straight with a heading.
    var isBodyBlank: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The heading a line opens, or `nil` when it isn't one. The space after `#`
    /// is required, so "#1 priority" and a bare "#" stay ordinary body text.
    private static func headingTitle(_ line: String) -> String? {
        line.hasPrefix("# ") ? String(line.dropFirst(2)) : nil
    }

    static func parse(_ notes: String) -> [NoteSection] {
        var sections: [NoteSection] = []
        var title: String?
        var lines: [String] = []
        for line in notes.components(separatedBy: "\n") {
            if let heading = headingTitle(line) {
                sections.append(NoteSection(title: title, bodyLines: lines))
                title = heading
                lines = []
            } else {
                lines.append(line)
            }
        }
        sections.append(NoteSection(title: title, bodyLines: lines))
        return sections
    }

    static func serialize(_ sections: [NoteSection]) -> String {
        var lines: [String] = []
        for section in sections {
            if let title = section.title {
                // A newline pasted into the heading field would split the section
                // on the next parse and strand the remainder under a heading the
                // user never wrote; fold it to a space instead.
                lines.append("# " + title.replacingOccurrences(of: "\n", with: " "))
            }
            lines.append(contentsOf: section.bodyLines)
        }
        return lines.joined(separator: "\n")
    }
}
