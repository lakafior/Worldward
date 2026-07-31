/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftData

/// Turns whatever a caller wrote into a `Country`.
///
/// The API is machine-facing and documents ISO alpha-2, but callers say "Spain",
/// "spain", "ESP" and "ES" interchangeably — so this accepts all of them rather
/// than bouncing a request a human would have understood. Matching is ordered
/// strongest-first and stops at the first tier that hits, which is what keeps
/// "IN" resolving to India instead of colliding with a name that contains "in".
///
/// Ambiguity is reported, never guessed: two countries whose names both match
/// throws `.ambiguousCountry` listing the ISO ids, so the caller can retry
/// precisely instead of silently editing the wrong row.
@MainActor
enum CountryResolver {

    /// Resolves `token`, or `nil` when nothing matches. Throws only on ambiguity.
    static func find(_ token: String, in context: ModelContext) throws -> Country? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Fast path: an exact ISO alpha-2 id, which is what the schemas ask for
        // and what `#Index([\Country.id])` is there to serve.
        let upper = trimmed.uppercased()
        if upper.count == 2 {
            let descriptor = FetchDescriptor<Country>(predicate: #Predicate { $0.id == upper })
            if let match = try context.fetch(descriptor).first { return match }
        }

        // Everything else needs the catalog in memory. It's ~239 rows, already
        // faulted in by any open list, so a scan costs less than four predicates.
        let all = try context.fetch(FetchDescriptor<Country>())
        let folded = trimmed.lowercased()

        if upper.count == 3, let match = all.first(where: { $0.iso3.uppercased() == upper }) {
            return match
        }

        // Stored English name, then the user's own language — so a Polish user
        // typing "Hiszpania" is understood without the caller knowing the locale.
        for candidates in [
            all.filter { $0.name.lowercased() == folded },
            all.filter { $0.localizedName.lowercased() == folded },
        ] where !candidates.isEmpty {
            guard candidates.count == 1 else {
                throw APIError.ambiguousCountry(trimmed, candidates: candidates.map(\.id).sorted())
            }
            return candidates[0]
        }

        // Last resort: a unique prefix ("United Arab" → AE). Prefix rather than
        // `contains`, so "Guinea" can't sweep up Papua New Guinea and throw.
        let prefixed = all.filter {
            $0.name.lowercased().hasPrefix(folded) || $0.localizedName.lowercased().hasPrefix(folded)
        }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            throw APIError.ambiguousCountry(trimmed, candidates: prefixed.map(\.id).sorted())
        }
        return nil
    }

    /// Resolves `token` or throws `.countryNotFound` — the form write paths want,
    /// since "couldn't find it" is a failure there rather than an empty result.
    static func require(_ token: String, in context: ModelContext) throws -> Country {
        guard let match = try find(token, in: context) else {
            throw APIError.countryNotFound(token)
        }
        return match
    }
}
