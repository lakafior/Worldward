/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Remembers which badges have already been celebrated and diffs each recompute
/// against that set, so a newly earned badge surfaces as a toast exactly once.
/// Achievements themselves stay fully derived (see `Achievement`); only the ids
/// already celebrated are persisted.
enum AchievementUnlocks {
    static let defaultsKey = "celebratedAchievementIDs"

    /// Diffs the current unlocked set against the persisted one, records the new
    /// state, and returns the achievements unlocked since the last call.
    ///
    /// The very first call seeds silently (returns nothing) so an existing
    /// traveler updating the app isn't greeted by a wall of toasts for badges
    /// earned long ago. The stored set mirrors reality rather than only growing:
    /// a badge that re-locks (say, a status edit removed) is dropped and will be
    /// celebrated again if re-earned.
    static func consumeNewlyUnlocked(
        from achievements: [Achievement], defaults: UserDefaults = .standard
    ) -> [Achievement] {
        let unlocked = achievements.filter(\.isUnlocked)
        let previous = defaults.stringArray(forKey: defaultsKey)
        defaults.set(unlocked.map(\.id), forKey: defaultsKey)
        guard let previous else { return [] }
        let alreadyCelebrated = Set(previous)
        return unlocked.filter { !alreadyCelebrated.contains($0.id) }
    }
}

/// What the unlock toast shows: a single badge, or a roll-up when several unlock
/// in one change (a photo import can add dozens of countries in one save, which
/// would otherwise queue a minute of toasts).
struct AchievementCelebration: Equatable {
    let symbol: String
    let tint: Color
    let overline: String
    let headline: String

    init?(newlyUnlocked: [Achievement]) {
        guard let first = newlyUnlocked.first else { return nil }
        if newlyUnlocked.count == 1 {
            symbol = first.symbol
            tint = first.tint
            overline = String(
                localized: "Achievement unlocked",
                comment: "Toast overline when one badge is newly earned")
            headline = first.title
        } else {
            symbol = "trophy.fill"
            tint = .brand
            overline = String(
                localized: "\(newlyUnlocked.count) achievements unlocked",
                comment: "Toast overline when several badges are earned at once")
            headline = newlyUnlocked.map(\.title).joined(separator: " · ")
        }
    }
}

/// The floating banner that celebrates a fresh unlock. Shown from the app root
/// over whichever tab is frontmost; tapping it opens the achievements grid.
struct AchievementToastView: View {
    let celebration: AchievementCelebration
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(celebration.tint.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: celebration.symbol)
                    .font(.title3)
                    .foregroundStyle(celebration.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(celebration.overline)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(celebration.headline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(celebration.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            Text(
                "Opens achievements",
                comment: "Accessibility hint on the achievement unlock toast"))
    }
}
