import AppIntents
import SwiftData
import SwiftUI

// MARK: - Country Detail (full Form view)

struct CountryDetailView: View {
    @Bindable var country: Country
    @Environment(\.modelContext) private var modelContext
    @State private var newVisitDate: Date
    @State private var newVisitNotes = ""
    @State private var showingAddVisit = false

    init(country: Country) {
        self.country = country
        // Default to one day after the most recent visit, so adding
        // consecutive visits requires less date-picking.
        let lastDate = country.visits.sorted { $0.date > $1.date }.first?.date
        _newVisitDate = State(
            initialValue: lastDate.map {
                Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? Date()
            } ?? Date())
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("\(country.flagEmoji) \(country.name)")
                        .font(.largeTitle)
                        .bold()
                    Text(country.continent)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical)

                Picker("Status", selection: $country.status) {
                    ForEach(CountryStatus.allCases) { status in
                        Label(status.label, systemImage: status.symbolName)
                            .tag(status)
                    }
                }
            }

            Section("Plans") {
                Picker("List", selection: $country.planStatus) {
                    ForEach(PlanStatus.allCases) { plan in
                        Label(plan.label, systemImage: plan.symbolName)
                            .tag(plan)
                    }
                }
            }

            if country.status.isVisited {
                Section("Visits") {
                    if country.visits.isEmpty {
                        ContentUnavailableView(
                            "No visits yet",
                            systemImage: "calendar",
                            description: Text("Add your first visit to this country")
                        )
                    } else {
                        ForEach(country.visits.sorted { $0.date > $1.date }) { visit in
                            VisitRow(visit: visit) { delete(visit) }
                        }
                        .onDelete(perform: deleteVisits)
                    }

                    if showingAddVisit {
                        DatePicker("Date", selection: $newVisitDate, displayedComponents: .date)
                        TextField("Notes", text: $newVisitNotes, axis: .vertical)
                            .lineLimit(3...5)

                        HStack {
                            Spacer()
                            Button("Cancel") {
                                showingAddVisit = false
                                newVisitDate = Date()
                                newVisitNotes = ""
                            }
                            Button("Add Visit") {
                                addVisit()
                            }
                        }
                    } else {
                        Button("Add Visit") {
                            showingAddVisit = true
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
        // Advertise the country on screen so Siri and Apple Intelligence can
        // answer questions about it ("have I been here?"). Keyed on the stable
        // ISO id; the entity is rebuilt in the closure from the live model.
        .userActivity(CountryEntity.viewingActivityType, element: country.id) { _, activity in
            let entity = CountryEntity(from: country)
            activity.title = "Viewing \(entity.flagEmoji) \(entity.name)"
            activity.appEntityIdentifier = EntityIdentifier(for: entity)
        }
    }

    private func addVisit() {
        let visit = Visit(date: newVisitDate, notes: newVisitNotes, country: country)
        country.visits.append(visit)

        showingAddVisit = false
        newVisitDate = Date()
        newVisitNotes = ""
    }

    /// Delete a single visit (used by the row's trash button).
    private func delete(_ visit: Visit) {
        modelContext.delete(visit)
    }

    /// Delete via swipe, matching the same date-sorted order shown in the list.
    private func deleteVisits(at offsets: IndexSet) {
        let sorted = country.visits.sorted { $0.date > $1.date }
        for index in offsets {
            modelContext.delete(sorted[index])
        }
    }
}

// MARK: - Visit Row

struct VisitRow: View {
    @Bindable var visit: Visit
    let onDelete: () -> Void
    @State private var isEditing = false
    @State private var editDate: Date
    @State private var editNotes: String

    init(visit: Visit, onDelete: @escaping () -> Void) {
        self.visit = visit
        self.onDelete = onDelete
        _editDate = State(initialValue: visit.date)
        _editNotes = State(initialValue: visit.notes)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("Date", selection: $editDate, displayedComponents: .date)
                TextField("Notes", text: $editNotes, axis: .vertical)
                    .lineLimit(3...5)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        isEditing = false
                    }
                    Button("Save") {
                        visit.date = editDate
                        visit.notes = editNotes
                        isEditing = false
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(visit.date, style: .date)
                            .font(.subheadline)
                            .monospacedDigit()

                        if !visit.notes.isEmpty {
                            Text(visit.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: { isEditing = true }) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }

                if !visit.photoIdentifiers.isEmpty {
                    VisitPhotosView(identifiers: visit.photoIdentifiers)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Country Detail Sheet

/// A sheet that wraps CountryDetailView so the map doesn't resize and Metal
/// doesn't need to re-acquire drawables. iOS-native sheet avoids the black
/// rendering artifacts that the inspector produces when overlaid on a Map.
struct CountryDetailSheet: View {
    @Bindable var country: Country
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CountryDetailView(country: country)
                .navigationTitle(country.name)
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

// MARK: - Location Status Sheet

/// A compact sheet that appears after the "Mark Location" toolbar button resolves
/// the current country. Shows the flag, name, and a status picker.
struct LocationStatusSheet: View {
    @Bindable var country: Country
    @Binding var status: CountryStatusOption
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Text(country.flagEmoji)
                            .font(.largeTitle)
                        VStack(alignment: .leading) {
                            Text(country.name)
                                .font(.headline)
                            Text(country.continent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Travel Status") {
                    Picker("Status", selection: $status) {
                        ForEach(CountryStatusOption.allCases) { option in
                            HStack {
                                Image(
                                    systemName: option.domainStatus.symbolName
                                )
                                .foregroundStyle(option.domainStatus.tint)
                                Text(option.domainStatus.label)
                            }
                            .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Mark Location")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark", action: onConfirm)
                }
            }
        }
    }
}
