import Foundation
import WidgetKit

/// A tiny, `Codable` summary of the user's travels, written by the app into the
/// shared App Group container and read by the widgets. Keeping the widget on a
/// snapshot — rather than opening SwiftData inside the extension — keeps it
/// lightweight and avoids relocating the app's store. Everything the widgets draw
/// is a plain value here (counts and flag emoji), so the extension never touches
/// the model.
///
/// This file is a member of BOTH the app and the widget extension targets.
struct WidgetSnapshot: Codable, Hashable {
    var visitedCountries: Int
    var totalCountries: Int
    var visitedContinents: Int
    var totalContinents: Int

    /// Visited-country flag emoji, strongest bond first then alphabetical — the
    /// same order the dashboard uses for its flag strip.
    var flags: [String]

    /// Share of the world's countries visited, `0...1`.
    var fraction: Double {
        totalCountries > 0 ? Double(visitedCountries) / Double(totalCountries) : 0
    }

    /// A friendly empty state for a fresh install, or when the app group isn't
    /// readable yet.
    static let placeholder = WidgetSnapshot(
        visitedCountries: 0, totalCountries: 195,
        visitedContinents: 0, totalContinents: 7, flags: [])

    /// A populated example used for the widget gallery and Xcode previews.
    static let sample = WidgetSnapshot(
        visitedCountries: 24, totalCountries: 195,
        visitedContinents: 4, totalContinents: 7,
        flags: [
            "🇯🇵", "🇫🇷", "🇮🇹", "🇪🇸", "🇩🇪", "🇵🇹", "🇬🇷", "🇳🇱", "🇧🇪", "🇨🇭",
            "🇺🇸", "🇨🇦", "🇲🇽", "🇧🇷", "🇦🇷", "🇿🇦", "🇪🇬", "🇲🇦", "🇦🇺", "🇹🇭",
            "🇻🇳", "🇰🇷", "🇮🇸", "🇳🇴",
        ])
}

/// Reads and writes the shared `WidgetSnapshot`. The app writes after any change
/// to the catalog; the widgets read on every timeline refresh.
enum WidgetSnapshotStore {
    /// Must match the `com.apple.security.application-groups` entitlement on both
    /// the app and the widget extension.
    static let appGroupID = "group.net.smigi.worldward"

    private static let fileName = "widget-snapshot.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Persist the latest snapshot and ask WidgetKit to redraw. A missing
    /// container — e.g. the app group isn't provisioned on a free team — is
    /// ignored so the app keeps working without widgets.
    static func write(_ snapshot: WidgetSnapshot) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The last snapshot the app wrote, or `.placeholder` if none is available.
    static func read() -> WidgetSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .placeholder }
        return snapshot
    }
}
