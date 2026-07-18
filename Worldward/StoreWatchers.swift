/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

// MARK: - Store watchers

/// An invisible view owning the store-wide change signatures — and the trip /
/// visit `@Query`s that feed them. Reading every trip's packing list (or every
/// visit's date) in a body registers Observation on all of it, so keeping these
/// keys here means a packing tick or visit edit invalidates this tiny view, not
/// the whole `ContentView` scene; the O(store) hashes also stop running on
/// every parent render.
struct StoreWatchers: View {
    let allCountries: [Country]
    /// Catalog changed (a country added/removed, or a status/plan edited — by
    /// hand, by an intent, or by the photo importer). Fired once initially so a
    /// fresh install populates the widget.
    let onCatalogChanged: () -> Void
    /// A trip changed: anything the widgets show, or anything the EventKit
    /// syncs mirror (packing items, stops, places).
    let onTripsChanged: () -> Void
    /// Anything achievements derive from changed. Fired once initially so
    /// changes applied outside this scene's lifetime (intents, a future iCloud
    /// sync) are caught on the next launch.
    let onAchievementsChanged: () -> Void

    @Query private var allTrips: [Trip]
    @Query(sort: \Visit.date) private var allVisits: [Visit]

    var body: some View {
        Color.clear
            .onChange(of: catalogKey, initial: true) { onCatalogChanged() }
            // Trip editing mutates the model live through `@Bindable` bindings —
            // there's no save chokepoint to hook — so a signature watched from a
            // long-lived view is the one reliable invalidation point. The
            // EventKit syncs piggyback on it: any local packing or itinerary
            // edit lands in Reminders / Calendar after a short debounce.
            .onChange(of: tripsKey) { onTripsChanged() }
            .onChange(of: achievementsKey, initial: true) { onAchievementsChanged() }
    }

    /// A cheap signature of every country's id, status, and plan. Statuses and
    /// plans change without the row count changing (detail edits, intents,
    /// photo imports), so watching a count alone would leave caches stale.
    private var catalogKey: Int {
        var hasher = Hasher()
        for country in allCountries {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
            hasher.combine(country.planStatusRaw)
        }
        return hasher.finalize()
    }

    /// `catalogKey`'s companion for trips: everything the upcoming-trip and
    /// packing widgets show (title, dates, flags, the packing list) feeds the
    /// hash, so edits to any of them — including a stop gaining or losing a
    /// country, or an item being ticked off in the trip editor — rewrite the
    /// snapshot.
    private var tripsKey: Int {
        var hasher = Hasher()
        for trip in allTrips {
            hasher.combine(trip.dedupID)
            hasher.combine(trip.title)
            hasher.combine(trip.startDate)
            hasher.combine(trip.endDate)
            hasher.combine(trip.flags)
            for item in trip.packing ?? [] {
                hasher.combine(item.dedupID)
                hasher.combine(item.title)
                hasher.combine(item.isPacked)
                hasher.combine(item.quantity)
                hasher.combine(item.order)
            }
            // Itinerary edits must change the key too: calendar sync mirrors
            // stops (title, date, note, places) to events.
            for stop in trip.itinerary ?? [] {
                hasher.combine(stop.title)
                hasher.combine(stop.note)
                hasher.combine(stop.date)
                hasher.combine(stop.order)
                hasher.combine(stop.country?.id)
                for place in stop.places ?? [] {
                    hasher.combine(place.title)
                    hasher.combine(place.latitude)
                    hasher.combine(place.longitude)
                }
            }
        }
        return hasher.finalize()
    }

    /// `catalogKey`'s companion for achievements: badges also derive from
    /// recorded visits (visit-count milestones, active years, repeat visits), so
    /// visit dates feed the hash alongside the status/plan signature. Watched by
    /// the unlock-toast diff.
    private var achievementsKey: Int {
        var hasher = Hasher()
        hasher.combine(catalogKey)
        for visit in allVisits {
            hasher.combine(visit.date)
        }
        return hasher.finalize()
    }
}

