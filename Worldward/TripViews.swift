/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import QuickLook
#endif

// MARK: - Export

/// A trip title, stripped of characters illegal in filenames, shared by the
/// Markdown and PDF exporters below and the `.wwtrip` exporter in
/// `TripFileTransfer.swift`. `nonisolated` because `ExportableTrip`'s
/// `transferRepresentation` (which calls it) is a nonisolated protocol
/// requirement, unlike ordinary declarations in this file.
nonisolated func sanitizedFileName(_ title: String) -> String {
    let cleaned =
        title
        .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Trip" : cleaned
}

/// Makes a trip shareable as a real Markdown file. The system writes it out named
/// after the trip with a `.md` extension (e.g. "Europe 2026.md"), so "Save to
/// Files", Apple Notes, Mail, etc. all receive a proper file rather than loose text.
struct ExportableTrip: Transferable {
    let title: String
    let markdown: String

    init(trip: Trip, options: TripExportOptions = .all) {
        self.title = trip.title
        self.markdown = trip.markdown(options: options)
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.markdown)
            .suggestedFileName { "\(sanitizedFileName($0.title)).md" }
    }
}

/// The include/exclude toggles for a shared trip file. Bound to the parent's
/// `@AppStorage`-backed raw value, so a choice sticks across trips and shapes
/// both the Markdown and the PDF the organizer hands out.
private struct TripExportOptionsSheet: View {
    @Binding var optionsRaw: Int
    @Environment(\.dismiss) private var dismiss

    private var options: TripExportOptions { TripExportOptions(rawValue: optionsRaw) }

    private func binding(_ option: TripExportOptions) -> Binding<Bool> {
        Binding(
            get: { options.contains(option) },
            set: { on in
                var updated = options
                if on { updated.insert(option) } else { updated.remove(option) }
                optionsRaw = updated.rawValue
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Itinerary", isOn: binding(.itinerary))
                    Toggle("Packing list", isOn: binding(.packing))
                    Toggle("Notes", isOn: binding(.notes))
                    Toggle("Attachments", isOn: binding(.attachments))
                    Toggle("Contacts", isOn: binding(.contacts))
                } header: {
                    Text("Include in export")
                } footer: {
                    Text(
                        "Applies to the Markdown and PDF share files. Markdown lists attached files by name; the PDF also embeds image attachments as pages."
                    )
                }
            }
            .navigationTitle("Export options")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 360, minHeight: 320)
        #endif
    }
}


// MARK: - Going tab

/// The Going tab: your **Trips** (multi-country plans), your **Wishlist**
/// (countries you want to visit but haven't planned yet), and **Suggestions**
/// (closest unvisited + AI picks for your next destination).
struct GoingView: View {
    let allCountries: [Country]
    /// Country centroids (id → coordinate) used for the "next closest" suggestions.
    /// Empty until the map's GeoJSON has finished loading, in which case that
    /// section is simply hidden.
    let centroids: [String: CLLocationCoordinate2D]
    @Binding var searchText: String
    @Binding var selectedContinent: String?
    @Binding var selectedYear: Int?
    @Binding var selectedCountry: Country?
    /// The trip shown in the macOS detail column. Ignored on iOS, where the
    /// trips list presents a sheet instead.
    @Binding var selectedTrip: Trip?

    enum Segment: String, CaseIterable, Identifiable {
        case trips = "Trips"
        case wishlist = "Wishlist"
        case suggestions = "Suggestions"
        var id: String { rawValue }

        /// Localized title for the segmented control.
        var label: String {
            switch self {
            case .trips: Str.Trip.tabTrips
            case .wishlist: Str.Trip.tabWishlist
            case .suggestions: Str.Trip.tabSuggestions
            }
        }
    }

    @State private var segment: Segment = .trips
    @State private var intentRouter = IntentRouter.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 8)

            Group {
                switch segment {
                case .trips:
                    TripsListView(allCountries: allCountries, selectedTrip: $selectedTrip)
                case .wishlist:
                    CountryListView(
                        allCountries: allCountries,
                        browseMode: .going,
                        searchText: $searchText,
                        selectedContinent: $selectedContinent,
                        selectedYear: $selectedYear,
                        selectedCountry: $selectedCountry)
                case .suggestions:
                    SuggestionsView(
                        allCountries: allCountries,
                        centroids: centroids)
                }
            }
            // Fills the column so the picker stays pinned to the top even when
            // the selected section shows a compact empty state.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // `OpenTripIntent` needs the trips list mounted to open its sheet, so a
        // pending request forces this section forward off whatever the user last
        // browsed (wishlist / suggestions).
        .onChange(of: intentRouter.pendingOpenTripID) {
            if intentRouter.pendingOpenTripID != nil { segment = .trips }
        }
        .onAppear {
            if intentRouter.pendingOpenTripID != nil { segment = .trips }
        }
    }
}

// MARK: - Trips list

private struct TripsListView: View {
    let allCountries: [Country]
    /// Drives the split view's detail column on macOS; unused on iOS.
    @Binding var selectedTrip: Trip?

    @Environment(\.modelContext) private var modelContext
    @Query private var trips: [Trip]
    @State private var editingTrip: Trip?
    @State private var intentRouter = IntentRouter.shared

    /// Whether the "Past Trips" disclosure is open. Collapsed by default so
    /// finished trips don't crowd the list; purely derived from `endDate` — a
    /// trip "archives" itself the moment its end date passes.
    @State private var showPastTrips = false

    /// Trips that haven't finished yet, soonest start first.
    private var upcomingTrips: [Trip] {
        let now = Date()
        return trips.filter { $0.endDate >= now }.sorted { $0.startDate < $1.startDate }
    }

    /// Finished trips, most recent first — rendered inside "Past Trips".
    private var pastTrips: [Trip] {
        let now = Date()
        return trips.filter { $0.endDate < now }.sorted { $0.startDate > $1.startDate }
    }

    /// Points at wherever "New Trip" actually lives: this view's own toolbar
    /// "+" on iOS, or the map toolbar's Add menu on macOS (see
    /// `ContentView.addTrip`).
    private var tripsEmptyStateHint: String {
        #if os(macOS)
            String(localized: "Plan your next adventure — choose Add ▸ New Trip on the map.")
        #else
            String(localized: "Plan your next adventure — tap ＋ to start a trip.")
        #endif
    }

    var body: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView(
                    "No trips yet",
                    systemImage: "suitcase",
                    description: Text(tripsEmptyStateHint))
            } else {
                #if os(macOS)
                    // Selection drives the split view's detail column (like
                    // Mail's message list) instead of presenting a sheet.
                    List(selection: $selectedTrip) {
                        tripRows(upcomingTrips)
                        pastTripsSection
                    }
                    .onDeleteCommand {
                        if let trip = selectedTrip { delete(trip) }
                    }
                #else
                    List {
                        tripRows(upcomingTrips)
                        pastTripsSection
                    }
                #endif
            }
        }
        .navigationTitle("Going")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        // macOS starts a trip from the map toolbar's Add menu instead (see
        // `ContentView.addTrip`), so the unified window toolbar doesn't show
        // this "+" right next to that one.
        #if !os(macOS)
            .toolbar {
                ToolbarItem {
                    Button {
                        addTrip()
                    } label: {
                        Label("New Trip", systemImage: "plus")
                    }
                }
            }
        #endif
        .sheet(item: $editingTrip) { trip in
            TripDetailSheet(trip: trip, allCountries: allCountries)
        }
        // `OpenTripIntent` routes here via the shared router. Watch both the
        // request and the query: on a cold launch the trip may not have loaded
        // when the request arrives, so a `trips` change retries.
        .onChange(of: intentRouter.pendingOpenTripID) { openPendingTripIfNeeded() }
        .onChange(of: trips.count) { openPendingTripIfNeeded() }
        .onAppear { openPendingTripIfNeeded() }
        .task {
            #if DEBUG
                // Screenshot capture: open the demo trip (the packing run then
                // scrolls itself down to the packing list — see TripDetailView,
                // which backs both the iOS sheet and the macOS inspector below).
                if ScreenshotSupport.isCapturing(.trip) || ScreenshotSupport.isCapturing(.packing) {
                    let trip = upcomingTrips.first ?? trips.first
                    #if os(macOS)
                        selectedTrip = trip
                    #else
                        editingTrip = trip
                    #endif
                }
            #endif
        }
    }

    /// The rows for one bucket of trips. On macOS rows are selectable tags with
    /// a delete context menu; on iOS they're buttons opening the edit sheet,
    /// with swipe-to-delete scoped to the bucket's own indices.
    @ViewBuilder private func tripRows(_ bucket: [Trip]) -> some View {
        #if os(macOS)
            ForEach(bucket) { trip in
                TripRow(trip: trip)
                    .tag(trip)
                    .contextMenu {
                        Button("Delete Trip", role: .destructive) {
                            delete(trip)
                        }
                    }
            }
        #else
            ForEach(bucket) { trip in
                Button {
                    editingTrip = trip
                } label: {
                    TripRow(trip: trip)
                }
            }
            .onDelete { offsets in
                for index in offsets { delete(bucket[index]) }
            }
        #endif
    }

    /// Finished trips, tucked into a collapsed disclosure so the list leads
    /// with what's ahead. Hidden entirely while there's nothing past.
    @ViewBuilder private var pastTripsSection: some View {
        if !pastTrips.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showPastTrips) {
                    tripRows(pastTrips)
                } label: {
                    Text("Past Trips")
                        .badge(pastTrips.count)
                }
            }
        }
    }

    private func addTrip() {
        let trip = Trip.newUpcoming(title: "New Trip")
        modelContext.insert(trip)
        editingTrip = trip
    }

    /// Delete a single trip (macOS context menu / ⌫), clearing the detail
    /// column first if it was showing that trip.
    private func delete(_ trip: Trip) {
        if selectedTrip == trip { selectedTrip = nil }
        modelContext.delete(trip)
    }

    /// Opens a trip requested by `OpenTripIntent`. Resolves the id against the
    /// live query; if the trip hasn't loaded/synced in yet it leaves the request
    /// pending (a `trips` change retries). Clears the id once opened so it fires
    /// exactly once — iOS presents the sheet, macOS fills the detail column.
    private func openPendingTripIfNeeded() {
        guard let id = intentRouter.pendingOpenTripID,
            let trip = trips.first(where: { $0.dedupID == id })
        else { return }
        intentRouter.pendingOpenTripID = nil
        #if os(macOS)
            selectedTrip = trip
        #else
            editingTrip = trip
        #endif
    }

}

private struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.title.isEmpty ? "Untitled Trip" : trip.title)
                .font(.headline)
            Text(trip.dateRangeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !trip.flags.isEmpty {
                Text(trip.flags).font(.subheadline)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Shared styling for the Notes section header's Edit/Done pair, so the two
/// read as one control in two states. `.textCase(nil)` opts out of the
/// uppercasing a grouped list applies to its headers.
private struct NotesHeaderButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.semibold))
            .textCase(nil)
            .buttonStyle(.borderless)
            .transition(.opacity)
    }
}

/// Which note field holds focus. Sections are addressed by id, never by index,
/// so a re-parse that merges or inserts one can't hand focus to a different
/// field than the one being typed in.
private enum NoteFieldFocus: Hashable {
    case title(UUID)
    case body(UUID)
}

