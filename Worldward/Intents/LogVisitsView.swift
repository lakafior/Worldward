/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FoundationModels
import SwiftData
import SwiftUI

/// A sheet that logs visits from a plain-language description. The user (or Siri,
/// via `LogVisitsFromDescriptionIntent`) supplies a sentence; the on-device model
/// extracts the countries and dates, and this screen lets the user review and
/// edit before anything is written — parsing can misread, so saving is always a
/// deliberate, confirmed step.
struct LogVisitsView: View {
    /// Pre-filled text, e.g. the phrase Siri captured. Empty for manual entry.
    var initialText: String = ""

    @State private var parser = VisitLogParser()
    @State private var text = ""
    @State private var items: [DraftItem] = []
    @FocusState private var fieldFocused: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// A reviewable, editable row backing one matched-or-unmatched parsed visit.
    private struct DraftItem: Identifiable {
        let id: UUID
        let country: Country?
        let rawName: String
        var date: Date
        var include: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if parser.isAvailable {
                    content
                } else {
                    unavailableView
                }
            }
            .navigationTitle("Log Visits from Text")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if !initialText.isEmpty, text.isEmpty {
                    text = initialText
                    runParse()
                }
            }
        }
    }

    // MARK: - Available content

    private var content: some View {
        Form {
            Section("Describe your trip") {
                TextField(
                    "e.g. I visited Japan and South Korea last spring",
                    text: $text, axis: .vertical
                )
                .lineLimit(2...5)
                .focused($fieldFocused)

                Button {
                    runParse()
                } label: {
                    Label("Find Visits", systemImage: "sparkles")
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || parser.phase == .working)
            }

            switch parser.phase {
            case .working:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading your description…")
                            .foregroundStyle(.secondary)
                    }
                }

            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

            case .parsed where items.isEmpty:
                Section {
                    ContentUnavailableView(
                        "No countries found",
                        systemImage: "magnifyingglass",
                        description: Text("Try naming the countries you visited more directly."))
                }

            default:
                draftSections
            }
        }
    }

    @ViewBuilder private var draftSections: some View {
        // ForEach($items) yields per-row bindings; each section renders only its
        // own kind, since a Binding array can't itself be filtered.
        if items.contains(where: { $0.country != nil }) {
            Section("Visits to save") {
                ForEach($items) { $item in
                    if let country = item.country {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $item.include) {
                                Text("\(country.flagEmoji) \(country.name)")
                                    .font(.headline)
                            }
                            if item.include {
                                DatePicker(
                                    "Date", selection: $item.date,
                                    displayedComponents: .date)
                            }
                        }
                    }
                }
            }
        }

        if items.contains(where: { $0.country == nil }) {
            Section("Couldn't match") {
                ForEach(items) { item in
                    if item.country == nil {
                        Label(item.rawName, systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        items.contains { $0.include && $0.country != nil }
    }

    // MARK: - Actions

    private func runParse() {
        fieldFocused = false
        items = []
        Task {
            await parser.parse(text)
            if case .parsed(let drafts) = parser.phase {
                items = drafts.map { draft in
                    DraftItem(
                        id: draft.id,
                        country: draft.country,
                        rawName: draft.rawName,
                        date: draft.date ?? Date(),
                        include: draft.country != nil)
                }
            }
        }
    }

    private func save() {
        for item in items where item.include {
            guard let country = item.country else { continue }
            let visit = Visit(date: item.date, notes: "", country: country, isImported: false)
            modelContext.insert(visit)
            // Promote an unvisited country, mirroring the Log Visit intent.
            if country.status == .notVisited {
                country.status = .visited
                country.statusIsImported = false
            }
        }
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Unavailable

    @ViewBuilder private var unavailableView: some View {
        switch parser.availability {
        case .unavailable(.appleIntelligenceNotEnabled):
            ContentUnavailableView(
                "Apple Intelligence is Off",
                systemImage: "sparkles",
                description: Text("Turn on Apple Intelligence in Settings to log visits from text."))
        case .unavailable(.modelNotReady):
            ContentUnavailableView(
                "Getting Ready",
                systemImage: "arrow.down.circle",
                description: Text("The on-device model is still downloading. Try again soon."))
        default:
            ContentUnavailableView(
                "Not Available",
                systemImage: "exclamationmark.triangle",
                description: Text("This device can't run the on-device parser."))
        }
    }
}
