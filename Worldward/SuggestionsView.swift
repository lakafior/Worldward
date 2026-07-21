/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreLocation
import SwiftData
import SwiftUI

// MARK: - Suggestions

/// The lens the smart suggestions are generated through. Each mode feeds the model
/// a different candidate set and guidance, so the picks answer a different question:
/// what's *easy* next, what *broadens* the map, or what *clusters* into one trip.
private enum SuggestionMode: String, CaseIterable, Identifiable {
    case closeToHome
    case fillAGap
    case buildATrip
    var id: String { rawValue }

    var label: String {
        switch self {
        case .closeToHome: String(localized: "Close to home", comment: "Suggestion mode")
        case .fillAGap: String(localized: "Fill a gap", comment: "Suggestion mode")
        case .buildATrip: String(localized: "Build a trip", comment: "Suggestion mode")
        }
    }

    /// The instruction handed to the model alongside the traveler profile.
    var guidance: String {
        switch self {
        case .closeToHome:
            "These candidates are the unvisited countries closest to where the traveler has already been. Favor easy, natural next trips."
        case .fillAGap:
            "These candidates are in regions the traveler has barely explored. Favor picks that broaden their map to new continents and regions."
        case .buildATrip:
            "These candidates lie close together and could be combined into one multi-country trip. Favor picks that pair into a single itinerary, and say how they connect."
        }
    }

    /// Shown when a mode has no candidates to offer yet.
    var emptyMessage: String {
        switch self {
        case .closeToHome:
            String(
                localized: "Nothing nearby left to suggest right now.",
                comment: "Empty state for the 'Close to home' suggestion mode")
        case .fillAGap:
            String(
                localized: "Visit a few more places first — then we can spot the gaps on your map.",
                comment: "Empty state for the 'Fill a gap' suggestion mode")
        case .buildATrip:
            String(
                localized: "No nearby cluster to build a trip from yet.",
                comment: "Empty state for the 'Build a trip' suggestion mode")
        }
    }
}

/// Closest unvisited countries + AI-powered destination suggestions, shown as
/// the **Suggestions** segment in the Going tab.
struct SuggestionsView: View {
    let allCountries: [Country]
    let centroids: [String: CLLocationCoordinate2D]

    @Environment(\.modelContext) private var modelContext
    @State private var insights = TravelInsights()
    /// Set to open the trip editor right after a suggestion creates a trip.
    @State private var editingTrip: Trip?

    /// Cached distance ranking. Computing it in `init` re-ran the O(n·m) pass
    /// (tens of thousands of distance calls) on every parent render — e.g. each
    /// keystroke in the shared search field — so it's derived once per catalog
    /// change via `.task(id:)` instead.
    @State private var suggestions: [(country: Country, distanceKM: Double)] = []
    /// English summary of the traveler, fed to the model for tailored picks.
    @State private var profile = ""
    /// `false` until the first derivation completes, so the "all visited" empty
    /// state can't flash before the suggestions exist.
    @State private var suggestionsReady = false

    /// Signature of everything the suggestions derive from: the visited set and
    /// whether the centroids have loaded.
    private var suggestionsKey: Int {
        var hasher = Hasher()
        for country in allCountries {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
            hasher.combine(country.planStatusRaw)
        }
        hasher.combine(centroids.count)
        return hasher.finalize()
    }

