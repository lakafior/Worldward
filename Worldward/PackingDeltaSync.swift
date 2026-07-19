/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(WatchConnectivity)

    import SwiftData
    import WatchConnectivity

    /// The instant packing-list channel between iPhone and Apple Watch. CloudKit
    /// is the source of truth for everything; this session exists only because
    /// CloudKit pushes reach the watch slowly (minutes), which would make checking
    /// items off across devices feel broken. Each toggle travels as a tiny
    /// `[dedupID: isPacked]` delta — `sendMessage` when the counterpart is live,
    /// else a queued `transferUserInfo` delivered on the next connection. Applying
    /// is idempotent and mirrors `ContentView.consumePendingPackingToggles`: ids
    /// that no longer resolve are dropped, and CloudKit later converges both
    /// stores on the same values anyway, so a lost or duplicated delta is fine.
    ///
    /// This file is a member of BOTH the iOS app and the watch app targets; on
    /// macOS the whole file compiles away (`WatchConnectivity` doesn't exist there).
    // `@unchecked Sendable` is sound: the class has no stored state — all its
    // static state is `@MainActor`-isolated.
    nonisolated final class PackingDeltaSync: NSObject, WCSessionDelegate, @unchecked Sendable {
        static let shared = PackingDeltaSync()

        /// The store incoming deltas are applied to, set once by each app at launch.
        @MainActor private static var container: ModelContainer?

        private static let payloadKey = "packingToggles"

        /// Wires the session up. Call once at launch, after the container exists.
        @MainActor static func activate(container: ModelContainer) {
            guard WCSession.isSupported() else { return }
            Self.container = container
            WCSession.default.delegate = shared
            WCSession.default.activate()
        }

        /// Ships one toggle to the counterpart device.
        static func send(dedupID: String, isPacked: Bool) {
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            let payload = [payloadKey: [dedupID: isPacked]]
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil)
            } else {
                session.transferUserInfo(payload)
            }
        }

        // MARK: - WCSessionDelegate

        func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: (any Error)?
        ) {}

        func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
            apply(message)
        }

        func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
            apply(userInfo)
        }

        #if os(iOS)
            func sessionDidBecomeInactive(_ session: WCSession) {}

            func sessionDidDeactivate(_ session: WCSession) {
                // The user switched to their other paired watch; activate for it.
                session.activate()
            }
        #endif

        /// Applies received `[dedupID: isPacked]` toggles to the local store.
        /// Fetch-all beats a per-id predicate for lists this small — the same
        /// trade `consumePendingPackingToggles` makes.
        private func apply(_ payload: [String: Any]) {
            guard let toggles = payload[Self.payloadKey] as? [String: Bool], !toggles.isEmpty
            else { return }
            Task { @MainActor in
                guard let context = Self.container?.mainContext else { return }
                let items = (try? context.fetch(FetchDescriptor<PackingItem>())) ?? []
                var changed = false
                for item in items {
                    if let packed = toggles[item.dedupID], item.isPacked != packed {
                        item.isPacked = packed
                        changed = true
                    }
                }
                if changed { try? context.save() }
            }
        }
    }
#endif
