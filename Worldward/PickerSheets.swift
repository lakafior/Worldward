/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftUI

// MARK: - Place search

/// A MapKit-backed place chooser for a stop: search for museums, landmarks,
/// restaurants… biased toward the stop's country. Results come from
/// `MKLocalSearch`, so each pick carries a real coordinate and address.
struct PlaceSearchSheet: View {
    /// The country to bias the search toward its region. `nil` for a worldwide
    /// search (a trip spanning several countries, or none yet).
    let country: Country?
    let onPick: (MKMapItem) -> Void
    /// Adds whatever the user typed as a plain, unsearched stop — a free day, a
    /// friend's place, anywhere MapKit doesn't list. Keeps the itinerary to a
    /// single "Add stop" entry point rather than a second button.
    let onAddCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Resolves the country's bounding region exactly once, shared by every
    /// search. A task (rather than the region itself) so the first search can
    /// *await* the lookup instead of racing it — an unbiased worldwide query
    /// returns a single arbitrary global match, not places in the country.
    @State private var regionTask: Task<MKCoordinateRegion?, Never>?

    var body: some View {
        NavigationStack {
            List {
                ForEach(results, id: \.self) { item in
                    Button {
                        onPick(item)
                        dismiss()
                    } label: {
                        resultRow(item)
                    }
                    .buttonStyle(.plain)
                }
                // Anything MapKit doesn't find can still go on the itinerary as a
                // plain stop, so the single "Add stop" flow never dead-ends.
                if !trimmedSearch.isEmpty {
                    Button {
                        onAddCustom(trimmedSearch)
                        dismiss()
                    } label: {
                        Label("Add “\(trimmedSearch)”", systemImage: "plus.circle")
                    }
                }
            }
            .overlay {
                if isSearching && results.isEmpty {
                    ProgressView()
                } else if results.isEmpty && trimmedSearch.isEmpty {
                    ContentUnavailableView(
                        "Find places to see",
                        systemImage: "mappin.and.ellipse",
                        description: Text(emptyDescription))
                }
            }
            .searchable(text: $search, prompt: "Museums, landmarks, restaurants…")
            .navigationTitle("Add a place")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { _ = await countryRegion() }
            .task(id: search) { await runSearch() }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var emptyDescription: String {
        if let country {
            return String(
                localized: "Search for sights and spots to visit in \(country.localizedName).")
        }
        return String(localized: "Search for sights and spots to visit at this stop.")
    }

    private func resultRow(_ item: MKMapItem) -> some View {
        let category = Self.categoryStyle(for: item.pointOfInterestCategory)
        // "Museum · 99 Rue de Rivoli, 75001 Paris, France" — the category names
        // what kind of place it is, the full address pins down which one.
        let subtitle = [category.label, fullAddress(of: item)]
            .compactMap { $0 }
            .joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: category.symbol)
                .foregroundStyle(Color.brand)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? String(localized: "Place"))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    /// The most complete one-line address available for a result — street, city
    /// and country when MapKit knows them.
    private func fullAddress(of item: MKMapItem) -> String? {
        item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
            ?? item.address?.fullAddress
            ?? item.address?.shortAddress
    }

    /// An icon and label for the common tourist-facing point-of-interest
    /// categories, so a result reads as "a museum" or "a park" at a glance.
    /// Anything unmapped falls back to a plain pin with no label.
    private static func categoryStyle(
        for category: MKPointOfInterestCategory?
    ) -> (symbol: String, label: String?) {
        switch category {
        case .museum:
            ("building.columns.fill", String(localized: "Museum"))
        case .landmark, .nationalMonument:
            ("star.circle.fill", String(localized: "Landmark"))
        case .castle, .fortress:
            ("building.fill", String(localized: "Castle"))
        case .park, .nationalPark:
            ("tree.fill", String(localized: "Park"))
        case .beach:
            ("beach.umbrella.fill", String(localized: "Beach"))
        case .zoo:
            ("pawprint.fill", String(localized: "Zoo"))
        case .aquarium:
            ("fish.fill", String(localized: "Aquarium"))
        case .amusementPark:
            ("sparkles", String(localized: "Amusement park"))
        case .restaurant:
            ("fork.knife", String(localized: "Restaurant"))
        case .cafe, .bakery:
            ("cup.and.saucer.fill", String(localized: "Café"))
        case .brewery, .winery:
            ("wineglass.fill", String(localized: "Bar"))
        case .hotel:
            ("bed.double.fill", String(localized: "Hotel"))
        case .theater, .movieTheater:
            ("theatermasks.fill", String(localized: "Theater"))
        case .stadium:
            ("sportscourt.fill", String(localized: "Stadium"))
        case .library:
            ("books.vertical.fill", String(localized: "Library"))
        case .store:
            ("bag.fill", String(localized: "Store"))
        case .marina:
            ("sailboat.fill", String(localized: "Marina"))
        case .campground:
            ("tent.fill", String(localized: "Campground"))
        default:
            ("mappin.circle.fill", nil)
        }
    }

    /// The country's bounding region, looked up on first use and cached. `nil`
    /// for free-form stops or when the lookup finds nothing. No `resultTypes`
    /// restriction on the lookup — a country isn't an *address*, so restricting
    /// to `.address` made the lookup fail and left every search unbiased.
    private func countryRegion() async -> MKCoordinateRegion? {
        if let regionTask { return await regionTask.value }
        guard let country else { return nil }
        let name = country.name
        let task = Task { () -> MKCoordinateRegion? in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = name
            let response = try? await MKLocalSearch(request: request).start()
            return response?.boundingRegion
        }
        regionTask = task
        return await task.value
    }

    /// Debounced live search: re-runs as the query changes, cancelling stale runs.
    private func runSearch() async {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        if let region = await countryRegion() {
            request.naturalLanguageQuery = term
            request.region = region
            // Keep results inside the country — a mere hint still lets "castle"
            // resolve to a stronger match on the other side of the world.
            request.regionPriority = .required
        } else if let country {
            // Region lookup failed: bias the query textually instead.
            request.naturalLanguageQuery = "\(term), \(country.name)"
        } else {
            request.naturalLanguageQuery = term
        }
        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return }
        results = response?.mapItems ?? []
    }
}

// MARK: - Country picker

/// A searchable country chooser used when adding a stop to a trip or
/// quick-adding from the Been/Going list.
struct CountryPickerSheet: View {
    let allCountries: [Country]
    let onPick: (Country) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Country] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return allCountries }
        return allCountries.filter {
            $0.name.localizedStandardContains(term)
                || $0.localizedName.localizedStandardContains(term)
        }
        .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { country in
                Button {
                    onPick(country)
                    dismiss()
                } label: {
                    HStack {
                        Text(country.flagEmoji)
                        Text(country.localizedName)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search countries")
            .navigationTitle("Add a country")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 450)
        #endif
    }
}

