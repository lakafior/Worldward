import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Codable snapshot of the user's travel data — the part of the store that's
/// actually theirs. The country catalog itself (names, continents, polygons) is
/// re-seeded from the bundled GeoJSON, so it's deliberately left out; only the
/// per-country status and visits are exported, keyed by ISO alpha-2 id.
struct TravelDataFile: Codable {
    var version: Int
    var exportedAt: Date
    var countries: [CountryRecord]
}

struct CountryRecord: Codable {
    var id: String  // ISO alpha-2
    var status: CountryStatus
    var statusIsImported: Bool
    var notes: String
    var visitDate: Date?  // legacy single-date field, preserved for round-tripping
    var visits: [VisitRecord]
    /// The plan axis (wishlist/planning). Optional so older backups — written
    /// before plans existed — still decode; a missing value imports as `.none`.
    var planStatus: PlanStatus?

    /// Builds a record from a country, or `nil` when the country has no user data
    /// worth exporting (so a clean install exports an empty list, not 250 blanks).
    @MainActor
    init?(from country: Country) {
        let hasData =
            country.status != .notVisited
            || country.planStatus != .none
            || !country.visits.isEmpty
            || !country.notes.isEmpty
            || country.visitDate != nil
        guard hasData else { return nil }

        self.id = country.id
        self.status = country.status
        self.statusIsImported = country.statusIsImported
        self.notes = country.notes
        self.visitDate = country.visitDate
        self.visits = country.visits.map(VisitRecord.init)
        self.planStatus = country.planStatus
    }

    /// Overwrites a country's travel data with this record. Replaces the country's
    /// visits wholesale so re-importing a backup is idempotent rather than additive.
    @MainActor
    func apply(to country: Country, in context: ModelContext) {
        country.status = status
        country.statusIsImported = statusIsImported
        country.notes = notes
        country.visitDate = visitDate
        country.planStatus = planStatus ?? .none

        for visit in country.visits {
            context.delete(visit)
        }
        for record in visits {
            let visit = Visit(
                date: record.date, notes: record.notes, country: country,
                isImported: record.isImported)
            visit.photoIdentifiers = record.photoIdentifiers
            context.insert(visit)
        }
    }
}

struct VisitRecord: Codable {
    var date: Date
    var notes: String
    var isImported: Bool
    var photoIdentifiers: [String]

    @MainActor
    init(from visit: Visit) {
        self.date = visit.date
        self.notes = visit.notes
        self.isImported = visit.isImported
        self.photoIdentifiers = visit.photoIdentifiers
    }
}

/// Encodes and decodes the travel-data backup, and applies an import to the store.
enum TravelDataTransfer {
    static let currentVersion = 1

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Serializes every country that has user data into a pretty-printed JSON backup.
    @MainActor
    static func export(from context: ModelContext) throws -> Data {
        let countries = try context.fetch(FetchDescriptor<Country>())
        let records = countries.compactMap(CountryRecord.init).sorted { $0.id < $1.id }
        let file = TravelDataFile(
            version: currentVersion, exportedAt: Date(), countries: records)
        return try encoder.encode(file)
    }

    /// Applies a backup to the store, matching records to existing countries by id.
    /// Unknown ids (e.g. from a newer dataset) are skipped. Returns the number of
    /// countries updated.
    @discardableResult
    @MainActor
    static func importData(_ data: Data, into context: ModelContext) throws -> Int {
        let file = try decoder.decode(TravelDataFile.self, from: data)

        let existing = try context.fetch(FetchDescriptor<Country>())
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var applied = 0
        for record in file.countries {
            guard let country = byID[record.id] else { continue }
            record.apply(to: country, in: context)
            applied += 1
        }
        try context.save()
        return applied
    }
}

/// A minimal `FileDocument` that carries raw JSON bytes, so `fileExporter` can
/// write the backup natively on both iOS and macOS.
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