/// Starter headings offered by "Add section", so the feature reads as something
/// more inviting than an empty box. Each is only text — the emoji is the first
/// character of the heading, so it needs no storage and exports like any other.
private enum NoteSectionPreset: String, CaseIterable, Identifiable {
    case insurance, transport, money, emergency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insurance:
            String(localized: "🛡️ Insurance", comment: "Preset heading for a trip note section")
        case .transport:
            String(localized: "✈️ Transport", comment: "Preset heading for a trip note section")
        case .money:
            String(localized: "💳 Money", comment: "Preset heading for a trip note section")
        case .emergency:
            String(localized: "🏥 Emergency", comment: "Preset heading for a trip note section")
        }
    }
}

extension String {
    /// Capitalizes only the first character, locale-aware. `.localizedCapitalized`
    /// would title-case every word ("In 12 Days"); relative date phrases want
    /// sentence case.
    fileprivate var sentenceCased: String {
        guard let first else { return self }
        return String(first).localizedUppercase + dropFirst()
    }
}

// MARK: - Trip detail

/// How the itinerary list is ordered. Country isn't a *level* above the stops —
/// it's an attribute each stop wears (a flag chip) — so grouping by it is just an
/// alternate sort, not a container. Manual keeps the user's hand-dragged order.
enum ItinerarySort: String, CaseIterable, Identifiable {
    case date, country, manual
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .date: "By date"
        case .country: "By country"
        case .manual: "Manual"
        }
    }

    var symbol: String {
        switch self {
        case .date: "calendar"
        case .country: "flag"
        case .manual: "line.3.horizontal"
        }
    }
}

/// Internal (not private): also presented by `SuggestionsView` when a
/// suggestion spins off a new trip.
struct TripDetailSheet: View {
    @Bindable var trip: Trip
    let allCountries: [Country]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TripDetailView(trip: trip, allCountries: allCountries)
                .navigationTitle(trip.title.isEmpty ? "Trip" : trip.title)
                #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct TripDetailView: View {
    @Bindable var trip: Trip
    let allCountries: [Country]

    @Environment(\.modelContext) private var modelContext
    /// Dismisses the containing sheet on iOS when jumping to the map; a no-op
    /// in the macOS detail column, where no sheet is presented.
    @Environment(\.dismiss) private var dismiss
    /// Country outline paths (id → polygon rings, `MKMapPoint` space) published by
    /// ContentView once the map loads. Lets an added place resolve its country
    /// on-device — no network, no deprecated geocoder — the same way
    /// `TripPhotoSuggestionsSheet` matches photo coordinates.
    @Environment(\.countryPaths) private var countryPaths
    /// The shared container catalog, used for the move menu, the assistant, and
    /// first-run seeding. Sorted so groups appear in a stable order everywhere.
    @Query(sort: \PackingContainer.sortOrder) private var allContainers: [PackingContainer]
    /// Saved packing templates, offered in the "Start from…" menu.
    @Query(sort: \PackingTemplate.name) private var templates: [PackingTemplate]
    /// Every trip, so the "Start from…" menu can copy another trip's packing list.
    @Query private var allTrips: [Trip]
    /// Presents the MapKit place search for adding a stop to the itinerary.
    @State private var showPlaceSearch = false
    /// The stop a picked file should attach to, or `nil` to attach it as a
    /// trip-level document. Set just before the file importer opens, read back in
    /// `attachFiles`.
    @State private var attachingToStop: ItineraryItem?
    /// How the itinerary is ordered on screen. Remembered across trips: someone
    /// who thinks in days keeps By date, someone touring one region keeps By
    /// country. Stored as the raw value so `@AppStorage` can persist it. Defaults
    /// to By date — an itinerary is a sequence of days before it's anything else,
    /// and grouping a first trip's two stops under a country heading reads as a
    /// structure the user didn't ask for. Anyone who already chose a sort keeps it.
    @AppStorage("tripItinerarySort") private var itinerarySortRaw = ItinerarySort.date.rawValue
    private var itinerarySort: ItinerarySort {
        ItinerarySort(rawValue: itinerarySortRaw) ?? .date
    }
    @State private var newPackingTitle = ""
    /// The container new items file into, stored by *name* rather than by
    /// identifier so it survives the shared catalog changing underneath it, and
    /// carried across trips — someone who always starts with the carry-on
    /// shouldn't have to re-pick it every trip. Empty means ungrouped.
    @AppStorage("packingAddContainer") private var addContainerName = ""
    @State private var calendarAlert: CalendarAlert?
    @State private var pdfExportError: String?
    /// A freshly written temp file — the exported PDF or an attachment —
    /// previewed in-place via Quick Look on iOS. Unused on macOS, which opens
    /// files in their default app directly instead.
    @State private var filePreviewURL: URL?
    @State private var showAttachmentImporter = false
    @State private var attachmentAlert: String?
    @State private var planner = TripPlanner()
    @State private var confirmClearPacking = false
    @State private var isAddingContainer = false
    @State private var newContainerName = ""
    /// The item to file into the container being created, or `nil` when creating
    /// an empty container from the controls section.
    @State private var pendingContainerItem: PackingItem?
    /// Container groups the user has collapsed, keyed by `PackingGroup.id`.
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var showSaveTemplate = false
    @State private var newTemplateName = ""
    @State private var showPhotoSuggestions = false
    /// `trip.notes` split on its `#` headings — one editable field per section.
    /// Derived state, re-parsed only when editing ends (see `reparseNotes`); the
    /// text itself always lives on the trip.
    @State private var noteSections: [NoteSection] = []
    /// Which section's body is showing the raw editor rather than the rendered
    /// preview. Tapping a preview flips it on; "Done" flips it back off.
    @State private var editingBodyID: NoteSection.ID?
    @FocusState private var noteFocus: NoteFieldFocus?
    #if os(macOS)
        /// The itinerary stop the pointer is currently over, driving its trailing
        /// delete button. macOS has no swipe-to-delete, so without this the only
        /// visible way to remove a stop is a right-click most people never try.
        @State private var hoveredStopID: ItineraryItem.ID?
    #endif
    /// Held across submits so a run of new packing items can be typed without
    /// tapping back into the field between each one.
    @FocusState private var packingFieldFocused: Bool
    /// Hides the one-shot "Add to Apple Calendar" button while calendar sync is
    /// on — the sync already mirrors the trip, so the button would double-book.
    @AppStorage(CalendarSync.enabledKey) private var calendarSyncEnabled = false
    /// Which sections the Markdown/PDF export carries — the organizer's control
    /// over the shared file. Persisted across trips as the OptionSet's raw value.
    @AppStorage("tripExportOptions") private var exportOptionsRaw = TripExportOptions.all.rawValue
    private var exportOptions: TripExportOptions { TripExportOptions(rawValue: exportOptionsRaw) }
    @State private var showExportOptions = false

    /// Translates freshly generated (English) assistant output into the user's
    /// language before it's saved. The on-device LLM names items in English;
    /// Apple's translator — far better than the LLM at translation — converts
    /// them here in the view. No-op when the app runs in English, and falls back
    /// to the English original when the language pair is unavailable, so
    /// generated content is never dropped.
    @State private var translator = AppTranslator()
    /// Which section is being translated + inserted, so the "Generating…" spinner
    /// stays up through the whole pipeline instead of ending when the (English)
    /// generation finishes — which used to read as "nothing happened".
    @State private var translating: TripPlanner.Field?

