/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The at-a-glance page, and the one the app opens on. It cascades: a trip
/// underway leads with today's stop, an upcoming one with its countdown, and
/// underneath (or alone, when nothing is planned) sits the traveller's standing
/// progress through the world. Only a brand-new install with no travel at all
/// reaches the empty state.
struct WatchNowView: View {
    let stats: TravelStats?
    let trips: [Trip]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // `trips` arrives sorted by start date, so the first trip
                    // that hasn't ended is the one underway if there is one, and
                    // otherwise the soonest to come.
                    if let focus = trips.first(where: { $0.isUpcoming(asOf: .now) }) {
                        tripHero(focus)
                    }
                    if let stats, stats.hasTravel {
                        worldHero(stats)
                    } else if trips.isEmpty {
                        ContentUnavailableView {
                            Label(Str.Watch.nothingLoggedTitle, systemImage: "globe")
                        } description: {
                            Text(Str.Watch.nothingLoggedMessage)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle(Str.Watch.now)
        }
    }

    // MARK: - Trip

    @ViewBuilder
    private func tripHero(_ trip: Trip) -> some View {
        let isUnderway = trip.startDate <= .now
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.title.isEmpty ? Str.Trip.untitled : trip.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 4) {
                if !trip.flags.isEmpty { Text(trip.flags) }
                // `.relative` renders "in 3 days" in the user's language with no
                // string of ours to translate — and no plural rules to hand-write
                // across 29 catalogs.
                Text(
                    isUnderway
                        ? Str.Watch.underway
                        : trip.startDate.formatted(.relative(presentation: .named))
                )
                .foregroundStyle(isUnderway ? Color.brand : Color.secondary)
                .bold(isUnderway)
            }
            .font(.footnote)

            if let today = todaysStop(of: trip) {
                Label(
                    "\(today.country?.flagEmoji ?? "📍") \(today.displayTitle)",
                    systemImage: "mappin.and.ellipse"
                )
                .font(.footnote)
                .lineLimit(2)
                .padding(.top, 2)
            }

            if let total = trip.packing?.count, total > 0 {
                ProgressView(value: Double(trip.packedCount), total: Double(total))
                    .tint(.brand)
                    .padding(.top, 2)
                Text("\(trip.packedCount)/\(total)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.brand.opacity(0.15), in: .rect(cornerRadius: 12))
    }

    private func todaysStop(of trip: Trip) -> ItineraryItem? {
        trip.sortedStops.first { stop in
            stop.date.map { Calendar.current.isDateInToday($0) } ?? false
        }
    }

    // MARK: - World

    @ViewBuilder
    private func worldHero(_ stats: TravelStats) -> some View {
        VStack(spacing: 8) {
            WatchRing(
                fraction: Double(stats.visitedCountries) / Double(max(1, stats.totalCountries)),
                value: "\(stats.visitedCountries)",
                caption: Str.Watch.countries)

            Text("\(stats.visitedContinents)/\(stats.totalContinents) \(Str.Watch.continents)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // The flags are the point of the app; a strip of them says more at a
            // glance than any number. Ordered strongest bond first by TravelStats.
            let flags = stats.visitedFlags.prefix(15).joined()
            if !flags.isEmpty {
                Text(flags)
                    .font(.footnote)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
