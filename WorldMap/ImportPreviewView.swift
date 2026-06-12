import SwiftData
import SwiftUI

/// Import sheet that walks through configuring, scanning, and reviewing a
/// photo-based visit import before anything is written to the database.
struct ImportPreviewView: View {
    var importer: PhotoImporter
    @Environment(\.dismiss) private var dismiss
    let modelContext: ModelContext

    @State private var settings = ImportSettings()

    var body: some View {
        NavigationStack {
            Group {
                switch importer.phase {
                case .config:
                    configForm
                case .scanning:
                    scanningView
                case .results:
                    resultsView
                }
            }
            .navigationTitle("Import from Photos")
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    // MARK: - Configuration

    private var configForm: some View {
        VStack(spacing: 0) {
            Form {
                Section("Scan mode") {
                    Picker("Scan mode", selection: $settings.scanMode) {
                        ForEach(ImportScanMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.scanMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Trips") {
                    Stepper(value: $settings.mergeGapDays, in: 1...60) {
                        LabeledContent(
                            "Merge gap",
                            value: "\(settings.mergeGapDays) day\(settings.mergeGapDays == 1 ? "" : "s")")
                    }
                    Text("Photos closer together than this are treated as one trip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(value: $settings.livedThresholdDays, in: 7...365) {
                        LabeledContent("\u{201C}Lived\u{201D} threshold", value: "\(settings.livedThresholdDays) days")
                    }
                    Text("A single trip at least this long marks the country as \u{201C}Lived\u{201D}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Home") {
                    Toggle("Mark most-visited country as home", isOn: $settings.markHome)
                    Text("Sets your most-present country to \u{201C}Living\u{201D}. An existing home is never overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") {
                    importer.cancelImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Scan Photos") {
                    importer.startImport(settings: settings)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(importer.importProgress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            if let warning = importer.homeWarning {
                Label(warning, systemImage: "house")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            List {
                if importer.proposedCountries.isEmpty {
                    ContentUnavailableView(
                        "No visits found",
                        systemImage: "photo",
                        description: Text(
                            "No photos with location data matched a country, or everything is already imported."
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(importer.proposedCountries) { proposed in
                        countryRow(proposed)
                    }
                }
            }

            Divider()
            HStack {
                Button("Back") {
                    importer.phase = .config
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if !importer.proposedCountries.isEmpty {
                    Button("Import \(importer.proposedCountries.count) Countries") {
                        importer.applyImport(to: modelContext, scanMode: settings.scanMode)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
    }

    private func countryRow(_ proposed: ProposedCountry) -> some View {
        DisclosureGroup {
            ForEach(proposed.trips) { trip in
                HStack {
                    Text(tripDateText(trip))
                        .font(.subheadline)
                    Spacer()
                    Text("\(trip.photoCount) photo\(trip.photoCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(proposed.flagEmoji)
                    .font(.title)

                VStack(alignment: .leading, spacing: 4) {
                    Text(proposed.countryName)
                        .font(.headline)
                    Text(
                        "\(proposed.trips.count) trip\(proposed.trips.count == 1 ? "" : "s") · \(proposed.totalDistinctDays) day\(proposed.totalDistinctDays == 1 ? "" : "s")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                statusBadge(proposed.proposedStatus, isHome: proposed.isHome)
            }
        }
    }

    private func statusBadge(_ status: CountryStatus, isHome: Bool) -> some View {
        Label(isHome ? "Home" : status.label, systemImage: status.symbolName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.2), in: Capsule())
            .foregroundStyle(status.tint)
    }

    private func tripDateText(_ trip: ProposedTrip) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        if Calendar.current.isDate(trip.startDate, inSameDayAs: trip.endDate) {
            return formatter.string(from: trip.startDate)
        }
        return "\(formatter.string(from: trip.startDate)) – \(formatter.string(from: trip.endDate))"
    }
}
