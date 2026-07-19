/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A focused, full-screen achievements viewer — badges only, no stats,
/// no timelines, no planning suggestions. Available from the Map tab toolbar.
struct AchievementsView: View {
    let countries: [Country]

    @Environment(\.dismiss) private var dismiss

    /// Pre-computed once in `init` so the body never re-runs the O(n) passes.
    private let stats: TravelStats
    private let achievements: [Achievement]
    private let unlockedCount: Int

    init(countries: [Country]) {
        self.countries = countries
        let stats = TravelStats(countries: countries)
        let achievements = Achievement.all(for: stats)
        self.stats = stats
        self.achievements = achievements
        self.unlockedCount = achievements.filter(\.isUnlocked).count
    }

    var body: some View {
        // macOS shows this inside the main window's "Your Travels" destination,
        // which is already on a navigation stack — nesting another would break
        // the back button. Only the iOS sheet needs its own stack and Done.
        #if os(macOS)
            grid
        #else
            NavigationStack {
                grid
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .frame(minWidth: 380, minHeight: 400)
        #endif
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HeroSection(unlocked: unlockedCount, total: achievements.count)
                AchievementsSection(achievements: achievements)
            }
            .padding()
        }
        .navigationTitle("Achievements")
    }
}

// MARK: - Hero

private struct HeroSection: View {
    let unlocked: Int
    let total: Int

    @ScaledMetric(relativeTo: .largeTitle) private var trophySize = 40.0

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: trophySize))
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            Text("\(unlocked)/\(total)")
                .font(.title.weight(.bold))
            Text("achievements unlocked")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Achievements grid

private struct AchievementsSection: View {
    let achievements: [Achievement]

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Achievement.Category.allCases) { category in
                let items = achievements.filter { $0.category == category }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.title)
                            .font(.headline)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(items) { achievement in
                                AchievementBadge(achievement: achievement)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Badge

private struct AchievementBadge: View {
    let achievement: Achievement
    @State private var showingDetail = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        achievement.isUnlocked
                            ? achievement.tint.opacity(0.15)
                            : Color.gray.opacity(0.1)
                    )
                    .aspectRatio(1, contentMode: .fit)

                VStack(spacing: 4) {
                    Image(systemName: achievement.symbol)
                        .font(.title2)
                        .foregroundStyle(
                            achievement.isUnlocked ? achievement.tint : Color.gray)

                    // Always reserved (not just for locked achievements) so every
                    // tile's icon box is the same height — otherwise the extra
                    // row made locked tiles taller than unlocked ones.
                    ProgressView(value: achievement.isUnlocked ? 1 : achievement.progress)
                        .tint(achievement.tint)
                        .padding(.horizontal, 8)
                        .opacity(achievement.isUnlocked ? 0 : 1)
                }
            }

            Text(achievement.title)
                .font(.caption2)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(achievement.isUnlocked ? .primary : .secondary)

            // Always reserved so unlocked and in-progress badges stay the same
            // height — otherwise the extra caption made in-progress ones taller.
            Text(achievement.isUnlocked ? " " : achievement.progressLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { showingDetail = true }
        // The tile is a tap target built from a gesture; present it to assistive
        // tech as one button carrying the badge's name and progress.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(achievement.title)
        .accessibilityValue(
            achievement.isUnlocked
                ? Text("Unlocked", comment: "Accessibility value: badge is earned")
                : Text(achievement.progressLabel))
        .accessibilityHint(achievement.detail)
        .accessibilityAddTraits(.isButton)
        // macOS: description on hover, and the detail as an anchored popover
        // (click-away or ✕-free Esc dismiss) instead of a modal sheet, which
        // on Mac had no visible way to close. iOS keeps the compact sheet.
        #if os(macOS)
            .help(achievement.detail)
            .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                AchievementDetailPopover(achievement: achievement)
                    .frame(width: 280)
            }
        #else
            .sheet(isPresented: $showingDetail) {
                AchievementDetailPopover(achievement: achievement)
                    .presentationDetents([.height(260)])
            }
        #endif
    }
}

// MARK: - Detail popover

private struct AchievementDetailPopover: View {
    let achievement: Achievement

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = 36.0

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: achievement.symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(achievement.tint)
                .accessibilityHidden(true)

            Text(achievement.title)
                .font(.headline)

            Text(achievement.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if achievement.isUnlocked {
                Label("Unlocked", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ProgressView(value: achievement.progress)
                    .tint(achievement.tint)
                Text(achievement.progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
