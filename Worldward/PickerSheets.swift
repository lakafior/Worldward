/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftUI

// MARK: - Place search

/// A MapKit-backed place chooser for a stop: search for museums, landmarks,
/// restaurants… biased toward the stop's country. Results come from
/// `MKLocalSearch`, so each pick carries a real coordinate and address.
struct PlaceSearchSheet: View {
    /// The country to bias the place search toward its region. `nil` for a
    /// worldwide search (a trip spanning several countries, or none yet).
    let country: Country?
    /// The trip's countries, offered as a scope selector when it spans more than
    /// one — so the search can be pointed at the leg you're planning rather than
    /// falling back to a worldwide search (the flat itinerary has no per-country
    /// context of its own). Empty or single-country trips show no selector.
    let scopeCountries: [Country]
    /// The app's own country catalog, matched against the query and offered above
    /// the MapKit results — so typing "Latvia" adds Latvia as a stop even when the
    /// place search is region-locked to another country.
    let allCountries: [Country]
    let onPick: (MKMapItem) -> Void
    /// Adds one of the app's countries as a country/region stop.
    let onPickCountry: (Country) -> Void
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

    /// App countries whose name matches the query, shown above the map results.
    /// Capped so a broad query ("stan") doesn't bury the places section.
    private var countryMatches: [Country] {
        guard !trimmedSearch.isEmpty else { return [] }
        return allCountries.filter {
            $0.localizedName.localizedStandardContains(trimmedSearch)
                || $0.name.localizedStandardContains(trimmedSearch)
        }
        .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
        .prefix(4).map { $0 }
    }
    /// The chosen scope country's id in a multi-country trip, or `nil` for
    /// "Anywhere". Single-country trips ignore this and always bias to `country`.
    @State private var selectedScopeID: String?
    /// Country bounding regions, resolved once each and reused as the scope changes.
    @State private var regionCache: [String: MKCoordinateRegion] = [:]

    /// The country the place search is biased toward: the picked scope on a
    /// multi-country trip, else the trip's sole country (or `nil` = worldwide).
    private var biasCountry: Country? {
        if scopeCountries.count >= 2 {
            return scopeCountries.first { $0.id == selectedScopeID }
        }
        return country
    }

    var body: some View {
        NavigationStack {
            List {
                // Multi-country trips: point the place search at one leg (or
                // Anywhere). Single-country trips are auto-scoped, so no selector.
                if scopeCountries.count >= 2 {
                    Picker("Search in", selection: $selectedScopeID) {
                        Text("Anywhere").tag(nil as String?)
                        ForEach(scopeCountries) { country in
                            Text("\(country.flagEmoji) \(country.localizedName)")
                                .tag(country.id as String?)
                        }
                    }
                }
                // App countries first — a whole-country stop, and the escape hatch
                // when the map search is region-locked to a different country.
                if !countryMatches.isEmpty {
                    Section(header: Text("Countries")) {
                        ForEach(countryMatches) { country in
                            Button {
                                onPickCountry(country)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(country.flagEmoji)
                                    Text(country.localizedName)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    ForEach(results, id: \.self) { item in
                        Button {
                            onPick(item)
                            dismiss()
                        } label: {
                            resultRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                    // Anything MapKit doesn't find can still go on the itinerary as
                    // a plain stop, so the single "Add stop" flow never dead-ends.
                    if !trimmedSearch.isEmpty {
                        Button {
                            onAddCustom(trimmedSearch)
                            dismiss()
                        } label: {
                            Label("Add “\(trimmedSearch)”", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    // Only labelled once the countries section is also present.
                    if !countryMatches.isEmpty { Text("Places") }
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
            // Re-runs when the query *or* the chosen scope changes, so switching
            // countries immediately re-biases the results.
            .task(id: "\(search)|\(selectedScopeID ?? "")") { await runSearch() }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var emptyDescription: String {
        if let biasCountry {
            return String(
                localized: "Search for sights and spots to visit in \(biasCountry.localizedName).")
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

    /// A country's bounding region, looked up on first use and cached so switching
    /// scope doesn't re-fetch. `nil` when the lookup finds nothing. No `resultTypes`
    /// restriction — a country isn't an *address*, so restricting to `.address`
    /// made the lookup fail and left every search unbiased.
    private func region(for country: Country) async -> MKCoordinateRegion? {
        if let cached = regionCache[country.id] { return cached }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = country.name
        let response = try? await MKLocalSearch(request: request).start()
        if let region = response?.boundingRegion { regionCache[country.id] = region }
        return response?.boundingRegion
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
        let bias = biasCountry
        if let bias, let region = await region(for: bias) {
            request.naturalLanguageQuery = term
            request.region = region
            // Keep results inside the country — a mere hint still lets "castle"
            // resolve to a stronger match on the other side of the world.
            request.regionPriority = .required
        } else if let bias {
            // Region lookup failed: bias the query textually instead.
            request.naturalLanguageQuery = "\(term), \(bias.name)"
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

