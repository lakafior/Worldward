/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    @Guide(
        description:
            "One concrete, specific reason to go — a single sentence of at most 25 words, naming a real sight, season, food, or how it fits the traveler's plans.")
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
    /// concrete reason. `profile` is an English summary of the traveler's footprint
    /// and wishlist; `guidance` describes the current suggestion mode (close to
    /// home, fill a gap, build a trip). Candidates are pre-formatted strings, and
    /// the model only ever picks from them — it can't invent a country.
    func suggestDestinations(profile: String, guidance: String, candidates: [String]) async throws
        -> [DestinationPick]
    {
        let session = LanguageModelSession {
            "You recommend a traveler's next destinations from a fixed candidate list."
            """
            Choose only from the candidates provided — never suggest a country that \
            isn't listed, and copy country names exactly as written. Tailor your two \
            or three picks to the traveler's profile and the guidance. Give each pick \
            one concrete, specific reason citing something real about the place.
            """
        }
        let list = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let prompt = """
            Traveler profile:
            \(profile)

            \(guidance)

            Candidates:
            \(list)

            Recommend the best next destinations for this traveler.
            """
        let response = try await session.respond(to: prompt, generating: DestinationPicks.self)
        return response.content.picks
    }
}
