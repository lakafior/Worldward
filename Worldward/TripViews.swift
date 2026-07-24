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
    /// country. Stored as the raw value so `@AppStorage` can persist it.
    @AppStorage("tripItinerarySort") private var itinerarySortRaw = ItinerarySort.country.rawValue
    private var itinerarySort: ItinerarySort {
        ItinerarySort(rawValue: itinerarySortRaw) ?? .date
    }
    @State private var newPackingTitle = ""
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
    @State private var showManageContainers = false
    @State private var newContainerName = ""
    /// The item to file into the container being created, or `nil` when creating
    /// an empty container from the controls section.
    @State private var pendingContainerItem: PackingItem?
    /// Container groups the user has collapsed, keyed by `PackingGroup.id`.
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var showSaveTemplate = false
    @State private var newTemplateName = ""
    @State private var showPhotoSuggestions = false
    /// Swaps the Notes row between the read-only Markdown preview and the raw
    /// `TextField`. Tapping the preview flips it on; the field losing focus
    /// flips it back off (see `notesSection`).
    @State private var isEditingNotes = false
    @FocusState private var notesFieldFocused: Bool
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
                notesSection
                documentsSection
                linksSection
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
            .task { seedContainersIfNeeded() }
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
            .sheet(isPresented: $showManageContainers) {
                ManageContainersView()
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

    private func stopRow(_ stop: ItineraryItem, showCountryChip: Bool) -> some View {
        StopRow(
            stop: stop,
            showCountryChip: showCountryChip,
            onAddAttachment: { attachToStop(stop) },
            onOpenAttachment: { openAttachment($0) })
            // The iOS list has swipe-to-delete; macOS has no swipe, so a context
            // menu (right-click / long-press) is the way to remove a stop there —
            // and it's a fine second affordance on iOS too.
            .contextMenu {
                Button(role: .destructive) {
                    modelContext.delete(stop)
                } label: {
                    Label("Delete Stop", systemImage: "trash")
                }
            }
    }

    /// A section header carrying the sort control on its trailing edge. `.textCase(nil)`
    /// keeps "Itinerary" and country names in their natural case.
    private func itineraryHeader(_ leading: Text) -> some View {
        HStack {
            leading
            Spacer()
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
        .textCase(nil)
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

            Button {
                showManageContainers = true
            } label: {
                // `bag.badge.plus` promised "add a bag"; this row opens an editor.
                Label("Manage containers", systemImage: "bag")
            }

            packingStartFromMenu

            if canUseAssistant {
                fillButton(field: .packing, action: fillPacking)
            }

            if !(trip.packing ?? []).isEmpty {
                Button {
                    newTemplateName = trip.title
                    showSaveTemplate = true
                } label: {
                    // Was `square.and.arrow.down` — the *download* glyph, and the
                    // mirror image of the Share icon a few rows up, so the two
                    // opposite actions read as a matched pair. Saving a reusable
                    // list is a stack-of-lists action.
                    Label("Save as template…", systemImage: "rectangle.stack.badge.plus")
                }

                Button(role: .destructive) {
                    confirmClearPacking = true
                } label: {
                    Label("Clear list", systemImage: "trash")
                }
                .confirmationDialog(
                    "Remove all \((trip.packing ?? []).count) packing items?",
                    isPresented: $confirmClearPacking, titleVisibility: .visible
                ) {
                    Button("Clear list", role: .destructive, action: clearPacking)
                }
            }
        } header: {
            Text(
                (trip.packing ?? []).isEmpty
                    ? "Packing" : "Packing · \(trip.packedCount)/\((trip.packing ?? []).count)")
        }
    }

    /// "Start from…" — applies a saved template or copies another trip's packing
    /// list. Hidden entirely when there's nothing to start from.
    @ViewBuilder private var packingStartFromMenu: some View {
        let otherTrips = allTrips.filter {
            $0.persistentModelID != trip.persistentModelID && !($0.packing ?? []).isEmpty
        }
        if !templates.isEmpty || !otherTrips.isEmpty {
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
                if !otherTrips.isEmpty {
                    Section("Copy from trip") {
                        ForEach(otherTrips) { other in
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
                // template…" above.
                Label("Start from…", systemImage: "rectangle.stack")
            }
        }
    }

    /// Notes often carry Markdown (the assistant's `suggestNotes` writes bold
    /// country headings and bullet lists), which a bare `TextField` shows as raw
    /// asterisks and dashes. Since a text field can't render styled text, the
    /// row swaps between two modes: a read-only rendered preview normally, and
    /// the raw editor after a tap — ended again by the field losing focus.
    private var notesSection: some View {
        Section {
            if trip.notes.isEmpty || isEditingNotes {
                TextField("Links, confirmations, ideas…", text: $trip.notes, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($notesFieldFocused)
                    // Only grabs focus when arriving via a tap on the preview —
                    // not when the section first shows the empty-notes field,
                    // where a keyboard popping up unasked would be hostile.
                    .onAppear { if isEditingNotes { notesFieldFocused = true } }
                    .onChange(of: notesFieldFocused) { isEditingNotes = notesFieldFocused }
            } else {
                TripNotesPreview(markdown: trip.notes)
                    .contentShape(.rect)
                    .onTapGesture { isEditingNotes = true }
                    // The tap-to-edit affordance is invisible to assistive tech.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(
                        Text("Edits the notes", comment: "Accessibility hint on the notes preview"))
            }

            if canUseAssistant {
                fillButton(field: .notes, action: fillNotes)
            }
        } header: {
            notesSectionHeader
        }
    }

    /// Carries both halves of the notes mode switch. Editing is ended by the
    /// field losing focus, but nothing inside a `List` takes it away — tapping
    /// other rows or the space around them leaves a text field first responder,
    /// so the raw Markdown used to stay on screen with no way back to the
    /// preview. "Done" is the explicit way out (`.scrollDismissesKeyboard` on the
    /// list gives the gestural one), and "Edit" is the way *in*: the rendered
    /// preview is tappable but looks exactly like static text, so the one
    /// affordance it had was invisible.
    @ViewBuilder private var notesSectionHeader: some View {
        HStack {
            Text("Notes")
            Spacer()
            if isEditingNotes {
                Button("Done") { notesFieldFocused = false }
                    .modifier(NotesHeaderButton())
            } else if !trip.notes.isEmpty {
                // Setting the flag swaps in the field, whose `.onAppear` takes
                // focus — the same path a tap on the preview follows.
                Button("Edit") { isEditingNotes = true }
                    .modifier(NotesHeaderButton())
            }
        }
        .animation(.snappy, value: isEditingNotes)
    }

    /// Trip-wide documents — files not tied to a single stop (insurance, a
    /// passport scan, a group itinerary PDF). A ticket for one place lives under
    /// that place's stop instead; both are stored inside the trip itself
    /// (`.externalStorage`), so they're on-device at a gate with no connectivity.
    private var documentsSection: some View {
        Section {
            if trip.documents.isEmpty {
                emptySectionPlaceholder(
                    symbol: "doc",
                    message: Text(
                        "No documents yet", comment: "Empty trip documents placeholder"))
            }
            ForEach(trip.documents) { attachment in
                AttachmentRow(attachment: attachment) { openAttachment(attachment) }
            }
            .onDelete(perform: deleteDocuments)
            Button {
                // A trip-level document isn't tied to any stop.
                attachingToStop = nil
                showAttachmentImporter = true
            } label: {
                Label("Add File", systemImage: "paperclip")
            }
        } header: {
            Text("Documents")
        } footer: {
            Text("Files for the whole trip. To attach a ticket to a place, use its stop above.")
        }
    }

    /// Trip-level web links — booking pages, timetables — that aren't tied to any
    /// one stop. Links pinned to a place live under that stop's row instead.
    private var linksSection: some View {
        Section {
            if trip.tripLinks.isEmpty {
                emptySectionPlaceholder(
                    symbol: "link",
                    message: Text("No links yet", comment: "Empty trip links placeholder"))
            }
            ForEach(trip.tripLinks) { link in
                LinkRow(link: link) { modelContext.delete(link) }
            }
            .onDelete(perform: deleteTripLinks)
            Button {
                addTripLink()
            } label: {
                Label("Add link", systemImage: "link")
            }
        } header: {
            Text("Links")
        } footer: {
            Text(
                "Web links for the whole trip — booking pages, timetables. To pin a link to a place, use its stop above."
            )
        }
    }

    private func addTripLink() {
        let link = TripLink(order: trip.tripLinks.count, trip: trip)
        modelContext.insert(link)
        if trip.links == nil { trip.links = [] }
        trip.links?.append(link)
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
    /// then opens the importer (shared with the trip-level "Add File").
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
                Text("Ungrouped").tag(nil as PersistentIdentifier?)
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
    @State private var hasDate: Bool

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
        _hasDate = State(initialValue: stop.date != nil)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            identityRow
            secondaryLine
            transportEditor

            // No `.font` override: a control's label belongs at body size.
            Toggle("Set a date", isOn: $hasDate)
                .onChange(of: hasDate) { _, on in
                    stop.date = on ? (stop.date ?? defaultStopDate) : nil
                }
                .animation(.snappy, value: hasDate)

            if hasDate {
                let selection = Binding(
                    get: { stop.date ?? defaultStopDate }, set: { stop.date = $0 })
                Group {
                    // Clamp to the trip's span so a stop's date can't wander
                    // outside it; unbounded only when there's no valid range.
                    if let range = tripDateRange {
                        DatePicker(
                            "Date", selection: selection, in: range,
                            displayedComponents: .date)
                    } else {
                        DatePicker("Date", selection: selection, displayedComponents: .date)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // `.subheadline`, not `.caption`: this is text the user wrote, and the
            // caption styles are for metadata *about* content, not content itself.
            TextField("Note", text: $stop.note, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...3)

            if isPlace {
                Button {
                    openInMaps()
                } label: {
                    Label("Open in Apple Maps", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }

            attachments
            linksEditor
        }
        .padding(.vertical, 2)
    }

    /// "Getting here": how the traveler reaches this stop. Optional — a menu picks
    /// the mode (or clears it); choosing one reveals a free-text field for flight
    /// or bus numbers, times, rental and confirmation details. Boarding passes go
    /// in this stop's attachments below.
    @ViewBuilder private var transportEditor: some View {
        Menu {
            Picker("Getting here", selection: transportSelection) {
                Text("None").tag(TransportMode?.none)
                ForEach(TransportMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbolName)
                        .tag(TransportMode?.some(mode))
                }
            }
        } label: {
            Label {
                Text(stop.transport?.label ?? String(localized: "Getting here"))
            } icon: {
                Image(systemName: stop.transport?.symbolName ?? "arrow.triangle.branch")
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderless)

        if stop.transport != nil {
            TextField(
                "Flight no., times, confirmation…", text: $stop.transportDetail, axis: .vertical
            )
            .font(.subheadline)
            .lineLimit(1...3)
        }
    }

    private var transportSelection: Binding<TransportMode?> {
        Binding(get: { stop.transport }, set: { stop.transport = $0 })
    }

    /// Links pinned to this stop (a bus timetable, a ticket page), each openable
    /// and removable, followed by an "Add link" button — mirroring `attachments`.
    @ViewBuilder private var linksEditor: some View {
        ForEach(stop.sortedLinks) { link in
            LinkRow(link: link) { modelContext.delete(link) }
        }
        Button {
            addStopLink()
        } label: {
            Label("Add link", systemImage: "link")
                .font(.subheadline)
        }
        .buttonStyle(.borderless)
    }

    private func addStopLink() {
        let link = TripLink(order: (stop.links ?? []).count, trip: stop.trip, item: stop)
        modelContext.insert(link)
        if stop.links == nil { stop.links = [] }
        stop.links?.append(link)
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
        }
    }

    /// Files attached to this stop, each openable with a remove button. A List
    /// row can't host `.onDelete`, so each carries its own destructive control.
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
        Button {
            onAddAttachment()
        } label: {
            Label("Attach file", systemImage: "paperclip")
                .font(.subheadline)
        }
        .buttonStyle(.borderless)
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

