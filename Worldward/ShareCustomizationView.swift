import SwiftUI

/// A compact sheet that lets the user tailor their shareable travel summary —
/// editing the headline, caption, which stats to include, and the brand theme —
/// with a live preview of the exact image that will be shared. Kept deliberately
/// lightweight: a single rendered card drives both the preview and the share.
struct ShareCustomizationView: View {
    let stats: TravelStats

    @Environment(\.dismiss) private var dismiss

    @State private var headline = ""
    @State private var caption = "Tracked with Worldward"
    @State private var showContinents = true
    @State private var showSecondMetric = true
    @State private var showMostVisited = true
    @State private var showCountryList = true
    @State private var theme: ShareCardTheme = .ocean
    @State private var messageText: String
    @State private var renderedImage: Image?

    init(stats: TravelStats) {
        self.stats = stats
        _messageText = State(initialValue: stats.shareText)
    }

    private var config: ShareCardConfig {
        ShareCardConfig(
            headline: headline, caption: caption,
            showContinents: showContinents, showSecondMetric: showSecondMetric,
            showMostVisited: showMostVisited, showCountryList: showCountryList)
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
                    TextField("Headline", text: $headline, prompt: Text("My World"))
                    TextField("Caption", text: $caption)
                    Picker("Theme", selection: $theme) {
                        ForEach(ShareCardTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Include") {
                    Toggle("Continents", isOn: $showContinents)
                    Toggle("Busiest year", isOn: $showSecondMetric)
                    Toggle("Most visited", isOn: $showMostVisited)
                    Toggle("Country list", isOn: $showCountryList)
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
        .onChange(of: config) { regenerate() }
        .onChange(of: theme) { regenerate() }
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
        renderedImage = renderShareImage(ShareCard(stats: stats, config: config, theme: theme))
    }
}
