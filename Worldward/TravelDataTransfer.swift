/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Codable snapshot of the user's travel data — the part of the store that's
/// actually theirs. The country catalog itself (names, continents, polygons) is
/// re-seeded from the bundled GeoJSON, so it's deliberately left out; only the
/// per-country status and visits are exported, keyed by ISO alpha-2 id.
/// `nonisolated` (with its country records) so the backup can be encoded and
/// decoded off the main actor — see `TravelDataTransfer.encode` / `decode`.
nonisolated struct TravelDataFile: Codable {
    var version: Int
    var exportedAt: Date
    var countries: [CountryRecord]
    /// Multi-country trips (Phase 2). Top-level rather than per-country.
    var trips: [TripRecord] = []
}

nonisolated extension TravelDataFile {
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

nonisolated struct CountryRecord: Codable {
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
            || !(country.visits ?? []).isEmpty
            || !country.notes.isEmpty
            || country.visitDate != nil
        guard hasData else { return nil }

        self.id = country.id
        self.status = country.status
        self.statusIsImported = country.statusIsImported
        self.notes = country.notes
        self.visitDate = country.visitDate
        self.visits = (country.visits ?? []).map(VisitRecord.init)
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

        for visit in country.visits ?? [] {
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

nonisolated struct VisitRecord: Codable {
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

/// `nonisolated` (like the other trip records below) so the `.wwtrip` share
/// flow can encode a record off the main actor — see `TripFileTransfer.swift` —
/// which also makes it `Sendable`; it's all value types.
nonisolated struct TripRecord: Codable {
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
    /// Saved links and contacts, both optional so pre-v6 backups still decode.
    /// Links shipped before this and were never carried here — a backup written
    /// by those builds restores with none, which is the same as it behaved then.
    var links: [LinkRecord]?
    var contacts: [ContactRecord]?
    /// The trip's CloudKit dedup token, carried so a re-shared `.wwtrip` file
    /// *updates* the receiver's copy instead of duplicating it. Optional so
    /// pre-v4 backups still decode; a missing value imports as a fresh ID.
    var dedupID: String?

    @MainActor
    init(from trip: Trip) {
        self.title = trip.title
        self.startDate = trip.startDate
        self.endDate = trip.endDate
        self.notes = trip.notes
        self.itinerary = trip.sortedStops.map(ItineraryItemRecord.init)
        self.packing = (trip.packing ?? []).map(PackingItemRecord.init)
        self.attachments = trip.sortedAttachments.map(AttachmentRecord.init)
        self.links = trip.sortedLinks.map(LinkRecord.init)
        self.contacts = trip.sortedContacts.map(ContactRecord.init)
        self.dedupID = trip.dedupID
    }
}

/// A saved link, with the stop it was pinned to carried the same way
/// `AttachmentRecord` carries it — by that stop's `order`, matched back to a
/// rebuilt `ItineraryItem` on import. A nil `stopOrder` restores trip-level.
nonisolated struct LinkRecord: Codable {
    var title: String
    var url: String
    var order: Int
    var stopOrder: Int?

    @MainActor
    init(from link: TripLink) {
        self.title = link.title
        self.url = link.url
        self.order = link.order
        self.stopOrder = link.item?.order
    }
}

/// A saved contact. `kind` rides as the raw string so an unknown value from a
/// newer build survives the round trip and degrades to `.other` on read.
nonisolated struct ContactRecord: Codable {
    var name: String
    var value: String
    var kind: String
    var order: Int
    var stopOrder: Int?

    @MainActor
    init(from contact: TripContact) {
        self.name = contact.name
        self.value = contact.value
        self.kind = contact.kind
        self.order = contact.order
        self.stopOrder = contact.item?.order
    }
}

nonisolated struct AttachmentRecord: Codable {
    var filename: String
    var data: Data
    var order: Int
    /// The file's description, and which stop it belongs to (by that stop's
    /// `order`, matched back to a rebuilt `ItineraryItem` on import). Both optional
    /// so pre-v5 backups still decode; a missing `stopOrder` restores as a
    /// trip-level document.
    var caption: String?
    var stopOrder: Int?

    @MainActor
    init(from attachment: TripAttachment) {
        self.filename = attachment.filename
        self.data = attachment.data
        self.order = attachment.order
        self.caption = attachment.caption.isEmpty ? nil : attachment.caption
        self.stopOrder = attachment.item?.order
    }
}

nonisolated struct ItineraryItemRecord: Codable {
    var title: String
    var note: String
    var date: Date?
    var order: Int
    var countryID: String?  // ISO alpha-2; re-linked on import, skipped if unknown
    /// A stop can now *be* a place, so it carries its own address line and pin.
    /// All optional so older backups (which kept these under nested `places`)
    /// still decode; `fill(_:from:)` unfolds any such `places` into sibling stops.
    var detail: String?
    var latitude: Double?
    var longitude: Double?
    var places: [StopPlaceRecord]?  // legacy nested places; unfolded on import

    @MainActor
    init(from item: ItineraryItem) {
        self.title = item.title
        self.note = item.note
        self.date = item.date
        self.order = item.order
        self.countryID = item.country?.id
        self.detail = item.detail.isEmpty ? nil : item.detail
        self.latitude = item.latitude
        self.longitude = item.longitude
        // Flat model: stops no longer nest places. Kept nil rather than [] so new
        // files don't carry an empty legacy field.
        self.places = nil
    }
}

nonisolated struct StopPlaceRecord: Codable {
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

nonisolated struct PackingItemRecord: Codable {
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
    /// attachments; v5 flattened the itinerary — stops carry their own
    /// coordinate/detail, and attachments carry a caption + the stop they belong
    /// to; v6 added trip links and contacts. Older files still decode (the new
    /// fields are optional; legacy nested `places` are unfolded on import), and
    /// older builds ignore the extra keys.
    static let currentVersion = 6

    /// Serializes every country that has user data into a pretty-printed JSON
    /// backup. The model snapshot has to happen on the main actor; the encode —
    /// pretty-printed, key-sorted, attachments as base64, so it grows with the
    /// user's files — runs off it.
    @MainActor
    static func export(from context: ModelContext) async throws -> Data {
        try await encode(snapshot(from: context))
    }

    /// Every country with user data, plus all trips, as plain value records.
    @MainActor
    static func snapshot(from context: ModelContext) throws -> TravelDataFile {
        let countries = try context.fetch(FetchDescriptor<Country>())
        let records = countries.compactMap(CountryRecord.init).sorted { $0.id < $1.id }
        let trips = try context.fetch(FetchDescriptor<Trip>())
            .sorted { $0.startDate < $1.startDate }
            .map(TripRecord.init)
        return TravelDataFile(
            version: currentVersion, exportedAt: Date(), countries: records, trips: trips)
    }

    @concurrent nonisolated static func encode(_ file: TravelDataFile) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Reads and decodes a backup off the main actor. Brackets security-scoped
    /// access itself (a file from the system picker needs it on iOS), so the
    /// read stays inside the scope.
    @concurrent nonisolated static func decode(contentsOf url: URL) async throws -> TravelDataFile {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TravelDataFile.self, from: Data(contentsOf: url))
    }

    /// What importing a backup would cost, measured before anything is written.
    /// `tripsReplaced` is the part worth confirming: unlike the CSV import, a
    /// backup restore deletes every existing trip, and there is no undo.
    struct ImportSummary {
        let countries: Int
        let trips: Int
        let tripsReplaced: Int
    }

    /// Measures a decoded backup against the current store without mutating
    /// anything, so the confirmation can name real numbers. Decoding happens
    /// first (in `decode(contentsOf:)`), which means a malformed file is
    /// rejected *before* the user is asked to approve a destructive write.
    @MainActor
    static func summarize(_ file: TravelDataFile, in context: ModelContext) throws -> ImportSummary {
        // Mirrors `importData`'s matching rule so the count the user approves is
        // the count they're told about afterwards.
        let knownIDs = Set(try context.fetch(FetchDescriptor<Country>()).map(\.id))
        return ImportSummary(
            countries: file.countries.count { knownIDs.contains($0.id) },
            trips: file.trips.count,
            tripsReplaced: try context.fetchCount(FetchDescriptor<Trip>())
        )
    }

    /// Applies a backup to the store, matching records to existing countries by id.
    /// Unknown ids (e.g. from a newer dataset) are skipped. Returns the number of
    /// countries updated.
    @discardableResult
    @MainActor
    static func importData(_ file: TravelDataFile, into context: ModelContext) throws -> Int {

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

        let container = try containerResolver(in: context)
        for record in file.trips {
            let trip = Trip()
            if let dedupID = record.dedupID { trip.dedupID = dedupID }
            context.insert(trip)
            fill(trip, from: record, in: context, countriesByID: byID, container: container)
        }

        try context.save()
        return applied
    }

    /// A resolver mapping container names to the shared catalog, creating
    /// missing ones once and reusing them across every trip it resolves.
    @MainActor
    static func containerResolver(
        in context: ModelContext
    ) throws -> (String?) -> PackingContainer? {
        let existingContainers = try context.fetch(FetchDescriptor<PackingContainer>())
        var containersByName = Dictionary(
            existingContainers.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        return { raw in
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
    }

    /// Fills `trip` from `record`, replacing its children wholesale. Shared by
    /// the backup import (fresh trips) and the `.wwtrip` receive flow — which
    /// updates a matching trip *in place*, preserving its calendar/reminder
    /// sync linkage rather than deleting and re-creating the row.
    @MainActor
    static func fill(
        _ trip: Trip, from record: TripRecord, in context: ModelContext,
        countriesByID: [String: Country], container: (String?) -> PackingContainer?
    ) {
        trip.title = record.title
        trip.startDate = record.startDate
        trip.endDate = record.endDate
        trip.notes = record.notes

        for stop in trip.itinerary ?? [] { context.delete(stop) }
        for item in trip.packing ?? [] { context.delete(item) }
        for attachment in trip.attachments ?? [] { context.delete(attachment) }
        for link in trip.links ?? [] { context.delete(link) }
        for contact in trip.contacts ?? [] { context.delete(contact) }
        trip.itinerary = []
        trip.packing = []
        trip.attachments = []
        trip.links = []
        trip.contacts = []

        // The itinerary is a single flat list of stops now. A legacy record's
        // nested `places` (from a build before the flatten) are unfolded into
        // sibling stops here — each place becomes its own stop carrying the
        // parent's country — so an old backup or `.wwtrip` still imports whole.
        // A running `order` interleaves stop, its places, next stop… in sequence.
        // `stopsByRecordOrder` re-links per-stop attachments below.
        var order = 0
        var stopsByRecordOrder: [Int: ItineraryItem] = [:]
        for stop in record.itinerary.sorted(by: { $0.order < $1.order }) {
            let country = stop.countryID.flatMap { countriesByID[$0] }
            let item = ItineraryItem(
                title: stop.title, note: stop.note, date: stop.date, order: order,
                country: country, trip: trip,
                detail: stop.detail ?? "", latitude: stop.latitude, longitude: stop.longitude)
            context.insert(item)
            if trip.itinerary == nil { trip.itinerary = [] }
            trip.itinerary?.append(item)
            stopsByRecordOrder[stop.order] = item
            order += 1
            for record in (stop.places ?? []).sorted(by: { $0.order < $1.order }) {
                let place = ItineraryItem(
                    title: record.title, order: order, country: country, trip: trip,
                    detail: record.detail, latitude: record.latitude, longitude: record.longitude)
                context.insert(place)
                trip.itinerary?.append(place)
                order += 1
            }
        }
        for (index, pack) in record.packing.enumerated() {
            let item = PackingItem(
                title: pack.title, isPacked: pack.isPacked,
                quantity: pack.quantity ?? 1,
                order: pack.order ?? index,
                trip: trip,
                container: container(pack.containerName))
            context.insert(item)
            if trip.packing == nil { trip.packing = [] }
            trip.packing?.append(item)
        }
        for record in (record.attachments ?? []).sorted(by: { $0.order < $1.order }) {
            // Re-link to the stop it belonged to (by that stop's record order); a
            // missing or unmatched `stopOrder` lands it as a trip-level document.
            let stop = record.stopOrder.flatMap { stopsByRecordOrder[$0] }
            let attachment = TripAttachment(
                filename: record.filename, data: record.data, order: record.order, trip: trip,
                caption: record.caption ?? "", item: stop)
            context.insert(attachment)
            if trip.attachments == nil { trip.attachments = [] }
            trip.attachments?.append(attachment)
            if let stop {
                if stop.attachments == nil { stop.attachments = [] }
                stop.attachments?.append(attachment)
            }
        }
        for record in (record.links ?? []).sorted(by: { $0.order < $1.order }) {
            let stop = record.stopOrder.flatMap { stopsByRecordOrder[$0] }
            let link = TripLink(
                title: record.title, url: record.url, order: record.order, trip: trip, item: stop)
            context.insert(link)
            if trip.links == nil { trip.links = [] }
            trip.links?.append(link)
            if let stop {
                if stop.links == nil { stop.links = [] }
                stop.links?.append(link)
            }
        }
        for record in (record.contacts ?? []).sorted(by: { $0.order < $1.order }) {
            let stop = record.stopOrder.flatMap { stopsByRecordOrder[$0] }
            let contact = TripContact(
                name: record.name, value: record.value,
                kind: ContactKind(rawValue: record.kind) ?? .other,
                order: record.order, trip: trip, item: stop)
            context.insert(contact)
            if trip.contacts == nil { trip.contacts = [] }
            trip.contacts?.append(contact)
            if let stop {
                if stop.contacts == nil { stop.contacts = [] }
                stop.contacts?.append(contact)
            }
        }
    }

    /// One-shot migration for stores written before the itinerary flatten: every
    /// `StopPlace` becomes a sibling `ItineraryItem` inserted right after its old
    /// parent, inheriting the parent's country and keeping its own coordinate and
    /// address line. Idempotent — once drained the store holds no `StopPlace`, so
    /// the guard makes every later launch a cheap no-op. Runs on the main actor at
    /// launch (see `ContentView.loadGeoJSON`), the only place SwiftData is touched.
    ///
    /// This can't run while the editor still *creates* `StopPlace`s (a relaunch
    /// mid-transition would convert places the UI just made), which is why it
    /// lands together with the flat-itinerary cutover rather than in Phase 1.
    @MainActor
    static func flattenLegacyPlaces(in context: ModelContext) {
        let legacy = (try? context.fetch(FetchDescriptor<StopPlace>())) ?? []
        guard !legacy.isEmpty else { return }

        // Rebuild each affected trip's itinerary as one flat, renumbered sequence:
        // stop, then the places that were nested under it, then the next stop.
        for trip in Set(legacy.compactMap { $0.stop?.trip }) {
            var order = 0
            for stop in trip.sortedStops {
                stop.order = order
                order += 1
                for place in stop.sortedPlaces {
                    let sibling = ItineraryItem(
                        title: place.title, order: order, country: stop.country, trip: trip,
                        detail: place.detail, latitude: place.latitude, longitude: place.longitude)
                    context.insert(sibling)
                    trip.itinerary?.append(sibling)
                    context.delete(place)
                    order += 1
                }
            }
        }
        // Orphans whose stop or trip is already gone: just drop them.
        for place in legacy where place.stop?.trip == nil { context.delete(place) }
        try? context.save()
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
