/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - Shared localized strings
//
// NOT a catalog of every string in the app — most live inline as `Text("…")`
// or `String(localized:)` at their point of use, and Xcode harvests those into
// `Localizable.xcstrings` on every build. This enum is only for strings that
// are genuinely *shared*: reused across several views, needed off the main
// actor by the exporters, or needed by the watch target.
//
// If a string has exactly one call site, write it inline there instead of
// adding it here. Entries that lose their last call site should be deleted —
// the translation is not lost as long as the same literal appears somewhere
// else, since the catalog is keyed by the string itself.

/// `nonisolated` so the exporters (`Trip.markdown(options:)`, `TripPDFRenderer`),
/// which run outside the main actor, can reuse these strings. Safe: every
/// member is an immutable `String`.
nonisolated enum Str {
    // MARK: - Tab bar
    enum Tab {
        static let been = String(localized: "Been", comment: "Tab bar: visited countries list")
        static let going = String(localized: "Going", comment: "Tab bar: trips and wishlist")
    }

    // MARK: - Map
    enum Map {
        static let filterAll = String(localized: "All", comment: "Map filter chip: show all")
        static let filterVisited = String(
            localized: "Visited", comment: "Map filter chip: visited only")
        static let filterPlanning = String(
            localized: "Planning", comment: "Map filter chip: planning only")
    }

    // MARK: - Country list
    enum List {
        static let searchPlaceholder = String(
            localized: "Search countries", comment: "List search field placeholder")
        static let emptyBeen = String(
            localized: "No countries yet", comment: "Empty state: no visited countries")
        static let emptyGoing = String(
            localized: "Nothing planned yet", comment: "Empty state: no planned countries")
        static let addButton = String(
            localized: "Add Country", comment: "Toolbar button to quick-add a country")
        static let sortName = String(
            localized: "Name", comment: "Sort option: alphabetical by name")
        static let sortRecent = String(
            localized: "Recently visited", comment: "Sort option: by most recent visit")
        static let sortLabel = String(
            localized: "Sort", comment: "Sort picker label")
        static let sortFilterLabel = String(
            localized: "Sort & Filter", comment: "Toolbar button: open sort/filter menu")
        static let continentSection = String(
            localized: "Continent", comment: "Filter section heading")
        static let continentAll = String(
            localized: "All", comment: "Filter option: show all continents")
        static let visitYearSection = String(
            localized: "Visit year", comment: "Filter section heading for visit years")
        static let visitYearAll = String(
            localized: "All years", comment: "Filter option: show all years")
    }

    // MARK: - Trips
    //
    // The label strings below are also read by the Markdown and PDF exporters,
    // which run off the main actor — hence the `nonisolated` enum above.
    enum Trip {
        static let tabTrips = String(localized: "Trips", comment: "Segmented control tab")
        static let tabWishlist = String(localized: "Wishlist", comment: "Segmented control tab")
        static let tabSuggestions = String(localized: "Suggestions", comment: "Segmented control tab")
        static let packing = String(
            localized: "Packing", comment: "Section header for packing list")
        static let itineraryLabel = String(
            localized: "Itinerary", comment: "Section header for trip itinerary")
        static let notesLabel = String(localized: "Notes", comment: "Section header for trip notes")
        static let attachmentsLabel = String(
            localized: "Attachments", comment: "Section header for trip attachments in exports")
        static let linksLabel = String(
            localized: "Links", comment: "Section header for trip links in exports")
        static let contactsLabel = String(
            localized: "Contacts", comment: "Section header for trip contacts in exports")
        static let untitled = String(
            localized: "Untitled Trip",
            comment: "Fallback trip title in Markdown/PDF exports when the trip has no name")
        static let packingOther = String(
            localized: "Other",
            comment: "Packing group heading for items not filed into any bag/container")
    }

    // MARK: - Watch app
    //
    // Used only by the WorldwardWatch / WorldwardWatchWidgets targets. Periphery
    // indexes the iOS targets only, so it reports every member here as unused.
    enum Watch {
        static let emptyTitle = String(
            localized: "No Upcoming Trips", comment: "Watch empty state title")
        static let emptyMessage = String(
            localized: "Plan a trip in Worldward on your iPhone and turn on iCloud sync — it will appear here.",
            comment: "Watch empty state message shown when no trips have synced yet")
        static let today = String(
            localized: "Today",
            comment: "Watch: label replacing the date on an itinerary stop happening today")
        static let now = String(
            localized: "Now", comment: "Watch tab: the at-a-glance page")
        static let upcoming = String(
            localized: "Upcoming", comment: "Watch: section header for trips that haven't ended")
        static let past = String(
            localized: "Past", comment: "Watch: section header for trips that already ended")
        static let underway = String(
            localized: "Underway", comment: "Watch: badge on a trip that has already started")
        static let recent = String(
            localized: "Recent", comment: "Watch: section header for the latest logged visits")
        static let countries = String(
            localized: "Countries", comment: "Watch: label under the visited-country count")
        static let continents = String(
            localized: "Continents", comment: "Watch: label under the visited-continent count")
        static let nothingLoggedTitle = String(
            localized: "Nothing Logged Yet",
            comment: "Watch empty state title when no country has been marked visited")
        static let nothingLoggedMessage = String(
            localized:
                "Mark the countries you've been to in Worldward on your iPhone — they'll show up here.",
            comment: "Watch empty state message when no country has been marked visited")
    }
}
