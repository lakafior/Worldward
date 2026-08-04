/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftData
import UserNotifications

/// Schedules Worldward's local, on-device travel reminders. Everything here is
/// opt-in: nothing is scheduled unless the user turns reminders on in Settings
/// (`notificationsEnabled`, off by default) and grants notification permission.
///
/// Gentle reminders, all rebuilt from a clean slate on each launch so their
/// content stays current and the app stays well under iOS's 64-pending limit:
///   • "On this day" — anniversaries of past visits (yearly).
///   • Trip start — a nudge 24 hours before an upcoming trip.
///   • Year recap — a single nudge each December.
///   • Inactivity — one prompt if the app goes unopened for a while.
enum NotificationManager {
    /// `@AppStorage` key shared by `SettingsView` and `ContentView`.
    static let enabledKey = "notificationsEnabled"

    /// At most this many "on this day" reminders, so the whole schedule stays
    /// comfortably below the system's 64-pending-notification cap.
    private static let maxOnThisDay = 24

    /// Requests permission to show notifications. Returns whether it was granted.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Removes every pending reminder. Used when the user turns reminders off.
    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Rebuilds the full reminder schedule from the current catalog and trips.
    /// Always clears existing pending requests first, then — only when reminders
    /// are enabled and authorized — schedules the fresh set. Safe to call on
    /// every launch.
    static func reschedule(enabled: Bool, countries: [Country], trips: [Trip] = []) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        guard enabled else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        var requests = onThisDayRequests(countries: countries)
        requests.append(contentsOf: tripStartRequests(trips: trips))
        requests.append(yearRecapRequest())
        requests.append(inactivityRequest())

        // Fire-and-forget: each awaited `add` is a round-trip to the
        // notifications daemon, and ~27 of them in series measurably stalled
        // launch by seconds on iOS. Failures were already swallowed, so hand
        // the whole batch to a background task and return immediately; the
        // single task awaits serially, keeping enqueue order after the
        // removeAll above.
        Task {
            for request in requests {
                try? await center.add(request)
            }
        }
    }

    // MARK: - Builders

    /// One yearly reminder per upcoming visit-anniversary date, nearest first,
    /// capped at `maxOnThisDay`. A single day aggregates every country visited on
    /// it across the years, e.g. "🇯🇵 Japan (2019), 🇫🇷 France (2022)".
    private static func onThisDayRequests(countries: [Country]) -> [UNNotificationRequest] {
        struct Anniversary {
            let flag: String
            let name: String
            let year: Int
        }
        let calendar = Calendar.current

        // Group every recorded visit by its month/day.
        var byDay: [DayKey: [Anniversary]] = [:]
        for country in countries {
            for date in country.allVisitDates {
                let parts = calendar.dateComponents([.month, .day, .year], from: date)
                guard let month = parts.month, let day = parts.day, let year = parts.year
                else { continue }
                byDay[DayKey(month: month, day: day), default: []]
                    .append(Anniversary(flag: country.flagEmoji, name: country.name, year: year))
            }
        }

        let now = Date()
        func nextOccurrence(_ key: DayKey) -> Date {
            calendar.nextDate(
                after: now,
                matching: DateComponents(month: key.month, day: key.day, hour: 9),
                matchingPolicy: .nextTime) ?? now
        }

        return byDay.keys
            .sorted { nextOccurrence($0) < nextOccurrence($1) }
            .prefix(maxOnThisDay)
            .map { key in
                let list = byDay[key]!
                    .sorted { $0.year < $1.year }
                    .map { "\($0.flag) \($0.name) (\($0.year))" }
                    .joined(separator: ", ")

                let content = UNMutableNotificationContent()
                content.title = "On this day ✈️"
                content.body = "You visited \(list)."
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: DateComponents(month: key.month, day: key.day, hour: 9),
                    repeats: true)
                return UNNotificationRequest(
                    identifier: "onthisday-\(key.month)-\(key.day)",
                    content: content, trigger: trigger)
            }
    }

    /// One notification per upcoming trip, firing 24 hours before it starts.
    /// Trips that start within the next 24 hours — or are already in progress —
    /// are skipped so the reminder only arrives when it's actually useful.
    private static func tripStartRequests(trips: [Trip]) -> [UNNotificationRequest] {
        let now = Date()
        // Trips starting within 24 hours can't get a "24 hours before" reminder.
        let fireLimit = now.addingTimeInterval(24 * 3600)

        return
            trips
            .filter { $0.startDate > fireLimit }
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)  // cap to stay well under the 64-pending limit
            .compactMap { trip -> UNNotificationRequest? in
                let fireDate = trip.startDate.addingTimeInterval(-24 * 3600)
                guard fireDate > now else { return nil }

                let flags = trip.flags.isEmpty ? "" : "\(trip.flags) · "
                let name = trip.title.isEmpty ? "Untitled Trip" : trip.title

                let content = UNMutableNotificationContent()
                content.title = "Upcoming trip ✈️"
                content.body = "\(flags)\(name) starts tomorrow — check your packing list!"
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour], from: fireDate),
                    repeats: false)
                return UNNotificationRequest(
                    identifier: "trip-\(trip.dedupID.prefix(8))",
                    content: content, trigger: trigger)
            }
    }

    /// A single nudge on 28 December to revisit the year-in-review.
    private static func yearRecapRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Your year in travel 🌍"
        content.body = "Your travel recap is ready — open Worldward to relive your year."
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(month: 12, day: 28, hour: 10),
            repeats: true)
        return UNNotificationRequest(identifier: "yearrecap", content: content, trigger: trigger)
    }

    /// A one-off prompt 45 days out. Because the whole schedule is rebuilt on every
    /// launch, this keeps moving forward and only fires if the app goes unopened.
    private static func inactivityRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Been a while 🧭"
        content.body = "Mark where you've been or log a recent trip in Worldward."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 45 * 24 * 60 * 60, repeats: false)
        return UNNotificationRequest(identifier: "inactivity", content: content, trigger: trigger)
    }

    /// A hashable month/day key for grouping anniversaries.
    private struct DayKey: Hashable {
        let month: Int
        let day: Int
    }
}
