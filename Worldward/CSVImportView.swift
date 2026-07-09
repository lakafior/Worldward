/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI

/// Preview-and-confirm sheet for a CSV import: shows the auto-detected column
/// mapping (overridable), what will be imported per country, and what didn't
/// match — nothing touches the store until Import is tapped. Presented from
/// Settings ▸ Data after picking a file.
struct CSVImportView: View {
    let text: String
    /// Called after a successful import with (countries touched, visits added);
    /// the presenter shows the summary alert.
    let onCompletion: (Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Country.name) private var countries: [Country]

    @State private var table: CSVTable?
    @State private var mapping = CSVTransfer.Mapping()
    @State private var plan = CSVTransfer.Plan()
    /// Import errors surface here rather than silently closing the sheet.
    @State private var applyError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import CSV")
                #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { runImport() }
                            .disabled(plan.countries.isEmpty)
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
        #else
            .frame(minWidth: 320, minHeight: 400)
        #endif
        .onAppear(perform: load)
        .onChange(of: mapping) { rebuild() }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { applyError != nil }, set: { if !$0 { applyError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(applyError ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let table {
            Form {
                columnsSection(table)
                summarySection
                if !plan.countries.isEmpty { previewSection }
                if !plan.unmatched.isEmpty { unmatchedSection }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "Nothing to import",
                systemImage: "tablecells.badge.ellipsis",
                description: Text("The file doesn't contain any readable rows."))
        }
    }

    // MARK: Sections

    /// The column mapping, pre-filled by the guesser and overridable per field.
    private func columnsSection(_ table: CSVTable) -> some View {
        Section {
            Picker("Country", selection: $mapping.country) {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    Text(table.columnLabel(column)).tag(column)
                }
            }
            optionalColumnPicker("Date", table: table, selection: $mapping.date)
            optionalColumnPicker("Status", table: table, selection: $mapping.status)
            optionalColumnPicker("Notes", table: table, selection: $mapping.notes)
        } header: {
            Text("Columns")
        } footer: {
            Text(
                "Columns were detected automatically — adjust them if the preview looks wrong. Only the country column is required."
            )
        }
    }

    private func optionalColumnPicker(
        _ title: LocalizedStringKey, table: CSVTable, selection: Binding<Int?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(nil as Int?)
            ForEach(0..<table.columnCount, id: \.self) { column in
                Text(table.columnLabel(column)).tag(column as Int?)
            }
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent {
                Text("\(plan.totalRows)")
            } label: {
                Text("Rows", comment: "CSV import summary: rows read from the file")
            }
            LabeledContent {
                Text("\(plan.countries.count)")
            } label: {
                Text("Countries matched", comment: "CSV import summary")
            }
            LabeledContent {
                Text("\(plan.datedVisits)")
            } label: {
                Text("Dated visits", comment: "CSV import summary")
            }
        } footer: {
            Text(
                "Importing fills in statuses and adds visits — it never removes or overwrites what's already recorded, and days you already logged are skipped."
            )
        }
    }

    private var previewSection: some View {
        Section("Will import") {
            ForEach(plan.countries) { entry in
                HStack(spacing: 8) {
                    Text(entry.country.flagEmoji)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.country.name)
                            .font(.subheadline.weight(.medium))
                        Text(detailLine(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let status = entry.status {
                        Text(status.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(status.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(status.tint)
                    }
                }
            }
        }
    }

    private var unmatchedSection: some View {
        Section {
            ForEach(plan.unmatched.prefix(30), id: \.self) { name in
                Label(name, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            if plan.unmatched.count > 30 {
                Text("…and \(plan.unmatched.count - 30) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Not recognised")
        } footer: {
            Text("These names didn't match any country and will be skipped.")
        }
    }

    private func detailLine(for entry: CSVTransfer.CountryPlan) -> String {
        if entry.dates.isEmpty {
            return String(localized: "status only", comment: "CSV import row: no dated visits")
        }
        let count = entry.dates.count
        let visitWord =
            count == 1
            ? String(localized: "visit") : String(localized: "visits")
        let span = entry.dates.map { $0.formatted(.dateTime.year()) }
        if let first = span.first, let last = span.last, first != last {
            return "\(count) \(visitWord) · \(first)–\(last)"
        }
        return "\(count) \(visitWord)" + (span.first.map { " · \($0)" } ?? "")
    }

    // MARK: Actions

    private func load() {
        guard let parsed = CSVTable.parse(text) else { return }
        table = parsed
        mapping = CSVTransfer.guessMapping(table: parsed, countries: countries)
        rebuild()
    }

    private func rebuild() {
        guard let table else { return }
        plan = CSVTransfer.plan(table: table, mapping: mapping, countries: countries)
    }

    private func runImport() {
        do {
            let result = try CSVTransfer.apply(plan, in: modelContext)
            dismiss()
            onCompletion(result.countries, result.visits)
        } catch {
            applyError = error.localizedDescription
        }
    }
}
