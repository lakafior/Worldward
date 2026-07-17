/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftData
import SwiftUI

// MARK: - Markdown export

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
            .suggestedFileName { "\($0.fileBaseName).md" }
    }

    /// The trip title, stripped of characters illegal in filenames.
    var fileBaseName: String {
        let cleaned =
            title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Trip" : cleaned
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

    var body: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView(
                    "No trips yet",
                    systemImage: "suitcase",
                    description: Text("Plan your next adventure — tap ＋ to start a trip."))
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
        .toolbar {
            ToolbarItem {
                Button {
                    addTrip()
                } label: {
                    Label("New Trip", systemImage: "plus")
                }
            }
        }
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
        #if os(macOS)
            selectedTrip = trip
        #else
            editingTrip = trip
        #endif
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

private struct TripDetailSheet: View {
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
        // grouped-form appearance.
        List {
            Section {
                TextField("Trip name", text: $trip.title, prompt: Text("e.g. Europe 2026"))
                DatePicker("Start", selection: $trip.startDate, displayedComponents: .date)
                DatePicker(
                    "End", selection: $trip.endDate, in: trip.startDate...,
                    displayedComponents: .date)
                if !trip.flags.isEmpty {
                    Text(trip.flags).font(.title3)
                }
                Button {
                    addToCalendar()
                } label: {
                    Label("Add to Apple Calendar", systemImage: "calendar.badge.plus")
                }
                ShareLink(
                    item: ExportableTrip(trip: trip),
                    preview: SharePreview(trip.title.isEmpty ? "Trip" : trip.title)
                ) {
                    Label("Share / Export (Markdown)", systemImage: "square.and.arrow.up")
                }
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
            CountryPickerSheet(allCountries: allCountries) { country in addStop(country: country) }
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
            "Couldn't generate",
            isPresented: Binding(
                get: { planner.errorMessage != nil }, set: { if !$0 { planner.clearError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(planner.errorMessage ?? "")
        }
        // Hosts the translation session that `translator.translate(_:)` awaits in
        // `fillPacking` / `fillNotes`.
        .appTranslation(translator)
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
                    Text("\(group.container?.name ?? "Other") · \(packed)/\(group.items.count)")
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

// MARK: - Place search

/// A MapKit-backed place chooser for a stop: search for museums, landmarks,
/// restaurants… biased toward the stop's country. Results come from
/// `MKLocalSearch`, so each pick carries a real coordinate and address.
private struct PlaceSearchSheet: View {
    /// The stop's country, used to bias the search toward its region. `nil` for
    /// a free-form stop — the search is then simply worldwide.
    let country: Country?
    let onPick: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    /// Resolves the country's bounding region exactly once, shared by every
    /// search. A task (rather than the region itself) so the first search can
    /// *await* the lookup instead of racing it — an unbiased worldwide query
    /// returns a single arbitrary global match, not places in the country.
    @State private var regionTask: Task<MKCoordinateRegion?, Never>?

    var body: some View {
        NavigationStack {
            List {
                ForEach(results, id: \.self) { item in
                    Button {
                        onPick(item)
                        dismiss()
                    } label: {
                        resultRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if isSearching && results.isEmpty {
                    ProgressView()
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "Find places to see",
                        systemImage: "mappin.and.ellipse",
                        description: Text(emptyDescription))
                }
            }
            .searchable(text: $search, prompt: "Museums, landmarks, restaurants…")
            .navigationTitle("Add a place")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { _ = await countryRegion() }
            .task(id: search) { await runSearch() }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var emptyDescription: String {
        if let country {
            return String(
                localized: "Search for sights and spots to visit in \(country.name).")
        }
        return String(localized: "Search for sights and spots to visit at this stop.")
    }

    private func resultRow(_ item: MKMapItem) -> some View {
        let category = Self.categoryStyle(for: item.pointOfInterestCategory)
        // "Museum · 99 Rue de Rivoli, 75001 Paris, France" — the category names
        // what kind of place it is, the full address pins down which one.
        let subtitle = [category.label, fullAddress(of: item)]
            .compactMap { $0 }
            .joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: category.symbol)
                .foregroundStyle(Color.brand)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? String(localized: "Place"))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    /// The most complete one-line address available for a result — street, city
    /// and country when MapKit knows them.
    private func fullAddress(of item: MKMapItem) -> String? {
        item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
            ?? item.address?.fullAddress
            ?? item.address?.shortAddress
    }

    /// An icon and label for the common tourist-facing point-of-interest
    /// categories, so a result reads as "a museum" or "a park" at a glance.
    /// Anything unmapped falls back to a plain pin with no label.
    private static func categoryStyle(
        for category: MKPointOfInterestCategory?
    ) -> (symbol: String, label: String?) {
        switch category {
        case .museum:
            ("building.columns.fill", String(localized: "Museum"))
        case .landmark, .nationalMonument:
            ("star.circle.fill", String(localized: "Landmark"))
        case .castle, .fortress:
            ("building.fill", String(localized: "Castle"))
        case .park, .nationalPark:
            ("tree.fill", String(localized: "Park"))
        case .beach:
            ("beach.umbrella.fill", String(localized: "Beach"))
        case .zoo:
            ("pawprint.fill", String(localized: "Zoo"))
        case .aquarium:
            ("fish.fill", String(localized: "Aquarium"))
        case .amusementPark:
            ("sparkles", String(localized: "Amusement park"))
        case .restaurant:
            ("fork.knife", String(localized: "Restaurant"))
        case .cafe, .bakery:
            ("cup.and.saucer.fill", String(localized: "Café"))
        case .brewery, .winery:
            ("wineglass.fill", String(localized: "Bar"))
        case .hotel:
            ("bed.double.fill", String(localized: "Hotel"))
        case .theater, .movieTheater:
            ("theatermasks.fill", String(localized: "Theater"))
        case .stadium:
            ("sportscourt.fill", String(localized: "Stadium"))
        case .library:
            ("books.vertical.fill", String(localized: "Library"))
        case .store:
            ("bag.fill", String(localized: "Store"))
        case .marina:
            ("sailboat.fill", String(localized: "Marina"))
        case .campground:
            ("tent.fill", String(localized: "Campground"))
        default:
            ("mappin.circle.fill", nil)
        }
    }

    /// The country's bounding region, looked up on first use and cached. `nil`
    /// for free-form stops or when the lookup finds nothing. No `resultTypes`
    /// restriction on the lookup — a country isn't an *address*, so restricting
    /// to `.address` made the lookup fail and left every search unbiased.
    private func countryRegion() async -> MKCoordinateRegion? {
        if let regionTask { return await regionTask.value }
        guard let country else { return nil }
        let name = country.name
        let task = Task { () -> MKCoordinateRegion? in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = name
            let response = try? await MKLocalSearch(request: request).start()
            return response?.boundingRegion
        }
        regionTask = task
        return await task.value
    }

    /// Debounced live search: re-runs as the query changes, cancelling stale runs.
    private func runSearch() async {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        if let region = await countryRegion() {
            request.naturalLanguageQuery = term
            request.region = region
            // Keep results inside the country — a mere hint still lets "castle"
            // resolve to a stronger match on the other side of the world.
            request.regionPriority = .required
        } else if let country {
            // Region lookup failed: bias the query textually instead.
            request.naturalLanguageQuery = "\(term), \(country.name)"
        } else {
            request.naturalLanguageQuery = term
        }
        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return }
        results = response?.mapItems ?? []
    }
}

// MARK: - Country picker

/// A searchable country chooser used when adding a stop to a trip or
/// quick-adding from the Been/Going list.
struct CountryPickerSheet: View {
    let allCountries: [Country]
    let onPick: (Country) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Country] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return allCountries }
        return allCountries.filter { $0.name.localizedStandardContains(term) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { country in
                Button {
                    onPick(country)
                    dismiss()
                } label: {
                    HStack {
                        Text(country.flagEmoji)
                        Text(country.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search countries")
            .navigationTitle("Add a country")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 450)
        #endif
    }
}

// MARK: - Suggestions

/// The lens the smart suggestions are generated through. Each mode feeds the model
/// a different candidate set and guidance, so the picks answer a different question:
/// what's *easy* next, what *broadens* the map, or what *clusters* into one trip.
private enum SuggestionMode: String, CaseIterable, Identifiable {
    case closeToHome
    case fillAGap
    case buildATrip
    var id: String { rawValue }

    var label: String {
        switch self {
        case .closeToHome: "Close to home"
        case .fillAGap: "Fill a gap"
        case .buildATrip: "Build a trip"
        }
    }

    /// The instruction handed to the model alongside the traveler profile.
    var guidance: String {
        switch self {
        case .closeToHome:
            "These candidates are the unvisited countries closest to where the traveler has already been. Favor easy, natural next trips."
        case .fillAGap:
            "These candidates are in regions the traveler has barely explored. Favor picks that broaden their map to new continents and regions."
        case .buildATrip:
            "These candidates lie close together and could be combined into one multi-country trip. Favor picks that pair into a single itinerary, and say how they connect."
        }
    }

    /// Shown when a mode has no candidates to offer yet.
    var emptyMessage: String {
        switch self {
        case .closeToHome: "Nothing nearby left to suggest right now."
        case .fillAGap:
            "Visit a few more places first — then we can spot the gaps on your map."
        case .buildATrip: "No nearby cluster to build a trip from yet."
        }
    }
}

/// Closest unvisited countries + AI-powered destination suggestions, shown as
/// the **Suggestions** segment in the Going tab.
private struct SuggestionsView: View {
    let allCountries: [Country]
    let centroids: [String: CLLocationCoordinate2D]

    @Environment(\.modelContext) private var modelContext
    @State private var insights = TravelInsights()
    /// Set to open the trip editor right after a suggestion creates a trip.
    @State private var editingTrip: Trip?

    /// Cached distance ranking. Computing it in `init` re-ran the O(n·m) pass
    /// (tens of thousands of distance calls) on every parent render — e.g. each
    /// keystroke in the shared search field — so it's derived once per catalog
    /// change via `.task(id:)` instead.
    @State private var suggestions: [(country: Country, distanceKM: Double)] = []
    /// English summary of the traveler, fed to the model for tailored picks.
    @State private var profile = ""
    /// `false` until the first derivation completes, so the "all visited" empty
    /// state can't flash before the suggestions exist.
    @State private var suggestionsReady = false

    /// Signature of everything the suggestions derive from: the visited set and
    /// whether the centroids have loaded.
    private var suggestionsKey: Int {
        var hasher = Hasher()
        for country in allCountries {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
            hasher.combine(country.planStatusRaw)
        }
        hasher.combine(centroids.count)
        return hasher.finalize()
    }

    /// The traveler's footprint plus their wishlist, in English, for the model.
    private static func makeProfile(countries: [Country]) -> String {
        var summary = TravelStats(countries: countries).explorationSummary
        let wishlist =
            countries
            .filter { $0.planStatus == .wishlist }
            .map(\.name)
        if !wishlist.isEmpty {
            summary += " On the wishlist: \(wishlist.prefix(6).joined(separator: ", "))."
        }
        return summary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if centroids.isEmpty || !suggestionsReady {
                    ContentUnavailableView(
                        "Map not ready",
                        systemImage: "globe",
                        description: Text("Country locations are still loading. Try again shortly.")
                    )
                } else if suggestions.isEmpty {
                    ContentUnavailableView(
                        "Nothing left to discover",
                        systemImage: "globe.desk.fill",
                        description: Text(
                            "You've visited every country — there's nothing left to suggest!"))
                } else {
                    closestSection

                    if insights.isAvailable {
                        SmartSuggestionsSection(
                            insights: insights,
                            allCountries: allCountries,
                            centroids: centroids,
                            profile: profile,
                            onAddToWishlist: addToWishlist,
                            onCreateTrip: createTrip)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Suggestions")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        // Re-derives when the visited set or the centroids change; body renders
        // in between just reuse the cached values.
        .task(id: suggestionsKey) {
            suggestions = nearestUnvisited(countries: allCountries, centroids: centroids)
            profile = Self.makeProfile(countries: allCountries)
            suggestionsReady = true
        }
        .sheet(item: $editingTrip) { trip in
            TripDetailSheet(trip: trip, allCountries: allCountries)
        }
    }

    /// Adds a suggested country to the wishlist (the blue "going" plan axis),
    /// leaving any stronger plan it already has untouched.
    private func addToWishlist(_ country: Country) {
        if country.planStatus == .none { country.planStatus = .wishlist }
    }

    /// Builds a trip from one or more suggested countries — each becomes an ordered
    /// stop and joins the map's "going" layer — then opens the editor so the
    /// traveler can fill in dates and details.
    private func createTrip(_ countries: [Country]) {
        guard !countries.isEmpty else { return }
        let trip = Trip(title: Self.tripTitle(for: countries))
        modelContext.insert(trip)
        for (index, country) in countries.enumerated() {
            let stop = ItineraryItem(order: index, country: country, trip: trip)
            modelContext.insert(stop)
            trip.itinerary.append(stop)
            if country.planStatus == .none { country.planStatus = .planning }
        }
        editingTrip = trip
    }

    /// A starter title for a freshly created trip; the user edits it in the sheet.
    private static func tripTitle(for countries: [Country]) -> String {
        guard let first = countries.first else { return "New Trip" }
        if countries.count == 1 { return first.name }
        return "\(first.name) & \(countries.count - 1) more"
    }

    private var closestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Closest unvisited")

            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.country.id) { index, item in
                    HStack {
                        Text(item.country.flagEmoji)
                        Text(item.country.name)
                        Spacer()
                        Text("\(Int(item.distanceKM.rounded())) km away")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 8)
                    if index < suggestions.count - 1 { Divider() }
                }
            }
            .padding(.horizontal)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Smart suggestions (Apple Intelligence)

/// Opt-in next-destination picks with a concrete rationale, generated on-device.
/// A mode picker drives *which* unvisited countries are offered (nearby, gap-filling,
/// or a cluster for one trip); the model only phrases, ranks, and tailors to the
/// traveler — the candidate set and flags come from real data, so it can't invent a
/// country. Each pick is actionable: add it to the wishlist or spin it into a trip.
private struct SmartSuggestionsSection: View {
    let insights: TravelInsights
    let allCountries: [Country]
    let centroids: [String: CLLocationCoordinate2D]
    let profile: String
    let onAddToWishlist: (Country) -> Void
    let onCreateTrip: ([Country]) -> Void

    @State private var mode: SuggestionMode = .closeToHome
    @State private var picks: [ResolvedPick] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Country ids the user added to the wishlist this session, so the button can
    /// flip to a confirmed state without re-querying the model.
    @State private var wishlisted: Set<String> = []
    @State private var translator = AppTranslator()

    private struct ResolvedPick: Identifiable {
        let country: Country
        let reason: String
        var id: String { country.id }
        var flag: String { country.flagEmoji }
        var name: String { country.name }
    }

    /// The candidate countries for the selected mode, with a distance for context.
    /// Cached in `@State` (recomputed via `.task(id:)` below) — as a computed
    /// property this O(n·m) pass re-ran on every body evaluation.
    @State private var candidates: [(country: Country, distanceKM: Double)] = []

    /// Signature of the candidate inputs: the mode plus the visited set.
    private var candidatesKey: Int {
        var hasher = Hasher()
        hasher.combine(mode)
        for country in allCountries {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
        }
        return hasher.finalize()
    }

    private func rebuildCandidates() {
        candidates =
            switch mode {
            case .closeToHome:
                nearestUnvisited(countries: allCountries, centroids: centroids, limit: 8)
            case .fillAGap:
                unvisitedFillingGaps(countries: allCountries, centroids: centroids, limit: 8)
            case .buildATrip:
                tripCluster(countries: allCountries, centroids: centroids, limit: 4)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Suggested for you")

            Picker("Mode", selection: $mode) {
                ForEach(SuggestionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in
                picks = []
                errorMessage = nil
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Thinking about where to go next…")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if picks.isEmpty {
                if candidates.isEmpty {
                    Text(mode.emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: generate) {
                        Label("Suggest with Apple Intelligence", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                }
            }

            if !picks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                        pickRow(pick)
                        if index < picks.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                // In trip-building mode the picks are a single cluster, so offer to
                // turn the whole set into one multi-stop trip.
                if mode == .buildATrip && picks.count > 1 {
                    Button {
                        onCreateTrip(picks.map(\.country))
                    } label: {
                        Label("Create one trip with all \(picks.count)", systemImage: "suitcase")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                }

                Button("Suggest again", action: generate)
                    .font(.caption)
                    .disabled(isLoading)
            }
        }
        .task(id: candidatesKey) { rebuildCandidates() }
        .appTranslation(translator)
    }

    /// One pick: flag, name, the model's reason, and the two actions.
    private func pickRow(_ pick: ResolvedPick) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(pick.flag)
            VStack(alignment: .leading, spacing: 6) {
                Text(pick.name).fontWeight(.medium)
                Text(pick.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button {
                        onAddToWishlist(pick.country)
                        wishlisted.insert(pick.country.id)
                    } label: {
                        Label(
                            isWishlisted(pick) ? "On wishlist" : "Wishlist",
                            systemImage: isWishlisted(pick) ? "star.fill" : "star")
                    }
                    .disabled(isWishlisted(pick))

                    Button {
                        onCreateTrip([pick.country])
                    } label: {
                        Label("Create trip", systemImage: "airplane")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .tint(.brand)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    /// `true` once added here, or if the country was already on any plan.
    private func isWishlisted(_ pick: ResolvedPick) -> Bool {
        wishlisted.contains(pick.country.id) || pick.country.planStatus != .none
    }

    private func generate() {
        isLoading = true
        errorMessage = nil
        let candidates = self.candidates
        let descriptions = candidates.map { "\($0.country.name) (\($0.country.continent))" }
        let profile = self.profile
        let guidance = mode.guidance
        Task {
            defer { isLoading = false }
            do {
                let raw = try await insights.suggestDestinations(
                    profile: profile, guidance: guidance, candidates: descriptions)
                let resolved = raw.compactMap { pick -> ResolvedPick? in
                    guard
                        let match = candidates.first(where: {
                            matches(pick.country, $0.country.name)
                        })
                    else { return nil }
                    return ResolvedPick(country: match.country, reason: pick.reason)
                }
                // Country names come from real data; only the model's reasons (free
                // English text) need translating into the user's language.
                let reasons = await translator.translate(resolved.map(\.reason))
                picks = zip(resolved, reasons).map { pick, reason in
                    ResolvedPick(country: pick.country, reason: reason)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Loose name match so a model paraphrase still resolves to a candidate.
    private func matches(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveContains(b) || b.localizedCaseInsensitiveContains(a)
    }
}

/// Simple section header reused inside the suggestions views.
private struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            if let trailing {
                Spacer()
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
