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
    @Environment(\.modelContext) private var modelContext

    @State private var exportDocument: JSONDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var transferAlert: TransferAlert?

    var body: some View {
        Form {
            appearanceSection
            notificationsSection
            dataSection
            aboutSection
        }
        .formStyle(.grouped)
        #if os(macOS)
            .frame(width: 460, height: 440)
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

    @ViewBuilder private var dataSection: some View {
        Section {
            Button("Export Travel Data…", action: startExport)
            Button("Import Travel Data…") { showImporter = true }
        } header: {
            Text("Data")
        } footer: {
            Text(
                "Export saves your country statuses and visits to a JSON file. Importing matches that file to your countries and replaces their travel data."
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

    @ViewBuilder private var aboutSection: some View {
        Section {
            LabeledContent("App Name", value: "Worldward")
            LabeledContent("License", value: "GPL 3.0")
            LabeledContent("Author", value: "Smigi")
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

#Preview {
    SettingsView()
}
