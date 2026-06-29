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

/// The Going tab: your **Trips** (multi-country plans) and your **Wishlist**
/// (countries you want to visit but haven't planned yet), behind a segmented
/// control. Trips lead; the wishlist is the Phase-1 planned-countries list.
struct GoingView: View {
    let allCountries: [Country]
    @Binding var searchText: String
    @Binding var selectedContinent: String?
    @Binding var selectedYear: Int?
    @Binding var selectedCountry: Country?

    enum Segment: String, CaseIterable, Identifiable {
        case trips = "Trips"
        case wishlist = "Wishlist"
        var id: String { rawValue }
    }

    @State private var segment: Segment = .trips

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            switch segment {
            case .trips:
                TripsListView(allCountries: allCountries)
            case .wishlist:
                CountryListView(
                    allCountries: allCountries,
                    browseMode: .going,
                    searchText: $searchText,
                    selectedContinent: $selectedContinent,
                    selectedYear: $selectedYear,
                    selectedCountry: $selectedCountry)
            }
        }
    }
}

// MARK: - Trips list

private struct TripsListView: View {
    let allCountries: [Country]

    @Environment(\.modelContext) private var modelContext
    @Query private var trips: [Trip]
    @State private var editingTrip: Trip?
    @State private var showManageContainers = false
    @State private var showManageTemplates = false

    /// Upcoming trips first (soonest start), then finished trips (most recent).
    private var orderedTrips: [Trip] {
        let now = Date()
        let upcoming = trips.filter { $0.endDate >= now }.sorted { $0.startDate < $1.startDate }
        let past = trips.filter { $0.endDate < now }.sorted { $0.startDate > $1.startDate }
        return upcoming + past
    }

    var body: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView(
                    "No trips yet",
                    systemImage: "suitcase",
                    description: Text("Plan your next adventure — tap ＋ to start a trip."))
            } else {
                List {
                    ForEach(orderedTrips) { trip in
                        Button {
                            editingTrip = trip
                        } label: {
                            TripRow(trip: trip)
                        }
                    }
                    .onDelete(perform: deleteTrips)
                }
            }
        }
        .navigationTitle("Going")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        showManageContainers = true
                    } label: {
                        Label("Manage Containers", systemImage: "bag")
                    }
                    Button {
                        showManageTemplates = true
                    } label: {
                        Label("Manage Templates", systemImage: "list.bullet.rectangle.portrait")
                    }
                } label: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
            }
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
        .sheet(isPresented: $showManageContainers) {
            ManageContainersView()
        }
        .sheet(isPresented: $showManageTemplates) {
            ManageTemplatesView()
        }
    }

    private func addTrip() {
        let trip = Trip(title: "New Trip")
        modelContext.insert(trip)
        editingTrip = trip
    }

    private func deleteTrips(at offsets: IndexSet) {
        let ordered = orderedTrips
        for index in offsets { modelContext.delete(ordered[index]) }
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

    var body: some View {
        // A `List` (not `Form`) so iOS 27's `reorderContainer` can host the
        // packing drag — the drop only commits inside a real list container.
        // `.insetGrouped` keeps the familiar grouped-form appearance.
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
            }

            itinerarySection
            packingSections
            notesSection
        }
        // Drag-to-reorder packing items within and across container groups; the
        // closure rewrites each moved item's container + `order`. The itinerary's
        // own `.onMove` is keyed to `ItineraryItem` and coexists.
        // Both reorderable collections use the new iOS 27 API so the list has a
        // single, consistent reorder system — mixing the legacy `.onMove` with a
        // `reorderContainer` in the same List corrupts UIKit's move bookkeeping
        // and crashes on drop.
        .reorderContainer(for: ItineraryItem.self) { difference in
            applyItineraryReorder(difference)
        }
        .reorderContainer(for: PackingItem.self, in: String.self) { difference in
            applyPackingReorder(difference)
        }
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
                .reorderable()
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
                    .reorderable(collectionID: group.id)
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
    /// and disables itself while any generation is in flight.
    private func fillButton(field: TripPlanner.Field, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if planner.busy == field {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Generating…")
                }
            } else {
                Label("Fill with LLM", systemImage: "sparkles")
            }
        }
        .disabled(planner.busy != nil)
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
    private func applyItineraryReorder(
        _ difference: ReorderDifference<PersistentIdentifier, ReorderableSingleCollectionIdentifier>
    ) {
        var ordered = trip.sortedStops
        let movingSet = Set(difference.sources)
        let moved = difference.sources.compactMap { id in
            ordered.first { $0.persistentModelID == id }
        }
        guard !moved.isEmpty else { return }
        ordered.removeAll { movingSet.contains($0.persistentModelID) }

        switch difference.destination.position {
        case .before(let targetID):
            let index = ordered.firstIndex { $0.persistentModelID == targetID } ?? ordered.endIndex
            ordered.insert(contentsOf: moved, at: index)
        case .end:
            ordered.append(contentsOf: moved)
        }

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

    /// Applies a drag-to-reorder *within a single container*, renumbering that
    /// group's items so `order` stays contiguous.
    ///
    /// Cross-container drags are intentionally ignored (the drop reverts): moving
    /// an item between containers changes two sections' row counts at once, which
    /// reliably crashes `UICollectionView`'s interactive-reorder commit ("invalid
    /// number of items in section"). Use the row's container menu to move an item
    /// to a different bag instead. Same-container reorders never change a section's
    /// count, so they commit cleanly.
    private func applyPackingReorder(
        _ difference: ReorderDifference<PersistentIdentifier, String>
    ) {
        let destID = difference.destination.collectionID
        let destContainer: PackingContainer? =
            destID == "ungrouped" ? nil : allContainers.first { $0.dedupID == destID }
        let destContainerID = destContainer?.persistentModelID

        let movingSet = Set(difference.sources)
        let moved = difference.sources.compactMap { id in
            trip.packing.first { $0.persistentModelID == id }
        }
        guard !moved.isEmpty else { return }

        // Ignore (revert) any drop that would move an item into a different
        // container — that path is handled by the per-row container menu.
        guard moved.allSatisfy({ $0.container?.persistentModelID == destContainerID })
        else { return }

        // The group's current items, minus the ones being dragged.
        var items =
            trip.packing
            .filter {
                $0.container?.persistentModelID == destContainerID
                    && !movingSet.contains($0.persistentModelID)
            }
            .sorted { $0.order < $1.order }

        switch difference.destination.position {
        case .before(let targetID):
            let index = items.firstIndex { $0.persistentModelID == targetID } ?? items.endIndex
            items.insert(contentsOf: moved, at: index)
        case .end:
            items.append(contentsOf: moved)
        }

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

    /// Asks the on-device model for a packing list — filed into the user's
    /// containers — and appends any items not already present (case-insensitive),
    /// leaving the user's own entries be.
    private func fillPacking() {
        Task {
            guard
                let suggestions = await planner.suggestPacking(
                    for: trip, containers: allContainers.map(\.name))
            else { return }

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
    }

    /// Asks the on-device model for sightseeing notes and appends them, preserving
    /// anything the user has already written.
    private func fillNotes() {
        Task {
            guard let text = await planner.suggestNotes(for: trip) else { return }
            if trip.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trip.notes = text
            } else {
                trip.notes += "\n\n" + text
            }
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
/// an optional date, and a note.
private struct StopRow: View {
    @Bindable var stop: ItineraryItem
    @State private var hasDate: Bool

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
        }
        .padding(.vertical, 2)
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
    }
}
