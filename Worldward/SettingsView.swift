/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The app-wide appearance preference. Stored as a raw `String` so it persists
/// directly via `@AppStorage`. `.system` defers to the device's Light/Dark setting.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The `ColorScheme` to force, or `nil` to follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The shared settings content. Rendered natively inside the macOS `Settings`
/// scene (⌘,) and inside a sheet on iOS/iPadOS — the same `Form` for both.
struct SettingsView: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("mapStyle") private var mapStyle: MapStyleOption = .standard
    @AppStorage(NotificationManager.enabledKey) private var notificationsEnabled = false
    @AppStorage(TripPlanner.profileKey) private var packingProfile: PackingProfile = .unspecified
    @AppStorage(TripPlanner.preferencesKey) private var packingPreferences = ""
    @AppStorage(TripPlanner.interestsKey) private var sightseeingInterests = ""
    @Environment(\.modelContext) private var modelContext

    @State private var exportDocument: JSONDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var csvExportDocument: CSVDocument?
    @State private var showCSVExporter = false
    @State private var showCSVImporter = false
    /// The CSV text awaiting preview, set after the picked file is read.
    @State private var csvPayload: CSVPayload?
    @State private var transferAlert: TransferAlert?
    @State private var showManageContainers = false
    @State private var showManageTemplates = false

    var body: some View {
        Form {
            appearanceSection
            #if os(macOS)
                if AppLanguages.shipped.count > 1 { LanguageSettingsSection() }
            #endif
            notificationsSection
            packingSection
            packingManagementSection
            dataSection
            aboutSection
        }
        .sheet(isPresented: $showManageContainers) {
            ManageContainersView()
        }
        .sheet(isPresented: $showManageTemplates) {
            ManageTemplatesView()
        }
        .formStyle(.grouped)
        #if os(macOS)
            .frame(width: 480, height: 540)
        #endif
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Worldward Backup",
            onCompletion: handleExport
        )
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            onCompletion: handleImport
        )
        .fileExporter(
            isPresented: $showCSVExporter,
            document: csvExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "Worldward Travel Data",
            onCompletion: handleExport
        )
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
            onCompletion: handleCSVImport
        )
        .sheet(item: $csvPayload) { payload in
            CSVImportView(text: payload.text) { countries, visits in
                transferAlert = TransferAlert(
                    title: "Import Complete",
                    message: String(
                        localized: "Added \(visits) visits across \(countries) countries.",
                        comment: "Alert after a CSV import")
                )
            }
        }
        .alert(
            Text(transferAlert?.title ?? ""),
            isPresented: alertIsPresented,
            presenting: transferAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appTheme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }

            Picker("Map Style", selection: $mapStyle) {
                ForEach(MapStyleOption.allCases) { style in
                    Label(style.label, systemImage: style.symbolName).tag(style)
                }
            }

            #if !os(macOS)
                Button("Language") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            #endif
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        Section {
            Toggle(
                "Travel reminders",
                isOn: Binding(get: { notificationsEnabled }, set: setNotifications))
        } header: {
            Text("Notifications")
        } footer: {
            Text(
                "Occasional on-device reminders: “on this day” travel memories, a year-in-review nudge each December, and a gentle prompt if you haven't logged a trip in a while. Off by default; nothing is sent unless you turn this on."
            )
        }
    }

    /// Toggling on requests permission and schedules the reminders; toggling off
    /// clears them. If permission is denied, the switch stays off and we point the
    /// user to the system Settings app.
    private func setNotifications(_ on: Bool) {
        guard on else {
            notificationsEnabled = false
            NotificationManager.cancelAll()
            return
        }
        Task {
            guard await NotificationManager.requestAuthorization() else {
                notificationsEnabled = false
                transferAlert = TransferAlert(
                    title: "Notifications Off",
                    message: String(
                        localized:
                            "Turn on notifications for Worldward in the Settings app to receive travel reminders."
                    )
                )
                return
            }
            notificationsEnabled = true
            let countries = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
            let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
            await NotificationManager.reschedule(enabled: true, countries: countries, trips: trips)
        }
    }

    @ViewBuilder private var packingSection: some View {
        Section {
            Picker("Pack for", selection: $packingProfile) {
                ForEach(PackingProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            TextField(
                "Preferences", text: $packingPreferences,
                prompt: Text("e.g. contact lenses, hiking gear, vegetarian"),
                axis: .vertical)
            TextField(
                "Interests", text: $sightseeingInterests,
                prompt: Text("e.g. hiking, street food, traveling with kids"),
                axis: .vertical)
        } header: {
            Text("Trip planning")
        } footer: {
            Text(
                "Tailors the on-device trip assistant. “Pack for” decides whether the packing list includes gender-specific items, preferences are extra packing notes it factors in, and interests steer the sightseeing suggestions."
            )
        }
    }

    @ViewBuilder private var packingManagementSection: some View {
        Section {
            Button {
                showManageContainers = true
            } label: {
                Label("Manage Containers", systemImage: "bag")
            }
            Button {
                showManageTemplates = true
            } label: {
                Label("Manage Templates", systemImage: "list.bullet.rectangle.portrait")
            }
        } header: {
            Text("Packing")
        } footer: {
            Text(
                "Containers are the bags you pack into (shared across all trips). Templates let you save and reuse a packing list."
            )
        }
    }

    /// The two transfer flows, kept deliberately separate: the JSON backup is the
    /// app's own full-fidelity format (restore replaces), while CSV is the
    /// outward-facing exchange format for spreadsheets and other trackers
    /// (import only adds).
    @ViewBuilder private var dataSection: some View {
        Section {
            Button("Export Travel Data…", action: startExport)
            Button("Import Travel Data…") { showImporter = true }
        } header: {
            Text("Backup")
        } footer: {
            Text(
                "A complete backup of your travel data — statuses, visits, notes, plans, and trips — as a JSON file for safekeeping or moving between devices. Importing replaces the travel data of every country in the file."
            )
        }

        Section {
            Button("Export CSV…", action: startCSVExport)
            Button("Import from CSV…") { showCSVImporter = true }
        } header: {
            Text("Spreadsheet (CSV)")
        } footer: {
            Text(
                "For exchanging with spreadsheets and other trackers. Export lists your visited countries and their visits; import adds countries and visits without touching what's already recorded."
            )
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { transferAlert != nil },
            set: { if !$0 { transferAlert = nil } }
        )
    }

    private func handleExport(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            transferAlert = TransferAlert(
                title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): performImport(from: url)
        case .failure(let error):
            transferAlert = TransferAlert(
                title: "Import Failed", message: error.localizedDescription)
        }
    }

    /// Reads the picked CSV as text (trying a few encodings, since spreadsheet
    /// exports vary) and hands it to the preview sheet.
    private func handleCSVImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard
                    let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .utf16)
                        ?? String(data: data, encoding: .isoLatin1),
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    transferAlert = TransferAlert(
                        title: "Import Failed",
                        message: String(localized: "The file couldn't be read as text."))
                    return
                }
                csvPayload = CSVPayload(text: text)
            } catch {
                transferAlert = TransferAlert(
                    title: "Import Failed", message: error.localizedDescription)
            }
        case .failure(let error):
            transferAlert = TransferAlert(
                title: "Import Failed", message: error.localizedDescription)
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            LabeledContent("App Name", value: "Worldward")
            LabeledContent("License", value: "MPL 2.0")
            LabeledContent("Author", value: "Smigi")
            Link(
                "Website",
                destination: URL(string: "https://worldward.smigi.net")!)
            Link(
                "Privacy Policy",
                destination: URL(string: "https://worldward.smigi.net/privacy")!)
            Link(
                "GitHub Repository",
                destination: URL(string: "https://github.com/lakafior/Worldward")!)
        } header: {
            Text("About")
        }
    }

    private func startExport() {
        do {
            let data = try TravelDataTransfer.export(from: modelContext)
            exportDocument = JSONDocument(data: data)
            showExporter = true
        } catch {
            transferAlert = TransferAlert(
                title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func startCSVExport() {
        let countries = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
        csvExportDocument = CSVDocument(text: CSVTransfer.export(countries: countries))
        showCSVExporter = true
    }

    private func performImport(from url: URL) {
        // A file returned by the system picker is security-scoped on iOS; bracket
        // the read so we keep access for exactly as long as we need it.
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let count = try TravelDataTransfer.importData(data, into: modelContext)
            transferAlert = TransferAlert(
                title: "Import Complete",
                message: String(localized: "Updated \(count) countries from the backup.")
            )
        } catch {
            transferAlert = TransferAlert(
                title: "Import Failed", message: error.localizedDescription)
        }
    }
}

/// A one-shot alert payload for export/import results.
private struct TransferAlert: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let message: String
}

