/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import FoundationModels

// MARK: - Traveler profile

/// An optional traveler profile that tailors the packing list. Persisted via
/// `@AppStorage` in Settings and read by `TripPlanner` when building the prompt,
/// so the assistant stops suggesting, say, a bra for a man who hasn't asked for
/// women's items.
enum PackingProfile: String, CaseIterable, Identifiable {
    case unspecified
    case mens
    case womens

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unspecified:
            String(localized: "Unspecified", comment: "Packing profile: no gender preference")
        case .mens: String(localized: "Men's", comment: "Packing profile: men's items")
        case .womens: String(localized: "Women's", comment: "Packing profile: women's items")
        }
    }

    /// A short English prompt fragment describing who to pack for. English because
    /// the assistant reasons in English (see `TripPlanner`); the resulting item
    /// names are translated afterwards.
    var promptHint: String {
        switch self {
        case .unspecified:
            "Pack only unisex basics; do not assume the traveler's gender, and skip "
                + "gender-specific clothing or toiletries."
        case .mens:
            "Pack for a man: include men's clothing and toiletries where appropriate."
        case .womens:
            "Pack for a woman: include women's clothing and toiletries where appropriate."
        }
    }
}

// MARK: - Guided-generation schema

/// One packing entry. Quantity is a generated field — not a hint buried in the
/// prompt — so the trip's length concretely drives how many socks, underwear etc.
/// the model packs.
@Generable
private struct GeneratedPackingItem {
    @Guide(
        description:
            "A concrete, packable object named in English, e.g. 'Underwear', 'Rain jacket', "
            + "'Plug adapter (Type G)'. Never a category or placeholder such as "
            + "'country-specific items' or 'essentials'.")
    var name: String

    @Guide(
        description:
            "How many to pack. Use 1 for single items and one-off gear (passport, jacket, "
            + "a single pair of shoes or slippers). Only true daily basics — underwear, socks "
            + "and t-shirts — scale with trip length (about one per day, capped near 7). Never "
            + "multiply footwear, outerwear or toiletries.",
        .range(1...14))
    var quantity: Int

    @Guide(
        description:
            "Which bag this item is packed in. Copy EXACTLY one of the container names you "
            + "were given, character for character. Only invent a new short container name if "
            + "the item genuinely fits none of them.")
    var container: String
}

/// A finished packing suggestion handed back to the view: the item title, how
/// many to pack, and the name of the container it belongs in (empty if the model
/// left it ungrouped).
struct PackingSuggestion {
    let title: String
    let quantity: Int
    let containerName: String
}

/// The shape we ask the on-device model to produce for a packing list. Guided
/// generation guarantees a clean, typed array instead of a string to parse.
@Generable
private struct GeneratedPackingList {
    @Guide(
        description:
            "A focused packing list, no duplicates, covering every essential category. "
            + "At most 25 items — prefer the essentials over an exhaustive list.",
        .maximumCount(25))
    var items: [GeneratedPackingItem]
}

// MARK: - Trip planning assistant

/// On-device trip-planning assistant built on the Foundation Models framework.
/// Given a trip's countries, dates and length it drafts a season-aware packing
/// list or a list of things to see. Everything runs on-device; when Apple
/// Intelligence is unavailable the caller hides the buttons (see `isAvailable`).
///
/// **English-only generation:** the small on-device model reasons and names items
/// far more reliably in English than when asked to think and translate at once
/// (which produced nonsense like "toy for walking"). So generation always runs in
/// English; the *view* then translates the results into the user's language with
/// Apple's Translation framework, which is a far better translator than this model.
///
/// Unlike `TravelIntelligence` — which is forbidden from using its own world
/// knowledge and must read the user's records through tools — planning *wants*
/// the model's geographic and seasonal knowledge, so it uses plain prompts with
/// no data tools.
@MainActor
@Observable
final class TripPlanner {

    /// `@AppStorage` keys for the traveler profile, shared with `SettingsView`.
    static let profileKey = "packingProfile"
    static let preferencesKey = "packingPreferences"

    /// Which section is currently generating, for in-place spinners. `nil` when idle.
    enum Field { case packing, notes }

    private(set) var busy: Field?
    private(set) var errorMessage: String?

    /// Re-read for availability each time, since the user can toggle Apple
    /// Intelligence in Settings between uses.
    private let model = SystemLanguageModel.default

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    // MARK: Public requests

