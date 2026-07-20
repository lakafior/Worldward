/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreLocation
import EventKit
import Foundation
import SwiftData
import SwiftUI

/// One-way sync from trips to a dedicated, app-owned "Worldward" calendar in
/// Apple Calendar: an all-day event spanning each trip, plus one all-day event
/// per dated stop — with `structuredLocation` set where a stop has a place with
/// coordinates, so Calendar shows its map and weather natively.
///
/// Unlike `ReminderSync` this is deliberately not two-way: trips are authored
/// in the app, so there's nothing to pull back. The app owns every event in its
/// calendar — each pass converges the calendar onto local state, so an event
/// edited or deleted in Calendar is simply rewritten or recreated, and deleting
/// the whole Worldward calendar triggers a clean rebuild.
///
/// Requires full calendar access (not the exporter's write-only grant), because
/// updating or removing an event later means reading it back by identifier.
/// Only events the sync itself created are ever touched.
///
/// The engine is stateless between passes, mirroring `ReminderSync`: every
/// trigger runs the same reconcile pass, and a pass that changes nothing writes
/// nothing, so `EKEventStoreChanged` loops die out on their own.
enum CalendarSync {
    /// `@AppStorage`/`UserDefaults` key for the global on/off toggle.
    static let enabledKey = "calendarSyncEnabled"
    /// Key for how many days after a trip ends its events are removed (0 = keep
    /// them for as long as the trip exists in the app).
    static let cleanupDaysKey = "calendarSyncCleanupDays"
    /// Key for the identifier of the app-created "Worldward" calendar.
    private static let calendarIDKey = "calendarSyncCalendarID"
    /// Key for the registry of every event identifier the sync created. Events
    /// in the registry that no trip references anymore (the trip was deleted,
    /// or a backup import replaced it) are removed on the next pass.
    private static let createdEventsKey = "calendarSyncCreatedEventIDs"

    /// Unlike Reminders' packing lists, a calendar of past trips doubles as a
    /// travel log — so events are kept by default.
    static let cleanupDaysDefault = 0

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var cleanupDays: Int {
        UserDefaults.standard.object(forKey: cleanupDaysKey) as? Int ?? cleanupDaysDefault
    }

    /// Created lazily on the first pass so that users who never enable sync pay
    /// nothing at launch. Kept alive afterwards because only a live store
    /// receives `EKEventStoreChanged` notifications.
    private static var cachedStore: EKEventStore?
    private static var store: EKEventStore {
        if let cachedStore { return cachedStore }
        let store = EKEventStore()
        cachedStore = store
        return store
    }

    private static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Prompts for full Calendar access (the settings toggle calls this before
    /// flipping on). Full access — not write-only like the one-shot exporter —
    /// because keeping events updated means reading them back by identifier.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    // MARK: - Passes

    /// Serializes overlapping triggers: a pass requested while one is running
    /// just queues a rerun instead of interleaving.
    private static var isSyncing = false
    private static var rerunRequested = false

    /// The whole sync: ensures the Worldward calendar exists, reconciles every
    /// eligible trip, retires trips past their cleanup window, and removes
    /// events whose trip is gone. Safe to call from anywhere at any time — it
    /// no-ops without the toggle or access.
    static func syncAll(context: ModelContext) async {
        guard isEnabled, hasAccess else { return }
        guard !isSyncing else {
            rerunRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerunRequested = false
            pass(context: context)
        } while rerunRequested
    }

    /// Turns sync off: removes the Worldward calendar (every event goes with
    /// it) and clears the local identifiers, leaving all trip data untouched.
    /// Flipping the toggle back on rebuilds the calendar from local state.
    static func disable(context: ModelContext) async {
        guard hasAccess else { return }
        if let id = UserDefaults.standard.string(forKey: calendarIDKey),
            let calendar = store.calendar(withIdentifier: id)
        {
            try? store.removeCalendar(calendar, commit: true)
        }
        UserDefaults.standard.removeObject(forKey: calendarIDKey)
        setCreatedEventIDs([])
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        for trip in trips { clearIDs(of: trip) }
    }

    private static func pass(context: ModelContext) {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        guard let calendar = ensureCalendar(trips: trips) else { return }
        let now = Date()

        var dirty = false
        var expected = Set<String>()
        for trip in trips {
            if isEligible(trip, now: now) {
                if reconcile(trip: trip, calendar: calendar) { dirty = true }
                expected.formUnion(knownIDs(of: trip))
            } else {
                // Past its cleanup window: remove the events, keep the trip —
                // lifecycle never erases data.
                if retireEvents(of: trip) { dirty = true }
            }
        }

        // Garbage-collect events whose trip is gone (deleted, or replaced by a
        // backup import) — the registry remembers what we created.
        for id in createdEventIDs() where !expected.contains(id) {
            if let event = store.event(withIdentifier: id) {
                try? store.remove(event, span: .thisEvent, commit: false)
                dirty = true
            }
        }
        setCreatedEventIDs(expected.sorted())

        if dirty { try? store.commit() }
    }

    /// Whether the trip should have live events: it hasn't aged past the
    /// cleanup window (0 = no window). Even a trip with no stops gets its
    /// banner event — the dates alone are worth seeing on the calendar.
    private static func isEligible(_ trip: Trip, now: Date) -> Bool {
        let days = cleanupDays
        guard days > 0 else { return true }
        return trip.endDate.addingTimeInterval(Double(days) * 86_400) >= now
    }

    // MARK: - Calendar

    /// Returns the app's calendar, creating it when missing — either never
    /// made, or the user deleted it in Calendar (taking every event with it).
    /// Stale ids are cleared in that case so the rebuild pushes everything
    /// fresh instead of chasing identifiers that no longer resolve.
    private static func ensureCalendar(trips: [Trip]) -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: calendarIDKey),
            let calendar = store.calendar(withIdentifier: id)
        {
            return calendar
        }

