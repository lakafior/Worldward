import EventKit
import Foundation

/// Adds a trip to the user's Apple Calendar via EventKit. Uses write-only access
/// (the app never reads existing events), so it only needs the "write calendars"
/// permission. Entirely optional — the app works without it.
///
/// Authorization status is cached after the first request so subsequent calls
/// don't prompt the user again within the same app launch.
enum CalendarExporter {
    enum Result {
        case added
        case denied
        case failed(String)
    }

    /// Cached authorization status after the first `requestWriteOnlyAccessToEvents` call.
    /// `nil` means we haven't asked yet.
    private static var cachedGranted: Bool?

    /// Creates an all-day event spanning the trip's dates in the default calendar.
    static func add(trip: Trip) async -> Result {
        let store = EKEventStore()

        // Use cached status if available; otherwise request and cache it.
        let granted: Bool
        if let cached = cachedGranted {
            granted = cached
        } else {
            do {
                granted = try await store.requestWriteOnlyAccessToEvents()
                cachedGranted = granted
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        guard granted else { return .denied }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failed("No default calendar is available.")
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = trip.title.isEmpty ? "Trip" : trip.title
        event.isAllDay = true
        event.startDate = trip.startDate
        event.endDate = trip.endDate

        let countryLine = trip.countries.map(\.name).joined(separator: ", ")
        event.notes =
            [countryLine, trip.notes]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        do {
            try store.save(event, span: .thisEvent)
            return .added
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
