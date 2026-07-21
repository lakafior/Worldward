/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import Photos
import SwiftData
import SwiftUI

extension EnvironmentValues {
    /// Country outline paths (id → polygon rings, in `MKMapPoint` space),
    /// published by ContentView once the GeoJSON loads; empty until then. Lets
    /// the trip photo suggestions match photo coordinates to the trip's
    /// countries without threading the geometry through every view between the
    /// map and the trip detail (and its separate macOS inspector path).
    @Entry var countryPaths: [String: [CGPath]] = [:]
}

/// One photo the scan proposes attaching: its stable PhotoKit identifier and
/// capture date. Only the identifier is ever stored, matching the app-wide
/// no-image-data policy.
struct SuggestedPhoto: Identifiable, Sendable {
    let id: String
    let date: Date
}

/// Review sheet for a finished trip: finds the library photos taken during the
/// trip's date range, groups them under the trip's countries by their location
/// metadata (photos without a location go in their own assignable group), and
/// attaches the confirmed selection to visits.
struct TripPhotoSuggestionsSheet: View {
    let trip: Trip

    @Environment(\.countryPaths) private var countryPaths
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case scanning
        case denied
        case empty
        case results
    }

    /// Photos matched to one trip country, resolved back on the main actor.
    private struct SuggestionGroup: Identifiable {
        let country: Country
        let photos: [SuggestedPhoto]
        var id: String { country.id }
    }

    @State private var phase: Phase = .scanning
    @State private var groups: [SuggestionGroup] = []
    @State private var noLocationPhotos: [SuggestedPhoto] = []
    /// The trip country the "no location" photos attach to; user-pickable on
    /// multi-country trips.
    @State private var noLocationCountryID = ""
    @State private var selected: Set<String> = []
    /// In-range photos whose location fell outside every trip country — home,
    /// layovers — surfaced as a count so their absence isn't mysterious.
    @State private var skippedElsewhere = 0

    /// Pre-selection cap per country, mirroring the photo importer's
    /// `maxStoredIdentifiers` policy so the default path doesn't bloat visits;
    /// the user can still tap to select more deliberately.
    private static let preselectLimit = 30

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .scanning:
                    ProgressView("Looking for trip photos…")
                case .denied:
                    ContentUnavailableView(
                        "No Photo Access",
                        systemImage: "lock.circle",
                        description: Text(
                            "Allow photo access in Settings to see photos from this trip."))
                case .empty:
                    ContentUnavailableView(
                        "No Photos Found",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(
                            "Your library has no new photos taken during this trip."))
                case .results:
                    resultsList
                }
            }
            .navigationTitle("Trip Photos")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addButtonTitle) { apply() }
                        .disabled(selected.isEmpty)
                }
            }
            .task { await scan() }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    private var addButtonTitle: String {
        selected.count == 1 ? "Add 1 Photo" : "Add \(selected.count) Photos"
    }

    // MARK: - Results

    private var resultsList: some View {
        List {
            ForEach(groups) { group in
                Section {
                    photoGrid(group.photos)
                } header: {
                    sectionHeader(
                        "\(group.country.flagEmoji) \(group.country.localizedName)",
                        photos: group.photos)
                }
            }

            if !noLocationPhotos.isEmpty {
                Section {
                    if trip.countries.count > 1 {
                        Picker("Attach to", selection: $noLocationCountryID) {
                            ForEach(trip.countries) { country in
                                Text("\(country.flagEmoji) \(country.localizedName)")
                                    .tag(country.id)
                            }
                        }
                    }
                    photoGrid(noLocationPhotos)
                } header: {
                    sectionHeader(
                        String(
                            localized: "No Location Data",
                            comment: "Header for photos with no GPS data during a trip import"),
                        photos: noLocationPhotos)
                } footer: {
                    Text(
                        "These photos carry no location metadata — check they're really from the trip before adding."
                    )
                }
            }

            if skippedElsewhere > 0 {
                Section {
                } footer: {
                    Text(
                        "\(skippedElsewhere) photo\(skippedElsewhere == 1 ? "" : "s") from this period were taken outside the trip's countries and skipped."
                    )
                }
            }
        }
    }

    private func sectionHeader(_ title: String, photos: [SuggestedPhoto]) -> some View {
        HStack {
            Text(title)
            Spacer()
            let allSelected = photos.allSatisfy { selected.contains($0.id) }
            Button(allSelected ? "Deselect All" : "Select All") {
                let ids = photos.map(\.id)
                if allSelected {
                    selected.subtract(ids)
                } else {
                    selected.formUnion(ids)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    private func photoGrid(_ photos: [SuggestedPhoto]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], spacing: 4) {
            ForEach(photos) { photo in
                SuggestionThumbnail(
                    identifier: photo.id,
                    isSelected: selected.contains(photo.id)
                ) {
                    if selected.contains(photo.id) {
                        selected.remove(photo.id)
                    } else {
                        selected.insert(photo.id)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Scan

    /// Outcome of the off-main library scan, in value types only.
    private struct ScanResult: Sendable {
        var byCountry: [String: [SuggestedPhoto]]
        var noLocation: [SuggestedPhoto]
        var skippedElsewhere: Int
    }

    private func scan() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }

        // Snapshot everything the scan needs on the main actor: the trip's date
        // range, only its own countries' polygon rings, and the identifiers
        // already attached to those countries' visits (so re-running the sheet
        // never re-suggests what's already there).
        let countries = trip.countries
        var paths: [String: [CGPath]] = [:]
        for country in countries {
            paths[country.id] = countryPaths[country.id] ?? []
        }
        let excluded = Set(countries.flatMap { ($0.visits ?? []).flatMap(\.photoIdentifiers) })
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: trip.startDate)
        let end =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: trip.endDate))
            ?? trip.endDate

        let result = await Self.scanLibrary(start: start, end: end, paths: paths, excluded: excluded)

        // Resolve country ids back to models, keeping the itinerary's stop order.
        groups = countries.compactMap { country in
            guard let photos = result.byCountry[country.id], !photos.isEmpty else { return nil }
            return SuggestionGroup(country: country, photos: photos)
        }
        noLocationPhotos = result.noLocation
        skippedElsewhere = result.skippedElsewhere
        noLocationCountryID = countries.first?.id ?? ""

        // Location-matched photos start selected (sampled across the range, up
        // to the cap); no-location ones start deselected — they might be from
        // home, so adding them stays a deliberate choice.
        var preselected: Set<String> = []
        for group in groups {
            preselected.formUnion(sampled(group.photos.map(\.id), limit: Self.preselectLimit))
        }
        selected = preselected

        phase = groups.isEmpty && noLocationPhotos.isEmpty ? .empty : .results
    }

    /// Up to `limit` ids, evenly spread across the (date-sorted) input so the
    /// pre-selection covers the whole trip rather than just its first days.
    private func sampled(_ ids: [String], limit: Int) -> [String] {
        guard ids.count > limit else { return ids }
        return (0..<limit).map { ids[$0 * ids.count / limit] }
    }

    /// Fetch the trip window's photos and bucket them: inside a trip country →
    /// that country; elsewhere → skipped (counted); no location (or geometry not
    /// loaded yet) → the assignable "no location" bucket. Touches only
    /// `Sendable` value types, mirroring `PhotoImporter.scanPhotos`.
    nonisolated private static func scanLibrary(
        start: Date, end: Date, paths: [String: [CGPath]], excluded: Set<String>
    ) async -> ScanResult {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: .image, options: options)

        let geometryAvailable = paths.contains { !$0.value.isEmpty }
        var byCountry: [String: [SuggestedPhoto]] = [:]
        var noLocation: [SuggestedPhoto] = []
        var skipped = 0

        // Paged like the importer's scan so long windows yield between batches.
        let total = fetch.count
        let pageSize = 500
        var processed = 0
        while processed < total {
            let upper = min(processed + pageSize, total)
            for asset in fetch.objects(at: IndexSet(processed..<upper)) {
                guard !excluded.contains(asset.localIdentifier) else { continue }
                let photo = SuggestedPhoto(
                    id: asset.localIdentifier, date: asset.creationDate ?? start)

                guard geometryAvailable, let location = asset.location else {
                    noLocation.append(photo)
                    continue
                }

                let mapPoint = MKMapPoint(location.coordinate)
                let cgPoint = CGPoint(x: mapPoint.x, y: mapPoint.y)
                var matchedID: String?
                outer: for (id, rings) in paths {
                    for ring in rings where ring.contains(cgPoint) {
                        matchedID = id
                        break outer
                    }
                }
                if let matchedID {
                    byCountry[matchedID, default: []].append(photo)
                } else {
                    skipped += 1
                }
            }
            processed = upper
            await Task.yield()
        }

        return ScanResult(
            byCountry: byCountry, noLocation: noLocation, skippedElsewhere: skipped)
    }

    // MARK: - Apply

    /// Attach the selection: for each country, reuse a visit already dated
    /// inside the trip's range, else start one dated at its first photo. Only
    /// raises a country's status (mirroring `LogVisitsView.save`); created
    /// visits are *not* flagged `isImported`, so a later importer "Overwrite"
    /// re-scan won't delete what the user confirmed here.
    private func apply() {
        let calendar = Calendar.current
        let rangeStart = calendar.startOfDay(for: trip.startDate)
        let rangeEnd =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: trip.endDate))
            ?? trip.endDate

        var picked: [String: [SuggestedPhoto]] = [:]
        for group in groups {
            let photos = group.photos.filter { selected.contains($0.id) }
            if !photos.isEmpty { picked[group.country.id, default: []] += photos }
        }
        let assigned = noLocationPhotos.filter { selected.contains($0.id) }
        if !assigned.isEmpty, !noLocationCountryID.isEmpty {
            picked[noLocationCountryID, default: []] += assigned
        }

        for country in trip.countries {
            guard var photos = picked[country.id], !photos.isEmpty else { continue }
            photos.sort { $0.date < $1.date }

            let visit =
                (country.visits ?? [])
                .filter { $0.date >= rangeStart && $0.date < rangeEnd }
                .min { $0.date < $1.date }
                ?? {
                    let new = Visit(
                        date: calendar.startOfDay(for: photos[0].date), notes: "",
                        country: country)
                    modelContext.insert(new)
                    country.visits = (country.visits ?? []) + [new]
                    return new
                }()

            let newIdentifiers = photos.map(\.id).filter { !visit.photoIdentifiers.contains($0) }
            visit.photoIdentifiers.append(contentsOf: newIdentifiers)

            if country.status == .notVisited {
                country.status = .visited
                country.statusIsImported = false
            }
        }

        try? modelContext.save()
        dismiss()
    }
}

/// A square, tappable thumbnail with a selection checkmark, loaded lazily from
/// the photo library (same request pattern as `VisitPhotosView`'s thumbnails).
private struct SuggestionThumbnail: View {
    let identifier: String
    let isSelected: Bool
    let toggle: () -> Void

    @State private var image: Image?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.tint, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.white, .tint)
                    .shadow(radius: 1)
                    .padding(4)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture(perform: toggle)
            .accessibilityLabel(Text("Photo"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .task(id: identifier) { await load() }
    }

    private func load() async {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetched.firstObject else { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        // 2x the largest cell the adaptive grid produces, for retina crispness.
        let target = CGSize(width: 176, height: 176)
        PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFill, options: options
        ) { result, _ in
            guard let result else { return }
            Task { @MainActor in self.image = Image(platformImage: result) }
        }
    }
}
