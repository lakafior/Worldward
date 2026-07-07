import SwiftUI

/// A compact sheet that lets the user tailor their shareable travel summary —
/// editing the headline, caption, which stats to include, and the brand theme —
/// with a live preview of the exact image that will be shared. Kept deliberately
/// lightweight: a single rendered card drives both the preview and the share.
struct ShareCustomizationView: View {
    let stats: TravelStats
    /// ISO 3166-1 alpha-2 id → status rank for visited countries, used to tint the
    /// optional map on the card.
    let tints: [String: Int]
    /// When set, the card and message summarize this single year (a
    /// year-in-review card) instead of the all-time footprint.
    let year: TravelStats.YearStat?

    @Environment(\.dismiss) private var dismiss

    @State private var headline = ""
    @State private var caption = "Tracked with Worldward"
    @State private var showMap = true
    @State private var showContinents = true
    @State private var showSecondMetric = true
    @State private var showMostVisited = true
    @State private var showCountryList = true
    @State private var showQRCode = true
    @State private var theme: ShareCardTheme = .ocean
    @State private var messageText: String
    @State private var renderedImage: Image?

    init(stats: TravelStats, tints: [String: Int] = [:], year: TravelStats.YearStat? = nil) {
        self.stats = stats
        self.tints = tints
        self.year = year
        _messageText = State(initialValue: year.map(stats.shareText(forYear:)) ?? stats.shareText)
    }

    private var config: ShareCardConfig {
        ShareCardConfig(
            headline: headline, caption: caption,
            showContinents: showContinents, showSecondMetric: showSecondMetric,
            showMostVisited: showMostVisited, showCountryList: showCountryList,
            showMap: showMap, showQRCode: showQRCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Card") {
                    TextField(
                        "Headline", text: $headline,
                        prompt: Text(year.map { "\($0.year) in Travel" } ?? "My World"))
                    TextField("Caption", text: $caption)
                    Picker("Theme", selection: $theme) {
                        ForEach(ShareCardTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Include") {
                    if !tints.isEmpty {
                        Toggle("World map", isOn: $showMap)
                    }
                    Toggle("Continents", isOn: $showContinents)
                    // The card's middle metric is the busiest year on the
                    // all-time card and the visit count on a year card.
                    Toggle(year == nil ? "Busiest year" : "Visits", isOn: $showSecondMetric)
                    Toggle("Most visited", isOn: $showMostVisited)
                    Toggle("Country list", isOn: $showCountryList)
                    Toggle("QR code", isOn: $showQRCode)
                }

                Section("Message") {
                    TextField("Message", text: $messageText, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    if let renderedImage {
                        ShareLink(
                            item: renderedImage,
                            preview: SharePreview("My Worldward travels", image: renderedImage)
                        ) {
                            Label("Share Image", systemImage: "photo")
                        }
                    }
                    ShareLink(item: messageText) {
                        Label("Share Text", systemImage: "text.quote")
                    }
                }
            }
            .navigationTitle("Share")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 640)
        .onAppear(perform: regenerate)
        .onChange(of: headline) { _, _ in regenerate() }
        .onChange(of: caption) { _, _ in regenerate() }
        .onChange(of: showMap) { _, _ in regenerate() }
        .onChange(of: showContinents) { _, _ in regenerate() }
        .onChange(of: showSecondMetric) { _, _ in regenerate() }
        .onChange(of: showMostVisited) { _, _ in regenerate() }
        .onChange(of: showCountryList) { _, _ in regenerate() }
        .onChange(of: showQRCode) { _, _ in regenerate() }
        .onChange(of: theme) { _, _ in regenerate() }
    }

    @ViewBuilder
    private var preview: some View {
        if let renderedImage {
            renderedImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 10, y: 5)
                .frame(maxWidth: 360)
                .padding(.vertical, 8)
        } else {
            ProgressView()
                .frame(height: 200)
        }
    }

    private func regenerate() {
        renderedImage = renderShareImage(
            ShareCard(stats: stats, year: year, config: config, theme: theme, tints: tints))
    }
}
