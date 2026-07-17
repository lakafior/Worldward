/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftData
import SwiftUI

@main
struct Worldward: App {
    /// The user's appearance choice, shared with `SettingsView` via the same key.
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    /// Identifier for the CloudKit container that would back iCloud sync. Sync is
    /// not enabled yet: it needs a paid Apple Developer Program membership (the
    /// current free Personal team can't provision iCloud/Push). The schema is
    /// already CloudKit-compatible — to turn sync on later, add the iCloud + Push
    /// capabilities and pass `cloudKitDatabase: .private(cloudKitContainerID)` to
    /// the `ModelConfiguration` below. Local JSON export/import is the backup path
    /// in the meantime.
    static let cloudKitContainerID = "iCloud.net.smigi.worldward"

    static let sharedModelContainer: ModelContainer = {
        LaunchClock.mark("model container: creating")
        let schema = Schema([
            Country.self, Visit.self, Trip.self, ItineraryItem.self, StopPlace.self,
            PackingItem.self, PackingContainer.self, PackingTemplate.self,
            PackingTemplateItem.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            // Seeding and reconciliation happen once in `ContentView`, fed by the
            // same bundled geometry file (`countries.wmgb`) that builds the map — so
            // the catalog and the map are always keyed by the same ids.
            LaunchClock.mark("model container: ready")
            return container
        } catch {
            // The store couldn't be opened — usually a dev-time schema change, but
            // this can also be a transient failure (disk full, file protection).
            // Move the store aside — never delete user data — and start fresh. The
            // -wal/-shm sidecars must move too, or the new store could replay the
            // old write-ahead log.
            let url = modelConfiguration.url
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                let destination = URL(fileURLWithPath: url.path + ".incompatible-\(stamp)" + suffix)
                try? FileManager.default.moveItem(at: source, to: destination)
            }
            if let newContainer = try? ModelContainer(
                for: schema, configurations: [modelConfiguration])
            {
                return newContainer
            }
            fatalError("Failed to create ModelContainer after resetting the store: \(error)")
        }
    }()

    /// Several Natural Earth records ship a `-99` ISO code instead of a real one.
    /// These fallbacks restore the proper ISO 3166-1 alpha-2 id so the country
    /// gets a flag, a map polygon, and a working tap target. Shared with
    /// `ContentView.loadGeoJSON` so both sides key everything by the same id.
    nonisolated static let isoFallbacks: [String: String] = [
        "France": "FR",
        "Norway": "NO",
        "Kosovo": "XK",
        "Indian Ocean Territories": "IO",
        "Clipperton Island": "CP",
    ]

    /// The usable id for a GeoJSON feature, or `nil` for records that should be
    /// dropped. A normal feature keys on its ISO alpha-2 value. A `-99` placeholder
    /// keys on its fallback if it has one (France, Norway, Kosovo…); otherwise it's
    /// a non-country the dataset ships with `-99` and no real code — a reef,
    /// military base, glacier or disputed zone — and is filtered out so it can't
    /// clutter the list or skew the statistics.
    nonisolated static func resolvedID(isoA2: String, name: String) -> String? {
        guard isoA2 == "-99" else { return isoA2 }
        return isoFallbacks[name]
    }

    /// Whether the store holds ids written by an older build that can't match a
    /// flag or polygon — a raw `-99` placeholder, or a country name used as the id
    /// (e.g. France saved as "France" instead of "FR"). When true, `ContentView`
    /// wipes and re-seeds. The check converges: once re-seeded the ids match and it
    /// stops firing, while records legitimately keyed by name are left alone.
    nonisolated static func hasStaleIDs(_ countries: [Country]) -> Bool {
        countries.contains { country in
            if let expected = isoFallbacks[country.name] { return country.id != expected }
            return country.id == "-99"
        }
    }

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appTheme.colorScheme)
                .onAppear {
                    // UndoManager is intentionally omitted: a SwiftData runtime bug
                    // (FB13659086) crashes with "A snapshot should exist before
                    // creating a new snapshot for undo" when the manager is attached
                    // and rapid changes occur. Remove this comment block once the
                    // framework issue is resolved in a future OS release.
                }
        }
        .modelContainer(Self.sharedModelContainer)
        // Undo/Redo commands are omitted alongside the UndoManager (see .onAppear).
        #if os(macOS)
            // Open at a comfortable desktop size, and let the window grow freely
            // while keeping the split view's own minimum.
            .defaultSize(width: 1180, height: 760)
            .windowResizability(.contentMinSize)
            // Surface the in-window destinations (and their ⌘-shortcuts) in a "Go" menu,
            // mirror the map toolbar's remaining actions into the menu bar, and
            // replace the generic About panel with our custom window.
            .commands {
                WorldwardCommands()
                AddCommands()
                MapFilterCommands()
                DataTransferCommands()
                CommandGroup(replacing: .appInfo) {
                    Button("About Worldward") {
                        openWindow(id: "about")
                    }
                }
            }
        #endif

        #if os(macOS)
            // Adds the standard "Worldward ▸ Settings…" menu item (⌘,). The Settings
            // scene is separate from the WindowGroup, so it needs the same model
            // container attached for export/import to read and write the store.
            Settings {
                SettingsView()
            }
            .modelContainer(Self.sharedModelContainer)

            // Custom About window, opened from the app menu instead of the default panel.
            Window("About Worldward", id: "about") {
                AboutView()
            }
            .windowResizability(.contentSize)

            // Menu bar extra with glanceable stats and quick actions.
            MenuBarExtra {
                let snapshot = WidgetSnapshotStore.read()
                let fraction =
                    snapshot.totalCountries > 0
                    ? Double(snapshot.visitedCountries) / Double(snapshot.totalCountries)
                    : 0.0

                Text(
                    "\(snapshot.visitedCountries) countries · \(snapshot.visitedContinents) continents · \(fraction.formatted(.percent))"
                )
                .font(.subheadline)
                .padding(.horizontal, 8)

                Divider()

                Button("Open Worldward") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("1")

                Button("Mark Current Location…") {
                    WidgetActionStore.requestMarkHere()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button("Quit Worldward") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Label("Worldward", systemImage: "globe")
            }
        #endif
    }
}

