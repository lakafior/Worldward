import SwiftData
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HeroSection(unlocked: unlockedCount, total: achievements.count)
                    AchievementsSection(achievements: achievements)
                }
                .padding()
            }
            .navigationTitle("Achievements")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // macOS shows this in its own window; the close button dismisses.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            #endif
        }
        #if os(iOS)
            .frame(minWidth: 380, minHeight: 400)
        #endif
    }
}

#if os(macOS)
    /// Hosts `AchievementsView` in its own resizable macOS window, querying the
    /// catalog itself so `openWindow(id:)` needs no payload.
    struct AchievementsWindowContent: View {
        @Query(sort: \Country.name) private var countries: [Country]
        var body: some View { AchievementsView(countries: countries) }
    }
#endif

// MARK: - Hero

private struct HeroSection: View {
    let unlocked: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.brand)
            Text("\(unlocked)/\(total)")
                .font(.title.weight(.bold))
            Text("achievements unlocked")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
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

                    if !achievement.isUnlocked {
                        ProgressView(value: achievement.progress)
                            .tint(achievement.tint)
                            .padding(.horizontal, 8)
                    }
                }
            }

            Text(achievement.title)
                .font(.caption2)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(achievement.isUnlocked ? .primary : .secondary)

            if !achievement.isUnlocked {
                Text(achievement.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .onTapGesture { showingDetail = true }
        .sheet(isPresented: $showingDetail) {
            AchievementDetailPopover(achievement: achievement)
                .presentationDetents([.height(260)])
        }
    }
}

// MARK: - Detail popover

private struct AchievementDetailPopover: View {
    let achievement: Achievement

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: achievement.symbol)
                .font(.system(size: 36))
                .foregroundStyle(achievement.tint)

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
