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
        let schema = Schema([
            Country.self, Visit.self, Trip.self, ItineraryItem.self, PackingItem.self,
            PackingContainer.self, PackingTemplate.self, PackingTemplateItem.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            // Seeding and reconciliation happen once in `ContentView`, fed by the
            // same bundled geometry file (`countries.wmgb`) that builds the map — so
            // the catalog and the map are always keyed by the same ids.
            return container
        } catch {
            // During development, schema changes can make the existing store incompatible.
            // Remove the old database and create a new clean one.
            let url = modelConfiguration.url
            try? FileManager.default.removeItem(at: url)
            // Try to create the container again after deleting the store
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appTheme.colorScheme)
                .onAppear {
                    // Set up UndoManager on the model context so every change
                    // (status, visit, trip edit) is undoable. SwiftData records
                    // undo actions automatically once the manager is attached.
                    let context = Self.sharedModelContainer.mainContext
                    if context.undoManager == nil {
                        context.undoManager = UndoManager()
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        #if os(macOS)
            // Standard Edit menu with Undo (⌘Z) / Redo (⇧⌘Z).
            .commands {
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") {
                        Self.sharedModelContainer.mainContext.undoManager?.undo()
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(
                        !(Self.sharedModelContainer.mainContext.undoManager?.canUndo ?? false))

                    Button("Redo") {
                        Self.sharedModelContainer.mainContext.undoManager?.redo()
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(
                        !(Self.sharedModelContainer.mainContext.undoManager?.canRedo ?? false))
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

            // Menu bar extra with glanceable stats and quick actions.
            MenuBarExtra {
                let snapshot = WidgetSnapshotStore.read()
                let percent =
                    snapshot.totalCountries > 0
                    ? Int(
                        (Double(snapshot.visitedCountries) / Double(snapshot.totalCountries) * 100)
                            .rounded())
                    : 0

                Text(
                    "\(snapshot.visitedCountries) countries · \(snapshot.visitedContinents) continents · \(percent)%"
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
