/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreLocation
import Foundation
import SwiftData

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

    @Relationship(deleteRule: .cascade, inverse: \ItineraryItem.trip)
    var itinerary: [ItineraryItem] = []

    @Relationship(deleteRule: .cascade, inverse: \PackingItem.trip)
    var packing: [PackingItem] = []

    init(
        title: String = "", startDate: Date = Date(), endDate: Date = Date(), notes: String = ""
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
    }

    /// Stops in their user-defined order.
    var sortedStops: [ItineraryItem] {
        itinerary.sorted { $0.order < $1.order }
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

    /// Items already ticked off the packing list.
    var packedCount: Int { packing.filter(\.isPacked).count }

    /// The packing list grouped by container — containers in their `sortOrder`,
    /// then the ungrouped items last. Containers with no items are omitted (they
    /// still live in the shared catalog and remain selectable).
    var packingGroups: [PackingGroup] {
        var containers: [PackingContainer] = []
        var seen = Set<PersistentIdentifier>()
        for item in packing {
            guard let container = item.container, !seen.contains(container.persistentModelID)
            else { continue }
            seen.insert(container.persistentModelID)
            containers.append(container)
        }
        containers.sort { $0.sortOrder < $1.sortOrder }

        var groups = containers.map { container in
            PackingGroup(
                container: container,
                items: packing.filter {
                    $0.container?.persistentModelID == container.persistentModelID
                }.sorted { $0.order < $1.order })
        }
        let ungrouped = packing.filter { $0.container == nil }.sorted { $0.order < $1.order }
        if !ungrouped.isEmpty { groups.append(PackingGroup(container: nil, items: ungrouped)) }
        return groups
    }

    /// A shareable Markdown summary of the trip — for the system share sheet
    /// (Apple Notes, Messages, Mail) or pasting into any Markdown editor.
    var markdownSummary: String {
        let name = title.isEmpty ? "Untitled Trip" : title
        let start = startDate.formatted(date: .abbreviated, time: .omitted)
        let end = endDate.formatted(date: .abbreviated, time: .omitted)
        let dateLine = start == end ? start : "\(start) – \(end)"

        var lines: [String] = ["# \(name)"]
        let header = [flags.isEmpty ? nil : flags, dateLine]
            .compactMap { $0 }
            .joined(separator: " · ")
        if !header.isEmpty { lines.append(header) }

        let stops = sortedStops
        if !stops.isEmpty {
            lines.append("")
            lines.append("## Itinerary")
            for (index, stop) in stops.enumerated() {
                let flag = stop.country?.flagEmoji ?? "📍"
                var line = "\(index + 1). \(flag) \(stop.displayTitle)"
                if let date = stop.date {
                    line += " — \(date.formatted(date: .abbreviated, time: .omitted))"
                }
                lines.append(line)
                if !stop.note.isEmpty { lines.append("   \(stop.note)") }
                for place in stop.sortedPlaces {
                    lines.append("   - 📍 \(place.title)")
                }
            }
        }

        if !packing.isEmpty {
            lines.append("")
            lines.append("## Packing")
            let groups = packingGroups
            // Only break the list into sub-headings once items are actually
            // filed into containers; a single ungrouped list stays flat.
            let useHeadings = groups.contains { $0.container != nil }
            for group in groups {
                if useHeadings {
                    lines.append("")
                    lines.append("### \(group.container?.name ?? "Other")")
                }
                for item in group.items {
                    let count = item.quantity > 1 ? " ×\(item.quantity)" : ""
                    lines.append("- [\(item.isPacked ? "x" : " ")] \(item.title)\(count)")
                }
            }
        }

        if !notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append(notes)
        }

        return lines.joined(separator: "\n")
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

    @Relationship(deleteRule: .cascade, inverse: \StopPlace.stop)
    var places: [StopPlace] = []

    init(
        title: String = "", note: String = "", date: Date? = nil, order: Int = 0,
        country: Country? = nil, trip: Trip? = nil
    ) {
        self.title = title
        self.note = note
        self.date = date
        self.order = order
        self.country = country
        self.trip = trip
    }

    /// A friendly label: the stop's title, else its country's name, else "Stop".
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let country { return country.name }
        return "Stop"
    }

    /// The stop's places-to-see in the order they were added.
    var sortedPlaces: [StopPlace] {
        places.sorted { $0.order < $1.order }
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

    @Relationship(deleteRule: .nullify, inverse: \PackingItem.container)
    var items: [PackingItem] = []

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

    @Relationship(deleteRule: .cascade, inverse: \PackingTemplateItem.template)
    var items: [PackingTemplateItem] = []

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