        for trip in trips { clearIDs(of: trip) }
        setCreatedEventIDs([])

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Worldward"
        calendar.cgColor = Color.brand.resolve(in: EnvironmentValues()).cgColor
        guard
            let source = store.defaultCalendarForNewEvents?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV })
                ?? store.sources.first(where: { $0.sourceType == .local })
        else { return nil }
        calendar.source = source
        guard (try? store.saveCalendar(calendar, commit: true)) != nil else { return nil }
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarIDKey)
        return calendar
    }

    // MARK: - Per-trip reconcile

    /// Converges one trip's events onto local state: the banner, one event per
    /// dated stop, and removal of events whose stop was deleted or undated.
    /// Returns whether the store was written.
    private static func reconcile(trip: Trip, calendar: EKCalendar) -> Bool {
        var dirty = false
        var expected = Set<String>()

        let countryLine = trip.countries.map(\.name).joined(separator: ", ")
        let banner = EventSpec(
            title: trip.title.isEmpty ? String(localized: "Trip") : trip.title,
            start: trip.startDate, end: trip.endDate,
            notes: [countryLine, trip.notes].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            locationText: nil, place: nil)
        if let id = upsert(banner, existingID: trip.calendarEventID, in: calendar, dirty: &dirty) {
            trip.calendarEventID = id
            expected.insert(id)
        }

        for stop in trip.sortedStops {
            guard let date = stop.date else {
                // A stop without a date can't be placed on a calendar; any
                // event from when it still had one is swept up below.
                stop.calendarEventID = ""
                continue
            }

            let flag = stop.country?.flagEmoji ?? ""
            let placeLines = stop.sortedPlaces.map { "• \($0.title)" }.joined(separator: "\n")
            // The first place with a coordinate carries the structuredLocation;
            // without one, the country name rides along as plain location text.
            let located = stop.sortedPlaces.first { $0.coordinate != nil }
            let spec = EventSpec(
                title: [flag, stop.displayTitle].filter { !$0.isEmpty }.joined(separator: " "),
                start: date, end: date,
                notes: [stop.note, placeLines].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                locationText: located == nil ? stop.country?.localizedName : nil,
                place: located.flatMap { place in
                    place.coordinate.map { (place.title, $0.latitude, $0.longitude) }
                })
            if let id = upsert(spec, existingID: stop.calendarEventID, in: calendar, dirty: &dirty) {
                stop.calendarEventID = id
                expected.insert(id)
            }
        }

        // Known ids with no live banner/stop behind them — the stop was deleted
        // (or lost its date) here, so its event follows.
        for id in knownIDs(of: trip).subtracting(expected) {
            if let event = store.event(withIdentifier: id) {
                try? store.remove(event, span: .thisEvent, commit: false)
                dirty = true
            }
        }
        trip.calendarKnownIDs = expected.sorted().joined(separator: ",")
        return dirty
    }

    /// Everything that defines one synced event, before it touches EventKit.
    private struct EventSpec {
        var title: String
        var start: Date
        var end: Date
        var notes: String
        /// Plain-text location, shown when no coordinate is available.
        var locationText: String?
        /// A titled coordinate → `structuredLocation`, which is what makes
        /// Calendar show the map and weather for the event.
        var place: (title: String, latitude: Double, longitude: Double)?
    }

    /// Creates or converges one all-day event. Only writes when something
    /// actually differs — that convergence is what keeps `EKEventStoreChanged`
    /// feedback loops from running forever. Returns the event's identifier, or
    /// `nil` when the store refused the save.
    private static func upsert(
        _ spec: EventSpec, existingID: String, in calendar: EKCalendar, dirty: inout Bool
    ) -> String? {
        let existing = existingID.isEmpty ? nil : store.event(withIdentifier: existingID)
        let event = existing ?? EKEvent(eventStore: store)
        var changed = existing == nil
        let dayCalendar = Calendar.current

        // Re-home an event the user moved to another calendar.
        if event.calendar?.calendarIdentifier != calendar.calendarIdentifier {
            event.calendar = calendar
            changed = true
        }
        if event.title != spec.title {
            event.title = spec.title
            changed = true
        }
        if !event.isAllDay {
            event.isAllDay = true
            changed = true
        }
        // All-day events are compared by calendar day, not instant — EventKit
        // normalizes the stored dates, so exact `Date` comparison would report
        // a difference on every pass and the convergence would never settle.
        let start = dayCalendar.startOfDay(for: spec.start)
        let end = dayCalendar.startOfDay(for: spec.end)
        if event.startDate == nil || !dayCalendar.isDate(event.startDate, inSameDayAs: start) {
            event.startDate = start
            changed = true
        }
        if event.endDate == nil || !dayCalendar.isDate(event.endDate, inSameDayAs: end) {
            event.endDate = end
            changed = true
        }
        let notes = spec.notes.isEmpty ? nil : spec.notes
        if (event.notes ?? "") != (notes ?? "") {
            event.notes = notes
            changed = true
        }

        if let place = spec.place {
            // Coordinates are compared with a small tolerance for the same
            // reason as the dates: the store may round what it gives back.
            let current = event.structuredLocation
            let coordinate = current?.geoLocation?.coordinate
            let matches =
                current?.title == place.title
                && coordinate.map {
                    abs($0.latitude - place.latitude) < 1e-6
                        && abs($0.longitude - place.longitude) < 1e-6
                } == true
            if !matches {
                let location = EKStructuredLocation(title: place.title)
                location.geoLocation = CLLocation(
                    latitude: place.latitude, longitude: place.longitude)
                event.structuredLocation = location
                changed = true
            }
        } else if (event.location ?? "") != (spec.locationText ?? "") {
            event.location = spec.locationText
            changed = true
        }

        guard changed else { return event.eventIdentifier }
        guard (try? store.save(event, span: .thisEvent, commit: false)) != nil else { return nil }
        dirty = true
        return event.eventIdentifier
    }

    // MARK: - Retire & bookkeeping

    /// Removes every event of one trip (if they still exist) and clears the
    /// local pairings. The trip itself is deliberately untouched.
    private static func retireEvents(of trip: Trip) -> Bool {
        var dirty = false
        for id in knownIDs(of: trip) {
            if let event = store.event(withIdentifier: id) {
                try? store.remove(event, span: .thisEvent, commit: false)
                dirty = true
            }
        }
        clearIDs(of: trip)
        return dirty
    }

    private static func clearIDs(of trip: Trip) {
        trip.calendarEventID = ""
        trip.calendarKnownIDs = ""
        for stop in trip.itinerary ?? [] { stop.calendarEventID = "" }
    }

    private static func knownIDs(of trip: Trip) -> Set<String> {
        Set(trip.calendarKnownIDs.split(separator: ",").map(String.init))
    }

    private static func createdEventIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: createdEventsKey) ?? []
    }

    private static func setCreatedEventIDs(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: createdEventsKey)
    }
}
