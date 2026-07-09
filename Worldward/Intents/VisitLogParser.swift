/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import FoundationModels
import SwiftData

// MARK: - Parsed model types

/// One visit the model extracted from a free-form sentence. The country is kept
/// as the raw name the user said — resolving it to a real catalog entry (and a
/// flag) is done in Swift, never by the model, so it can't invent ISO codes.
@Generable
struct ParsedVisit {
    @Guide(description: "The country name exactly as the user referred to it, in English where possible.")
    var country: String

    @Guide(description: "The visit date as yyyy-MM-dd, only if a date, month, season, or year is implied. Omit otherwise.")
    var date: String?
}

/// The full set of visits pulled from one sentence.
@Generable
struct ParsedVisitList {
    @Guide(description: "One entry per country the user said they visited. Empty if none are mentioned.")
    var visits: [ParsedVisit]
}

// MARK: - Resolved draft

/// A parsed visit after Swift has resolved it against the country catalog. A nil
/// `country` means the model named a place that doesn't match any catalog entry,
/// which the review UI surfaces so the user isn't misled into thinking it saved.
struct VisitDraft: Identifiable {
    let id = UUID()
    /// The raw name the model returned, kept for showing unmatched entries.
    let rawName: String
    /// The resolved catalog country, or nil when no match was found.
    let country: Country?
    /// The parsed visit date, or nil when none was implied.
    let date: Date?

    var isMatched: Bool { country != nil }
}

// MARK: - Parser

/// Turns a natural-language sentence ("I went to Japan and South Korea last
/// spring") into reviewable `VisitDraft`s using on-device guided generation.
/// Entirely local; gated on Apple Intelligence availability like the Q&A surface.
@MainActor
@Observable
final class VisitLogParser {

    enum Phase: Equatable {
        case idle
        case working
        case parsed([VisitDraft])
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.working, .working): true
            case let (.parsed(a), .parsed(b)): a.map(\.id) == b.map(\.id)
            case let (.failed(a), .failed(b)): a == b
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle

    private let model = SystemLanguageModel.default
    private let container: ModelContainer

    init(container: ModelContainer? = nil) {
        self.container = container ?? Worldward.sharedModelContainer
    }

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    var availability: SystemLanguageModel.Availability { model.availability }

    /// Extracts visits from `text`, resolves them against the catalog, and
    /// publishes the result through `phase`.
    func parse(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        phase = .working
        do {
            let today = Self.todayFormatter.string(from: Date())
            let session = LanguageModelSession {
                "You extract structured travel visits from a sentence the user writes."
                """
                Today is \(today). Resolve relative time references such as "last \
                spring" or "two years ago" into a representative yyyy-MM-dd date. \
                If a country is mentioned with no time at all, omit its date.
                """
                "List one entry per country the user actually visited. Never invent countries."
            }
            let result = try await session.respond(to: trimmed, generating: ParsedVisitList.self)
            let countries = try ModelContext(container).fetch(FetchDescriptor<Country>())
            let drafts = result.content.visits.map { parsed in
                VisitDraft(
                    rawName: parsed.country,
                    country: Self.resolve(parsed.country, in: countries),
                    date: Self.parseDate(parsed.date))
            }
            phase = .parsed(drafts)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() { phase = .idle }

    // MARK: - Resolution helpers

    /// Matches a free-text name to a catalog country: exact (case-insensitive)
    /// first, then a contains match in either direction to catch "South Korea"
    /// vs. a catalog "Korea" style entry.
    static func resolve(_ name: String, in countries: [Country]) -> Country? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        if let exact = countries.first(where: {
            $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame
        }) {
            return exact
        }
        return countries.first { country in
            country.name.localizedCaseInsensitiveContains(query)
                || query.localizedCaseInsensitiveContains(country.name)
        }
    }

    /// Parses the model's date string. Accepts full dates, year-month, or a bare
    /// year so a vaguely-dated visit still lands in the right year.
    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
