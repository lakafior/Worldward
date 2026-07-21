/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftData
import SwiftUI

/// The watch companion app: a glanceable window onto upcoming trips — check the
/// packing list off your wrist, see today's itinerary. Data arrives through the
/// same CloudKit private database the iPhone app syncs to; the watch never seeds
/// countries or edits trips. `PackingDeltaSync` layers an instant phone↔watch
/// channel over CloudKit for the one interactive feature, since CloudKit pushes
/// reach the watch too slowly for a check-off to feel live.
@main
struct WorldwardWatch: App {
    /// Unlike the iPhone (where sync is an opt-in Settings toggle), the watch
    /// always attaches CloudKit — without it there is no data source at all.
    /// When CloudKit can't attach (no iCloud account, first-launch race) the
    /// app falls back to an empty local store and the root view's empty state
    /// points the user at the iPhone's sync toggle instead of crashing.
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Country.self, Visit.self, Trip.self, ItineraryItem.self, StopPlace.self,
            PackingItem.self, PackingContainer.self, PackingTemplate.self,
            PackingTemplateItem.self, TripAttachment.self,
        ])
        let cloud = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.net.smigi.worldward"))
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            return container
        }
        let local = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [local]) {
            return container
        }

        // Both attempts failed. Because the two configurations share one store
        // URL, that almost always means the file on disk predates a schema
        // change — so it would keep failing on every launch, and a `fatalError`
        // here would leave the watch app permanently unlaunchable with no user
        // remedy but deleting it. Move the store aside instead (never delete:
        // the phone is the source of truth) and retry, mirroring the iPhone's
        // recovery in `Worldward.sharedModelContainer`. The -wal/-shm sidecars
        // must move too, or the fresh store could replay the old write-ahead log.
        let url = local.url
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            let destination = URL(fileURLWithPath: url.path + ".incompatible-\(stamp)" + suffix)
            try? FileManager.default.moveItem(at: source, to: destination)
        }

        // CloudKit first again: an empty store that re-syncs from the phone is a
        // full recovery, whereas a local one only gets the next delta.
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            return container
        }
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("Failed to create ModelContainer after resetting the store: \(error)")
        }
    }()

    init() {
        PackingDeltaSync.activate(container: Self.sharedModelContainer)
        // A packing toggle arriving from the iPhone should update the watch-face
        // complications too, not just the on-screen list.
        let container = Self.sharedModelContainer
        PackingDeltaSync.onDidApply = { @MainActor in
            WatchComplicationRefresh.run(context: container.mainContext)
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