    var body: some View {
        // Uses a `List` (rather than `Form`) for consistent drag-to-reorder
        // behaviour across sections. `.insetGrouped` keeps the familiar
        // grouped-form appearance. The chain below is split across two `let`s
        // (and wrapped in `Group` so Quick Look can attach outside it) because,
        // taken as one expression, it's long enough to push Swift's modifier
        // type-checking past a reasonable time budget.
        Group {
            let list = List {
                tripIdentitySection
                itinerarySection
                packingSections
                notesSections
                essentialsSection
                tripPhotosSection
            }
            // Drag-to-reorder packing items within and across container groups; the
            // closure rewrites each moved item's container + `order`. The itinerary's
            // own `.onMove` is also handled below.
            //
            // Both use the legacy `.onMove` API (available since macOS 14 / iOS 17)
            // instead of the newer `reorderContainer` + `reorderable` scheme that was
            // introduced in macOS 27 / iOS 27. Switch to that API when the deployment
            // target reaches 27.0.
            #if os(iOS)
                .listStyle(.insetGrouped)
                .toolbar { EditButton() }
                // Scrolling away from the notes field resigns it, which flips the
                // Markdown back to its rendered preview — the gestural counterpart
                // to the Notes section's Done button.
                .scrollDismissesKeyboard(.interactively)
            #endif
            .task(id: trip.persistentModelID) {
                seedContainersIfNeeded()
                // Unconditional, and keyed on the trip: editing a second trip
                // reuses this view, and a stale field list would then show — and
                // on the next keystroke save — the previous trip's notes.
                noteSections = NoteSection.parse(trip.notes)
            }
            // Every keystroke mirrors straight back onto the trip, so closing the
            // editor mid-word can't lose anything.
            .onChange(of: noteSections) { writeNotesThrough() }
            // Editing ended: only now may a typed "# " split a field in two.
            .onChange(of: noteFocus) { previous, current in
                if previous != nil, current == nil { reparseNotes() }
            }
            // A write from somewhere else — CloudKit landing a sync, the
            // assistant appending — rebuilds the fields. Skipped while a field
            // has focus so an arriving sync can't yank the cursor mid-sentence.
            .onChange(of: trip.notes) { _, updated in
                guard noteFocus == nil, NoteSection.serialize(noteSections) != updated else {
                    return
                }
                noteSections = NoteSection.parse(updated)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        tripActionsMenu
                    } label: {
                        Label("Trip actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showPlaceSearch) {
                // Bias the search to the trip's country when there's exactly one;
                // otherwise search worldwide. One sheet handles searched places
                // (auto country) and free-form custom stops.
                PlaceSearchSheet(
                    country: soleCountry,
                    scopeCountries: trip.countries,
                    allCountries: allCountries,
                    onPick: { item in addPlace(item) },
                    onPickCountry: { country in addCountryStop(country) },
                    onAddCustom: { title in addCustomStop(title) })
            }
            .sheet(isPresented: $showExportOptions) {
                TripExportOptionsSheet(optionsRaw: $exportOptionsRaw)
            }
            .sheet(isPresented: $showPhotoSuggestions) {
                TripPhotoSuggestionsSheet(trip: trip)
            }
            .alert("New container", isPresented: $isAddingContainer) {
                TextField("Name", text: $newContainerName)
                Button("Add", action: createContainer)
                Button("Cancel", role: .cancel, action: resetContainerDraft)
            } message: {
                Text("Bags and cases are shared across all your trips.")
            }
            // Lives on the list rather than on the button that raises it: that
            // button is now inside the packing header's menu, and a dialog
            // attached inside a menu goes down with the menu before it presents.
            .confirmationDialog(
                "Remove all \((trip.packing ?? []).count) packing items?",
                isPresented: $confirmClearPacking, titleVisibility: .visible
            ) {
                Button("Clear list", role: .destructive, action: clearPacking)
            }
            .alert("Save as template", isPresented: $showSaveTemplate) {
                TextField("Template name", text: $newTemplateName)
                Button("Save", action: saveTemplate)
                Button("Cancel", role: .cancel, action: resetTemplateDraft)
            } message: {
                Text("Reuse this packing list on future trips.")
            }

            ScrollViewReader { proxy in
                list
                    .task {
                        #if DEBUG
                            await scrollToPackingIfCapturing(proxy)
                        #endif
                    }
            }
            .alert(
                    "Apple Calendar",
                    isPresented: Binding(
                        get: { calendarAlert != nil }, set: { if !$0 { calendarAlert = nil } })
                ) {
                    // Without this the denial was a dead end: "turn it on in
                    // Settings" behind an OK button, leaving the user to find the
                    // pane themselves. Matches the Settings screen's own alerts.
                    if calendarAlert?.isPermissionDenied == true {
                        OpenPrivacySettingsButton(macPane: "Privacy_Calendars")
                    }
                    Button("OK", role: .cancel) {}
                } message: {
                    if let calendarAlert { Text(calendarAlert.message) }
                }
                .alert(
                    "Export PDF",
                    isPresented: Binding(
                        get: { pdfExportError != nil }, set: { if !$0 { pdfExportError = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(pdfExportError ?? "")
                }
                .alert(
                    "Couldn't generate",
                    isPresented: Binding(
                        get: { planner.errorMessage != nil },
                        set: { if !$0 { planner.clearError() } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(planner.errorMessage ?? "")
                }
                .fileImporter(
                    isPresented: $showAttachmentImporter,
                    allowedContentTypes: [.data],
                    allowsMultipleSelection: true,
                    onCompletion: attachFiles)
                .alert(
                    "Attachments",
                    isPresented: Binding(
                        get: { attachmentAlert != nil }, set: { if !$0 { attachmentAlert = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(attachmentAlert ?? "")
                }
                // Hosts the translation session that `translator.translate(_:)`
                // awaits in `fillPacking` / `fillNotes`.
                .appTranslation(translator)
        }
        #if !os(macOS)
            .quickLookPreview($filePreviewURL)
        #endif
    }

    /// At-a-glance identity for the trip: its flags, its dates, and how near it
    /// is. Opening a trip you've already built used to tell you nothing without
    /// reading a date picker — this answers "which trip, and how soon?" before
    /// any of the form rows. Rendered without a row background so it reads as a
    /// header rather than as the first item in the form.
    /// The trip's identity in one section: a clear-backgrounded header (flags,
    /// dates, countdown) floating above the editable name and dates. Merged from
    /// the old separate header + details sections — one fewer thing to scroll past
    /// before the itinerary.
    private var tripIdentitySection: some View {
        Section {
            VStack(spacing: 12) {
                if !trip.flags.isEmpty {
                    Text(trip.flags)
                        .font(.system(size: 44))
                        .lineLimit(1)
                        // Long-haul trips can carry a dozen flags; scale them down
                        // rather than truncating the set.
                        .minimumScaleFactor(0.4)
                        // The itinerary below names every country properly —
                        // VoiceOver reciting the emoji here would just be noise.
                        .accessibilityHidden(true)
                }
                VStack(spacing: 4) {
                    Text(trip.dateRangeText)
                        .font(.headline)
                    Text(countdownText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                // Editing either date picker below re-derives the countdown;
                // rolling the digits ties the two together visually.
                .animation(.snappy, value: countdownText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)

            TextField("Trip name", text: $trip.title, prompt: Text("e.g. Europe 2026"))
            DatePicker("Start", selection: $trip.startDate, displayedComponents: .date)
            DatePicker(
                "End", selection: $trip.endDate, in: trip.startDate...,
                displayedComponents: .date)
        }
    }

    /// The trip's countries when there's exactly one, else `nil`. Biases place
    /// search and is the country a freshly added place inherits, so a
    /// single-country trip stays coherent without the user tagging every place.
    private var soleCountry: Country? {
        let countries = trip.countries
        return countries.count == 1 ? countries.first : nil
    }

    /// The trip's verbs, gathered into the toolbar's overflow menu rather than
    /// spending a whole form section on them: add to Calendar (unless sync already
    /// mirrors the trip), the Share/Export submenu, and jump-to-map.
    @ViewBuilder private var tripActionsMenu: some View {
        if !calendarSyncEnabled {
            Button {
                addToCalendar()
            } label: {
                Label("Add to Apple Calendar", systemImage: "calendar.badge.plus")
            }
        }
        exportButtons
        Button {
            // Hands the trip to ContentView through the router (the map lives
            // several presentation layers away), which switches to the Map tab
            // and frames the route.
            IntentRouter.shared.pendingMapTrip = trip
            dismiss()
        } label: {
            Label("View Route on Map", systemImage: "map")
        }
        .disabled((trip.itinerary ?? []).isEmpty)
    }

    /// A one-line answer to "how soon?". `RelativeDateTimeFormatter` supplies the
    /// localized "in 12 days" / "3 weeks ago" phrasing in all 29 languages for
    /// free — only the mid-trip case needs a catalog string of its own.
    private var countdownText: String {
        switch trip.phase() {
        case .upcoming(let days):
            Self.relativeFormatter.localizedString(from: DateComponents(day: days))
                .sentenceCased
        case .underway(let day, let total):
            String(
                localized: "Day \(day) of \(total)",
                comment: "Trip header countdown while the trip is under way")
        case .past(let days):
            Self.relativeFormatter.localizedString(from: DateComponents(day: -days))
                .sentenceCased
        }
    }

    /// `.named` so a trip starting tomorrow reads "Tomorrow" rather than
    /// "in 1 day".
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    private func addToCalendar() {
        Task {
            switch await CalendarExporter.add(trip: trip) {
            case .added:
                calendarAlert = CalendarAlert(message: "Added to your calendar.")
            case .denied:
                calendarAlert = CalendarAlert(
                    message:
                        "Worldward doesn't have calendar access. Turn it on in Settings to add trips.",
                    isPermissionDenied: true)
            case .failed(let message):
                calendarAlert = CalendarAlert(message: "Couldn't add to calendar: \(message)")
            }
        }
    }

    /// A calendar result worth surfacing, plus whether it was a permission
    /// denial. Denials get an "Open Settings" escape hatch; a plain failure has
    /// nowhere useful to send the user, so it only gets an OK.
    ///
    /// The message is a `LocalizedStringResource`, not a `String`: these were
    /// plain literals passed through `Text(String)` — the *non*-localizing
    /// overload — so all three read in English in every language.
    private struct CalendarAlert {
        let message: LocalizedStringResource
        var isPermissionDenied = false
    }

    /// Renders the trip's PDF to a fresh temp file and opens it directly — in
    /// Preview.app on macOS, in an in-place Quick Look preview on iOS — rather
    /// than through the share picker, which only offers a couple of generic
    /// services for raw PDF data. Each export gets its own UUID'd subdirectory so
    /// the viewer always loads new content instead of a stale, already-open
    /// document at a reused path.
    private func exportPDFAndOpen() {
        let data = TripPDFRenderer.render(trip: trip, options: exportOptions)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url =
            directory
            .appendingPathComponent(sanitizedFileName(trip.title))
            .appendingPathExtension("pdf")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            #if os(macOS)
                NSWorkspace.shared.open(url)
            #else
                filePreviewURL = url
            #endif
        } catch {
            pdfExportError = error.localizedDescription
        }
    }

    /// Markdown + PDF export, folded into a single Share submenu. "Export options…"
    /// leads: it opens the include/exclude sheet whose choices (persisted) shape
    /// both the Markdown and the PDF below it — the control a group organizer
    /// wants over the file they hand out.
    @ViewBuilder private var exportButtons: some View {
        Menu {
            Button {
                showExportOptions = true
            } label: {
                Label("Export options…", systemImage: "slider.horizontal.3")
            }
            ShareLink(
                item: ExportableTrip(trip: trip, options: exportOptions),
                preview: SharePreview(trip.title.isEmpty ? "Trip" : trip.title)
            ) {
                Label("Share as Markdown", systemImage: "doc.plaintext")
            }
            // The share picker only lists a couple of generic services (Shortcuts,
            // AirDrop) for arbitrary PDF data, so this opens the rendered file
            // straight in the platform's own viewer instead: Preview.app on macOS,
            // an in-place Quick Look preview on iOS.
            Button {
                exportPDFAndOpen()
            } label: {
                Label("Export PDF", systemImage: "doc.richtext")
            }
            // App-to-app: a `.wwtrip` file (AirDrop, Messages, Files) that
            // another Worldward install opens as an add-or-update import —
            // see `TripFileTransfer.swift`. Always the whole trip, so the export
            // options don't apply.
            ShareLink(
                item: ExportableTripFile(trip: trip),
                preview: SharePreview(trip.title.isEmpty ? "Trip" : trip.title)
            ) {
                Label("Share Trip File", systemImage: "arrow.up.doc")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    /// Once the trip's end date has passed, offers to find the library photos
    /// taken during the trip and attach them to visits. Purely derived from
    /// `endDate` — no stored "suggested" flag, no background work, and no photo
    /// permission prompt until the button is tapped.
    @ViewBuilder private var tripPhotosSection: some View {
        if trip.endDate < Date(), !trip.countries.isEmpty {
            Section {
                Button {
                    showPhotoSuggestions = true
                } label: {
                    Label("Attach Trip Photos", systemImage: "photo.on.rectangle.angled")
                }
            } footer: {
                Text("Find photos taken during this trip and attach them to your country visits.")
            }
        }
    }

    /// A single flat list of stops, each wearing its country as a flag chip rather
    /// than sitting under a country *level*. One "Add stop" adds a searched place
    /// (its country resolved automatically from its location) or a free-form stop.
    /// The list re-sorts By date, By country (a light grouped view), or Manual.
    @ViewBuilder private var itinerarySection: some View {
        if (trip.itinerary ?? []).isEmpty {
            Section("Itinerary") {
                // The Add button right below is the next action, so this only
                // needs to name the gap and look considered doing it.
                emptySectionPlaceholder(
                    symbol: "signpost.right.and.left",
                    message: Text("No stops yet", comment: "Empty itinerary placeholder"))
                addStopButton
            }
        } else if itinerarySort == .country {
            // Each country is a light sort-label header (like Contacts' A/B/C),
            // not a container the stops live inside. The chip is dropped from the
            // rows here since the header already names the country.
            ForEach(countryGroups) { group in
                Section {
                    ForEach(group.stops) { stop in stopRow(stop, showCountryChip: false) }
                        .onDelete { deleteDisplayed($0, in: group.stops) }
                } header: {
                    if group.id == countryGroups.first?.id {
                        itineraryHeader(Text(group.headerText))
                    } else {
                        Text(group.headerText).textCase(nil)
                    }
                }
            }
            Section { addStopButton }
        } else {
            Section {
                let stops = displayedStops
                // `.onMove` only in Manual — dragging a list that's sorted by a
                // computed key (date) can't map a drop back to a stable order.
                if itinerarySort == .manual {
                    ForEach(stops) { stop in stopRow(stop, showCountryChip: true) }
                        .onDelete { deleteDisplayed($0, in: stops) }
                        .onMove(perform: moveItineraryStop)
                } else {
                    ForEach(stops) { stop in stopRow(stop, showCountryChip: true) }
                        .onDelete { deleteDisplayed($0, in: stops) }
                }
                addStopButton
            } header: {
                itineraryHeader(Text("Itinerary"))
            }
        }
    }

    private var addStopButton: some View {
        Button {
            showPlaceSearch = true
        } label: {
            Label("Add stop", systemImage: "plus")
        }
    }

    @ViewBuilder private func stopRow(_ stop: ItineraryItem, showCountryChip: Bool) -> some View {
        #if os(macOS)
            // The row reserves the trailing slot whether or not the pointer is
            // there, so fading the button in can't reflow the row underneath it.
            HStack(alignment: .top, spacing: 8) {
                stopRowBody(stop, showCountryChip: showCountryChip)
                deleteStopButton(stop)
            }
            .onHover { inside in
                if inside {
                    hoveredStopID = stop.id
                } else if hoveredStopID == stop.id {
                    // Only clear when *this* row is the one being left: rows exit
                    // and enter in either order, and a stale exit would otherwise
                    // blank the button on the row the pointer just arrived at.
                    hoveredStopID = nil
                }
            }
        #else
            stopRowBody(stop, showCountryChip: showCountryChip)
        #endif
    }

    private func stopRowBody(_ stop: ItineraryItem, showCountryChip: Bool) -> some View {
        StopRow(
            stop: stop,
            showCountryChip: showCountryChip,
            onAddAttachment: { attachToStop(stop) },
            onOpenAttachment: { openAttachment($0) })
            // The iOS list has swipe-to-delete; macOS has the hover button above.
            // The context menu backs both up — right-click on macOS, long-press on
            // iOS — and is the only one of the three VoiceOver reaches by pointer.
            .contextMenu {
                Button(role: .destructive) {
                    modelContext.delete(stop)
                } label: {
                    Label("Delete Stop", systemImage: "trash")
                }
            }
    }

    #if os(macOS)
        /// The hover-revealed delete control, aligned to the top of the row so it
        /// sits beside the stop's name rather than floating against the middle of
        /// a tall row of date and transport controls. Faded rather than removed —
        /// see `stopRow` — and left hit-testable while transparent, which costs
        /// nothing (the pointer can't reach it without first revealing it) and
        /// keeps it reachable by VoiceOver.
        private func deleteStopButton(_ stop: ItineraryItem) -> some View {
            Button(role: .destructive) {
                modelContext.delete(stop)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: minimumHitTarget, height: minimumHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .opacity(hoveredStopID == stop.id ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: hoveredStopID)
            .help("Delete Stop")
            .accessibilityLabel(Text("Delete Stop"))
        }
    #endif

    /// A section header carrying the sort control on its trailing edge. `.textCase(nil)`
    /// keeps "Itinerary" and country names in their natural case.
    private func itineraryHeader(_ leading: Text) -> some View {
        HStack {
            leading
            Spacer()
            if showsItinerarySort {
                Menu {
                    Picker("Sort", selection: sortSelection) {
                        ForEach(ItinerarySort.allCases) { sort in
                            Label(sort.label, systemImage: sort.symbol).tag(sort)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .textCase(nil)
            }
        }
        .textCase(nil)
    }

    /// Whether re-sorting is a meaningful thing to offer yet. The control used to
    /// show from the very first stop, where all three orders produce the same list.
    /// It earns its place once there are enough stops to lose track of, or a second
    /// country to group by.
    private var showsItinerarySort: Bool {
        let stops = trip.sortedStops
        return stops.count >= 4 || Set(stops.compactMap { $0.country?.id }).count >= 2
    }

    private var sortSelection: Binding<ItinerarySort> {
        Binding(get: { itinerarySort }, set: { itinerarySortRaw = $0.rawValue })
    }

    /// Stops ordered for the flat (By date / Manual) views. By date sends dated
    /// stops up in chronological order and lets undated ones settle at the bottom
    /// in their manual order; Manual is simply the hand-dragged order.
    private var displayedStops: [ItineraryItem] {
        guard itinerarySort == .date else { return trip.sortedStops }
        return trip.sortedStops.sorted {
            switch ($0.date, $1.date) {
            case let (left?, right?): return (left, $0.order) < (right, $1.order)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.order < $1.order
            }
        }
    }

    /// The stops grouped by country in first-appearance order, for the By country
    /// view. A stop with no country falls into a trailing "No country" group.
    private var countryGroups: [ItineraryCountryGroup] {
        var order: [String] = []
        var buckets: [String: [ItineraryItem]] = [:]
        for stop in trip.sortedStops {
            let key = stop.country?.id ?? "__none"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(stop)
        }
        return order.map { key in
            let stops = (buckets[key] ?? []).sorted {
                ($0.date ?? .distantFuture, $0.order) < ($1.date ?? .distantFuture, $1.order)
            }
            let country = stops.first?.country
            return ItineraryCountryGroup(
                id: key,
                flag: country?.flagEmoji ?? "📍",
                name: country?.localizedName ?? String(localized: "No country"),
                stops: stops)
        }
    }

    /// An overall progress bar, one Section per container that has items (plus an
    /// "Other" group for ungrouped items), followed by the shared controls section.
    #if DEBUG
        /// Scroll anchor so screenshot capture can jump straight to the packing list.
        fileprivate static let packingAnchorID = "ww-packing-anchor"

        /// Screenshot capture: bring the packing list into view inside the editor.
        /// The short wait lets the sheet finish presenting before we scroll.
        private func scrollToPackingIfCapturing(_ proxy: ScrollViewProxy) async {
            guard ScreenshotSupport.isCapturing(.packing) else { return }
            try? await Task.sleep(for: .milliseconds(700))
            proxy.scrollTo(Self.packingAnchorID, anchor: .top)
        }
    #endif

    @ViewBuilder private var packingSections: some View {
        if !(trip.packing ?? []).isEmpty {
            Section {
                let total = (trip.packing ?? []).count
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        // The count leads now rather than trailing the bar in
                        // `.caption`: in field mode this is the whole point of the
                        // screen, and it was styled as an afterthought.
                        Text("\(trip.packedCount) of \(total) packed")
                            .font(.subheadline.weight(.medium))
                            // Rolls the digits instead of cutting to the new value.
                            .contentTransition(.numericText())
                        Spacer()
                        if trip.packedCount == total {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    ProgressView(value: Double(trip.packedCount), total: Double(total))
                        // Matches the green of the row checkmarks, so the bar and
                        // the thing filling it read as one system.
                        .tint(.green)
                }
                // Checking an item off used to snap the bar with no motion at all.
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: trip.packedCount)
                // Finishing the list is the one moment on this screen worth
                // marking — otherwise a full bar arrives in silence. Only on the
                // transition *into* completion: a plain `== total` trigger would
                // also fire when unpacking the last item.
                .sensoryFeedback(trigger: trip.packedCount) { old, new in
                    new == total && old != total ? .success : nil
                }
            }
            #if DEBUG
                .id(Self.packingAnchorID)
            #endif
        }

        ForEach(trip.packingGroups) { group in
            Section {
                if !collapsedGroupIDs.contains(group.id) {
                    ForEach(group.items) { item in
                        PackingItemRow(item: item, containers: allContainers) {
                            pendingContainerItem = item
                            isAddingContainer = true
                        }
                    }
                    .onMove { sources, destination in
                        movePackingItem(in: group, from: sources, to: destination)
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(group.items[index]) }
                    }
                }
            } header: {
                packingGroupHeader(group)
            }
        }

        packingControlsSection
    }

    /// A tappable group header that collapses/expands its container and shows a
    /// packed-count badge plus a chevron reflecting the collapsed state.
    private func packingGroupHeader(_ group: PackingGroup) -> some View {
        let packed = group.items.filter(\.isPacked).count
        let collapsed = collapsedGroupIDs.contains(group.id)
        return Button {
            withAnimation(.snappy(duration: 0.25)) {
                if collapsed {
                    collapsedGroupIDs.remove(group.id)
                } else {
                    collapsedGroupIDs.insert(group.id)
                }
            }
        } label: {
            HStack {
                Label {
                    Text(
                        "\(group.container?.name ?? Str.Trip.packingOther) · \(packed)/\(group.items.count)"
                    )
                    // Checking an item off updates this group's tally too; roll it
                    // in step with the overall progress count above.
                    .contentTransition(.numericText())
                    .animation(.snappy, value: packed)
                } icon: {
                    Image(systemName: group.container?.symbolName ?? "tray")
                }
                Spacer()
                // One chevron rotated, not two symbols swapped: the eye reads it
                // as the same object turning, which is what says the group is
                // still there. It's also what `DisclosureGroup` does natively.
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: collapsed)
        .accessibilityValue(
            collapsed
                ? Text("Collapsed", comment: "Accessibility value: packing group is folded shut")
                : Text("Expanded", comment: "Accessibility value: packing group is open"))
    }

    private var packingControlsSection: some View {
        Section {
            HStack {
                TextField("Add item", text: $newPackingTitle)
                    .focused($packingFieldFocused)
                    // `.onSubmit` alone dropped focus after every item, so building
                    // a list meant tapping back into the field between each one.
                    // Keeping focus lets you type the whole list in one go, the way
                    // Reminders does.
                    .submitLabel(.next)
                    .onSubmit {
                        addPacking()
                        packingFieldFocused = true
                    }
                Button("Add", action: addPacking)
                    .disabled(newPackingTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            addDestinationPicker

            if canUseAssistant {
                fillButton(field: .packing, action: fillPacking)
            }
        } header: {
            packingHeader
        }
    }

    /// The header carries the list's own verbs on its trailing edge. They used to
    /// be four full-weight rows stacked under the "Add item" field — at the same
    /// visual weight as the field itself, which is the one row you touch on every
    /// trip. Managing the container catalog isn't offered here at all: a container
    /// is created in place from a packing row's own menu, and renamed or deleted in
    /// Settings ▸ Packing, which is where templates have always been managed.
    private var packingHeader: some View {
        HStack {
            Text(
                (trip.packing ?? []).isEmpty
                    ? "Packing" : "Packing · \(trip.packedCount)/\((trip.packing ?? []).count)")
            Spacer()
            if hasPackingOptions {
                Menu {
                    packingStartFromMenu
                    if !(trip.packing ?? []).isEmpty {
                        Button {
                            newTemplateName = trip.title
                            showSaveTemplate = true
                        } label: {
                            // Was `square.and.arrow.down` — the *download* glyph,
                            // and the mirror image of the Share icon, so the two
                            // opposite actions read as a matched pair. Saving a
                            // reusable list is a stack-of-lists action.
                            Label("Save as template…", systemImage: "rectangle.stack.badge.plus")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmClearPacking = true
                        } label: {
                            Label("Clear list", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Packing options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .textCase(nil)
            }
        }
        .textCase(nil)
    }

    /// Which bag the next typed item goes into. Every added item used to land in
    /// "Other" with no way to say otherwise — the only remedy was the per-row move
    /// menu, after the fact, once per item. Naming the destination *before* you
    /// type also holds it for a whole run of items, which is how a bag actually
    /// gets packed.
    ///
    /// A plain `Picker` row rather than a control crowded onto the "Add item" line:
    /// there it sat against the Add button with both rendered in grey, reading as
    /// one ambiguous "Other Add". As a row it matches the Start/End pickers above
    /// and states the destination in full.
    @ViewBuilder private var addDestinationPicker: some View {
        if !allContainers.isEmpty {
            Picker(selection: $addContainerName) {
                Text(Str.Trip.packingOther).tag("")
                ForEach(allContainers) { container in
                    Label(container.name, systemImage: container.symbolName).tag(container.name)
                }
            } label: {
                // The icon tracks the selection, so the row shows the destination
                // twice over — glyph and name — for a control read at arm's length
                // over an open suitcase.
                Label("Add to", systemImage: addContainer?.symbolName ?? "tray")
            }
        }
    }

    /// The container `addDestinationMenu` currently points at, or `nil` for the
    /// ungrouped "Other" pile. Resolved by name each time rather than held as a
    /// reference, so a container renamed or deleted from Settings just falls back
    /// to ungrouped instead of dangling.
    private var addContainer: PackingContainer? {
        allContainers.first { $0.name == addContainerName }
    }

    /// Other trips whose packing lists could seed this one.
    private var otherPackedTrips: [Trip] {
        allTrips.filter {
            $0.persistentModelID != trip.persistentModelID && !($0.packing ?? []).isEmpty
        }
    }

    /// Whether the header's overflow menu has anything to offer — otherwise it's
    /// hidden rather than opening onto nothing.
    private var hasPackingOptions: Bool {
        !(trip.packing ?? []).isEmpty || !templates.isEmpty || !otherPackedTrips.isEmpty
    }

    /// "Start from…" — applies a saved template or copies another trip's packing
    /// list. Hidden entirely when there's nothing to start from.
    @ViewBuilder private var packingStartFromMenu: some View {
        if !templates.isEmpty || !otherPackedTrips.isEmpty {
            Menu {
                if !templates.isEmpty {
                    Section("Templates") {
                        ForEach(templates) { template in
                            Button(template.name.isEmpty ? "Untitled" : template.name) {
                                applyTemplate(template)
                            }
                        }
                    }
                }
                if !otherPackedTrips.isEmpty {
                    Section("Copy from trip") {
                        ForEach(otherPackedTrips) { other in
                            Button(other.title.isEmpty ? "Untitled Trip" : other.title) {
                                copyPacking(from: other)
                            }
                        }
                    }
                }
            } label: {
                // Three unrelated meanings used to share the tray metaphor: this
                // menu, the "Other" group's icon, and the move-to-container
                // button. The tray now belongs to containers alone; starting from
                // a saved list is a stack-of-lists action, matching "Save as
                // template…" below.
                Label("Start from…", systemImage: "rectangle.stack")
            }
        }
    }

    /// Notes are one Markdown string, split on its `# ` headings into a field per
    /// section (see `NoteSection`). The lead field — everything before the first
    /// heading — is the plain "Notes" box the trip has always had, so a note
    /// written before sections existed keeps behaving exactly as it did.
    ///
    /// Each body keeps the old two-mode swap: a rendered preview normally (the
    /// assistant's `suggestNotes` writes bold headings and bullet lists, which a
    /// bare `TextField` shows as raw asterisks), the raw editor after a tap.
    @ViewBuilder private var notesSections: some View {
        ForEach($noteSections) { $section in
            Section {
                noteBody(for: $section)
                // The assistant appends to the note as a whole, so its button
                // belongs to the lead section rather than to every heading.
                if section.title == nil, canUseAssistant {
                    fillButton(field: .notes, action: fillNotes)
                }
            } header: {
                noteHeader(for: $section)
            }
            // Headings are text the user wrote; a section header would otherwise
            // upper-case them and misrepresent what's stored.
            .textCase(nil)
        }
        Section {
            addNoteSectionMenu
        }
    }

    /// One section's body: the rendered preview until tapped, then the raw
    /// editor. A titled section can also have its heading removed from here,
    /// which merges its text upward rather than deleting anything.
    @ViewBuilder private func noteBody(for section: Binding<NoteSection>) -> some View {
        let id = section.wrappedValue.id
        Group {
            if section.wrappedValue.isBodyBlank || editingBodyID == id {
                TextField("Links, confirmations, ideas…", text: section.body, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($noteFocus, equals: .body(id))
                    // Only grabs focus when arriving via a tap on the preview —
                    // not when the section first shows an empty field, where a
                    // keyboard popping up unasked would be hostile.
                    .onAppear { if editingBodyID == id { noteFocus = .body(id) } }
            } else {
                TripNotesPreview(markdown: section.wrappedValue.body)
                    .contentShape(.rect)
                    .onTapGesture { editingBodyID = id }
                    // The tap-to-edit affordance is invisible to assistive tech.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(
                        Text("Edits the notes", comment: "Accessibility hint on the notes preview"))
            }
        }
        .swipeActions(edge: .trailing) {
            if section.wrappedValue.title != nil {
                Button {
                    removeHeading(id)
                } label: {
                    Label("Remove section heading", systemImage: "text.badge.minus")
                }
            }
        }
        .contextMenu {
            if section.wrappedValue.title != nil {
                Button {
                    removeHeading(id)
                } label: {
                    Label("Remove section heading", systemImage: "text.badge.minus")
                }
            }
        }
    }

    /// The lead section keeps the static "Notes" title; every other section's
    /// header *is* its heading, editable in place. "Done" is the explicit way out
    /// of the raw editor — nothing inside a `List` takes focus away, so tapping
    /// another row would otherwise leave the raw Markdown on screen with no way
    /// back to the preview.
    @ViewBuilder private func noteHeader(for section: Binding<NoteSection>) -> some View {
        let id = section.wrappedValue.id
        HStack {
            if section.wrappedValue.title == nil {
                Text("Notes")
            } else {
                TextField(
                    "Section title",
                    text: Binding(
                        get: { section.wrappedValue.title ?? "" },
                        set: { section.wrappedValue.title = $0 })
                )
                .font(.headline)
                .focused($noteFocus, equals: .title(id))
            }
            Spacer()
            if editingBodyID == id {
                Button("Done") {
                    editingBodyID = nil
                    noteFocus = nil
                }
                .modifier(NotesHeaderButton())
            } else if !section.wrappedValue.isBodyBlank {
                // Setting the flag swaps in the field, whose `.onAppear` takes
                // focus — the same path a tap on the preview follows. The pencil
                // does the real discoverability work: the rendered preview below
                // is tappable but looks inert, so the header needs to signal that
                // this section is editable at all.
                Button { editingBodyID = id } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .modifier(NotesHeaderButton())
            }
        }
        .animation(.snappy, value: editingBodyID)
    }

    /// Starter headings, so the feature is discoverable as something other than
    /// an empty box. Each is just text: the emoji is the first character of the
    /// heading, needing no storage of its own and exporting like any other.
    private var addNoteSectionMenu: some View {
        Menu {
            ForEach(NoteSectionPreset.allCases) { preset in
                Button(preset.title) { addNoteSection(titled: preset.title) }
            }
            Divider()
            Button("Custom section…") { addNoteSection(titled: "") }
        } label: {
            Label("Add section", systemImage: "text.append")
        }
    }

    private func addNoteSection(titled title: String) {
        let section = NoteSection(title: title, bodyLines: [""])
        withAnimation(.snappy) { noteSections.append(section) }
        writeNotesThrough()
        // A preset lands ready to write in; a custom one needs its name first.
        editingBodyID = title.isEmpty ? nil : section.id
        noteFocus = title.isEmpty ? .title(section.id) : .body(section.id)
    }

    /// Drops a section's heading and folds its text into the section above.
    /// Nothing is deleted, which is what lets this be a one-tap action with no
    /// confirmation — to remove the text you clear the field.
    private func removeHeading(_ id: NoteSection.ID) {
        guard let index = noteSections.firstIndex(where: { $0.id == id }), index > 0 else { return }
        withAnimation(.snappy) {
            let removed = noteSections.remove(at: index)
            noteSections[index - 1].bodyLines.append(contentsOf: removed.bodyLines)
        }
        writeNotesThrough()
    }

    /// Mirrors the fields back into `trip.notes` on every keystroke, exactly as
    /// the single bound field used to, so leaving the screen can never lose text.
    /// Deliberately does *not* re-parse: rebuilding the field list mid-word would
    /// change view identity and yank the cursor. Restructuring is `reparseNotes`.
    private func writeNotesThrough() {
        let text = NoteSection.serialize(noteSections)
        if text != trip.notes { trip.notes = text }
    }

    /// Re-derives the fields once editing ends — this is where a "# " typed
    /// inside a body finally becomes its own section. Skipped when the heading
    /// structure is unchanged, so tabbing between fields doesn't churn identity.
    private func reparseNotes() {
        let reparsed = NoteSection.parse(trip.notes)
        guard reparsed.map(\.title) != noteSections.map(\.title) else { return }
        withAnimation(.snappy) { noteSections = reparsed }
    }

    /// What the trip as a whole carries rather than any one stop: files (insurance,
    /// a passport scan, a group itinerary PDF), web links (a booking page, the
    /// city's transport timetable) and contacts (the insurer's emergency line, a
    /// tour operator). Attachments are stored inside the trip itself
    /// (`.externalStorage`), so they're on-device at a gate with no connectivity.
    ///
    /// One section rather than three, and no placeholders: an empty trip shows a
    /// single "Add to trip" row instead of three empty sections whose footers had
    /// to explain which level each kind of item belonged to. The scope is now
    /// carried by *where you add from* — this menu for the whole trip, a stop's own
    /// menu for that stop — so there's nothing left to spell out.
    private var essentialsSection: some View {
        Section {
            ForEach(trip.documents) { attachment in
                AttachmentRow(attachment: attachment) { openAttachment(attachment) }
            }
            .onDelete(perform: deleteDocuments)
            ForEach(trip.tripLinks) { link in
                LinkRow(link: link) { modelContext.delete(link) }
            }
            .onDelete(perform: deleteTripLinks)
            ForEach(trip.tripContacts) { contact in
                ContactRow(contact: contact) { modelContext.delete(contact) }
            }
            .onDelete(perform: deleteTripContacts)
            Menu {
                Button {
                    // A trip-level document isn't tied to any stop.
                    attachingToStop = nil
                    showAttachmentImporter = true
                } label: {
                    Label("Add file", systemImage: "paperclip")
                }
                Button(action: addTripLink) {
                    Label("Add link", systemImage: "link")
                }
                Button(action: addTripContact) {
                    Label("Add contact", systemImage: "person.crop.circle.badge.plus")
                }
            } label: {
                Label("Add to trip", systemImage: "plus")
            }
        } header: {
            Text("Essentials")
        }
    }

    private func addTripContact() {
        let contact = TripContact(order: trip.tripContacts.count, trip: trip)
        modelContext.insert(contact)
        if trip.contacts == nil { trip.contacts = [] }
        withAnimation(.snappy) { trip.contacts?.append(contact) }
    }

    private func deleteTripContacts(_ offsets: IndexSet) {
        let contacts = trip.tripContacts
        for index in offsets { modelContext.delete(contacts[index]) }
    }

    private func addTripLink() {
        let link = TripLink(order: trip.tripLinks.count, trip: trip)
        modelContext.insert(link)
        if trip.links == nil { trip.links = [] }
        withAnimation(.snappy) { trip.links?.append(link) }
    }

    private func deleteTripLinks(_ offsets: IndexSet) {
        let links = trip.tripLinks
        for index in offsets { modelContext.delete(links[index]) }
    }

    /// A section-scoped empty state: symbol above a line of text, centred in the
    /// row. Deliberately lighter than `ContentUnavailableView`, which is sized for
    /// a whole screen and dwarfs the add button sitting right beneath it.
    private func emptySectionPlaceholder(symbol: String, message: Text) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
            message
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    /// The on-device assistant is only offered when Apple Intelligence is ready
    /// *and* the trip has at least one country — its suggestions are driven by the
    /// destinations and their season.
    private var canUseAssistant: Bool {
        planner.isAvailable && !trip.countries.isEmpty
    }

    /// A shared "Fill with LLM" row that shows a spinner while its field generates
    /// or translates, and disables itself while any generation is in flight.
    private func fillButton(field: TripPlanner.Field, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if planner.busy == field || translating == field {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Generating…")
                }
            } else {
                Label("Fill with LLM", systemImage: "sparkles")
            }
        }
        .disabled(planner.busy != nil || translating != nil)
    }

    // MARK: Mutations

    /// The next free ordering slot, so a new stop lands at the end of the list.
    private var nextStopOrder: Int { ((trip.itinerary ?? []).map(\.order).max() ?? -1) + 1 }

    /// Adds a place picked from search as a stop carrying its own coordinate and
    /// address line. Its country is resolved from the location (see
    /// `resolveCountry`) rather than chosen by hand, so the flag chip and the
    /// trip's hero flags fill themselves in.
    private func addPlace(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        let stop = ItineraryItem(
            title: item.name ?? String(localized: "Place"),
            order: nextStopOrder, country: nil, trip: trip,
            detail: item.address?.shortAddress ?? item.address?.fullAddress ?? "",
            latitude: coordinate.latitude, longitude: coordinate.longitude)
        insertStop(stop)
        resolveCountry(for: stop, at: coordinate)
    }

    /// Adds one of the app's countries as a country/region stop (flag + name, no
    /// coordinate) — for planning "we're going to Latvia" before picking places,
    /// and the way to add a second country when place search is region-locked.
    private func addCountryStop(_ country: Country) {
        let stop = ItineraryItem(order: nextStopOrder, country: country, trip: trip)
        insertStop(stop)
        if country.planStatus == .none { country.planStatus = .planning }
    }

    /// Adds a free-form stop the user typed — no map location, so no auto country
    /// (they can leave it untagged, or it groups under "No country").
    private func addCustomStop(_ title: String) {
        insertStop(ItineraryItem(title: title, order: nextStopOrder, trip: trip))
    }

    private func insertStop(_ stop: ItineraryItem) {
        modelContext.insert(stop)
        if trip.itinerary == nil { trip.itinerary = [] }
        trip.itinerary?.append(stop)
    }

    /// Resolves a place's coordinate to its country using the bundled country
    /// outlines (the same `\.countryPaths` `TripPhotoSuggestionsSheet` matches
    /// photos against), and tags the stop — so its flag chip and the trip's hero
    /// flags reflect it and the country joins the blue "going" plan layer. Fully
    /// on-device: no network, no deprecated geocoder. Best-effort — if nothing
    /// contains the point (or the outlines haven't loaded) the stop stays
    /// unflagged, exactly as a country-less custom stop would.
    private func resolveCountry(for stop: ItineraryItem, at coordinate: CLLocationCoordinate2D) {
        let mapPoint = MKMapPoint(coordinate)
        let point = CGPoint(x: mapPoint.x, y: mapPoint.y)
        var matchedID: String?
        outer: for (id, rings) in countryPaths {
            for ring in rings where ring.contains(point) {
                matchedID = id
                break outer
            }
        }
        guard let matchedID,
            let country = allCountries.first(where: { $0.id == matchedID })
        else { return }
        stop.country = country
        if country.planStatus == .none { country.planStatus = .planning }
    }

    /// Applies a drag-to-reorder of the itinerary (a single collection) and
    /// renumbers every stop's `order` so the new arrangement persists. Only wired
    /// up in Manual sort. Uses the legacy `.onMove` API (macOS 14 / iOS 17).
    private func moveItineraryStop(from source: IndexSet, to destination: Int) {
        var ordered = trip.sortedStops
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, stop) in ordered.enumerated() { stop.order = index }
    }

    private func deleteDisplayed(_ offsets: IndexSet, in stops: [ItineraryItem]) {
        for index in offsets { modelContext.delete(stops[index]) }
    }

    private func addPacking() {
        let title = newPackingTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let item = PackingItem(title: title, order: nextPackingOrder, trip: trip)
        item.container = addContainer
        // Animated so the new row slides into its group rather than popping in —
        // when you're adding a run of items, it's the only confirmation that each
        // one landed where you expected.
        withAnimation(.snappy) {
            modelContext.insert(item)
            trip.packing?.append(item)
        }
        newPackingTitle = ""
    }

    /// The next free ordering slot, so a new item lands at the end of its group.
    private var nextPackingOrder: Int { ((trip.packing ?? []).map(\.order).max() ?? -1) + 1 }

    private func clearPacking() {
        for item in trip.packing ?? [] { modelContext.delete(item) }
    }

    /// Applies a drag-to-reorder *within a single container group*, renumbering
    /// that group's items so `order` stays contiguous.
    ///
    /// Cross-container drags are intentionally not supported by the legacy `.onMove`
    /// API (each `ForEach` is scoped to its section), which matches the old
    /// behaviour — use the row's container menu to move an item to a different bag.
    private func movePackingItem(in group: PackingGroup, from source: IndexSet, to destination: Int) {
        var items = group.items
        items.move(fromOffsets: source, toOffset: destination)
        for (index, item) in items.enumerated() { item.order = index }
    }

    // MARK: Templates

    /// Appends a saved template's items, skipping titles already on the list
    /// (case-insensitive) and resolving each item's container by name.
    private func applyTemplate(_ template: PackingTemplate) {
        addPackingItems(
            (template.items ?? []).sorted { $0.order < $1.order }
                .map { ($0.title, $0.quantity, $0.containerName) })
    }

    /// Appends another trip's packing items, skipping duplicates and resolving
    /// containers by name so they file into this trip's catalog.
    private func copyPacking(from other: Trip) {
        addPackingItems(
            (other.packing ?? []).sorted { $0.order < $1.order }
                .map { ($0.title, $0.quantity, $0.container?.name ?? "") })
    }

    /// Shared appender for templates and trip-copies: inserts each `(title,
    /// quantity, containerName)` not already present, in increasing `order`.
    private func addPackingItems(_ sources: [(title: String, quantity: Int, containerName: String)])
    {
        var existing = Set((trip.packing ?? []).map { $0.title.lowercased() })
        var cache: [String: PackingContainer] = [:]
        var order = nextPackingOrder
        for source in sources {
            let key = source.title.lowercased()
            guard !key.isEmpty, !existing.contains(key) else { continue }
            existing.insert(key)
            let item = PackingItem(
                title: source.title, quantity: source.quantity, order: order, trip: trip)
            item.container = resolveContainer(named: source.containerName, cache: &cache)
            modelContext.insert(item)
            trip.packing?.append(item)
            order += 1
        }
    }

    /// Saves the current packing list as a reusable template, storing each item's
    /// container by name for portability.
    private func saveTemplate() {
        let name = newTemplateName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !(trip.packing ?? []).isEmpty else { return resetTemplateDraft() }
        let template = PackingTemplate(name: name)
        modelContext.insert(template)
        for (index, source) in (trip.packing ?? []).sorted(by: { $0.order < $1.order }).enumerated() {
            let templateItem = PackingTemplateItem(
                title: source.title, quantity: source.quantity, order: index,
                containerName: source.container?.name ?? "", template: template)
            modelContext.insert(templateItem)
            template.items?.append(templateItem)
        }
        resetTemplateDraft()
    }

    private func resetTemplateDraft() {
        newTemplateName = ""
        showSaveTemplate = false
    }

    // MARK: Containers

    /// Pre-creates a small starter set of containers the first time any trip is
    /// opened, so grouping is useful immediately. Runs once — it no-ops as soon as
    /// the shared catalog has anything in it.
    private func seedContainersIfNeeded() {
        guard allContainers.isEmpty else { return }
        let defaults: [(String, String)] = [
            ("Carry-on", "suitcase.rolling.fill"),
            ("Personal item", "backpack.fill"),
            ("Checked bag", "suitcase.fill"),
        ]
        for (index, container) in defaults.enumerated() {
            modelContext.insert(
                PackingContainer(name: container.0, symbolName: container.1, sortOrder: index))
        }
    }

    private func createContainer() {
        let name = newContainerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return resetContainerDraft() }
        let order = (allContainers.map(\.sortOrder).max() ?? -1) + 1
        let container = PackingContainer(name: name, sortOrder: order)
        modelContext.insert(container)
        if let item = pendingContainerItem { item.container = container }
        resetContainerDraft()
    }

    private func resetContainerDraft() {
        newContainerName = ""
        pendingContainerItem = nil
    }

    /// Maps a container name from the assistant to a real container: an existing
    /// one (matched case-insensitively, so it never duplicates "Carry-on"), one
    /// created earlier in this same fill, or a brand-new container. `cache` keeps
    /// names consistent within a fill, since `allContainers` won't refresh mid-loop.
    private func resolveContainer(
        named raw: String, cache: inout [String: PackingContainer]
    ) -> PackingContainer? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let existing = allContainers.first(where: { $0.name.lowercased() == key }) {
            return existing
        }
        if let created = cache[key] { return created }
        let order = (allContainers.map(\.sortOrder).max() ?? -1) + 1 + cache.count
        let container = PackingContainer(name: name, sortOrder: order)
        modelContext.insert(container)
        cache[key] = container
        return container
    }

    // MARK: On-device assistant

    /// Asks the on-device model for a packing list (named in English), translates
    /// the item names into the user's language, then inserts them. `translator`
    /// returns the English names unchanged when the app runs in English or the
    /// language pair is unavailable, so the list always lands.
    private func fillPacking() {
        Task {
            guard
                let suggestions = await planner.suggestPacking(
                    for: trip, containers: allContainers.map(\.name))
            else { return }

            translating = .packing
            defer { translating = nil }
            let titles = await translator.translate(suggestions.map(\.title))
            insertPacking(
                zip(suggestions, titles).map { suggestion, title in
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return PackingSuggestion(
                        title: name.isEmpty ? suggestion.title : name,
                        quantity: suggestion.quantity,
                        containerName: suggestion.containerName)
                })
        }
    }

    /// Asks the on-device model for sightseeing notes (in English), translates them
    /// into the user's language (English passes straight through), then appends.
    private func fillNotes() {
        Task {
            guard let text = await planner.suggestNotes(for: trip) else { return }
            translating = .notes
            defer { translating = nil }
            let translated = await translator.translate(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            insertNotes(translated.isEmpty ? text : translated)
        }
    }

    /// Appends packing suggestions, filing each into its container and skipping any
    /// item already present (case-insensitive) so the user's own entries are kept.
    private func insertPacking(_ suggestions: [PackingSuggestion]) {
        var existing = Set((trip.packing ?? []).map { $0.title.lowercased() })
        var createdContainers: [String: PackingContainer] = [:]
        var order = nextPackingOrder
        for suggestion in suggestions {
            let key = suggestion.title.lowercased()
            guard !existing.contains(key) else { continue }
            existing.insert(key)
            let item = PackingItem(
                title: suggestion.title, quantity: suggestion.quantity, order: order, trip: trip)
            item.container = resolveContainer(
                named: suggestion.containerName, cache: &createdContainers)
            modelContext.insert(item)
            trip.packing?.append(item)
            order += 1
        }
    }

    /// Per-file attachment cap. Tickets and confirmations are typically well
    /// under a megabyte; the cap only exists to keep an accidental video pick
    /// from ballooning the store.
    private static let maxAttachmentBytes = 25 * 1024 * 1024

    /// Copies the picked files into the trip as attachments. Oversized or
    /// unreadable files are skipped with an alert; the rest still attach.
    /// Queues a picked file to attach to `stop` rather than the trip as a whole,
    /// then opens the importer (shared with Essentials' trip-level "Add file").
    private func attachToStop(_ stop: ItineraryItem) {
        attachingToStop = stop
        showAttachmentImporter = true
    }

    private func attachFiles(_ result: Result<[URL], Error>) {
        // Which stop (if any) these files belong to was set just before the
        // importer opened; clear it once we're done so the next pick defaults to
        // a trip-level document.
        let targetStop = attachingToStop
        defer { attachingToStop = nil }
        switch result {
        case .failure(let error):
            attachmentAlert = error.localizedDescription
        case .success(let urls):
            var order = ((trip.attachments ?? []).map(\.order).max() ?? -1) + 1
            for url in urls {
                let needsAccess = url.startAccessingSecurityScopedResource()
                defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    guard data.count <= Self.maxAttachmentBytes else {
                        attachmentAlert = String(
                            localized:
                                "Files over \(Self.maxAttachmentBytes / 1_048_576) MB can't be attached.",
                            comment: "Alert when a picked attachment exceeds the size limit")
                        continue
                    }
                    let attachment = TripAttachment(
                        filename: url.lastPathComponent, data: data, order: order, trip: trip,
                        item: targetStop)
                    modelContext.insert(attachment)
                    if trip.attachments == nil { trip.attachments = [] }
                    trip.attachments?.append(attachment)
                    if let targetStop {
                        if targetStop.attachments == nil { targetStop.attachments = [] }
                        targetStop.attachments?.append(attachment)
                    }
                    order += 1
                } catch {
                    attachmentAlert = error.localizedDescription
                }
            }
        }
    }

    /// Writes the attachment to a fresh temp file (named after the original,
    /// in its own UUID'd subdirectory, same scheme as `exportPDFAndOpen`) and
    /// opens it — default app on macOS, in-place Quick Look preview on iOS.
    private func openAttachment(_ attachment: TripAttachment) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(sanitizedFileName(attachment.filename))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try attachment.data.write(to: url, options: .atomic)
            #if os(macOS)
                NSWorkspace.shared.open(url)
            #else
                filePreviewURL = url
            #endif
        } catch {
            attachmentAlert = error.localizedDescription
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        let ordered = trip.documents
        for index in offsets { modelContext.delete(ordered[index]) }
    }

    /// Appends generated notes, preserving anything the user has already written.
    private func insertNotes(_ text: String) {
        if trip.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trip.notes = text
        } else {
            trip.notes += "\n\n" + text
        }
    }
}

/// One attachment row: a type icon, the original filename, and the stored size.
/// The whole row opens the file — Quick Look on iOS, the default app on macOS.
private struct AttachmentRow: View {
    let attachment: TripAttachment
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Int64(attachment.byteCount), format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbolName: String {
        switch (attachment.filename as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff": "photo"
        case "pkpass": "wallet.pass"
        default: "doc"
        }
    }
}

/// Read-only rendering of the minimal Markdown subset trip notes use — the same
/// subset `TripPDFRenderer.notesContent` draws in the PDF export: `#`–`###`
/// headings, a line that's entirely `**bold**` (how `suggestNotes` marks its
/// country headings), `-`/`*` bullets, and inline `**bold**`/`*italic*` spans.
/// Line classification is shared with the PDF renderer so the two never
/// disagree; anything unrecognised stays plain text.
private struct TripNotesPreview: View {
    let markdown: String

    private enum Line {
        case heading(String)
        case bullet(String)
        case body(String)
    }

    private var lines: [Line] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let heading = TripPDFRenderer.headingText(trimmed) { return .heading(heading) }
            if let bullet = TripPDFRenderer.bulletText(trimmed) { return .bullet(bullet) }
            return .body(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                switch line {
                case .heading(let text):
                    Text(inline(text))
                        .font(.headline)
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(inline(text))
                    }
                case .body(let text):
                    Text(inline(text))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// Styles inline spans (`**bold**`, `*italic*`, `` `code` ``) within one
    /// line; on a parse error the raw text shows as-is.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Minimum tappable size for the small glyph buttons in the trip rows. 44pt is
/// the iOS HIG floor; macOS drives with a pointer, where 44pt would bloat these
/// already-dense nested rows.
#if os(macOS)
    private let minimumHitTarget: CGFloat = 28
#else
    private let minimumHitTarget: CGFloat = 44
#endif

/// A packing-list row: a tappable check-off control on the left and a "move to
/// container" menu on the right. Editing `item.container` directly persists the
/// change through SwiftData.
private struct PackingItemRow: View {
    @Bindable var item: PackingItem
    let containers: [PackingContainer]
    /// Invoked when the user picks "New container…" so the parent can present the
    /// naming alert with this item queued to be filed into the new container.
    let onNewContainer: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Three controls on one line only works while the title has room to breathe.
    /// At accessibility sizes the stepper and menu grow enough to crush it down to
    /// a couple of characters, so the row stacks instead. Keyed on the type size
    /// rather than `ViewThatFits` so a merely *long* item name doesn't reflow the
    /// layout at normal sizes.
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                checkOffControl
                HStack {
                    quantityStepper
                    Spacer()
                    containerMenu
                }
            }
        } else {
            HStack {
                checkOffControl
                Spacer()
                quantityStepper
                containerMenu
            }
        }
    }

    private var checkOffControl: some View {
        Button {
            item.isPacked.toggle()
            #if canImport(WatchConnectivity)
                PackingDeltaSync.send(dedupID: item.dedupID, isPacked: item.isPacked)
            #endif
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.isPacked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isPacked ? .green : .secondary)
                Text(item.title)
                    .strikethrough(item.isPacked)
                    .foregroundStyle(item.isPacked ? .secondary : .primary)
                if item.quantity > 1 {
                    Text("×\(item.quantity)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Reads as a switch: "Sunscreen, on/off" — clearer than a button
        // whose label happens to contain a checkmark image.
        .accessibilityLabel(item.title)
        .accessibilityValue(
            item.isPacked
                ? Text("Packed", comment: "Accessibility value: packing item is checked off")
                : Text("Not packed", comment: "Accessibility value: packing item still open"))
        .accessibilityAddTraits(.isToggle)
        // The tactile heart of the screen — you check these off standing over a
        // suitcase, often without looking at the phone.
        .sensoryFeedback(.impact(flexibility: .soft), trigger: item.isPacked)
    }

    private var quantityStepper: some View {
        Stepper("Quantity", value: $item.quantity, in: 1...99)
            .labelsHidden()
    }

    private var containerMenu: some View {
        Menu {
            Picker("Container", selection: containerSelection) {
                // Named for the group the item visibly lands in, matching the
                // "Add item" row's destination menu and the group header itself.
                Text(Str.Trip.packingOther).tag(nil as PersistentIdentifier?)
                ForEach(containers) { container in
                    Label(container.name, systemImage: container.symbolName)
                        .tag(container.persistentModelID as PersistentIdentifier?)
                }
            }
            Divider()
            Button {
                onNewContainer()
            } label: {
                Label("New container…", systemImage: "plus")
            }
        } label: {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(.secondary)
                // The glyph alone is ~20pt — well under the touch minimum, and it
                // sits a thumb's width from the stepper.
                .frame(width: minimumHitTarget, height: minimumHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Move to container"))
    }

    private var containerSelection: Binding<PersistentIdentifier?> {
        Binding(
            get: { item.container?.persistentModelID },
            set: { id in item.container = containers.first { $0.persistentModelID == id } })
    }
}

/// One country's stops for the itinerary's By-country view: the flag, the
/// localized name, and the stops filed under it. A grouping for *display* only —
/// the stops remain a flat list; this never becomes a stored container.
private struct ItineraryCountryGroup: Identifiable {
    let id: String
    let flag: String
    let name: String
    let stops: [ItineraryItem]

    var headerText: String { "\(flag) \(name)" }
}

/// An inline-editable itinerary stop — the single flat unit the itinerary is now
/// built from. It's either a *place* (a pin picked from search, shown with 📍, an
/// address line and an "Open in Apple Maps" button) or a *country / region*
/// marker (shown with its flag). Either way it carries its own optional date,
/// note, and attached files. Places-to-see are no longer nested inside a stop —
/// they *are* stops, siblings in the same list.
private struct StopRow: View {
    @Bindable var stop: ItineraryItem
    /// Whether to show the country as a flag chip on this row. Hidden in the
    /// By-country view, where the section header already names the country.
    let showCountryChip: Bool
    /// Queues a file to attach to *this* stop, then opens the shared importer.
    let onAddAttachment: () -> Void
    /// Opens an attached file (Quick Look on iOS, default app on macOS).
    let onOpenAttachment: (TripAttachment) -> Void
    @Environment(\.modelContext) private var modelContext
    /// Whether the note field is on screen. Every other optional field is driven
    /// by its own content — a date shows because there *is* a date — but a note
    /// starts empty, so this bridges the gap between choosing "Add note" and
    /// typing into it.
    @State private var showsNote: Bool
    /// Set when "Add note" is chosen so the freshly revealed field takes focus,
    /// and cleared the moment it does. A plain `onAppear` check would re-grab
    /// focus every time the row scrolled back into view.
    @State private var focusNoteOnAppear = false
    @FocusState private var noteFocused: Bool

    init(
        stop: ItineraryItem,
        showCountryChip: Bool,
        onAddAttachment: @escaping () -> Void,
        onOpenAttachment: @escaping (TripAttachment) -> Void
    ) {
        self.stop = stop
        self.showCountryChip = showCountryChip
        self.onAddAttachment = onAddAttachment
        self.onOpenAttachment = onOpenAttachment
        _showsNote = State(initialValue: !stop.note.isEmpty)
    }

    /// A stop with a coordinate came from place search — render it as a place.
    private var isPlace: Bool { stop.coordinate != nil }

    /// A sensible date for a stop the user just decided to schedule: pick up from
    /// the last dated stop (so a run of stops flows forward from where the plan
    /// left off), else the trip's own start — never today, which is rarely where
    /// a planned trip begins.
    private var defaultStopDate: Date {
        let others = (stop.trip?.sortedStops ?? []).filter { $0 !== stop }
        if let latest = others.compactMap(\.date).max() { return latest }
        return stop.trip?.startDate ?? Date()
    }

    /// The trip's span, used to keep a stop's date inside it — a stop can't fall
    /// before the trip starts or after it ends. `nil` when there's no trip or the
    /// span is somehow inverted, leaving the picker unbounded rather than crashing
    /// on a bad `ClosedRange`.
    private var tripDateRange: ClosedRange<Date>? {
        guard let trip = stop.trip, trip.startDate <= trip.endDate else { return nil }
        return trip.startDate...trip.endDate
    }

    /// Every field is driven by its own content: a stop that carries nothing is a
    /// single line, and each editor appears the moment there's something for it to
    /// hold. Adding any of them is one control — `detailMenu`, on the identity row
    /// — rather than a permanently open row per capability, which left a plain
    /// stop standing nine rows tall with seven of them empty.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            identityRow
            secondaryLine
            if stop.transport != nil { transportEditor }
            if stop.date != nil { dateEditor }
            if showsNote {
                // `.subheadline`, not `.caption`: this is text the user wrote, and
                // the caption styles are for metadata *about* content, not content.
                TextField("Note", text: $stop.note, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...3)
                    .focused($noteFocused)
                    .onAppear {
                        if focusNoteOnAppear {
                            focusNoteOnAppear = false
                            noteFocused = true
                        }
                    }
            }
            attachments
            links
            contacts
        }
        .padding(.vertical, 2)
    }

    /// The stop's date and how long you're staying. Shown only once a date is
    /// set — "Set a date" in `detailMenu` assigns `defaultStopDate`, which is
    /// what reveals this; "Remove date" clears it away again.
    @ViewBuilder private var dateEditor: some View {
        let selection = Binding(get: { stop.date ?? defaultStopDate }, set: { stop.date = $0 })
        // Clamp to the trip's span so a stop's date can't wander outside it;
        // unbounded only when there's no valid range.
        if let range = tripDateRange {
            DatePicker("Date", selection: selection, in: range, displayedComponents: .date)
        } else {
            DatePicker("Date", selection: selection, displayedComponents: .date)
        }
        // How long you're here, inferred from the gap to the next dated stop (the
        // trip's end for the last one). A gray hint, not an editable field — see
        // `ItineraryItem.stayDayCount`.
        if let days = stop.stayDayCount {
            Text("^[\(days) day](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Everything optional a stop can carry, behind one control on the identity
    /// row. Entries drop out as they're taken up — a stop that already has a date
    /// offers to remove it instead — so the menu only ever lists what's actually
    /// available to do next.
    private var detailMenu: some View {
        Menu {
            Button {
                withAnimation(.snappy) { stop.date = stop.date == nil ? defaultStopDate : nil }
            } label: {
                stop.date == nil
                    ? Label("Set a date", systemImage: "calendar")
                    : Label("Remove date", systemImage: "calendar.badge.minus")
            }
            // Once a mode is picked the row shows its own copy of this picker, so
            // the mode can be changed or cleared where it's displayed.
            if stop.transport == nil { transportPicker }
            if !showsNote {
                Button {
                    focusNoteOnAppear = true
                    withAnimation(.snappy) { showsNote = true }
                } label: {
                    Label("Add note", systemImage: "text.alignleft")
                }
            }
            Button(action: onAddAttachment) {
                Label("Attach file", systemImage: "paperclip")
            }
            Button(action: addStopLink) {
                Label("Add link", systemImage: "link")
            }
            Button(action: addStopContact) {
                Label("Add contact", systemImage: "person.crop.circle.badge.plus")
            }
            if isPlace {
                Divider()
                Button(action: openInMaps) {
                    Label("Open in Apple Maps", systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // The glyph alone is well under the touch minimum, and it sits
                // beside a text field that would otherwise swallow near misses.
                .frame(width: minimumHitTarget, height: minimumHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("Add detail")
        .accessibilityLabel(Text("Add detail"))
    }

    /// "Getting here": how the traveler reaches this stop. Rendered only once a
    /// mode has been picked (from `detailMenu`) — the menu stays on the row so the
    /// mode can be changed or cleared where it shows, and the free-text field takes
    /// flight or bus numbers, times, rental and confirmation details. Boarding
    /// passes go in this stop's attachments.
    @ViewBuilder private var transportEditor: some View {
        Menu {
            transportPicker
        } label: {
            Label {
                Text(stop.transport?.label ?? String(localized: "Getting here"))
            } icon: {
                Image(systemName: stop.transport?.symbolName ?? "arrow.triangle.branch")
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderless)

        TextField("Flight no., times, confirmation…", text: $stop.transportDetail, axis: .vertical)
            .font(.subheadline)
            .lineLimit(1...3)
    }

    /// The mode list itself, shared by `detailMenu` (which offers it while the stop
    /// has no transport) and `transportEditor` (which offers it afterwards), so the
    /// two can't drift apart.
    private var transportPicker: some View {
        Picker("Getting here", selection: transportSelection) {
            Text("None").tag(TransportMode?.none)
            ForEach(TransportMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbolName)
                    .tag(TransportMode?.some(mode))
            }
        }
    }

    private var transportSelection: Binding<TransportMode?> {
        Binding(
            get: { stop.transport },
            set: { mode in withAnimation(.snappy) { stop.transport = mode } })
    }

    /// Links pinned to this stop (a bus timetable, a ticket page), each openable
    /// and removable. Adding one is in `detailMenu` — a stop with no links shows
    /// nothing here rather than a standing "Add link" button.
    @ViewBuilder private var links: some View {
        ForEach(stop.sortedLinks) { link in
            LinkRow(link: link) { modelContext.delete(link) }
        }
    }

    private func addStopLink() {
        let link = TripLink(order: (stop.links ?? []).count, trip: stop.trip, item: stop)
        modelContext.insert(link)
        if stop.links == nil { stop.links = [] }
        withAnimation(.snappy) { stop.links?.append(link) }
    }

    /// Contacts pinned to this stop — the hotel's front desk on the hotel stop,
    /// a guide on a booked tour. Mirrors `links`.
    @ViewBuilder private var contacts: some View {
        ForEach(stop.sortedContacts) { contact in
            ContactRow(contact: contact) { modelContext.delete(contact) }
        }
    }

    private func addStopContact() {
        let contact = TripContact(
            order: (stop.contacts ?? []).count, trip: stop.trip, item: stop)
        modelContext.insert(contact)
        if stop.contacts == nil { stop.contacts = [] }
        withAnimation(.snappy) { stop.contacts?.append(contact) }
    }

    /// The row's secondary line: the country as a flag chip (the whole point of
    /// "country as an attribute, not a level"), then the address line when the
    /// stop is a searched place. Hidden for country markers, whose flag+name are
    /// already the title, and in the By-country view, where the header names it.
    @ViewBuilder private var secondaryLine: some View {
        let country = showCountryChip && isPlace ? stop.country : nil
        let hasDetail = !stop.detail.isEmpty
        if country != nil || hasDetail {
            HStack(spacing: 6) {
                if let country {
                    Text("\(country.flagEmoji) \(country.localizedName)")
                }
                if country != nil && hasDetail {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
                if hasDetail {
                    Text(stop.detail)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// The stop's identity line: a pin for a place or a flag for a country/region,
    /// then its name. A country marker shows the country name with an optional
    /// custom name trailing; a place shows its own title.
    @ViewBuilder private var identityRow: some View {
        HStack(spacing: 8) {
            Text(isPlace ? "📍" : (stop.country?.flagEmoji ?? "📍"))
            if !isPlace, let country = stop.country {
                // The country *is* this marker's identity — real text, not a grey
                // prompt — with the optional custom name in the trailing value slot.
                Text(country.localizedName)
                    .font(.headline)
                Spacer(minLength: 12)
                TextField("Add a name", text: $stop.title)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            } else {
                // A place (or a country-less stop): whatever it's titled is its
                // only identity, so it stays primary.
                TextField(isPlace ? "Place" : "Stop", text: $stop.title)
                    .font(.headline)
            }
            detailMenu
        }
    }

    /// Files attached to this stop, each openable with a remove button. A List
    /// row can't host `.onDelete`, so each carries its own destructive control.
    /// Attaching one is in `detailMenu`.
    @ViewBuilder private var attachments: some View {
        ForEach(stop.sortedAttachments) { attachment in
            HStack(spacing: 8) {
                AttachmentRow(attachment: attachment) { onOpenAttachment(attachment) }
                Button(role: .destructive) {
                    modelContext.delete(attachment)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: minimumHitTarget, height: minimumHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Remove file")
                .accessibilityLabel(Text("Remove file"))
            }
        }
    }

    private func openInMaps() {
        guard let coordinate = stop.coordinate else { return }
        let item = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil)
        item.name = stop.displayTitle
        item.openInMaps()
    }
}

/// One editable link row — a title over its URL, an open button when the URL
/// parses, and a remove control. Shared by the trip-level Links section and each
/// stop's own links; both edit the `TripLink` in place, matching how stops and
/// packing items are edited inline rather than through a sheet.
private struct LinkRow: View {
    @Bindable var link: TripLink
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $link.title)
                    .font(.subheadline)
                TextField("https://…", text: $link.url)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
            }
            if let resolved = link.resolvedURL {
                Button {
                    openURL(resolved)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .help("Open link")
                .accessibilityLabel(Text("Open link"))
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: minimumHitTarget, height: minimumHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Remove link")
            .accessibilityLabel(Text("Remove link"))
        }
    }
}

/// One editable contact: its kind, a name, the number or address, and a button
/// that hands the value to the system — the dialer, WhatsApp, or a mail
/// composer. Mirrors `LinkRow`; the kind leads the row because it drives the
/// icon, the keyboard and what the action button does.
private struct ContactRow: View {
    @Bindable var contact: TripContact
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Contact kind", selection: $contact.contactKind) {
                    ForEach(ContactKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbolName).tag(kind)
                    }
                }
            } label: {
                Image(systemName: contact.contactKind.symbolName)
                    .font(.subheadline)
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help("Contact kind")
            .accessibilityLabel(Text("Contact kind"))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $contact.name)
                    .font(.subheadline)
                TextField(contact.contactKind.valuePrompt, text: $contact.value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(keyboardType)
                    #endif
            }

            // Absent until the value parses into something openable, so a
            // half-typed number doesn't offer a call that would fail.
            if let action = contact.actionURL {
                Button {
                    openURL(action)
                } label: {
                    Image(systemName: contact.contactKind.symbolName)
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .help(actionLabel)
                .accessibilityLabel(Text(actionLabel))
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: minimumHitTarget, height: minimumHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Remove contact")
            .accessibilityLabel(Text("Remove contact"))
        }
    }

    /// What the action button promises, phrased per kind so VoiceOver announces
    /// "Call" rather than a generic "Open".
    private var actionLabel: String {
        switch contact.contactKind {
        case .phone: String(localized: "Call", comment: "Contact action")
        case .whatsapp: String(localized: "Open WhatsApp", comment: "Contact action")
        case .email: String(localized: "Send email", comment: "Contact action")
        case .other: String(localized: "Open", comment: "Contact action")
        }
    }

    #if !os(macOS)
        private var keyboardType: UIKeyboardType {
            switch contact.contactKind {
            case .phone, .whatsapp: .phonePad
            case .email: .emailAddress
            case .other: .default
            }
        }
    #endif
}

