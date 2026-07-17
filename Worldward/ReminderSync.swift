/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import EventKit
import Foundation
import SwiftData

/// Two-way sync between trips' packing lists and Apple Reminders: one Reminders
/// list per trip, one reminder per packing item. Ticking a reminder (in the
/// Reminders app, via Siri, or on Apple Watch) marks the item packed here;
/// checking, adding, renaming or deleting an item here mirrors to Reminders.
///
/// Representation limits — EventKit exposes neither the Reminders app's
/// sections/groups nor sub-tasks, and reminders have no quantity field — so the
/// mapping degrades deliberately: the container rides in the reminder's notes,
/// the quantity in the title as "×N", and both are parsed back on import.
///
/// The engine is stateless between passes: every trigger (app foreground, a
/// local packing edit, an `EKEventStoreChanged` notification) runs the same
/// reconcile pass, which converges — a pass that changes nothing writes
/// nothing, so notification loops die out on their own.
enum ReminderSync {
    /// `@AppStorage`/`UserDefaults` key for the global on/off toggle.
    static let enabledKey = "remindersSyncEnabled"
    /// Key for how many days after a trip ends its list is removed (0 = keep
    /// the list for as long as the trip exists in the app).
    static let cleanupDaysKey = "remindersCleanupDays"
    /// Key for the registry of list identifiers this app created. Lists in the
    /// registry that no trip references anymore (the trip was deleted, or a
    /// backup import replaced it) are garbage-collected on the next pass.
    private static let createdListsKey = "remindersCreatedListIDs"

    static let cleanupDaysDefault = 7

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var cleanupDays: Int {
        UserDefaults.standard.object(forKey: cleanupDaysKey) as? Int ?? cleanupDaysDefault
    }

    /// Created lazily on the first pass so that users who never enable sync pay
    /// nothing at launch. Kept alive afterwards because only a live store
    /// receives `EKEventStoreChanged` notifications.
    private static var cachedStore: EKEventStore?
    private static var store: EKEventStore {
        if let cachedStore { return cachedStore }
        let store = EKEventStore()
        cachedStore = store
        return store
    }

    private static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// Prompts for full Reminders access (the settings toggle calls this before
    /// flipping on). Full access — not write-only — because two-way sync must
    /// read completion states back.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    // MARK: - Passes

    /// Serializes overlapping triggers: a pass requested while one is running
    /// just queues a rerun instead of interleaving.
    private static var isSyncing = false
    private static var rerunRequested = false

    /// The whole sync: garbage-collects orphaned lists, retires lists of trips
    /// past their cleanup window, then reconciles every remaining trip. Safe to
    /// call from anywhere at any time — it no-ops without the toggle or access.
    static func syncAll(context: ModelContext) async {
        guard isEnabled, hasAccess else { return }
        guard !isSyncing else {
            rerunRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerunRequested = false
            await pass(context: context)
        } while rerunRequested
    }

    /// Turns sync off: removes every list the app created and clears the local
    /// identifiers, leaving all packing data untouched. Flipping the toggle
    /// back on rebuilds the lists from local state.
    static func disable(context: ModelContext) async {
        guard hasAccess else { return }
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        for trip in trips where !trip.reminderListID.isEmpty {
            retireList(of: trip)
        }
        for id in createdListIDs() {
            if let calendar = store.calendar(withIdentifier: id) {
                try? store.removeCalendar(calendar, commit: true)
            }
        }
        setCreatedListIDs([])
    }

    private static func pass(context: ModelContext) async {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let containers = (try? context.fetch(FetchDescriptor<PackingContainer>())) ?? []
        let now = Date()

        // Garbage-collect lists whose trip is gone (deleted, or replaced by a
        // backup import) — the registry remembers what we created.
        let referenced = Set(trips.map(\.reminderListID))
        var registry = createdListIDs()
        registry.removeAll { id in
            guard !referenced.contains(id) else { return false }
            if let calendar = store.calendar(withIdentifier: id) {
                try? store.removeCalendar(calendar, commit: true)
            }
            return true
        }
        setCreatedListIDs(registry)

        for trip in trips {
            guard isEligible(trip, now: now) else {
                // Past its cleanup window (or nothing left to pack): retire the
                // list, keep every local item — lifecycle never erases data.
                retireList(of: trip)
                continue
            }
            await reconcile(trip: trip, containers: containers, context: context)
        }
    }

