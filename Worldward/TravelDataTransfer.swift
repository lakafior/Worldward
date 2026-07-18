/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    /// Multi-country trips (Phase 2). Top-level rather than per-country.
    var trips: [TripRecord] = []
}

extension TravelDataFile {
    private enum CodingKeys: String, CodingKey {
        case version, exportedAt, countries, trips
    }

    /// Custom decoding so a v1 backup (written before trips existed) still loads —
    /// `trips` simply defaults to empty. Defined in an extension to keep the
    /// memberwise initializer the exporter uses.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        countries = try c.decode([CountryRecord].self, forKey: .countries)
        trips = try c.decodeIfPresent([TripRecord].self, forKey: .trips) ?? []
    }
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

struct TripRecord: Codable {
    var title: String
    var startDate: Date
    var endDate: Date
    var notes: String
    var itinerary: [ItineraryItemRecord]
    var packing: [PackingItemRecord]
    /// Optional so pre-v4 backups still decode. The bytes ride along as base64 —
    /// backups grow accordingly, but a backup that silently dropped your tickets
    /// wouldn't be a backup.
    var attachments: [AttachmentRecord]?

    @MainActor
    init(from trip: Trip) {
        self.title = trip.title
        self.startDate = trip.startDate
        self.endDate = trip.endDate
        self.notes = trip.notes
        self.itinerary = trip.sortedStops.map(ItineraryItemRecord.init)
        self.packing = trip.packing.map(PackingItemRecord.init)
        self.attachments = trip.sortedAttachments.map(AttachmentRecord.init)
    }
}

struct AttachmentRecord: Codable {
    var filename: String
    var data: Data
    var order: Int

    @MainActor
    init(from attachment: TripAttachment) {
        self.filename = attachment.filename
        self.data = attachment.data
        self.order = attachment.order
    }
}

struct ItineraryItemRecord: Codable {
    var title: String
    var note: String
    var date: Date?
    var order: Int
    var countryID: String?  // ISO alpha-2; re-linked on import, skipped if unknown
    var places: [StopPlaceRecord]?  // optional so pre-places backups still decode

    @MainActor
    init(from item: ItineraryItem) {
        self.title = item.title
        self.note = item.note
        self.date = item.date
        self.order = item.order
        self.countryID = item.country?.id
        self.places = item.sortedPlaces.map(StopPlaceRecord.init)
    }
}

struct StopPlaceRecord: Codable {
    var title: String
    var detail: String
    var latitude: Double?
    var longitude: Double?
    var order: Int

    @MainActor
    init(from place: StopPlace) {
        self.title = place.title
        self.detail = place.detail
        self.latitude = place.latitude
        self.longitude = place.longitude
        self.order = place.order
    }
}

struct PackingItemRecord: Codable {
    var title: String
    var isPacked: Bool
    /// Optional so v2 backups — written before these fields existed — still
    /// decode; a missing value falls back to the model's defaults on import.
    var quantity: Int?
    var order: Int?
    /// The container's *name* (the same portable convention as
    /// `PackingTemplateItem.containerName`); resolved or created on import.
    var containerName: String?

    @MainActor
    init(from item: PackingItem) {
        self.title = item.title
        self.isPacked = item.isPacked
        self.quantity = item.quantity
        self.order = item.order
        self.containerName = item.container?.name
    }
}

/// Encodes and decodes the travel-data backup, and applies an import to the store.
enum TravelDataTransfer {
    /// v3 added quantity/order/containerName to packing items; v4 added trip
    /// attachments. Older files still decode (the fields are optional), and
    /// older builds ignore the extra keys.
    static let currentVersion = 4

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
        let trips = try context.fetch(FetchDescriptor<Trip>())
            .sorted { $0.startDate < $1.startDate }
            .map(TripRecord.init)
        let file = TravelDataFile(
            version: currentVersion, exportedAt: Date(), countries: records, trips: trips)
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

        // Trips are replaced wholesale so re-importing a backup is idempotent
        // rather than additive (cascade delete removes their stops and packing).
        for trip in try context.fetch(FetchDescriptor<Trip>()) {
            context.delete(trip)
        }

        // Resolve packing containers by name against the shared catalog, creating
        // missing ones once and reusing them across every trip in the backup.
        let existingContainers = try context.fetch(FetchDescriptor<PackingContainer>())
        var containersByName = Dictionary(
            existingContainers.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        func container(named raw: String?) -> PackingContainer? {
            guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            let key = name.lowercased()
            if let existing = containersByName[key] { return existing }
            let order = (containersByName.values.map(\.sortOrder).max() ?? -1) + 1
            let created = PackingContainer(name: name, sortOrder: order)
            context.insert(created)
            containersByName[key] = created
            return created
        }

        for record in file.trips {
            let trip = Trip(
                title: record.title, startDate: record.startDate,
                endDate: record.endDate, notes: record.notes)
            context.insert(trip)
            for stop in record.itinerary.sorted(by: { $0.order < $1.order }) {
                let item = ItineraryItem(
                    title: stop.title, note: stop.note, date: stop.date, order: stop.order,
                    country: stop.countryID.flatMap { byID[$0] }, trip: trip)
                context.insert(item)
                trip.itinerary.append(item)
                for record in (stop.places ?? []).sorted(by: { $0.order < $1.order }) {
                    let place = StopPlace(
                        title: record.title, detail: record.detail,
                        latitude: record.latitude, longitude: record.longitude,
                        order: record.order, stop: item)
                    context.insert(place)
                    item.places.append(place)
                }
            }
            for (index, pack) in record.packing.enumerated() {
                let item = PackingItem(
                    title: pack.title, isPacked: pack.isPacked,
                    quantity: pack.quantity ?? 1,
                    order: pack.order ?? index,
                    trip: trip,
                    container: container(named: pack.containerName))
                context.insert(item)
                trip.packing.append(item)
            }
            for record in (record.attachments ?? []).sorted(by: { $0.order < $1.order }) {
                let attachment = TripAttachment(
                    filename: record.filename, data: record.data, order: record.order, trip: trip)
                context.insert(attachment)
                trip.attachments.append(attachment)
            }
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
