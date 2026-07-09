/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The app's brand palette, lifted directly from the app-icon / launch-screen
/// gradient: a sky-blue fading into a deep royal-blue (the royal tone is also
/// `LaunchBackground.colorset`). Every accent on the travel dashboard, the
/// achievement badges, and the share card draws from these so the whole feature
/// reads as one cohesive blue identity rather than the old orange.
extension Color {
    /// Top of the icon gradient — a bright sky blue.
    static let brandSky = Color(.displayP3, red: 0.523, green: 0.806, blue: 0.982)
    /// A mid-tone azure that bridges the sky and royal ends.
    static let brandAzure = Color(.displayP3, red: 0.298, green: 0.553, blue: 0.918)
    /// Base of the icon gradient — a deep royal blue. The default single accent.
    static let brandRoyal = Color(.displayP3, red: 0.161, green: 0.350, blue: 0.832)
    /// An indigo-leaning blue for the rarest "every continent" badges.
    static let brandIndigo = Color(.displayP3, red: 0.271, green: 0.247, blue: 0.776)
    /// A blue-green still inside the family, used for completion badges.
    static let brandTeal = Color(.displayP3, red: 0.184, green: 0.631, blue: 0.804)

    /// The primary single-color brand accent.
    static let brand = brandRoyal
}

extension ShapeStyle where Self == LinearGradient {
    /// The signature sky→royal diagonal, matching the app icon. Used for emphasis fills.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [.brandSky, .brandRoyal],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A small set of on-brand gradients the user can pick for their share card.
enum ShareCardTheme: String, CaseIterable, Identifiable {
    case ocean
    case midnight
    case sky

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ocean: "Ocean"
        case .midnight: "Midnight"
        case .sky: "Sky"
        }
    }

    /// The two-stop gradient painted behind the share card.
    var colors: [Color] {
        switch self {
        case .ocean:
            [.brandSky, .brandRoyal]
        case .midnight:
            [.brandRoyal, Color(.displayP3, red: 0.063, green: 0.110, blue: 0.353)]
        case .sky:
            [Color(.displayP3, red: 0.659, green: 0.871, blue: 0.992), .brandAzure]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
