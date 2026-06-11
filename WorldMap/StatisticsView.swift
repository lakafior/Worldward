import SwiftUI

// Travel statistics shown in the toolbar popover.
struct StatisticsView: View {
    let countries: [Country]

    /// One named continent bucket with its visited/total tally.
    private struct ContinentStat: Identifiable {
        let name: String
        let visited: Int
        let total: Int
        var id: String { name }
    }

    /// All statistics derived in a single pass over the countries.
    private struct Stats {
        let visited: Int
        let total: Int
        let visitedContinents: Int
        let continents: [ContinentStat]
    }

    private var stats: Stats {
        var visited = 0
        var buckets: [String: (visited: Int, total: Int)] = [:]
        for country in countries {
            if country.isVisited { visited += 1 }
            var bucket = buckets[country.continent, default: (0, 0)]
            bucket.total += 1
            if country.isVisited { bucket.visited += 1 }
            buckets[country.continent] = bucket
        }

        let continents = buckets
            .map { ContinentStat(name: $0.key, visited: $0.value.visited, total: $0.value.total) }
            .sorted { $0.name < $1.name }

        return Stats(
            visited: visited,
            total: countries.count,
            visitedContinents: continents.lazy.filter { $0.visited > 0 }.count,
            continents: continents
        )
    }

    private func percent(_ value: Int, of total: Int) -> Double {
        total > 0 ? Double(value) / Double(total) * 100 : 0
    }

    var body: some View {
        let stats = stats

        VStack(alignment: .leading, spacing: 16) {
            Text("Travel Statistics")
                .font(.title2)
                .bold()
                .padding(.bottom, 4)

            StatRow(title: "Visited countries",
                    value: "\(stats.visited) / \(stats.total)",
                    percent: percent(stats.visited, of: stats.total))

            StatRow(title: "Visited continents",
                    value: "\(stats.visitedContinents) / \(stats.continents.count)",
                    percent: percent(stats.visitedContinents, of: stats.continents.count))

            Divider()

            Text("By continent")
                .font(.headline)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(stats.continents) { continent in
                        StatRow(title: continent.name,
                                value: "\(continent.visited) / \(continent.total)",
                                percent: percent(continent.visited, of: continent.total))
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding()
        .frame(width: 350, height: 450)
    }
}

struct StatRow: View {
    var title: String
    var value: String
    var percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
            HStack {
                ProgressView(value: percent, total: 100)
                    .tint(.green)
                Text(String(format: "%.1f%%", percent))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 45, alignment: .trailing)
            }
        }
    }
}
