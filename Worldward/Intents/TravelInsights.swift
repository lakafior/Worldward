import Foundation
import FoundationModels

// MARK: - Generated types

/// One AI-recommended next destination, chosen from a candidate list and paired
/// with a short reason. The `country` string is matched back to a real catalog
/// entry in the view — the model only ever picks from names we provide.
@Generable
struct DestinationPick {
    @Guide(description: "The country name, copied exactly from the provided candidate list.")
    var country: String

    @Guide(description: "A short, friendly reason to go next — at most 15 words.")
    var reason: String
}

@Generable
struct DestinationPicks {
    @Guide(description: "Up to three recommended destinations, chosen only from the candidate list.")
    var picks: [DestinationPick]
}

// MARK: - Service

/// On-device generators for the two "delight" features on the dashboard: a warm
/// year-in-review recap and rationale-backed next-destination picks. Both run
/// through the Foundation Models system model, are gated on availability, and
/// take already-computed facts (from `TravelStats`) so the model only writes
/// prose — it never counts or invents geography.
@MainActor
@Observable
final class TravelInsights {

    private let model = SystemLanguageModel.default

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    /// Writes a short, upbeat recap of a single year's travels. `countries` are
    /// pre-formatted "flag name" strings; the model only phrases them.
    func yearInReview(year: Int, countries: [String], visits: Int) async throws -> String {
        let session = LanguageModelSession {
            "You write short, warm year-in-review recaps of someone's travels."
            """
            Keep it to two or three upbeat sentences. Mention a few of the \
            countries by name and the feeling of the year. Don't list every \
            country, invent places, or add statistics that aren't given.
            """
        }
        let list = countries.joined(separator: ", ")
        let prompt = """
            Year: \(year). Countries visited: \(list). Total recorded visits: \(visits).
            Write the recap.
            """
        let response = try await session.respond(to: prompt)
        return response.content
    }

    /// Picks up to three next destinations from a candidate list, each with a
    /// one-line reason. Candidates are pre-formatted descriptive strings.
    func suggestDestinations(candidates: [String]) async throws -> [DestinationPick] {
        let session = LanguageModelSession {
            "You recommend a traveler's next destinations from a fixed candidate list."
            """
            Choose only from the candidates provided — never suggest a country \
            that isn't listed. Pick the most appealing two or three and give each \
            a short, specific reason. Copy country names exactly as written.
            """
        }
        let list = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let prompt = """
            Candidates (closest unvisited countries):
            \(list)

            Recommend the best next destinations.
            """
        let response = try await session.respond(to: prompt, generating: DestinationPicks.self)
        return response.content.picks
    }
}
