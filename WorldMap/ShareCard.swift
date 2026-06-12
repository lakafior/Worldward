import SwiftUI

/// A self-contained, fixed-size card summarizing the user's travels, designed to
/// be rasterized by `ImageRenderer` and shared. It takes no environment so it
/// renders identically off-screen; pass a `year` to produce a year-in-review card.
struct ShareCard: View {
    let stats: TravelStats
    var year: TravelStats.YearStat? = nil

    private var headline: String {
        if let year { return "\(year.year) in Travel" }
        return "My World"
    }

    private var primaryCount: Int {
        year?.countries ?? stats.visitedCountries
    }

    private var primaryLabel: String {
        let plural = primaryCount == 1 ? "country" : "countries"
        return year == nil ? "countries visited" : "\(plural) this year"
    }

    /// The visited countries the card lists: all of them, or just the chosen year.
    private var countryList: [(flag: String, name: String)] {
        if let year { return stats.countries(inYear: year.year) }
        return stats.visitedList
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(headline)
                    .font(.title2.bold())
                Spacer()
                Text("🌍")
                    .font(.title)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(primaryCount)")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(primaryLabel)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 24) {
                metric(value: "\(stats.visitedContinents)", label: "continents")
                if let busiest = stats.busiestYear, year == nil {
                    metric(value: "\(busiest.year)", label: "busiest year")
                } else if year != nil {
                    metric(value: "\(year?.visits ?? 0)", label: "visits")
                }
                if let most = stats.mostVisited {
                    metric(value: most.flag, label: "most visited")
                }
            }

            if !countryList.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(year == nil ? "Countries visited" : "Visited this year")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(countryList.map { "\($0.flag) \($0.name)" }.joined(separator: "   "))
                        .font(.system(size: 15))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Tracked with WorldMap")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 380, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.51, blue: 0.09),
                    Color(red: 0.84, green: 0.30, blue: 0.05),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .foregroundStyle(.white)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// Rasterizes a SwiftUI view into a shareable `Image`, bridging the AppKit/UIKit
/// split. Must run on the main actor because `ImageRenderer` touches the view.
@MainActor
func renderShareImage(_ view: some View, scale: CGFloat = 2) -> Image? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    #if os(macOS)
        guard let image = renderer.nsImage else { return nil }
        return Image(nsImage: image)
    #else
        guard let image = renderer.uiImage else { return nil }
        return Image(uiImage: image)
    #endif
}
