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
}

/// A single checkable entry on a trip's packing list.
@Model
final class PackingItem {
    var title: String = ""
    var isPacked: Bool = false
    var trip: Trip?

    init(title: String = "", isPacked: Bool = false, trip: Trip? = nil) {
        self.title = title
        self.isPacked = isPacked
        self.trip = trip
    }
}
