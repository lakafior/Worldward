/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftData
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import QuickLook
#endif

// MARK: - Export

/// A trip title, stripped of characters illegal in filenames, shared by the
/// Markdown and PDF exporters below. `nonisolated` because `ExportableTrip`'s
/// `transferRepresentation` (which calls it) is a nonisolated protocol
/// requirement, unlike ordinary declarations in this file.
private nonisolated func sanitizedFileName(_ title: String) -> String {
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

    init(trip: Trip) {
        self.title = trip.title
        self.markdown = trip.markdownSummary
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.markdown)
            .suggestedFileName { "\(sanitizedFileName($0.title)).md" }
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
            case .suggestions: "Suggestions"
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
        let trip = Trip(title: "New Trip")
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
            Text(dateRange)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !trip.flags.isEmpty {
                Text(trip.flags).font(.subheadline)
            }
        }
        .contentShape(Rectangle())
    }

    private var dateRange: String {
        let start = trip.startDate.formatted(date: .abbreviated, time: .omitted)
        let end = trip.endDate.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }
}

// MARK: - Trip detail

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
    /// The shared container catalog, used for the move menu, the assistant, and
    /// first-run seeding. Sorted so groups appear in a stable order everywhere.
    @Query(sort: \PackingContainer.sortOrder) private var allContainers: [PackingContainer]
    /// Saved packing templates, offered in the "Start from…" menu.
    @Query(sort: \PackingTemplate.name) private var templates: [PackingTemplate]
    /// Every trip, so the "Start from…" menu can copy another trip's packing list.
    @Query private var allTrips: [Trip]
    @State private var showCountryPicker = false
    @State private var newPackingTitle = ""
    @State private var calendarAlert: String?
    @State private var pdfExportError: String?
    /// The freshly rendered PDF, previewed in-place via Quick Look on iOS. Unused
    /// on macOS, which opens the file in Preview.app directly instead.
    @State private var pdfPreviewURL: URL?
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
    /// Hides the one-shot "Add to Apple Calendar" button while calendar sync is
    /// on — the sync already mirrors the trip, so the button would double-book.
    @AppStorage(CalendarSync.enabledKey) private var calendarSyncEnabled = false

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
                Section {
                    TextField("Trip name", text: $trip.title, prompt: Text("e.g. Europe 2026"))
                    DatePicker("Start", selection: $trip.startDate, displayedComponents: .date)
                    DatePicker(
                        "End", selection: $trip.endDate, in: trip.startDate...,
                        displayedComponents: .date)
                    if !trip.flags.isEmpty {
                        Text(trip.flags).font(.title3)
                    }
                    if !calendarSyncEnabled {
                        Button {
                            addToCalendar()
                        } label: {
                            Label("Add to Apple Calendar", systemImage: "calendar.badge.plus")
                        }
                    }
                    exportButtons
                    Button {
                        // Hands the trip to ContentView through the router (the map
                        // lives several presentation layers away), which switches to
                        // the Map tab and frames the route.
                        IntentRouter.shared.pendingMapTrip = trip
                        dismiss()
                    } label: {
                        Label("View Route on Map", systemImage: "map")
                    }
                    .disabled(trip.itinerary.isEmpty)
                }

                tripPhotosSection
                itinerarySection
                packingSections
                notesSection
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
            #endif
            .task { seedContainersIfNeeded() }
            .sheet(isPresented: $showCountryPicker) {
                CountryPickerSheet(allCountries: allCountries) { country in
                    addStop(country: country)
                }
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

            list
                .alert(
                    "Apple Calendar",
                    isPresented: Binding(
                        get: { calendarAlert != nil }, set: { if !$0 { calendarAlert = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(calendarAlert ?? "")
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
                // Hosts the translation session that `translator.translate(_:)`
                // awaits in `fillPacking` / `fillNotes`.
                .appTranslation(translator)
        }
        #if !os(macOS)
            .quickLookPreview($pdfPreviewURL)
        #endif
    }

    private func addToCalendar() {
        Task {
            switch await CalendarExporter.add(trip: trip) {
            case .added:
                calendarAlert = "Added to your calendar."
            case .denied:
                calendarAlert =
                    "Worldward doesn't have calendar access. Turn it on in Settings to add trips."
            case .failed(let message):
                calendarAlert = "Couldn't add to calendar: \(message)"
            }
        }
    }

    /// Renders the trip's PDF to a fresh temp file and opens it directly — in
    /// Preview.app on macOS, in an in-place Quick Look preview on iOS — rather
    /// than through the share picker, which only offers a couple of generic
    /// services for raw PDF data. Each export gets its own UUID'd subdirectory so
    /// the viewer always loads new content instead of a stale, already-open
    /// document at a reused path.
    private func exportPDFAndOpen() {
        let data = TripPDFRenderer.render(trip: trip)
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
                pdfPreviewURL = url
            #endif
        } catch {
            pdfExportError = error.localizedDescription
        }
    }

    /// Markdown + PDF export, folded into a single Share row so the trip-info
    /// section doesn't spend two rows on export. Split out of that `Section` —
    /// folding it in there pushed the `@ViewBuilder` closure's type-checking
    /// past a reasonable time budget on iOS.
    @ViewBuilder private var exportButtons: some View {
        Menu {
            ShareLink(
                item: ExportableTrip(trip: trip),
                preview: SharePreview(trip.title.isEmpty ? "Trip" : trip.title)
            ) {
                Label("Share / Export (Markdown)", systemImage: "doc.plaintext")
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

    private var itinerarySection: some View {
        Section("Itinerary") {
            if trip.itinerary.isEmpty {
                Text("No stops yet").foregroundStyle(.secondary)
            } else {
                ForEach(trip.sortedStops) { stop in
                    StopRow(stop: stop)
                }
                .onMove(perform: moveItineraryStop)
                .onDelete(perform: deleteStops)
            }
            Button {
                showCountryPicker = true
            } label: {
                Label("Add a country / stop", systemImage: "plus")
            }
        }
    }

    /// An overall progress bar, one Section per container that has items (plus an
    /// "Other" group for ungrouped items), followed by the shared controls section.
    @ViewBuilder private var packingSections: some View {
        if !trip.packing.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(
                        value: Double(trip.packedCount), total: Double(trip.packing.count))
                    Text("\(trip.packedCount) of \(trip.packing.count) packed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            if collapsed {
                collapsedGroupIDs.remove(group.id)
            } else {
                collapsedGroupIDs.insert(group.id)
            }
        } label: {
            HStack {
                Label {
                    Text(
                        "\(group.container?.name ?? Str.Trip.packingOther) · \(packed)/\(group.items.count)"
                    )
                } icon: {
                    Image(systemName: group.container?.symbolName ?? "tray")
                }
                Spacer()
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var packingControlsSection: some View {
        Section {
            HStack {
                TextField("Add item", text: $newPackingTitle)
                    .onSubmit { addPacking() }
                Button("Add", action: addPacking)
                    .disabled(newPackingTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                showManageContainers = true
            } label: {
                Label("Manage containers", systemImage: "bag.badge.plus")
            }

            packingStartFromMenu

            if canUseAssistant {
                fillButton(field: .packing, action: fillPacking)
            }

            if !trip.packing.isEmpty {
                Button {
                    newTemplateName = trip.title
                    showSaveTemplate = true
                } label: {
                    Label("Save as template…", systemImage: "square.and.arrow.down")
                }

                Button(role: .destructive) {
                    confirmClearPacking = true
                } label: {
                    Label("Clear list", systemImage: "trash")
                }
                .confirmationDialog(
                    "Remove all \(trip.packing.count) packing items?",
                    isPresented: $confirmClearPacking, titleVisibility: .visible
                ) {
                    Button("Clear list", role: .destructive, action: clearPacking)
                }
            }
        } header: {
            Text(
                trip.packing.isEmpty
                    ? "Packing" : "Packing · \(trip.packedCount)/\(trip.packing.count)")
        }
    }

    /// "Start from…" — applies a saved template or copies another trip's packing
    /// list. Hidden entirely when there's nothing to start from.
    @ViewBuilder private var packingStartFromMenu: some View {
        let otherTrips = allTrips.filter {
            $0.persistentModelID != trip.persistentModelID && !$0.packing.isEmpty
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
                Label("Start from…", systemImage: "tray.full")
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Links, confirmations, ideas…", text: $trip.notes, axis: .vertical)
                .lineLimit(3...8)

            if canUseAssistant {
                fillButton(field: .notes, action: fillNotes)
            }
        }
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

    private func addStop(country: Country) {
        let nextOrder = (trip.itinerary.map(\.order).max() ?? -1) + 1
        let stop = ItineraryItem(order: nextOrder, country: country, trip: trip)
        modelContext.insert(stop)
        trip.itinerary.append(stop)
        // Map tie-in: a planned stop's country joins the blue "going" layer.
        if country.planStatus == .none { country.planStatus = .planning }
    }

    private func deleteStops(at offsets: IndexSet) {
        let ordered = trip.sortedStops
        for index in offsets { modelContext.delete(ordered[index]) }
    }

    /// Applies a drag-to-reorder of the itinerary (a single collection) and
    /// renumbers every stop's `order` so the new arrangement persists.
    /// Uses the legacy `.onMove` API (available since macOS 14 / iOS 17).
    private func moveItineraryStop(from source: IndexSet, to destination: Int) {
        var ordered = trip.sortedStops
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, stop) in ordered.enumerated() { stop.order = index }
    }

    private func addPacking() {
        let title = newPackingTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let item = PackingItem(title: title, order: nextPackingOrder, trip: trip)
        modelContext.insert(item)
        trip.packing.append(item)
        newPackingTitle = ""
    }

    /// The next free ordering slot, so a new item lands at the end of its group.
    private var nextPackingOrder: Int { (trip.packing.map(\.order).max() ?? -1) + 1 }

    private func clearPacking() {
        for item in trip.packing { modelContext.delete(item) }
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
            template.items.sorted { $0.order < $1.order }
                .map { ($0.title, $0.quantity, $0.containerName) })
    }

    /// Appends another trip's packing items, skipping duplicates and resolving
    /// containers by name so they file into this trip's catalog.
    private func copyPacking(from other: Trip) {
        addPackingItems(
            other.packing.sorted { $0.order < $1.order }
                .map { ($0.title, $0.quantity, $0.container?.name ?? "") })
    }

    /// Shared appender for templates and trip-copies: inserts each `(title,
    /// quantity, containerName)` not already present, in increasing `order`.
    private func addPackingItems(_ sources: [(title: String, quantity: Int, containerName: String)])
    {
        var existing = Set(trip.packing.map { $0.title.lowercased() })
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
            trip.packing.append(item)
            order += 1
        }
    }

    /// Saves the current packing list as a reusable template, storing each item's
    /// container by name for portability.
    private func saveTemplate() {
        let name = newTemplateName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !trip.packing.isEmpty else { return resetTemplateDraft() }
        let template = PackingTemplate(name: name)
        modelContext.insert(template)
        for (index, source) in trip.packing.sorted(by: { $0.order < $1.order }).enumerated() {
            let templateItem = PackingTemplateItem(
                title: source.title, quantity: source.quantity, order: index,
                containerName: source.container?.name ?? "", template: template)
            modelContext.insert(templateItem)
            template.items.append(templateItem)
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
        var existing = Set(trip.packing.map { $0.title.lowercased() })
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
            trip.packing.append(item)
            order += 1
        }
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

/// A packing-list row: a tappable check-off control on the left and a "move to
/// container" menu on the right. Editing `item.container` directly persists the
/// change through SwiftData.
private struct PackingItemRow: View {
    @Bindable var item: PackingItem
    let containers: [PackingContainer]
    /// Invoked when the user picks "New container…" so the parent can present the
    /// naming alert with this item queued to be filed into the new container.
    let onNewContainer: () -> Void

    var body: some View {
        HStack {
            Button {
                item.isPacked.toggle()
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

            Spacer()

            Stepper("Quantity", value: $item.quantity, in: 1...99)
                .labelsHidden()

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
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Move to container"))
        }
    }

    private var containerSelection: Binding<PersistentIdentifier?> {
        Binding(
            get: { item.container?.persistentModelID },
            set: { id in item.container = containers.first { $0.persistentModelID == id } })
    }
}

/// An inline-editable itinerary stop: its country flag, an optional custom name,
/// an optional date, a note, and the places to see there.
private struct StopRow: View {
    @Bindable var stop: ItineraryItem
    @Environment(\.modelContext) private var modelContext
    @State private var hasDate: Bool
    @State private var showPlaceSearch = false

    init(stop: ItineraryItem) {
        self.stop = stop
        _hasDate = State(initialValue: stop.date != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stop.country?.flagEmoji ?? "📍")
                TextField(
                    "Stop", text: $stop.title,
                    prompt: Text(stop.country?.name ?? "Stop"))
            }

            Toggle("Set a date", isOn: $hasDate)
                .font(.caption)
                .onChange(of: hasDate) { _, on in
                    stop.date = on ? (stop.date ?? Date()) : nil
                }

            if hasDate {
                DatePicker(
                    "Date",
                    selection: Binding(get: { stop.date ?? Date() }, set: { stop.date = $0 }),
                    displayedComponents: .date)
            }

            TextField("Note", text: $stop.note, axis: .vertical)
                .font(.caption)
                .lineLimit(1...3)

            ForEach(stop.sortedPlaces) { place in
                StopPlaceRow(place: place) { delete(place) }
            }

            Button {
                showPlaceSearch = true
            } label: {
                Label("Add a place to see", systemImage: "mappin.and.ellipse")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showPlaceSearch) {
            PlaceSearchSheet(country: stop.country) { item in add(item) }
        }
    }

    /// Saves a picked search result as a place under this stop.
    private func add(_ item: MKMapItem) {
        let nextOrder = (stop.places.map(\.order).max() ?? -1) + 1
        let coordinate = item.location.coordinate
        let place = StopPlace(
            title: item.name ?? String(localized: "Place"),
            detail: item.address?.shortAddress ?? item.address?.fullAddress ?? "",
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            order: nextOrder, stop: stop)
        modelContext.insert(place)
        stop.places.append(place)
    }

    private func delete(_ place: StopPlace) {
        modelContext.delete(place)
    }
}

/// One place-to-see under a stop: a pin, the name and location line, a button to
/// open it in Apple Maps (when it has a coordinate), and a remove button.
private struct StopPlaceRow: View {
    let place: StopPlace
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(Color.brand)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.title).font(.caption)
                if !place.detail.isEmpty {
                    Text(place.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if place.coordinate != nil {
                Button {
                    openInMaps()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open in Apple Maps")
                .accessibilityLabel(Text("Open in Apple Maps"))
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove place")
            .accessibilityLabel(Text("Remove place"))
        }
        .padding(.leading, 4)
    }

    private func openInMaps() {
        guard let coordinate = place.coordinate else { return }
        let item = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil)
        item.name = place.title
        item.openInMaps()
    }
}

