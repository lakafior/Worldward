/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import Photos
import PhotosUI
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
        let lastDate = (country.visits ?? []).max { $0.date < $1.date }?.date
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

            // MARK: Country Facts
            if let facts = CountryFactsDB.facts(for: country.id) {
                Section("Facts") {
                    LabeledContent {
                        Text(facts.currency)
                    } label: {
                        Label("Currency", systemImage: "dollarsign.circle")
                    }

                    LabeledContent {
                        Text(facts.languages.formatted(.list(type: .and)))
                    } label: {
                        Label("Languages", systemImage: "globe")
                    }

                    LabeledContent {
                        Text(facts.plugTypes.map { "Type \($0)" }.formatted(.list(type: .and)))
                    } label: {
                        Label("Plug Types", systemImage: "powerplug.portrait")
                    }

                    LabeledContent {
                        Text(facts.drivingSide.label)
                    } label: {
                        Label("Driving Side", systemImage: "car")
                    }

                    LabeledContent {
                        Text(facts.emergencyNumber)
                            .monospacedDigit()
                    } label: {
                        Label("Emergency", systemImage: "cross.circle")
                    }
                }
            }

            if country.status.isVisited {
                Section("Visits") {
                    if (country.visits ?? []).isEmpty {
                        ContentUnavailableView(
                            "No visits yet",
                            systemImage: "calendar",
                            description: Text("Add your first visit to this country")
                        )
                    } else {
                        ForEach((country.visits ?? []).sorted { $0.date > $1.date }) { visit in
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
        // On macOS the Form already supplies grouped insets and lives in a resizable
        // detail column, so skip the extra padding (which double-pads) and give it a
        // comfortable ideal width; iOS keeps the padded sheet layout.
        #if os(iOS)
            .padding()
            .frame(minWidth: 300)
        #else
            .frame(minWidth: 320, idealWidth: 380, minHeight: 480)
        #endif
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
        if country.visits == nil { country.visits = [] }
        country.visits?.append(visit)

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
        let sorted = (country.visits ?? []).sorted { $0.date > $1.date }
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
    /// Photos picked to attach to this visit; consumed (and cleared) as soon as
    /// the picker returns. Only the stable identifiers are stored, matching the
    /// importer's no-image-data policy.
    @State private var pickedPhotos: [PhotosPickerItem] = []

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
                    PhotosPicker(
                        selection: $pickedPhotos, matching: .images, photoLibrary: .shared()
                    ) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .help("Attach photos from your library")
                    .accessibilityLabel(Text("Attach photos"))
                    Button(action: { isEditing = true }) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Edit visit"))
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("Delete visit"))
                }

                if !visit.photoIdentifiers.isEmpty {
                    VisitPhotosView(identifiers: visit.photoIdentifiers) { identifier in
                        visit.photoIdentifiers.removeAll { $0 == identifier }
                    }
                }
            }
            .padding(.vertical, 4)
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                // `photoLibrary: .shared()` guarantees each item carries the
                // asset's stable localIdentifier — the same key the importer
                // stores — so the thumbnails re-fetch from the library on demand.
                let new = items.compactMap(\.itemIdentifier)
                    .filter { !visit.photoIdentifiers.contains($0) }
                pickedPhotos = []
                guard !new.isEmpty else { return }
                Task {
                    // The picker itself needs no permission, but re-fetching the
                    // thumbnails through PhotoKit does — ask on first use so the
                    // strip doesn't render as gray placeholders.
                    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    visit.photoIdentifiers.append(contentsOf: new)
                }
            }
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