    /// Drafts a packing list tailored to the trip's countries, season and length,
    /// sorting each item into one of the trip's `containers`. Item names come back
    /// in English; the caller translates them via the Translation framework. Returns
    /// the suggestions, or `nil` if generation failed or was empty.
    func suggestPacking(for trip: Trip, containers: [String]) async -> [PackingSuggestion]? {
        await run(.packing) {
            let session = LanguageModelSession {
                """
                You are Worldward's trip-planning assistant. You write focused, \
                practical packing lists, using your knowledge of geography, climate \
                and the season to judge the likely weather and activities.
                """
                """
                Cover each essential category, adapting specifics to the destinations \
                and season: clothing basics (underwear, socks, tops, bottoms, \
                sleepwear); season-appropriate layers & outerwear; suitable footwear; \
                toiletries; health items (personal medication, sunscreen); \
                electronics (chargers); and travel documents (passport, tickets, cards).
                """
                """
                Use the trip facts to choose concrete extras. Pack exactly one plug \
                adapter, naming the destination's plug types in the item, e.g. \
                'Plug adapter (Type G)'. Add whatever else these specific places and \
                this season genuinely call for — insect repellent in the tropics, a \
                compact umbrella for a rainy season, swimwear for a beach trip.
                """
                """
                Every item name must be a single concrete, packable object, written \
                in English (the traveler's own notes may be in another language — \
                still answer in English). Never output category placeholders such as \
                'country-specific items', 'destination-specific items', 'essentials' \
                or 'miscellaneous'.
                """
                """
                Set quantity from the trip length: about one of each daily basic \
                (underwear, socks, t-shirts) per day, capped around 7; quantity 1 for \
                everything else, including footwear, outerwear and toiletries. No \
                duplicates.
                """
                """
                Judge the season and likely weather at each destination from the travel \
                month, remembering the southern hemisphere's seasons are reversed. Pack \
                clothing suited to that weather only — never heavy winter clothing for a \
                warm-season trip, nor summer-only items for a cold-season trip.
                """
                Self.profileInstruction()
                Self.containerInstruction(for: containers)
            }
            let response = try await session.respond(
                to: "Create a packing list for this trip.\n\(Self.facts(for: trip))",
                generating: GeneratedPackingList.self)

            let items =
                response.content.items
                .compactMap { item -> PackingSuggestion? in
                    let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return nil }
                    let container = item.container.trimmingCharacters(in: .whitespacesAndNewlines)
                    return PackingSuggestion(
                        title: name, quantity: max(1, item.quantity), containerName: container)
                }
            return items.isEmpty ? nil : items
        }
    }

    /// Drafts free-text notes proposing what to see and do on the trip, formatted
    /// as a short Markdown list grouped by country. Returns English Markdown (the
    /// caller translates it via the Translation framework), or `nil` on failure.
    func suggestNotes(for trip: Trip) async -> String? {
        await run(.notes) {
            let session = LanguageModelSession {
                """
                You are Worldward's trip-planning assistant. You suggest what a \
                traveler should see and do, using your knowledge of each place's \
                landmarks, culture and seasonal highlights.
                """
                """
                Reply in concise English Markdown. Group suggestions by country with a \
                bold heading per country, then a short bulleted list (about 3–5 \
                bullets) of must-see sights, experiences or tips. Be specific and \
                practical — name real places — and write no preamble.
                """
            }
            let text = try await session.respond(
                to: "Suggest things to see and do on this trip.\n\(Self.facts(for: trip))",
                options: GenerationOptions(maximumResponseTokens: 900)
            ).content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// Clears any error banner.
    func clearError() { errorMessage = nil }

    // MARK: Prompt building

    /// Instruction describing who to pack for, from the saved `PackingProfile` and
    /// the user's free-text preferences. Defaults to unisex basics when nothing is set.
    private static func profileInstruction() -> String {
        let defaults = UserDefaults.standard
        let profile =
            PackingProfile(rawValue: defaults.string(forKey: profileKey) ?? "") ?? .unspecified
        var line = profile.promptHint
        let prefs = (defaults.string(forKey: preferencesKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefs.isEmpty {
            line += " Also account for the traveler's own notes: \(prefs)."
        }
        return line
    }

    /// Instruction telling the model which containers to file items into. When the
    /// user already has containers we constrain to them by name (so non-English
    /// names are preserved); otherwise the model groups items into a few sensible
    /// containers of its own.
    private static func containerInstruction(for containers: [String]) -> String {
        let names = containers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if names.isEmpty {
            return """
                Sort the items into a few sensible bags by giving each a short \
                'container' label (for example a toiletry bag, a day bag, and a \
                main case). Reuse the same label for items that travel together.
                """
        }
        return """
            File every item into one of these containers by copying its name \
            EXACTLY into the item's 'container' field: \(names.joined(separator: ", ")). \
            Only coin a new short container name if an item fits none of them.
            """
    }

    // MARK: Private

    /// Runs a generation request, managing the `busy` flag and error surface.
    private func run<T>(_ field: Field, _ work: () async throws -> T?) async -> T? {
        busy = field
        errorMessage = nil
        defer { busy = nil }
        do {
            return try await work()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// A compact, factual description of the trip for the prompt: its countries,
    /// its dates, the travel month (so the model can reason about the season), its
    /// length in days, and per-country facts relevant to packing (plug types, driving
    /// side). Formatted in English since generation runs in English.
    private static func facts(for trip: Trip) -> String {
        let names = trip.countries.map { "\($0.flagEmoji) \($0.name)" }
        let destinations =
            names.isEmpty ? "an unspecified destination" : names.joined(separator: ", ")

        let english = Locale(identifier: "en_US")
        let dateStyle = Date.FormatStyle(date: .long, time: .omitted).locale(english)
        let start = trip.startDate.formatted(dateStyle)
        let end = trip.endDate.formatted(dateStyle)
        let month = trip.startDate.formatted(Date.FormatStyle().month(.wide).locale(english))
        let days = max(
            1,
            (Calendar.current.dateComponents([.day], from: trip.startDate, to: trip.endDate).day
                ?? 0) + 1)

        var result = """
            Trip facts:
            Destinations: \(destinations).
            Dates: \(start) to \(end) (\(days) day\(days == 1 ? "" : "s")).
            Travel month: \(month).
            """

        // Per-country facts the model uses to tailor packing suggestions.
        for country in trip.countries {
            if let facts = CountryFactsDB.facts(for: country.id) {
                let plugs = facts.plugTypes.map { "Type \($0)" }
                    .formatted(.list(type: .and))
                let driving = facts.drivingSide.promptHint
                result += "\n\(country.name) uses \(plugs) plug adapters and \(driving)."
            }
        }

        return result
    }
}
