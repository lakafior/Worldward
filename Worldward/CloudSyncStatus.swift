/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CloudKit
import CoreData
import SwiftData
import SwiftUI

/// Live state of the CloudKit mirror behind the SwiftData store.
///
/// SwiftData syncs silently: when `NSPersistentCloudKitContainer` hits a *fatal*
/// export error — a field or record type the Production schema doesn't have yet —
/// it resets the mirroring delegate and then refuses every later request with
/// "Never successfully initialized". Nothing surfaces in the UI, the store keeps
/// saving locally, and the device simply stops syncing until the next launch. The
/// only public signal is `eventChangedNotification`, so this object listens for it
/// and keeps the result somewhere the UI can show it.
///
/// The last failure is mirrored into `UserDefaults` because the interesting
/// errors happen seconds after launch, long before anyone opens Settings.
@MainActor @Observable
final class CloudSyncStatus {
    static let shared = CloudSyncStatus()

    /// A manual sync is in flight (pull-to-refresh, or Settings ▸ Sync Now).
    private(set) var isSyncing = false
    /// When CloudKit last completed an import or export without an error.
    private(set) var lastSyncDate: Date?
    /// The most specific message from the last failure, or `nil` while healthy.
    /// Survives relaunches so a launch-time failure is still visible later.
    private(set) var failureReason: String?

    /// Whether the container attached to CloudKit at all. `false` means the
    /// user turned sync off, or `ModelContainer` fell back to the local store.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Worldward.syncEnabledKey) as? Bool ?? true
    }

    private static let lastSyncKey = "cloudSyncLastSuccess"
    private static let failureKey = "cloudSyncLastFailure"

    /// Continuations waiting on `sync(_:)`, resumed by the next finished event.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        failureReason = UserDefaults.standard.string(forKey: Self.failureKey)
    }

    /// Folds one `NSPersistentCloudKitContainer` event into the published state.
    /// Only finished events (`endDate != nil`) count — an in-flight event says
    /// nothing about whether the round trip worked.
    func apply(_ notification: Notification) {
        guard
            let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
            event.endDate != nil
        else { return }

        if event.succeeded {
            // A successful setup on its own proves nothing moved yet, so only
            // real imports and exports refresh the timestamp.
            if event.type != .setup {
                lastSyncDate = event.endDate
                UserDefaults.standard.set(event.endDate, forKey: Self.lastSyncKey)
            }
            failureReason = nil
            UserDefaults.standard.removeObject(forKey: Self.failureKey)
        } else if let error = event.error {
            let reason = Self.describe(error)
            failureReason = reason
            UserDefaults.standard.set(reason, forKey: Self.failureKey)
        }

        resumeWaiters()
    }

    /// Flushes pending edits and waits for CloudKit to report back.
    ///
    /// There is no public "sync now" API: saving is what enqueues an export, and
    /// the scheduler decides when to run it. So this saves, then waits for the
    /// next finished event — up to `timeout`. The wait is the honest part: when
    /// the mirror is dead no event ever arrives, the timeout expires, and the
    /// caller is left looking at `failureReason` instead of a spinner that
    /// pretended to work.
    func sync(_ context: ModelContext, timeout: Duration = .seconds(8)) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        if context.hasChanges { try? context.save() }

        guard isEnabled else { return }

        let settled = Task { @MainActor in
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            resumeWaiters()
        }
        await settled.value
        deadline.cancel()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    /// The most useful sentence we can pull out of a CloudKit error.
    ///
    /// A schema mismatch arrives as a `CKError.partialFailure` whose top-level
    /// description is the useless "Failed to modify some records"; the sentence
    /// that names the offending field ("Cannot create or modify field
    /// 'CD_dedupID' in record 'CD_Visit' in production schema") is buried one
    /// level down in `partialErrorsByItemID`. Dig it out — that string is the
    /// difference between "sync is broken" and knowing which schema to deploy.
    nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let partials = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            // Every record in the batch after the first fails with a generic
            // "Batch Request Failed"; the first real reason is the one to show.
            for case let underlying as NSError in partials.values
            where underlying.code != CKError.batchRequestFailed.rawValue {
                return underlying.localizedDescription
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let inner = describe(underlying)
            if !inner.isEmpty { return inner }
        }
        return nsError.localizedDescription
    }
}

/// An invisible view that pipes CloudKit's sync events into `CloudSyncStatus`.
///
/// A view rather than an observer set up in `Worldward.init()`: `.onReceive` is
/// the one notification path already proven under this project's strict
/// concurrency settings, and dropping this next to `StoreWatchers` costs nothing.
/// Safe to place in more than one scene — it only forwards.
struct CloudSyncWatcher: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSPersistentCloudKitContainer.eventChangedNotification)
            ) { notification in
                CloudSyncStatus.shared.apply(notification)
            }
    }
}

extension View {
    /// Pull-to-refresh that asks CloudKit to catch up.
    ///
    /// On iOS this is the gesture people already reach for when a list looks
    /// stale. On macOS `.refreshable` has no pull gesture, so the Mac's entry
    /// point is Settings ▸ iCloud ▸ Sync Now instead — same call underneath.
    func syncRefreshable(_ context: ModelContext) -> some View {
        refreshable {
            await CloudSyncStatus.shared.sync(context)
        }
    }
}
