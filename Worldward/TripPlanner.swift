import Foundation
import FoundationModels

// MARK: - Guided-generation schema

/// One packing entry. Quantity is a generated field — not a hint buried in the
/// prompt — so the trip's length concretely drives how many socks, underwear etc.
/// the model packs.
@Generable
private struct GeneratedPackingItem {
    @Guide(description: "Short item name, e.g. 'Underwear', 'Rain jacket', 'Toothbrush'.")
    var name: String

    @Guide(
        description:
            "How many to pack. 1 for single items (passport, jacket). For daily basics like "
            + "underwear, socks and t-shirts, scale to the trip length (about one per day, "
            + "capped near 7–10 since laundry is possible).",
        .range(1...30))
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
            "A thorough packing list, no duplicates, covering every essential category.")
    var items: [GeneratedPackingItem]
}

// MARK: - Trip planning assistant

/// On-device trip-planning assistant built on the Foundation Models framework.
/// Given a trip's countries, dates and length it drafts a season-aware packing
/// list or a list of things to see. Everything runs on-device; when Apple
/// Intelligence is unavailable the caller hides the buttons (see `isAvailable`).
///
/// Unlike `TravelIntelligence` — which is forbidden from using its own world
/// knowledge and must read the user's records through tools — planning *wants*
/// the model's geographic and seasonal knowledge, so it uses plain prompts with
/// no data tools.
@MainActor
@Observable
final class TripPlanner {

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
    /// sorting each item into one of the trip's `containers`. Returns the
    /// suggestions, or `nil` if generation failed or was empty.
    func suggestPacking(for trip: Trip, containers: [String]) async -> [PackingSuggestion]? {
        await run(.packing) {
            let session = LanguageModelSession {
                """
                You are Worldward's trip-planning assistant. You write thorough, \
                practical packing lists. Use your knowledge of geography, climate \
                and the time of year to judge the likely weather and activities.
                """
                """
                ALWAYS cover every one of these categories, adapting the specifics \
                to the destinations and season:
                • Clothing basics: underwear, socks, t-shirts/tops, trousers/bottoms, sleepwear.
                • Weather layers & outerwear suited to the season (e.g. coat, rain jacket, sun hat).
                • Footwear appropriate to the activities.
                • Toiletries & cosmetics: toothbrush, toothpaste, deodorant, shampoo, skincare, razor.
                • Health: any personal medication, plasters, sunscreen.
                • Electronics: phone charger, and a power adapter matching the destination's plug type.
                • Travel documents: passport, tickets/bookings, payment cards.
                • A few destination-specific items.
                """
                """
                Set quantity from the trip length: pack roughly one of each daily \
                basic (underwear, socks, t-shirts) per day, capped around 7–10. Use \
                quantity 1 for single items. No duplicates.
                """
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

    /// Drafts free-text notes proposing what to see and do on the trip, formatted
    /// as a short Markdown list grouped by country. Returns `nil` on failure.
    func suggestNotes(for trip: Trip) async -> String? {
        await run(.notes) {
            let session = LanguageModelSession {
                """
                You are Worldward's trip-planning assistant. You suggest what a \
                traveler should see and do, using your knowledge of each place's \
                landmarks, culture and seasonal highlights.
                """
                """
                Reply in concise Markdown. Group suggestions by country with a bold \
                heading per country, then a short bulleted list of must-see sights, \
                experiences or tips. Be specific and practical; no preamble.
                """
            }
            let text = try await session.respond(
                to: "Suggest things to see and do on this trip.\n\(Self.facts(for: trip))"
            ).content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// Clears any error banner.
    func clearError() { errorMessage = nil }

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
    /// its dates, and its length in days (which the model would otherwise have to
    /// compute itself).
    private static func facts(for trip: Trip) -> String {
        let names = trip.countries.map { "\($0.flagEmoji) \($0.name)" }
        let destinations =
            names.isEmpty ? "an unspecified destination" : names.joined(separator: ", ")

        let start = trip.startDate.formatted(date: .long, time: .omitted)
        let end = trip.endDate.formatted(date: .long, time: .omitted)
        let days = max(
            1,
            (Calendar.current.dateComponents([.day], from: trip.startDate, to: trip.endDate).day
                ?? 0) + 1)

        return """
            Destinations: \(destinations).
            Dates: \(start) to \(end) (\(days) day\(days == 1 ? "" : "s")).
            """
    }
}
