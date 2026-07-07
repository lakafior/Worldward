import CoreImage.CIFilterBuiltins
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

/// What the user can tweak about their share card. Defaults reproduce the
/// original card exactly, so callers that don't customize get the same output.
struct ShareCardConfig: Equatable {
    /// Overrides the default headline when non-empty.
    var headline: String = ""
    /// The small footer line. Hidden when empty.
    var caption: String = "Tracked with Worldward"
    var showContinents = true
    /// The middle metric: busiest year (all-time card) or visits (year card).
    var showSecondMetric = true
    var showMostVisited = true
    var showCountryList = true
    /// The tinted world map, featured below the headline.
    var showMap = true
}

/// A self-contained, fixed-size card summarizing the user's travels, designed to
/// be rasterized by `ImageRenderer` and shared. It takes no environment so it
/// renders identically off-screen; pass a `year` to produce a year-in-review card.
struct ShareCard: View {
    let stats: TravelStats
    var year: TravelStats.YearStat? = nil
    var config = ShareCardConfig()
    var theme: ShareCardTheme = .ocean
    /// ISO 3166-1 alpha-2 id → status rank for visited countries, used to tint the
    /// map. Empty leaves the map off even when `config.showMap` is set.
    var tints: [String: Int] = [:]

    private var headline: String {
        let custom = config.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
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

    private var caption: String {
        config.caption.trimmingCharacters(in: .whitespacesAndNewlines)
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

            if config.showMap, !tints.isEmpty, WorldMapStore.shared != nil {
                WorldMapCanvas(tints: tints)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
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
                if config.showContinents {
                    metric(value: "\(stats.visitedContinents)", label: "continents")
                }
                if config.showSecondMetric {
                    if let busiest = stats.busiestYear, year == nil {
                        metric(value: "\(busiest.year)", label: "busiest year")
                    } else if year != nil {
                        metric(value: "\(year?.visits ?? 0)", label: "visits")
                    }
                }
                if config.showMostVisited, let most = stats.mostVisited {
                    metric(value: most.flag, label: "most visited")
                }
            }

            if config.showCountryList, !countryList.isEmpty {
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

            if !caption.isEmpty {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            QRCodeView(url: "https://github.com/lakafior/Worldward")
                .frame(width: 32, height: 32)
                .padding(12)
        }
        .padding(28)
        .frame(width: 380, alignment: .topLeading)
        .background(theme.gradient)
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

/// A tiny QR code generated on-device from a URL, using Core Image. Rendered
/// through a `CIContext` into a bitmap-backed `CGImage`: a `UIImage(ciImage:)`
/// has no bitmap backing and draws blank in SwiftUI and `ImageRenderer`, which
/// silently dropped the QR code from shared cards on iOS.
private struct QRCodeView: View {
    let url: String

    var body: some View {
        if let cgImage = Self.generateQRCode(from: url) {
            Image(decorative: cgImage, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private static func generateQRCode(from string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
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
