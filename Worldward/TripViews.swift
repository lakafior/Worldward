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
    @State private var showCountryPicker = false
    @State private var newPackingTitle = ""
    @State private var calendarAlert: String?
    @State private var planner = TripPlanner()
    @State private var confirmClearPacking = false

    var body: some View {
        Form {
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
            packingSection
            notesSection
        }
        #if os(iOS)
            .toolbar { EditButton() }
        #endif
        .sheet(isPresented: $showCountryPicker) {
            CountryPickerSheet(allCountries: allCountries) { country in addStop(country: country) }
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
                .onDelete(perform: deleteStops)
                .onMove(perform: moveStops)
            }
            Button {
                showCountryPicker = true
            } label: {
                Label("Add a country / stop", systemImage: "plus")
            }
        }
    }

    private var packingSection: some View {
        Section {
            ForEach(trip.packing) { item in
                Button {
                    item.isPacked.toggle()
                } label: {
                    HStack {
                        Image(systemName: item.isPacked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isPacked ? .green : .secondary)
                        Text(item.title)
                            .strikethrough(item.isPacked)
                            .foregroundStyle(item.isPacked ? .secondary : .primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deletePacking)

            HStack {
                TextField("Add item", text: $newPackingTitle)
                    .onSubmit { addPacking() }
                Button("Add", action: addPacking)
                    .disabled(newPackingTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if canUseAssistant {
                fillButton(field: .packing, action: fillPacking)
            }

            if !trip.packing.isEmpty {
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

    private func moveStops(from source: IndexSet, to destination: Int) {
        var ordered = trip.sortedStops
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, stop) in ordered.enumerated() { stop.order = index }
    }

    private func addPacking() {
        let title = newPackingTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let item = PackingItem(title: title, trip: trip)
        modelContext.insert(item)
        trip.packing.append(item)
        newPackingTitle = ""
    }

    private func deletePacking(at offsets: IndexSet) {
        let items = offsets.map { trip.packing[$0] }
        for item in items { modelContext.delete(item) }
    }

    private func clearPacking() {
        for item in trip.packing { modelContext.delete(item) }
    }

    // MARK: On-device assistant

    /// Asks the on-device model for a packing list and appends any items not
    /// already on the list (case-insensitive), leaving the user's own entries be.
    private func fillPacking() {
        Task {
            guard let suggestions = await planner.suggestPacking(for: trip) else { return }
            var existing = Set(trip.packing.map { $0.title.lowercased() })
            for title in suggestions {
                let key = title.lowercased()
                guard !existing.contains(key) else { continue }
                existing.insert(key)
                let item = PackingItem(title: title, trip: trip)
                modelContext.insert(item)
                trip.packing.append(item)
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