    /// Whether the trip should have a live Reminders list: it has items to
    /// mirror and hasn't aged past the cleanup window (0 = no window).
    private static func isEligible(_ trip: Trip, now: Date) -> Bool {
        guard !trip.packing.isEmpty else { return false }
        let days = cleanupDays
        guard days > 0 else { return true }
        return trip.endDate.addingTimeInterval(Double(days) * 86_400) >= now
    }

    // MARK: - Per-trip reconcile

    private static func reconcile(
        trip: Trip, containers: [PackingContainer], context: ModelContext
    ) async {
        var calendar =
            trip.reminderListID.isEmpty ? nil : store.calendar(withIdentifier: trip.reminderListID)

        if calendar == nil {
            // No list — either never created, or the user deleted it in
            // Reminders. Stale pairings must be cleared either way, so the
            // rebuild below pushes every item fresh instead of mistaking them
            // all for Reminders-side deletions.
            trip.reminderKnownIDs = ""
            for item in trip.packing {
                item.reminderID = ""
                item.reminderSyncedAt = nil
            }
            guard let created = makeList(for: trip) else { return }
            calendar = created
        }
        guard let calendar else { return }

        // The app owns the list's name; renaming the trip renames the list.
        let expectedListTitle = listTitle(for: trip)
        if calendar.title != expectedListTitle {
            calendar.title = expectedListTitle
            try? store.saveCalendar(calendar, commit: true)
        }

        let reminders = await fetchReminders(in: calendar)
        let remindersByID = Dictionary(
            uniqueKeysWithValues: reminders.map { ($0.calendarItemIdentifier, $0) })
        var knownIDs = Set(trip.reminderKnownIDs.split(separator: ",").map(String.init))
        var pairedIDs = Set<String>()
        var deletedItems: [PackingItem] = []
        var dirtyStore = false

        for item in trip.packing {
            if !item.reminderID.isEmpty, let reminder = remindersByID[item.reminderID] {
                pairedIDs.insert(item.reminderID)
                knownIDs.insert(item.reminderID)
                if syncPaired(item: item, reminder: reminder) { dirtyStore = true }
            } else if !item.reminderID.isEmpty {
                // Its reminder vanished while the list survived — the user
                // deleted it in Reminders, so the item mirrors away.
                knownIDs.remove(item.reminderID)
                deletedItems.append(item)
            } else {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar
                reminder.title = reminderTitle(for: item)
                reminder.notes = item.container?.name
                reminder.isCompleted = item.isPacked
                guard (try? store.save(reminder, commit: false)) != nil else { continue }
                dirtyStore = true
                item.reminderID = reminder.calendarItemIdentifier
                item.reminderSyncedAt = Date()
                pairedIDs.insert(item.reminderID)
                knownIDs.insert(item.reminderID)
            }
        }

        for (id, reminder) in remindersByID where !pairedIDs.contains(id) {
            if knownIDs.contains(id) {
                // We paired this reminder before but its item is gone — the
                // user deleted the item in the app, so the reminder follows.
                try? store.remove(reminder, commit: false)
                dirtyStore = true
                knownIDs.remove(id)
            } else {
                // Never seen: the user added it in the Reminders app — import
                // it, resolving "×N" and a container named in the notes.
                let (title, quantity) = parseReminderTitle(reminder.title ?? "")
                guard !title.isEmpty else { continue }
                let containerName = (reminder.notes ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let container = containers.first {
                    $0.name.compare(containerName, options: .caseInsensitive) == .orderedSame
                }
                let order = (trip.packing.map(\.order).max() ?? -1) + 1
                let item = PackingItem(
                    title: title, isPacked: reminder.isCompleted, quantity: quantity,
                    order: order, trip: trip, container: containerName.isEmpty ? nil : container)
                item.reminderID = id
                item.reminderSyncedAt = Date()
                context.insert(item)
                trip.packing.append(item)
                knownIDs.insert(id)
            }
        }

        for item in deletedItems { context.delete(item) }
        trip.reminderKnownIDs = knownIDs.sorted().joined(separator: ",")
        if dirtyStore { try? store.commit() }
    }

    /// Reconciles one item ↔ reminder pair. Last-writer-wins per side: if the
    /// reminder changed since our last write, its state is pulled first; then
    /// whatever still differs is pushed. Returns whether the store was written.
    private static func syncPaired(item: PackingItem, reminder: EKReminder) -> Bool {
        let syncedAt = item.reminderSyncedAt ?? .distantPast
        var touched = false

        if let modified = reminder.lastModifiedDate, modified > syncedAt {
            if item.isPacked != reminder.isCompleted {
                item.isPacked = reminder.isCompleted
                touched = true
            }
            let (title, quantity) = parseReminderTitle(reminder.title ?? "")
            if !title.isEmpty, title != item.title || quantity != item.quantity {
                item.title = title
                item.quantity = quantity
                touched = true
            }
        }

        var dirty = false
        let expectedTitle = reminderTitle(for: item)
        if reminder.title != expectedTitle {
            reminder.title = expectedTitle
            dirty = true
        }
        if reminder.isCompleted != item.isPacked {
            reminder.isCompleted = item.isPacked
            dirty = true
        }
        let expectedNotes = item.container?.name ?? ""
        if (reminder.notes ?? "") != expectedNotes {
            reminder.notes = expectedNotes.isEmpty ? nil : expectedNotes
            dirty = true
        }
        if dirty {
            try? store.save(reminder, commit: false)
            touched = true
        }
        if touched { item.reminderSyncedAt = Date() }
        return dirty
    }

    // MARK: - Lists

    private static func listTitle(for trip: Trip) -> String {
        let name = trip.title.isEmpty ? String(localized: "Trip") : trip.title
        return "Worldward · \(name)"
    }

    private static func makeList(for trip: Trip) -> EKCalendar? {
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = listTitle(for: trip)
        guard
            let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV })
                ?? store.sources.first(where: { $0.sourceType == .local })
        else { return nil }
        calendar.source = source
        guard (try? store.saveCalendar(calendar, commit: true)) != nil else { return nil }
        trip.reminderListID = calendar.calendarIdentifier
        var registry = createdListIDs()
        registry.append(calendar.calendarIdentifier)
        setCreatedListIDs(registry)
        return calendar
    }

    /// Removes the trip's list from Reminders (if it still exists) and clears
    /// every local pairing. Local packing items are deliberately untouched.
    private static func retireList(of trip: Trip) {
        guard !trip.reminderListID.isEmpty else { return }
        if let calendar = store.calendar(withIdentifier: trip.reminderListID) {
            try? store.removeCalendar(calendar, commit: true)
        }
        var registry = createdListIDs()
        registry.removeAll { $0 == trip.reminderListID }
        setCreatedListIDs(registry)
        trip.reminderListID = ""
        trip.reminderKnownIDs = ""
        for item in trip.packing {
            item.reminderID = ""
            item.reminderSyncedAt = nil
        }
    }

    private static func createdListIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: createdListsKey) ?? []
    }

    private static func setCreatedListIDs(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: createdListsKey)
    }

    /// `EKReminder` predates Sendable and `fetchReminders` calls back on an
    /// arbitrary queue, so the result crosses back to the main actor inside an
    /// `@unchecked Sendable` box. Safe: the array is freshly fetched, unshared,
    /// and only ever touched from the main actor afterwards.
    private struct ReminderBatch: @unchecked Sendable {
        let reminders: [EKReminder]
    }

    private static func fetchReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [calendar])
        let batch = await withCheckedContinuation {
            (continuation: CheckedContinuation<ReminderBatch, Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: ReminderBatch(reminders: reminders ?? []))
            }
        }
        return batch.reminders
    }

    // MARK: - Title mapping

    /// Reminders have no quantity field, so it rides in the title: "Socks ×3".
    /// Mirrors the format `Trip.markdownSummary` already uses.
    private static func reminderTitle(for item: PackingItem) -> String {
        item.quantity > 1 ? "\(item.title) ×\(item.quantity)" : item.title
    }

    /// The inverse of `reminderTitle(for:)` — splits a trailing "×N" off, so
    /// titles typed or edited in the Reminders app round-trip. A title without
    /// the suffix means quantity 1.
    private static func parseReminderTitle(_ raw: String) -> (title: String, quantity: Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: /^(.*?)\s*×\s*(\d+)$/),
            let quantity = Int(match.2), quantity >= 1
        else { return (trimmed, 1) }
        let title = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return (trimmed, 1) }
        return (title, quantity)
    }
}
