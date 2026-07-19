/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftData

/// Recomputes the watch complication snapshot from the CloudKit-backed store and
/// writes it to the App Group the complications read. The watch app calls this on
/// launch and whenever its data changes (including after a `PackingDeltaSync`
/// toggle); `WatchComplicationStore.write` skips unchanged snapshots, so calling
/// it liberally is cheap. This is the watch's analogue of the iPhone's
/// `refreshWidgetSnapshot` — it reuses `TravelStats` for the country/continent
/// counts so both platforms count identically.
@MainActor
enum WatchComplicationRefresh {
    static func run(context: ModelContext) {
        let countries = (try? context.fetch(FetchDescriptor<Country>())) ?? []
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let stats = TravelStats(countries: countries)
        let now = Date()

        // The soonest trip that hasn't finished — the one to count down to.
        let nextTrip = trips
            .filter { $0.isUpcoming(asOf: now) }
            .min { $0.startDate < $1.startDate }

        // The packing complication follows one trip: the journey underway, else
        // the soonest upcoming one, that actually has a packing list. Sorting by
        // start date gives that for free — a trip underway started earliest.
        let packingTrip = trips
            .filter { $0.isUpcoming(asOf: now) && !($0.packing ?? []).isEmpty }
            .min { $0.startDate < $1.startDate }
        let packing = packingTrip?.packing ?? []

        WatchComplicationStore.write(
            WatchComplicationSnapshot(
                visitedCountries: stats.visitedCountries,
                totalCountries: stats.totalCountries,
                visitedContinents: stats.visitedContinents,
                totalContinents: stats.totalContinents,
                nextTripTitle: nextTrip?.title ?? "",
                nextTripStart: nextTrip?.startDate,
                nextTripEnd: nextTrip?.endDate,
                packedItems: packing.filter(\.isPacked).count,
                totalPackingItems: packing.count))
    }
}
