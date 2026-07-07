import EventKit
import Foundation

/// Adds a trip to the user's Apple Calendar via EventKit. Uses write-only access
/// (the app never reads existing events), so it only needs the "write calendars"
/// permission. Entirely optional — the app works without it.
enum CalendarExporter {
    enum Result {
        case added
        case denied
        case failed(String)
    }

    /// Creates an all-day event spanning the trip's dates in the default calendar.
    static func add(trip: Trip) async -> Result {
        let store = EKEventStore()

        // No caching: the system only prompts once and remembers the decision, so
        // this is cheap — and it picks up a grant made in Settings after an
        // earlier denial, which a per-launch cache would miss.
        let granted: Bool
        do {
            granted = try await store.requestWriteOnlyAccessToEvents()
        } catch {
            return .failed(error.localizedDescription)
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
