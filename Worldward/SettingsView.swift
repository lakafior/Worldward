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
        case .system: String(localized: "System", comment: "Appearance: follow the device setting")
        case .light: String(localized: "Light", comment: "Appearance: always light")
        case .dark: String(localized: "Dark", comment: "Appearance: always dark")
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

/// The escape hatch on every permission-denied alert, wherever one is raised.
/// Telling someone to go to Settings without taking them there leaves them to
/// find the pane themselves; iOS deep-links straight to Worldward's own page,
/// and macOS opens the matching Privacy & Security pane, the closest equivalent.
struct OpenPrivacySettingsButton: View {
    /// The macOS Privacy & Security pane to open — e.g. `Privacy_Calendars`.
    /// Unused on iOS, which has a single per-app page.
    let macPane: String

    var body: some View {
        Button("Open Settings") {
            #if os(macOS)
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?\(macPane)")
                {
                    NSWorkspace.shared.open(url)
                }
            #else
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            #endif
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
    @AppStorage(ReminderSync.enabledKey) private var remindersSyncEnabled = false
    @AppStorage(ReminderSync.cleanupDaysKey) private var remindersCleanupDays =
        ReminderSync.cleanupDaysDefault
    @AppStorage(CalendarSync.enabledKey) private var calendarSyncEnabled = false
    @AppStorage(CalendarSync.cleanupDaysKey) private var calendarCleanupDays =
        CalendarSync.cleanupDaysDefault
    @AppStorage(Worldward.syncEnabledKey) private var iCloudSyncEnabled = true
    @State private var syncStatus = CloudSyncStatus.shared
    @Environment(\.modelContext) private var modelContext

    @State private var exportDocument: JSONDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var csvExportDocument: CSVDocument?
    @State private var showCSVExporter = false
    @State private var showCSVImporter = false
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    @State private var transferAlert: TransferAlert?
    /// A picked backup held between validation and the user confirming the
    /// (irreversible) trip replacement.
    @State private var pendingImport: PendingImport?
    /// Which sheet this screen is presenting, if any. One piece of state and one
    /// `.sheet` rather than a flag and a modifier per destination: SwiftUI honours
    /// only *one* sheet presentation per view, so the three `.sheet` modifiers that
    /// used to be chained here shadowed one another — "Manage Templates" set its
    /// flag and presented nothing at all, leaving templates unreachable.
    @State private var sheet: SettingsSheet?
    @State private var remindersAccessDenied = false
    @State private var calendarAccessDenied = false
    @State private var notificationsAccessDenied = false
    /// In-flight flags for the three permission-gated toggles. Each covers the
    /// whole round trip — permission prompt plus the first sync — so the switch
    /// can't be re-tapped while a sync is mid-write.
    @State private var notificationsBusy = false
    @State private var calendarBusy = false
    @State private var remindersBusy = false
    #if os(macOS)
        /// Lets the File ▸ Import/Export menu commands (see `DataTransferCommands`
        /// in Worldward.swift) trigger the same pickers as the buttons below,
        /// even though those commands live outside this view's hierarchy.
        @State private var intentRouter = IntentRouter.shared
    #endif

    var body: some View {
        settingsContent
        .sheet(item: $sheet) { destination in
            switch destination {
            case .containers: ManageContainersView()
            case .templates: ManageTemplatesView()
            case .csvImport(let text):
                CSVImportView(text: text) { countries, visits in
                    transferAlert = TransferAlert(
                        title: "Import Complete",
                        message: String(
                            localized: "Added \(visits) visits across \(countries) countries.",
                            comment: "Alert after a CSV import")
                    )
                }
            }
        }
        // macOS opens Settings in its own scene, which can outlive (or precede)
        // any main window, so the sync section can't rely on ContentView's copy.
        .background(CloudSyncWatcher())
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            // `defaultFilename` takes a plain String, so the name only gets
            // localized if we resolve it ourselves — the save panel shows it.
            defaultFilename: String(
                localized: "Worldward Backup",
                comment: "The title of the JSON backup file that can be shared."),
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
            defaultFilename: String(
                localized: "Worldward Travel Data",
                comment: "The title of the CSV file that can be shared."),
            onCompletion: handleExport
        )
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
            onCompletion: handleCSVImport
        )
        .confirmationDialog(
            "Import this backup?",
            isPresented: pendingImportIsPresented,
            presenting: pendingImport
        ) { pending in
            // Destructive only when there is actually something to lose; a
            // first-ever restore onto an empty store isn't a scary operation.
            if pending.summary.tripsReplaced > 0 {
                Button("Replace and Import", role: .destructive) { applyImport(pending) }
            } else {
                Button("Import") { applyImport(pending) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.summary.tripsReplaced > 0 {
                Text(
                    "This backup holds \(pending.summary.countries) countries and \(pending.summary.trips) trips. Importing it replaces the \(pending.summary.tripsReplaced) trips already in Worldward, along with their stops and packing lists. This can't be undone."
                )
            } else {
                Text(
                    "This backup holds \(pending.summary.countries) countries and \(pending.summary.trips) trips, and will update the matching countries in Worldward."
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
        #if os(macOS)
            .onChange(of: intentRouter.pendingOpenExportJSON) { consumePendingDataTransferRequests() }
            .onChange(of: intentRouter.pendingOpenExportCSV) { consumePendingDataTransferRequests() }
            .onChange(of: intentRouter.pendingOpenImportJSON) { consumePendingDataTransferRequests() }
            .onChange(of: intentRouter.pendingOpenImportCSV) { consumePendingDataTransferRequests() }
            .onAppear {
                // Cold open: the menu command may have set these before this
                // window existed.
                consumePendingDataTransferRequests()
            }
        #endif
    }

    #if os(macOS)
        /// A Mac Settings window carries its categories in the window's own tab
        /// strip, not in one long scroll — the same shape as System Settings and
        /// every Apple app's preferences. Eleven groups never fit a fixed-size
        /// window: the single `Form` this replaces conceded as much, asking for an
        /// ideal 560pt that its own footers overflowed in a wordier language.
        ///
        /// The grouping follows what a person came here to change, not which
        /// framework backs it: everything that mirrors data into another Apple app
        /// sits together, and everything about copies of the data — iCloud, backup,
        /// CSV — sits together.
        private var settingsContent: some View {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    Form {
                        appearanceSection
                        if AppLanguages.shipped.count > 1 { LanguageSettingsSection() }
                    }
                }
                Tab("Trips", systemImage: "suitcase") {
                    Form {
                        packingSection
                        packingManagementSection
                    }
                }
                Tab("Apple Apps", systemImage: "app.badge") {
                    Form {
                        notificationsSection
                        calendarSection
                        remindersSection
                    }
                }
                Tab("Automation", systemImage: "terminal") {
                    Form { AutomationSettingsSection() }
                }
                Tab("Sync & Data", systemImage: "icloud") {
                    Form {
                        syncSection
                        dataSection
                    }
                }
            }
            .formStyle(.grouped)
            // Fixed, not ideal: a grouped Form is a scroll view with no intrinsic
            // height, so the window has to state one. Sized for the roomiest tab
            // that still reads as a Settings window rather than a document.
            .frame(width: 540, height: 480)
        }
    #else
        private var settingsContent: some View {
            Form {
                appearanceSection
                notificationsSection
                packingSection
                packingManagementSection
                calendarSection
                remindersSection
                syncSection
                dataSection
                aboutSection
            }
            .formStyle(.grouped)
        }
    #endif

    #if os(macOS)
        /// Runs whichever File ▸ Import/Export menu command requested this
        /// window, mirroring the `dataSection` buttons below.
        private func consumePendingDataTransferRequests() {
            if intentRouter.pendingOpenExportJSON {
                intentRouter.pendingOpenExportJSON = false
                startExport()
            }
            if intentRouter.pendingOpenExportCSV {
                intentRouter.pendingOpenExportCSV = false
                startCSVExport()
            }
            if intentRouter.pendingOpenImportJSON {
                intentRouter.pendingOpenImportJSON = false
                showImporter = true
            }
            if intentRouter.pendingOpenImportCSV {
                intentRouter.pendingOpenImportCSV = false
                showCSVImporter = true
            }
        }
    #endif

    @ViewBuilder private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $appTheme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            } label: {
                Label("Theme", systemImage: "paintbrush")
            }

            Picker(selection: $mapStyle) {
                ForEach(MapStyleOption.allCases) { style in
                    Label(style.label, systemImage: style.symbolName).tag(style)
                }
            } label: {
                Label("Map Style", systemImage: "map")
            }

            #if !os(macOS)
                // Deep-links out to the system Settings app, so it carries the
                // same leaving-the-app glyph as the About links.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label("Language", systemImage: "globe")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
            #endif
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        Section {
            Toggle(isOn: Binding(get: { notificationsEnabled }, set: setNotifications)) {
                Label("Travel reminders", systemImage: "bell")
            }
            .disabled(notificationsBusy)
            if notificationsBusy {
                SyncProgressRow(title: "Scheduling…")
            }
        } header: {
            Text("Notifications")
        } footer: {
            // The switch's own off state already says "off by default"; a footer
            // repeating it is a line of prose the reader pays for twice.
            Text(
                "Occasional on-device reminders: “on this day” travel memories, a year-in-review nudge each December, and a gentle prompt if you haven't logged a trip in a while."
            )
        }
        .animation(.snappy, value: notificationsBusy)
        .sensoryFeedback(.success, trigger: notificationsEnabled) { _, on in on }
        .alert("Notifications Off", isPresented: $notificationsAccessDenied) {
            OpenPrivacySettingsButton(macPane: "Privacy_Notifications")
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Turn on notifications for Worldward in the Settings app to receive travel reminders."
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
        // The switch stays off until authorization actually comes back — writing
        // it optimistically made a denial flick the knob on and straight back off.
        notificationsBusy = true
        Task {
            defer { notificationsBusy = false }
            guard await NotificationManager.requestAuthorization() else {
                notificationsEnabled = false
                notificationsAccessDenied = true
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
            Picker(selection: $packingProfile) {
                ForEach(PackingProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            } label: {
                Label("Pack for", systemImage: "suitcase")
            }
            TextField(text: $packingPreferences, prompt: Text("e.g. contact lenses, hiking gear, vegetarian"), axis: .vertical) {
                Label("Preferences", systemImage: "wand.and.stars")
            }
            TextField(text: $sightseeingInterests, prompt: Text("e.g. hiking, street food, traveling with kids"), axis: .vertical) {
                Label("Interests", systemImage: "star")
            }
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
                sheet = .containers
            } label: {
                Label("Manage Containers", systemImage: "bag")
            }
            Button {
                sheet = .templates
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

    @ViewBuilder private var calendarSection: some View {
        Section {
            Toggle(isOn: $calendarSyncEnabled) {
                Label("Sync Trips with Apple Calendar", systemImage: "calendar.badge.checkmark")
            }
            .disabled(calendarBusy)
            .onChange(of: calendarSyncEnabled) { _, enabled in
                calendarBusy = true
                Task {
                    defer { calendarBusy = false }
                    guard enabled else {
                        await CalendarSync.disable(context: modelContext)
                        return
                    }
                    if await CalendarSync.requestAccess() {
                        await CalendarSync.syncAll(context: modelContext)
                    } else {
                        calendarSyncEnabled = false
                        calendarAccessDenied = true
                    }
                }
            }
            if calendarBusy {
                SyncProgressRow(title: "Syncing…")
            }
            if calendarSyncEnabled && !calendarBusy {
                CleanupDaysPicker(selection: $calendarCleanupDays) {
                    Task { await CalendarSync.syncAll(context: modelContext) }
                }
            }
        } header: {
            Text("Apple Calendar")
        } footer: {
            // What it does and what it can't touch. The access requirement lives
            // in the denial alert below, where it's actionable rather than
            // hypothetical, and the per-stop map and weather are self-evident the
            // first time the user opens one of the events.
            Text(
                "Mirrors trips to a dedicated “Worldward” calendar — an event per trip and per dated stop — kept up to date as you edit. Never touches your other calendars; turning it off removes only the Worldward one."
            )
        }
        // The cleanup picker is a consequence of the toggle, so let it slide in
        // rather than materialise — an instant row insert reads as a glitch.
        .animation(.snappy, value: calendarSyncEnabled)
        .animation(.snappy, value: calendarBusy)
        // Only when a sync actually landed: the denial path clears the toggle
        // before this fires, and switching off shouldn't feel like a success.
        .sensoryFeedback(.success, trigger: calendarBusy) { was, now in
            was && !now && calendarSyncEnabled
        }
        .alert("Calendar Access Needed", isPresented: $calendarAccessDenied) {
            OpenPrivacySettingsButton(macPane: "Privacy_Calendars")
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Allow full Calendar access for Worldward in Settings → Privacy & Security → Calendars, then turn sync on again."
            )
        }
    }

    @ViewBuilder private var remindersSection: some View {
        Section {
            Toggle(isOn: $remindersSyncEnabled) {
                Label("Sync with Apple Reminders", systemImage: "checklist")
            }
            .disabled(remindersBusy)
            .onChange(of: remindersSyncEnabled) { _, enabled in
                remindersBusy = true
                Task {
                    defer { remindersBusy = false }
                    guard enabled else {
                        await ReminderSync.disable(context: modelContext)
                        return
                    }
                    if await ReminderSync.requestAccess() {
                        await ReminderSync.syncAll(context: modelContext)
                    } else {
                        remindersSyncEnabled = false
                        remindersAccessDenied = true
                    }
                }
            }
            if remindersBusy {
                SyncProgressRow(title: "Syncing…")
            }
            if remindersSyncEnabled && !remindersBusy {
                CleanupDaysPicker(selection: $remindersCleanupDays) {
                    Task { await ReminderSync.syncAll(context: modelContext) }
                }
            }
        } header: {
            Text("Apple Reminders")
        } footer: {
            Text(
                "Mirrors upcoming trips' packing lists to Reminders, two-way — tick an item off in Reminders, via Siri, or on Apple Watch and it's packed here. Turning it off removes only those Reminders lists."
            )
        }
        .animation(.snappy, value: remindersSyncEnabled)
        .animation(.snappy, value: remindersBusy)
        .sensoryFeedback(.success, trigger: remindersBusy) { was, now in
            was && !now && remindersSyncEnabled
        }
        .alert("Reminders Access Needed", isPresented: $remindersAccessDenied) {
            OpenPrivacySettingsButton(macPane: "Privacy_Reminders")
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Allow Reminders access for Worldward in Settings → Privacy & Security → Reminders, then turn sync on again."
            )
        }
    }

    /// `true` when this launch's model container actually attached CloudKit —
    /// distinct from the toggle, which only takes effect on the next launch or
    /// can fail (build without the iCloud capability, no iCloud account).
    private var iCloudSyncActive: Bool {
        Worldward.sharedModelContainer.configurations.contains {
            $0.cloudKitContainerIdentifier != nil
        }
    }

    /// The iCloud-sync opt-in. The flag is read once at launch, when
    /// `Worldward.sharedModelContainer` is built, so a change applies on the
    /// next launch. The status row keeps the fallback honest: if CloudKit
    /// couldn't attach, the user sees "not active" rather than assuming the
    /// toggle alone means their data is syncing.
    @ViewBuilder private var syncSection: some View {
        Section {
            Toggle(isOn: $iCloudSyncEnabled) {
                Label("Sync with iCloud", systemImage: "icloud")
            }
            if iCloudSyncEnabled {
                Label {
                    Text(
                        iCloudSyncActive
                            ? "iCloud sync is active on this device."
                            : "Sync is not active yet. Relaunch Worldward to apply — if it stays off, check that you're signed in to iCloud on this device."
                    )
                    if let errorDesc = Worldward.cloudKitErrorDescription {
                        Text(errorDesc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: iCloudSyncActive ? "checkmark.icloud" : "exclamationmark.icloud")
                        .foregroundStyle(iCloudSyncActive ? Color.green : Color.orange)
                }
                .font(.callout)
                // Symbol plus two text runs is three VoiceOver stops otherwise.
                .accessibilityElement(children: .combine)

                // Attaching to a container is only half the story: the mirror can
                // attach cleanly and then die on the first export. These two rows
                // report what actually happened, and give the Mac the manual
                // trigger that pull-to-refresh provides on iOS.
                if iCloudSyncActive {
                    LabeledContent("Last synced") {
                        Text(
                            syncStatus.lastSyncDate.map {
                                $0.formatted(date: .abbreviated, time: .shortened)
                            } ?? String(localized: "Never", comment: "iCloud sync has never run"))
                    }
                    if let reason = syncStatus.failureReason {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud rejected the last change.")
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.icloud")
                                .foregroundStyle(Color.orange)
                        }
                        .font(.callout)
                    }
                    Button {
                        Task { await syncStatus.sync(modelContext) }
                    } label: {
                        if syncStatus.isSyncing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Syncing…")
                            }
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled(syncStatus.isSyncing)
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(
                "Keeps your travel data — statuses, visits, trips, packing lists, and attachments — up to date across your devices through your personal iCloud. Takes effect the next time Worldward starts."
            )
        }
        .animation(.snappy, value: iCloudSyncEnabled)
    }

    /// The two transfer flows, kept deliberately separate: the JSON backup is the
    /// app's own full-fidelity format (restore replaces), while CSV is the
    /// outward-facing exchange format for spreadsheets and other trackers
    /// (import only adds).
    @ViewBuilder private var dataSection: some View {
        // Two sections, not one: a Form footer belongs to its own Section, so
        // merging these put both captions under all four buttons with nothing
        // tying either to its pair. The grouping is what carries the meaning.
        Section {
            Button(action: startExport) {
                Label("Export Travel Data…", systemImage: "square.and.arrow.up")
            }
            Button { showImporter = true } label: {
                Label("Import Travel Data…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text(
                "A complete JSON backup — statuses, visits, notes, plans, and trips — for safekeeping or moving between devices. Importing replaces the travel data of every country in the file."
            )
        }

        Section {
            Button(action: startCSVExport) {
                Label("Export CSV…", systemImage: "doc.text")
            }
            Button { showCSVImporter = true } label: {
                Label("Import from CSV…", systemImage: "doc.badge.plus")
            }
        } header: {
            Text("Spreadsheet (CSV)")
        } footer: {
            Text(
                "For spreadsheets and other trackers. Export lists your visited countries and their visits; import only adds, never overwrites."
            )
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { transferAlert != nil },
            set: { if !$0 { transferAlert = nil } }
        )
    }

    private var pendingImportIsPresented: Binding<Bool> {
        Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil } }
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
                sheet = .csvImport(text: text)
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
        // The identity block, matching the macOS About window (`AboutView`):
        // the app's own name and version are a header, not key-value trivia.
        Section {
            VStack(spacing: 4) {
                Text("Worldward")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(versionString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        }

        Section {
            LabeledContent {
                Text("MPL 2.0")
            } label: {
                Label("License", systemImage: "doc.plaintext")
            }
            LabeledContent {
                Text("Smigi")
            } label: {
                Label("Author", systemImage: "person")
            }
            ExternalLinkRow(
                title: "Website",
                systemImage: "globe",
                destination: URL(string: "https://worldward.smigi.net")!)
            ExternalLinkRow(
                title: "Privacy Policy",
                systemImage: "hand.raised",
                destination: URL(string: "https://worldward.smigi.net/privacy")!)
            ExternalLinkRow(
                title: "GitHub Repository",
                systemImage: "chevron.left.forwardslash.chevron.right",
                destination: URL(string: "https://github.com/lakafior/Worldward")!)
        } header: {
            Text("About")
        }
    }

    private func startExport() {
        Task {
            do {
                let data = try await TravelDataTransfer.export(from: modelContext)
                exportDocument = JSONDocument(data: data)
                showExporter = true
            } catch {
                transferAlert = TransferAlert(
                    title: "Export Failed", message: error.localizedDescription)
            }
        }
    }

    private func startCSVExport() {
        let countries = (try? modelContext.fetch(FetchDescriptor<Country>())) ?? []
        csvExportDocument = CSVDocument(text: CSVTransfer.export(countries: countries))
        showCSVExporter = true
    }

    /// Reads and validates the picked backup, then hands it to the confirmation
    /// step. Nothing is written here: a restore deletes every existing trip, so
    /// the one irreversible flow in the app doesn't fire straight off a file
    /// picker where a mis-tap costs the user their trips.
    private func performImport(from url: URL) {
        Task {
            do {
                // Read + decode off the main actor (it brackets the picker's
                // security-scoped access itself); only the store count is here.
                let file = try await TravelDataTransfer.decode(contentsOf: url)
                pendingImport = PendingImport(
                    file: file,
                    summary: try TravelDataTransfer.summarize(file, in: modelContext))
            } catch {
                transferAlert = TransferAlert(
                    title: "Import Failed", message: error.localizedDescription)
            }
        }
    }

    /// Applies a backup the user has confirmed. The file was already decoded for
    /// the summary, so a failure here is a write failure, not a bad file.
    private func applyImport(_ pending: PendingImport) {
        do {
            let count = try TravelDataTransfer.importData(pending.file, into: modelContext)
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

/// A row that opens something outside Worldward. The trailing glyph is the
/// standard signal that the tap leaves the app for a browser — without it the
/// row is indistinguishable from a push into another screen.
private struct ExternalLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            // Without this the hit area is only the label, not the full row.
            .contentShape(.rect)
        }
    }
}

/// The inline "working" row shown while a permission request or sync is in
/// flight. It lives in the section the user just acted in, so the feedback is
/// where their attention already is rather than in a modal.
private struct SyncProgressRow: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// How long a synced trip's events or reminders outlive the trip itself.
/// Shared by the Calendar and Reminders sections, which differ only in which
/// service they re-sync once the choice changes.
private struct CleanupDaysPicker: View {
    @Binding var selection: Int
    /// Re-runs the owning service's sync so the new window applies immediately.
    let resync: () -> Void

    var body: some View {
        Picker(selection: $selection) {
            Text("Never (keep with trip)").tag(0)
            ForEach([1, 3, 7, 14, 30], id: \.self) { days in
                Text("^[\(days) day](inflect: true)").tag(days)
            }
        } label: {
            Label("Remove after trip ends", systemImage: "clock.badge.xmark")
        }
        .onChange(of: selection) { resync() }
    }
}

/// A validated backup waiting for the user's go-ahead, with the counts the
/// confirmation quotes back to them.
private struct PendingImport: Identifiable {
    let id = UUID()
    let file: TravelDataFile
    let summary: TravelDataTransfer.ImportSummary
}

/// A one-shot alert payload for export/import results.
private struct TransferAlert: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let message: String
}

/// Everything Settings can present as a sheet, in one type so the screen needs a
/// single `.sheet(item:)`. Chaining one `.sheet` per destination silently drops
/// all but one of them — SwiftUI honours only one sheet presentation per view.
///
/// `id` is a fresh UUID per value rather than the case name: a CSV import must
/// re-present even when the same file is picked twice in a row, and identity is
/// what `sheet(item:)` keys on.
private enum SettingsSheet: Identifiable {
    case containers
    case templates
    case csvImport(text: String)

    var id: String {
        switch self {
        case .containers: "containers"
        case .templates: "templates"
        // Distinct per payload so picking a second file re-presents the preview.
        case .csvImport(let text): "csv-\(text.hashValue)"
        }
    }
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

    /// Settings section for the local MCP server — the one place Worldward can be
    /// driven from outside.
    ///
    /// Everything is behind a switch that starts off, and the section only ever
    /// shows what the user needs to act on: whether it's listening, whether an
    /// assistant may change anything, and the command or JSON snippet that
    /// connects a client.
    /// The token is never displayed — it's copied as part of that command or
    /// snippet, so there's nothing on screen to shoulder-surf or leak into a
    /// screenshot.
    struct AutomationSettingsSection: View {
        @AppStorage(MCPServer.enabledKey) private var serverEnabled = false
        @AppStorage(MCPServer.writesAllowedKey) private var writesAllowed = true
        @AppStorage(MCPServer.deletionsAllowedKey) private var deletionsAllowed = false
        @AppStorage(MCPServer.personalAllowedKey) private var personalAllowed = false
        @AppStorage(MCPServer.portKey) private var port = MCPServer.defaultPort
        @State private var server = MCPServer.shared
        @State private var selectedClient = MCPClient.claudeDesktop
        @State private var didCopy = false
        @State private var didCopyJSON = false

        var body: some View {
            Section {
                Toggle(isOn: $serverEnabled) {
                    Label("Local Automation Server", systemImage: "terminal")
                }

                if serverEnabled {
                    statusRow

                    // Three switches, not one per tool: these are the questions a
                    // person can actually answer about their own data. Deletions
                    // are their own because nothing in the app can undo one, and
                    // personal details are their own because phone numbers and
                    // document names are a different kind of disclosure from
                    // "which countries have I been to".
                    Toggle(isOn: $writesAllowed) {
                        Label("Allow Changes", systemImage: "square.and.pencil")
                    }

                    Toggle(isOn: $deletionsAllowed) {
                        Label("Allow Deletions", systemImage: "trash")
                    }
                    .disabled(!writesAllowed)

                    Toggle(isOn: $personalAllowed) {
                        Label("Share Personal Details", systemImage: "person.text.rectangle")
                    }

                    LabeledContent("Port") {
                        TextField(
                            "Port", value: $port,
                            format: .number.grouping(.never)
                        )
                        .labelsHidden()
                        .frame(width: 80)
                        #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                        #endif
                    }

                    Picker("Client", selection: $selectedClient) {
                        ForEach(MCPClient.allCases) { client in
                            Text(client.displayName).tag(client)
                        }
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            server.setupJSON(for: selectedClient), forType: .string)
                        didCopyJSON = true
                    } label: {
                        Label(
                            didCopyJSON ? "Copied" : "Copy JSON Config",
                            systemImage: didCopyJSON ? "checkmark" : "curlybraces")
                    }
                    .disabled(!server.state.isRunning)

                    LabeledContent("Config file") {
                        Text(selectedClient.configFile)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.setupCommand, forType: .string)
                        didCopy = true
                    } label: {
                        Label(
                            didCopy ? "Copied" : "Copy Setup Command",
                            systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(!server.state.isRunning)

                    Button {
                        server.regenerateToken()
                        didCopy = false
                        didCopyJSON = false
                    } label: {
                        Label("Reset Access Token", systemImage: "key")
                    }
                }
            } header: {
                Text("Automation")
            } footer: {
                Text(
                    "Lets an AI assistant running on this Mac read your travel data and plan trips into Worldward, through a server that only accepts connections from this computer. Worldward never sends anything out by itself — but whatever you connect can see the data you ask it about, and if that assistant runs in the cloud, what it reads leaves your Mac. Leave this off unless you're using it.\n\nAllow Changes lets it edit your trips; Allow Deletions lets it remove them, which nothing can undo. Share Personal Details covers your contacts, the names of files you've attached, and the packing profile from Settings — planning works fine without it."
                )
            }
            .animation(.snappy, value: serverEnabled)
            .animation(.snappy, value: writesAllowed)
            .onChange(of: serverEnabled) { server.applyPreference() }
            // A new port means a new socket and a new setup command, so the copy
            // buttons' "Copied" ticks have to stop claiming otherwise.
            .onChange(of: port) {
                didCopy = false
                didCopyJSON = false
                if serverEnabled { server.start() }
            }
            .onChange(of: selectedClient) { didCopyJSON = false }
        }

        @ViewBuilder private var statusRow: some View {
            Label {
                switch server.state {
                case .running(let port):
                    Text("Listening on 127.0.0.1, port \(Int(port)).")
                case .failed(let message):
                    Text(message)
                case .stopped:
                    Text("Not listening yet.")
                }
            } icon: {
                Image(systemName: server.state.isRunning ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(server.state.isRunning ? Color.green : Color.orange)
            }
            .font(.callout)
            // Symbol plus text is two VoiceOver stops otherwise.
            .accessibilityElement(children: .combine)
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
                Picker(selection: $selection) {
                    ForEach(AppLanguages.shipped, id: \.self) { code in
                        Text(AppLanguages.displayName(for: code)).tag(code)
                    }
                } label: {
                    Label("Language", systemImage: "globe")
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
            .animation(.snappy, value: selection)
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
