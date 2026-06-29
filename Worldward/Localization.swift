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

enum Str {
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
        static let empty = String(
            localized: "No trips yet", comment: "Empty state when no trips exist")
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