#if os(macOS)
    /// A "Go" menu exposing the main window's in-window destinations as
    /// first-class Mac commands with keyboard shortcuts. Everything stays in the
    /// main window — these push over the map rather than opening new windows.
    struct WorldwardCommands: Commands {
        /// The main window's navigation stack, published by `ContentView` via
        /// `focusedSceneValue`. `nil` when no main window has focus.
        @FocusedBinding(\.macDestinations) private var destinations: [MacDestination]?

        var body: some Commands {
            CommandMenu("Go") {
                Button("Your Travels") { go(.travels) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(destinations == nil)
                Button("Ask About Your Travels") { go(.chat) }
                    .keyboardShortcut("4", modifiers: .command)
                    .disabled(destinations == nil)
            }
        }

        /// Navigates the main window to `destination`, replacing whatever was
        /// pushed; a no-op when it's already on top.
        private func go(_ destination: MacDestination) {
            guard destinations?.last != destination else { return }
            destinations = [destination]
        }
    }

    /// Mirrors the map toolbar's "+" menu (see `ContentView`) as a top-level
    /// "Add" menu. Every item works even with no main window key: Current
    /// Location reuses the widget-style request the menu bar extra already
    /// makes, and Photos/Description hand off through `IntentRouter` the same
    /// way an App Intent would, so the app activates and opens a window itself.
    struct AddCommands: Commands {
        var body: some Commands {
            CommandMenu("Add") {
                Button("From Current Location") {
                    WidgetActionStore.requestMarkHere()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("From Photos…") {
                    IntentRouter.shared.pendingOpenPhotoImporter = true
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("From Description…") {
                    IntentRouter.shared.pendingLogVisitsText = ""
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    /// Mirrors the map toolbar's filter picker as a "View ▸ Filter" submenu,
    /// the HIG-standard home for display/filter toggles. Disabled when no main
    /// window is key, since the filter has no meaning without a map to apply to.
    struct MapFilterCommands: Commands {
        @FocusedBinding(\.mapFilter) private var mapFilter: MapFilter?

        var body: some Commands {
            CommandGroup(after: .toolbar) {
                Menu("Filter") {
                    ForEach(MapFilter.allCases) { filter in
                        Button {
                            mapFilter = filter
                        } label: {
                            if mapFilter == filter {
                                Label(filter.label, systemImage: "checkmark")
                            } else {
                                Text(filter.label)
                            }
                        }
                    }
                }
                .disabled(mapFilter == nil)
            }
        }
    }

    /// Mirrors Settings' Backup/CSV actions (see `SettingsView.dataSection`) as
    /// File ▸ Import/Export submenus. Each item opens the Settings window and
    /// hands off through `IntentRouter`, the same cold-launch-safe mechanism an
    /// App Intent uses, so the picker opens whether or not Settings was already
    /// showing.
    struct DataTransferCommands: Commands {
        @Environment(\.openSettings) private var openSettings

        var body: some Commands {
            CommandGroup(after: .importExport) {
                Menu("Import") {
                    Button("Travel Data (JSON)…") {
                        IntentRouter.shared.pendingOpenImportJSON = true
                        openSettings()
                    }
                    Button("CSV…") {
                        IntentRouter.shared.pendingOpenImportCSV = true
                        openSettings()
                    }
                }
                Menu("Export") {
                    Button("Travel Data (JSON)…") {
                        IntentRouter.shared.pendingOpenExportJSON = true
                        openSettings()
                    }
                    Button("CSV…") {
                        IntentRouter.shared.pendingOpenExportCSV = true
                        openSettings()
                    }
                }
            }
        }
    }
#endif
