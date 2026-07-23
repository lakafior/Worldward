/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - Localization Strings
//
// Every user-facing string in the app, grouped by feature. To enable
// translations:
//
//   1. Xcode → File → New → File → String Catalog → name it `Localizable`
//   2. Add the file to the Worldward target
//   3. Build — Xcode automatically populates the catalog from every
//      `Text("…")` and `String(localized:)` in the codebase
//   4. Click "+" in the catalog to add a language
//
// For new strings, simply write `Text("Hello")` in SwiftUI or
// `String(localized: "Hello", comment: "…")` in code — the catalog
// catches them all on the next build.
//
// Translators: this file lists every string with its context. Use it
// as a reference when filling in the `Localizable.xcstrings` catalog.

/// `nonisolated` so the exporters (`Trip.markdownSummary`, `TripPDFRenderer`),
/// which run outside the main actor, can reuse these strings. Safe: every
/// member is an immutable `String`.
nonisolated enum Str {
    // MARK: - Tab bar
    enum Tab {
        static let map = String(localized: "Map", comment: "Tab bar: world map")
        static let been = String(localized: "Been", comment: "Tab bar: visited countries list")
        static let going = String(localized: "Going", comment: "Tab bar: trips and wishlist")
    }

    // MARK: - Map
    enum Map {
        static let searchPlaceholder = String(
            localized: "Find a country…", comment: "Map search text field placeholder")
        static let filterAll = String(localized: "All", comment: "Map filter chip: show all")
        static let filterVisited = String(
            localized: "Visited", comment: "Map filter chip: visited only")
        static let filterPlanning = String(
            localized: "Planning", comment: "Map filter chip: planning only")
        static let styleStandard = String(
            localized: "Standard", comment: "Map style option: default map")
        static let styleHybrid = String(
            localized: "Hybrid", comment: "Map style option: satellite + labels")
        static let styleSatellite = String(
            localized: "Satellite", comment: "Map style option: pure imagery")
        static let hint = String(
            localized: "Tap a country to see details",
            comment: "Tooltip shown below the map on macOS")
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

    // MARK: - Country detail
    enum Detail {
        static let status = String(
            localized: "Status", comment: "Section header for travel status picker")
        static let plans = String(
            localized: "Plans", comment: "Section header for plan status picker")
        static let visits = String(localized: "Visits", comment: "Section header for visit list")
        static let addVisit = String(localized: "Add Visit", comment: "Button to add a new visit")
        static let noVisits = String(
            localized: "No visits yet", comment: "Empty state when no visits recorded")
    }

    // MARK: - Trips
    enum Trip {
        static let tabTrips = String(localized: "Trips", comment: "Segmented control tab")
        static let tabWishlist = String(localized: "Wishlist", comment: "Segmented control tab")
        static let tabSuggestions = String(localized: "Suggestions", comment: "Segmented control tab")
        static let newButton = String(
            localized: "New Trip", comment: "Toolbar button to create a trip")
        static let addStop = String(
            localized: "Add a country / stop", comment: "Button to add an itinerary stop")
        static let packing = String(
            localized: "Packing", comment: "Section header for packing list")
        static let addPackingItem = String(
            localized: "Add item", comment: "Text field placeholder for new packing item")
        static let itineraryLabel = String(
            localized: "Itinerary", comment: "Section header for trip itinerary")
        static let notesLabel = String(localized: "Notes", comment: "Section header for trip notes")
        static let attachmentsLabel = String(
            localized: "Attachments", comment: "Section header for trip attachments in exports")
        static let untitled = String(
            localized: "Untitled Trip",
            comment: "Fallback trip title in Markdown/PDF exports when the trip has no name")
        static let packingOther = String(
            localized: "Other",
            comment: "Packing group heading for items not filed into any bag/container")
        static let empty = String(
            localized: "No trips yet", comment: "Empty state when no trips exist")
    }

    // MARK: - Watch app
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

    // MARK: - Statistics
    enum Stats {
        static let title = String(
            localized: "Your Travels", comment: "Statistics sheet navigation title")
        static let shareImage = String(
            localized: "Share Image Card", comment: "Menu item: share as image")
        static let exportCSV = String(localized: "Export CSV", comment: "Menu item: export as CSV")
        static let timeline = String(
            localized: "Travel Timeline", comment: "Section header for visit timeline")
        static let yearInReview = String(
            localized: "Year in review", comment: "Section header for year review cards")
        static let nextDest = String(
            localized: "Next destinations", comment: "Section header for suggestions")
        static let achievements = String(
            localized: "Achievements", comment: "Section header for badge grid")
        static let continents = String(
            localized: "Continents", comment: "Section header for continent progress")
    }

    // MARK: - Settings
    enum Settings {
        static let title = String(localized: "Settings", comment: "Settings sheet navigation title")
        static let appearance = String(localized: "Appearance", comment: "Settings section header")
        static let theme = String(localized: "Theme", comment: "Picker label: light/dark/system")
        static let mapStyle = String(
            localized: "Map Style", comment: "Picker label: map appearance")
        static let notifications = String(
            localized: "Notifications", comment: "Settings section header")
        static let reminders = String(localized: "Travel reminders", comment: "Toggle label")
        static let data = String(localized: "Data", comment: "Settings section header")
        static let export = String(
            localized: "Export Travel Data…", comment: "Button to export JSON backup")
        static let `import` = String(
            localized: "Import Travel Data…", comment: "Button to import JSON backup")
        static let about = String(localized: "About", comment: "Settings section header")
    }

    // MARK: - Notifications
    enum Notif {
        static let onThisDay = String(
            localized: "On this day ✈️", comment: "Notification title: visit anniversary")
        static let upcomingTrip = String(
            localized: "Upcoming trip ✈️", comment: "Notification title: trip starts tomorrow")
        static let yearRecap = String(
            localized: "Your year in travel 🌍", comment: "Notification title: December recap")
        static let inactivityNudge = String(
            localized: "Been a while 🧭", comment: "Notification title: inactive prompt")
    }

    // MARK: - General actions
    enum Action {
        static let done = String(localized: "Done", comment: "Button: dismiss sheet")
        static let cancel = String(localized: "Cancel", comment: "Button: cancel action")
        static let save = String(localized: "Save", comment: "Button: save changes")
        static let share = String(localized: "Share", comment: "Button: open share sheet")
        static let add = String(localized: "Add", comment: "Button: add item")
        static let back = String(localized: "Back", comment: "Button: go back")
    }

    // MARK: - Chat
    enum Chat {
        static let button = String(
            localized: "Ask About Your Travels", comment: "Toolbar button to open AI travel chat")
        static let placeholder = String(
            localized: "Ask about your travels…", comment: "Chat text field placeholder")
    }

    // MARK: - Share card
    enum Card {
        static let defaultHeadline = String(
            localized: "My World", comment: "Share card default title")
        static let defaultCaption = String(
            localized: "Tracked with Worldward", comment: "Share card default footer")
    }
}
