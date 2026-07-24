/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

/// A lightweight, `Codable` / `Sendable` representation of a `Trip` suitable as an
/// `AppEntity`. The struct carries only identity and display fields; the underlying
/// `@Model` object is fetched on demand by `TripEntityQuery`.
///
/// Keying on the per-row `dedupID` (the same token CloudKit de-dup and the packing
/// widget already rely on) keeps identities stable across launches, devices, and
/// import/export — a `PersistentIdentifier` wouldn't survive leaving the app, and a
/// trip has no natural unique key of its own the way a country has its ISO code.
struct TripEntity: IndexedEntity {

    /// The trip's `dedupID`. Stable across sync and process boundaries.
    let id: String

    /// The trip's title, or a placeholder for an untitled trip.
    let title: String

    /// Pre-joined flag emoji for the trip's countries (mirroring `Trip.flags`), so
    /// the entity can render without consulting SwiftData.
    let flags: String

    /// The trip's date span as one line ("12 Mar – 20 Mar"), used as the subtitle.
    let dateRange: String

    // ---- AppEntity conformance ----

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trip")

    var displayRepresentation: DisplayRepresentation {
        let leading = flags.isEmpty ? "✈️" : flags
        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: "\(leading) \(title)"),
            subtitle: LocalizedStringResource(stringLiteral: dateRange)
        )
    }

    static let defaultQuery = TripEntityQuery()
}

// MARK: - Entity Query

struct TripEntityQuery: EntityQuery {

    /// Resolve a handful of trips by `dedupID` — used when a shortcut runs with a
    /// pre-selected trip.
    func entities(for identifiers: [TripEntity.ID]) async throws -> [TripEntity] {
        let context = await ModelContext(Worldward.sharedModelContainer)
        let all = try context.fetch(FetchDescriptor<Trip>())
        return all.filter { identifiers.contains($0.dedupID) }.map(TripEntity.init(from:))
    }

    /// Trips for the Shortcuts picker: upcoming ones first (soonest start first),
    /// then finished ones (most recent first), so the trip a person is most likely
    /// to act on sits at the top.
    func suggestedEntities() async throws -> [TripEntity] {
        let context = await ModelContext(Worldward.sharedModelContainer)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let now = Date()
        let upcoming = trips.filter { $0.endDate >= now }.sorted { $0.startDate < $1.startDate }
        let past = trips.filter { $0.endDate < now }.sorted { $0.startDate > $1.startDate }
        return (upcoming + past).map(TripEntity.init(from:))
    }
}

// MARK: - Mapping

extension TripEntity {
    /// Convert a SwiftData `Trip` into the lightweight entity.
    init(from trip: Trip) {
        self.id = trip.dedupID
        self.title = trip.title.isEmpty ? String(localized: "Untitled Trip") : trip.title
        self.flags = trip.flags
        self.dateRange = trip.dateRangeText
    }
}

// MARK: - Spotlight indexing

extension TripEntity {
    /// Augments the default (title/subtitle) attributes with keywords so a search
    /// for the trip's name surfaces it in Spotlight.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = flags.isEmpty ? title : "\(flags) \(title)"
        attributes.contentDescription = dateRange
        attributes.keywords = [title, "trip", "travel", "itinerary", "packing"]
        return attributes
    }
}

/// Publishes the user's trips to Spotlight so they're findable in system search and
/// reasoned over by Apple Intelligence. Unlike the country catalog (which changes
/// only on a re-seed), trips are edited freely, so the index is gated on a content
/// signature — the count plus a cheap hash of each trip's identity, title, and
/// dates — and re-indexed only when that actually changes.
enum TripSpotlightIndexer {
    private static let stateKey = "TripSpotlightIndexSignature"
    /// The `dedupID`s last written to Spotlight, so a trip that was deleted since
    /// can be removed (indexing alone only upserts — it never drops stale ids).
    private static let indexedIDsKey = "TripSpotlightIndexedIDs"

    @MainActor
    static func indexIfNeeded(_ trips: [Trip]) async {
        var hasher = Hasher()
        hasher.combine(trips.count)
        for trip in trips.sorted(by: { $0.dedupID < $1.dedupID }) {
            hasher.combine(trip.dedupID)
            hasher.combine(trip.title)
            hasher.combine(trip.startDate)
            hasher.combine(trip.endDate)
            hasher.combine(trip.flags)
        }
        let signature = hasher.finalize()
        guard UserDefaults.standard.integer(forKey: stateKey) != signature else { return }

        let currentIDs = Set(trips.map(\.dedupID))
        let previousIDs = Set(UserDefaults.standard.stringArray(forKey: indexedIDsKey) ?? [])
        let removedIDs = Array(previousIDs.subtracting(currentIDs))

        let entities = trips.map(TripEntity.init(from:))
        do {
            // Drop trips deleted since the last pass, then upsert the current set.
            if !removedIDs.isEmpty {
                try await CSSearchableIndex.default()
                    .deleteSearchableItems(withIdentifiers: removedIDs)
            }
            try await CSSearchableIndex.default().indexAppEntities(entities)
            UserDefaults.standard.set(signature, forKey: stateKey)
            UserDefaults.standard.set(Array(currentIDs), forKey: indexedIDsKey)
        } catch {
            // Best-effort: a failure just leaves the signature unset, so the next
            // change retries. Nothing user-facing depends on the index.
        }
    }
}
