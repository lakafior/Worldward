/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - .wwtrip file format

extension UTType {
    /// The `.wwtrip` document type — a single trip shared app-to-app (AirDrop,
    /// Messages, Files). Declared in `Info.plist` (`UTExportedTypeDeclarations`
    /// + `CFBundleDocumentTypes`) so the system routes these files to Worldward.
    /// `nonisolated`: referenced from the nonisolated `transferRepresentation`.
    nonisolated static let worldwardTrip = UTType(exportedAs: "net.smigi.worldward.trip")
}

/// The envelope inside a `.wwtrip` file: one `TripRecord` (the same portable
/// snapshot the JSON backup uses — itinerary, packing, attachments, dedup ID)
/// plus a version, so the trip-share format can evolve independently of the
/// backup format.
nonisolated struct TripFile: Codable {
    var version: Int
    var trip: TripRecord
}

/// An opened `.wwtrip` file held for the confirm sheet. `Identifiable` so it
/// can drive `.sheet(item:)` in `ContentView`.
nonisolated struct ReceivedTripFile: Identifiable {
    let id = UUID()
    let trip: TripRecord
}

extension TravelDataTransfer {
    nonisolated static let currentTripFileVersion = 1

    /// Encodes a single-trip `.wwtrip` payload. `nonisolated` because the share
    /// sheet's `DataRepresentation` exporting closure runs off the main actor —
    /// which is also why it builds its own encoder rather than touching the
    /// main-actor `encoder` static.
    nonisolated static func encodeTripFile(_ record: TripRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(TripFile(version: currentTripFileVersion, trip: record))
    }

    nonisolated static func decodeTripFile(_ data: Data) throws -> TripFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TripFile.self, from: data)
    }

    /// Applies a received trip: a trip with the same `dedupID` is updated in
    /// place (so a round-tripped file — you share it, they improve it, they
    /// send it back — converges instead of duplicating), otherwise a new trip
    /// is inserted carrying the file's ID so future re-shares keep matching.
    @MainActor
    static func importTrip(_ record: TripRecord, into context: ModelContext) throws {
        let countries = try context.fetch(FetchDescriptor<Country>())
        let byID = Dictionary(
            countries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let trip: Trip
        if let existing = try existingTrip(matching: record, in: context) {
            trip = existing
        } else {
            trip = Trip()
            if let dedupID = record.dedupID { trip.dedupID = dedupID }
            context.insert(trip)
        }
        fill(
            trip, from: record, in: context, countriesByID: byID,
            container: try containerResolver(in: context))
        try context.save()
    }

    /// The receiver's trip a `.wwtrip` file would update, or `nil` when it
    /// would add a new one. Also drives the confirm sheet's add-vs-update copy.
    @MainActor
    static func existingTrip(matching record: TripRecord, in context: ModelContext) throws -> Trip?
    {
        guard let dedupID = record.dedupID else { return nil }
        return try context.fetch(FetchDescriptor<Trip>()).first { $0.dedupID == dedupID }
    }
}

// MARK: - Sending

/// Makes a trip shareable as a `.wwtrip` file. Holds the pre-built `TripRecord`
/// (plain value types, so `Sendable`); the actual JSON encoding — including
/// base64 of any attachments — runs in the export closure, i.e. only when the
/// user actually shares, not on every render of the Share menu.
nonisolated struct ExportableTripFile: Transferable {
    let title: String
    let record: TripRecord

    @MainActor
    init(trip: Trip) {
        self.title = trip.title
        self.record = TripRecord(from: trip)
    }

    static var transferRepresentation: some TransferRepresentation {
        // A `FileRepresentation` (not `DataRepresentation`): macOS only offers
        // Shortcuts/Copy for raw in-memory data of a custom content type — the
        // full service list (AirDrop, Mail, Messages…) appears only for a real
        // file on disk. Each export gets its own UUID'd temp subdirectory so
        // the visible filename can be the trip's own name.
        FileRepresentation(exportedContentType: .worldwardTrip) { item in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("\(sanitizedFileName(item.title)).wwtrip")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TravelDataTransfer.encodeTripFile(item.record).write(to: url, options: .atomic)
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
        .suggestedFileName { "\(sanitizedFileName($0.title)).wwtrip" }
    }
}

// MARK: - Receiving

/// The confirm sheet for an opened `.wwtrip` file: what the trip contains, and
/// whether accepting it adds a new trip or updates the existing one with the
/// same origin (dedup ID). Nothing touches the store until the user confirms.
struct TripFileImportSheet: View {
    let record: TripRecord

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?

    /// Resolved once per presentation — the sheet is short-lived and the store
    /// can't change under it while it's up.
    private var existingTrip: Trip? {
        (try? TravelDataTransfer.existingTrip(matching: record, in: modelContext)) ?? nil
    }

    private var dateLine: String {
        let start = record.startDate.formatted(date: .abbreviated, time: .omitted)
        let end = record.endDate.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }

    var body: some View {
        NavigationStack {
            let existing = existingTrip
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title.isEmpty ? Str.Trip.untitled : record.title)
                            .font(.headline)
                        Text(dateLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(Str.Trip.itineraryLabel, value: "\(record.itinerary.count)")
                    LabeledContent(Str.Trip.packing, value: "\(record.packing.count)")
                    if let attachments = record.attachments, !attachments.isEmpty {
                        LabeledContent("Attachments", value: "\(attachments.count)")
                    }
                    if let links = record.links, !links.isEmpty {
                        LabeledContent("Links", value: "\(links.count)")
                    }
                    if let contacts = record.contacts, !contacts.isEmpty {
                        LabeledContent("Contacts", value: "\(contacts.count)")
                    }
                } footer: {
                    if let existing {
                        Text(
                            "This will update your existing “\(existing.title)”."
                        )
                    }
                }
                Section {
                    Button {
                        accept()
                    } label: {
                        Label(
                            existing != nil ? "Update Trip" : "Add Trip",
                            systemImage: existing != nil
                                ? "arrow.triangle.2.circlepath" : "plus")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Received Trip")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .alert(
                "Received Trip",
                isPresented: Binding(
                    get: { importError != nil }, set: { if !$0 { importError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
        #if os(macOS)
            .frame(minWidth: 360, minHeight: 320)
        #endif
    }

    private func accept() {
        do {
            try TravelDataTransfer.importTrip(record, into: modelContext)
            dismiss()
        } catch {
            importError = error.localizedDescription
        }
    }
}
