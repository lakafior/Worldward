/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

/// Visited countries, grouped by continent and flattened to plain values.
///
/// Deliberately *not* `[Country]`: the model objects would re-fault as the list
/// scrolls, and localizing every name inside a sort comparator would re-run the
/// catalog lookup on each comparison. Built once per store change by
/// `WatchRootView` and handed down.
struct WatchContinentGroup: Identifiable {
    struct Entry: Identifiable {
        let id: String  // ISO alpha-2
        let flag: String
        let name: String
        let status: CountryStatus
    }

    let continent: Continent
    let entries: [Entry]

    var id: String { continent.rawValue }

    /// Buckets the visited countries by continent, in canonical continent order,
    /// dropping continents with nothing in them.
    static func grouped(_ countries: [Country]) -> [WatchContinentGroup] {
        var buckets: [String: [Entry]] = [:]
        for country in countries where country.isVisited {
            buckets[country.continent, default: []].append(
                Entry(
                    id: country.id, flag: country.flagEmoji,
                    name: country.localizedName, status: country.status))
        }
        return Continent.allCases.compactMap { continent in
            guard let entries = buckets[continent.rawValue], !entries.isEmpty else { return nil }
            return WatchContinentGroup(
                continent: continent,
                entries: entries.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
        }
    }
}

/// The "Been" page: how much of the world is behind you, what you logged most
/// recently, and the full list of visited countries by continent.
struct WatchBeenView: View {
    let stats: TravelStats?
    let groups: [WatchContinentGroup]

    /// Bounded at the source — only the handful of visits the section shows are
    /// ever fetched. Its own `@Query` so a newly synced visit appears without
    /// waiting on the cached-stats signature.
    @Query private var recentVisits: [Visit]

    init(stats: TravelStats?, groups: [WatchContinentGroup]) {
        self.stats = stats
        self.groups = groups
        var descriptor = FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 6
        _recentVisits = Query(descriptor)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let stats, stats.hasTravel {
                    content(stats)
                } else {
                    ContentUnavailableView {
                        Label(Str.Watch.nothingLoggedTitle, systemImage: "globe")
                    } description: {
                        Text(Str.Watch.nothingLoggedMessage)
                    }
                }
            }
            .navigationTitle(Str.Tab.been)
        }
    }

    @ViewBuilder
    private func content(_ stats: TravelStats) -> some View {
        List {
            Section {
                WatchRing(
                    fraction: Double(stats.visitedCountries) / Double(max(1, stats.totalCountries)),
                    value: "\(stats.visitedCountries)",
                    caption: Str.Watch.countries)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            if !recentVisits.isEmpty {
                Section(Str.Watch.recent) {
                    ForEach(recentVisits) { visit in
                        HStack(spacing: 6) {
                            Text(visit.country?.flagEmoji ?? "📍")
                            Text(visit.country?.localizedName ?? "—")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(visit.date.formatted(.dateTime.year().month(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }
            }

            Section(Str.Watch.continents) {
                ForEach(stats.continents) { continent in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(continent.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(continent.visited)/\(continent.total)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                        ProgressView(value: continent.fraction)
                            .tint(continent.isComplete ? .brandTeal : .brand)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            ForEach(groups) { group in
                Section(group.continent.localizedName) {
                    ForEach(group.entries) { entry in
                        HStack(spacing: 6) {
                            Text(entry.flag)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: entry.status.symbolName)
                                .foregroundStyle(entry.status.tint)
                        }
                        .font(.footnote)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(entry.name)
                        .accessibilityValue(entry.status.label)
                    }
                }
            }
        }
    }
}