/// The text of a picked CSV file, wrapped so `sheet(item:)` can present it.
private struct CSVPayload: Identifiable {
    let id = UUID()
    let text: String
}

#Preview {
    SettingsView()
}

#if os(macOS)
    import AppKit

    /// macOS in-app language switching.
    ///
    /// iOS deep-links to the system Settings app (there is no macOS equivalent),
    /// so the Mac gets its own picker. String Catalog strings are resolved from
    /// `Bundle.main` at launch and can't be re-resolved in-process — `\.locale`
    /// only changes number/date *formatting*, not which `.lproj` is read — so
    /// switching language means writing `AppleLanguages` and relaunching.
    enum AppLanguages {
        /// Languages the app actually ships, excluding the "Base" pseudo-locale,
        /// ordered by display name.
        static var shipped: [String] {
            Bundle.main.localizations
                .filter { $0 != "Base" }
                .sorted { displayName(for: $0) < displayName(for: $1) }
        }

        /// The language's name in its own script (autonym), e.g. "Deutsch", "Polski".
        static func displayName(for code: String) -> String {
            let locale = Locale(identifier: code)
            return (locale.localizedString(forIdentifier: code) ?? code).localizedCapitalized
        }

        /// The BCP-47 code currently active for this running process.
        static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

        /// Native, sandbox-safe relaunch: start a fresh instance, then terminate
        /// this one. No shell spawn, so it's allowed under the App Sandbox.
        static func relaunch() {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL, configuration: config
            ) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    /// Settings section to pick the app language and relaunch to apply it.
    struct LanguageSettingsSection: View {
        /// The language live for *this* process; compared against the picker so a
        /// no-op selection (or a settings reset) doesn't spuriously prompt a restart.
        private let launchLanguage = AppLanguages.current
        @State private var selection = AppLanguages.current
        @State private var showRestart = false

        var body: some View {
            Section {
                Picker("Language", selection: $selection) {
                    ForEach(AppLanguages.shipped, id: \.self) { code in
                        Text(AppLanguages.displayName(for: code)).tag(code)
                    }
                }
                .onChange(of: selection) { _, newValue in
                    guard newValue != launchLanguage else { return }
                    UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    showRestart = true
                }
            } header: {
                Text("Language")
            } footer: {
                if selection != launchLanguage {
                    Text("Restart Worldward to finish changing the language.")
                }
            }
            .confirmationDialog(
                "Restart to change language?", isPresented: $showRestart
            ) {
                Button("Restart Now") { AppLanguages.relaunch() }
                Button("Later", role: .cancel) {}
            } message: {
                Text("Worldward needs to restart to switch languages.")
            }
        }
    }
#endif