    /// The traveler's footprint plus their wishlist, in English, for the model.
    private static func makeProfile(countries: [Country]) -> String {
        var summary = TravelStats(countries: countries).explorationSummary
        let wishlist =
            countries
            .filter { $0.planStatus == .wishlist }
            .map(\.name)
        if !wishlist.isEmpty {
            summary += " On the wishlist: \(wishlist.prefix(6).joined(separator: ", "))."
        }
        return summary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if centroids.isEmpty || !suggestionsReady {
                    ContentUnavailableView(
                        "Map not ready",
                        systemImage: "globe",
                        description: Text("Country locations are still loading. Try again shortly.")
                    )
                } else if suggestions.isEmpty {
                    ContentUnavailableView(
                        "Nothing left to discover",
                        systemImage: "globe.desk.fill",
                        description: Text(
                            "You've visited every country — there's nothing left to suggest!"))
                } else {
                    closestSection

                    if insights.isAvailable {
                        SmartSuggestionsSection(
                            insights: insights,
                            allCountries: allCountries,
                            centroids: centroids,
                            profile: profile,
                            onAddToWishlist: addToWishlist,
                            onCreateTrip: createTrip)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(Str.Trip.tabSuggestions)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        // Re-derives when the visited set or the centroids change; body renders
        // in between just reuse the cached values.
        .task(id: suggestionsKey) {
            suggestions = nearestUnvisited(countries: allCountries, centroids: centroids)
            profile = Self.makeProfile(countries: allCountries)
            suggestionsReady = true
        }
        .sheet(item: $editingTrip) { trip in
            TripDetailSheet(trip: trip, allCountries: allCountries)
        }
    }

    /// Adds a suggested country to the wishlist (the blue "going" plan axis),
    /// leaving any stronger plan it already has untouched.
    private func addToWishlist(_ country: Country) {
        if country.planStatus == .none { country.planStatus = .wishlist }
    }

    /// Builds a trip from one or more suggested countries — each becomes an ordered
    /// stop and joins the map's "going" layer — then opens the editor so the
    /// traveler can fill in dates and details.
    private func createTrip(_ countries: [Country]) {
        guard !countries.isEmpty else { return }
        let trip = Trip(title: Self.tripTitle(for: countries))
        modelContext.insert(trip)
        for (index, country) in countries.enumerated() {
            let stop = ItineraryItem(order: index, country: country, trip: trip)
            modelContext.insert(stop)
            if trip.itinerary == nil { trip.itinerary = [] }
            trip.itinerary?.append(stop)
            if country.planStatus == .none { country.planStatus = .planning }
        }
        editingTrip = trip
    }

    /// A starter title for a freshly created trip; the user edits it in the sheet.
    private static func tripTitle(for countries: [Country]) -> String {
        guard let first = countries.first else { return "New Trip" }
        if countries.count == 1 { return first.name }
        return "\(first.name) & \(countries.count - 1) more"
    }

    private var closestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: String(
                    localized: "Closest unvisited",
                    comment: "Section header above the nearest unvisited countries"))

            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.country.id) { index, item in
                    HStack {
                        Text(item.country.flagEmoji)
                        Text(item.country.localizedName)
                        Spacer()
                        Text("\(Int(item.distanceKM.rounded())) km away")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 8)
                    if index < suggestions.count - 1 { Divider() }
                }
            }
            .padding(.horizontal)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Smart suggestions (Apple Intelligence)

/// Opt-in next-destination picks with a concrete rationale, generated on-device.
/// A mode picker drives *which* unvisited countries are offered (nearby, gap-filling,
/// or a cluster for one trip); the model only phrases, ranks, and tailors to the
/// traveler — the candidate set and flags come from real data, so it can't invent a
/// country. Each pick is actionable: add it to the wishlist or spin it into a trip.
private struct SmartSuggestionsSection: View {
    let insights: TravelInsights
    let allCountries: [Country]
    let centroids: [String: CLLocationCoordinate2D]
    let profile: String
    let onAddToWishlist: (Country) -> Void
    let onCreateTrip: ([Country]) -> Void

    @State private var mode: SuggestionMode = .closeToHome
    @State private var picks: [ResolvedPick] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Country ids the user added to the wishlist this session, so the button can
    /// flip to a confirmed state without re-querying the model.
    @State private var wishlisted: Set<String> = []
    @State private var translator = AppTranslator()

    private struct ResolvedPick: Identifiable {
        let country: Country
        let reason: String
        var id: String { country.id }
        var flag: String { country.flagEmoji }
        var name: String { country.localizedName }
    }

    /// The candidate countries for the selected mode, with a distance for context.
    /// Cached in `@State` (recomputed via `.task(id:)` below) — as a computed
    /// property this O(n·m) pass re-ran on every body evaluation.
    @State private var candidates: [(country: Country, distanceKM: Double)] = []

