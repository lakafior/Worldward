import SwiftUI

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
                Text("\(Int((fraction * 100).rounded()))%")
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
