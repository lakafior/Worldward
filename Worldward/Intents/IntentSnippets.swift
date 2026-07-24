/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Next Trip Snippet

/// The visual result for `GetNextTripIntent`: the trip's flags and title, a big
/// countdown (or "day N of M" while underway), and the date range. Built from
/// plain values so it renders cheaply wherever the system shows it.
struct NextTripSnippet: View {
    let title: String
    let flags: String
    let phase: TripPhase
    let dateRange: String

    /// The big number and its caption, derived from the phase.
    private var headline: (number: String, caption: String) {
        switch phase {
        case .upcoming(let daysAway):
            return daysAway == 0
                ? (String(localized: "Today"), String(localized: "departure"))
                : ("\(daysAway)", daysAway == 1 ? String(localized: "day to go") : String(localized: "days to go"))
        case .underway(let day, let total):
            return ("\(day)", String(localized: "of \(total) days"))
        case .past(let daysAgo):
            return ("\(daysAgo)", String(localized: "days ago"))
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Next Trip", systemImage: "airplane.departure")
                    .font(.headline)
                    .foregroundStyle(Color.brand)

                if !flags.isEmpty {
                    Text(flags).font(.title3).lineLimit(1)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(dateRange)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                Text(headline.number)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.brand)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(headline.caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Packing Progress Snippet

/// The visual result for `GetPackingProgressIntent`: a progress bar plus the
/// packed / total counts for a trip.
struct PackingProgressSnippet: View {
    let title: String
    let flags: String
    let packed: Int
    let total: Int

    private var fraction: Double {
        total > 0 ? Double(packed) / Double(total) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Packing", systemImage: "suitcase.fill")
                .font(.headline)
                .foregroundStyle(Color.brand)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(packed)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.brand)
                Text("of \(total) packed")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            ProgressView(value: fraction)
                .tint(Color.brand)

            HStack(spacing: 6) {
                if !flags.isEmpty { Text(flags).font(.subheadline).lineLimit(1) }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Visit Count Snippet

/// The visual result for `GetVisitCountIntent`, shown by Siri, Spotlight, and
/// Shortcuts. Built from plain values (no SwiftData) so it renders cheaply
/// wherever the system displays it. Kept background-free per Apple's guidance —
/// the system draws it over its own translucent material.
struct VisitCountSnippet: View {
    let visited: Int
    let total: Int
    let continents: Int
    /// Per-status tallies to show as chips: label, count, tint.
    let statuses: [(label: String, count: Int, color: Color)]
    /// Flag emoji of visited countries, ordered for the strip.
    let flags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Countries Visited", systemImage: "globe.europe.africa.fill")
                .font(.headline)
                .foregroundStyle(Color.brand)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(visited)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.brand)
                Text("of \(total)")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }

            Text("Across \(continents) continent\(continents == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.primary)

            if !statuses.isEmpty {
                HStack(spacing: 8) {
                    ForEach(statuses, id: \.label) { status in
                        HStack(spacing: 4) {
                            Circle().fill(status.color).frame(width: 8, height: 8)
                            Text("\(status.label) \(status.count)")
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                }
            }

            if !flags.isEmpty {
                Text(flags.prefix(60).joined(separator: " "))
                    .font(.title3)
                    .lineLimit(3)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Continent Progress Snippet

/// The visual result for `GetContinentProgressIntent`: a progress bar plus the
/// flags of visited countries on that continent.
struct ContinentProgressSnippet: View {
    let continent: String
    let visited: Int
    let total: Int
    let flags: [String]

    private var fraction: Double {
        total > 0 ? Double(visited) / Double(total) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(continent, systemImage: "map.fill")
                .font(.headline)
                .foregroundStyle(Color.brand)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fraction, format: .percent.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.brand)
                Text("\(visited) of \(total) countries")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            ProgressView(value: fraction)
                .tint(Color.brand)

            if !flags.isEmpty {
                Text(flags.prefix(60).joined(separator: " "))
                    .font(.title3)
                    .lineLimit(3)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