    /// Signature of the candidate inputs: the mode plus the visited set.
    private var candidatesKey: Int {
        var hasher = Hasher()
        hasher.combine(mode)
        for country in allCountries {
            hasher.combine(country.id)
            hasher.combine(country.statusRaw)
        }
        return hasher.finalize()
    }

    private func rebuildCandidates() {
        candidates =
            switch mode {
            case .closeToHome:
                nearestUnvisited(countries: allCountries, centroids: centroids, limit: 8)
            case .fillAGap:
                unvisitedFillingGaps(countries: allCountries, centroids: centroids, limit: 8)
            case .buildATrip:
                tripCluster(countries: allCountries, centroids: centroids, limit: 4)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: String(
                    localized: "Suggested for you",
                    comment: "Section header above the AI destination suggestions"))

            Picker("Mode", selection: $mode) {
                ForEach(SuggestionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in
                picks = []
                errorMessage = nil
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Thinking about where to go next…")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if picks.isEmpty {
                if candidates.isEmpty {
                    Text(mode.emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: generate) {
                        Label("Suggest with Apple Intelligence", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                }
            }

            if !picks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                        pickRow(pick)
                        if index < picks.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                // In trip-building mode the picks are a single cluster, so offer to
                // turn the whole set into one multi-stop trip.
                if mode == .buildATrip && picks.count > 1 {
                    Button {
                        onCreateTrip(picks.map(\.country))
                    } label: {
                        Label("Create one trip with all \(picks.count)", systemImage: "suitcase")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                }

                Button("Suggest again", action: generate)
                    .font(.caption)
                    .disabled(isLoading)
            }
        }
        .task(id: candidatesKey) { rebuildCandidates() }
        .appTranslation(translator)
    }

    /// One pick: flag, name, the model's reason, and the two actions.
    private func pickRow(_ pick: ResolvedPick) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(pick.flag)
            VStack(alignment: .leading, spacing: 6) {
                Text(pick.name).fontWeight(.medium)
                Text(pick.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button {
                        onAddToWishlist(pick.country)
                        wishlisted.insert(pick.country.id)
                    } label: {
                        Label(
                            isWishlisted(pick) ? "On wishlist" : "Wishlist",
                            systemImage: isWishlisted(pick) ? "star.fill" : "star")
                    }
                    .disabled(isWishlisted(pick))

                    Button {
                        onCreateTrip([pick.country])
                    } label: {
                        Label("Create trip", systemImage: "airplane")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .tint(.brand)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    /// `true` once added here, or if the country was already on any plan.
    private func isWishlisted(_ pick: ResolvedPick) -> Bool {
        wishlisted.contains(pick.country.id) || pick.country.planStatus != .none
    }

    private func generate() {
        isLoading = true
        errorMessage = nil
        let candidates = self.candidates
        let descriptions = candidates.map { "\($0.country.name) (\($0.country.continent))" }
        let profile = self.profile
        let guidance = mode.guidance
        Task {
            defer { isLoading = false }
            do {
                let raw = try await insights.suggestDestinations(
                    profile: profile, guidance: guidance, candidates: descriptions)
                let resolved = raw.compactMap { pick -> ResolvedPick? in
                    guard
                        let match = candidates.first(where: {
                            matches(pick.country, $0.country.name)
                        })
                    else { return nil }
                    return ResolvedPick(country: match.country, reason: pick.reason)
                }
                // Country names come from real data; only the model's reasons (free
                // English text) need translating into the user's language.
                let reasons = await translator.translate(resolved.map(\.reason))
                picks = zip(resolved, reasons).map { pick, reason in
                    ResolvedPick(country: pick.country, reason: reason)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Loose name match so a model paraphrase still resolves to a candidate.
    private func matches(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveContains(b) || b.localizedCaseInsensitiveContains(a)
    }
}

/// Simple section header reused inside the suggestions views.
private struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            if let trailing {
                Spacer()
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
