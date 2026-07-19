/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A country's place in your travel *plans* — a separate axis from `CountryStatus`
/// (where you've *been*). A country can carry both: e.g. visited Japan and still
/// on your wishlist to return. Ordered weakest→strongest intent, and rendered in a
/// cool blue family so plans read as distinct from the warm "been there" scale.
enum PlanStatus: String, CaseIterable, Identifiable, Codable {
    case none
    case wishlist
    case planning

    var id: String { rawValue }

    /// Human-readable name for the picker and legend.
    var label: String {
        switch self {
        case .none:     String(localized: "Not planned", comment: "Plan status: no plans")
        case .wishlist: String(localized: "Wishlist", comment: "Plan status: on the wishlist")
        case .planning: String(localized: "Planning", comment: "Plan status: actively planning")
        }
    }

    /// SF Symbol shown in the country list and plan picker.
    var symbolName: String {
        switch self {
        case .none:     "circle"
        case .wishlist: "star"
        case .planning: "airplane"
        }
    }

    /// Whether the country is on your plans at all.
    var isPlanned: Bool { self != .none }

    /// Cool blue scale — light for a loose wishlist, deeper once you're actively
    /// planning. `none` is clear so unplanned countries show the bare map.
    var color: Color {
        switch self {
        case .none:     .clear
        case .wishlist: Color(red: 0.40, green: 0.72, blue: 0.95)
        case .planning: Color(red: 0.13, green: 0.42, blue: 0.80)
        }
    }

    /// An always-visible tint for badges and chips (neutral gray for `none`).
    var tint: Color { self == .none ? .gray : color }

    /// The chip/badge tint honoring the user's Increase Contrast setting: the
    /// light wishlist blue darkens so small icons stay legible on light
    /// backgrounds; the deeper planning blue already passes.
    func tint(increasedContrast: Bool) -> Color {
        guard increasedContrast, self == .wishlist else { return tint }
        return Color(red: 0.08, green: 0.42, blue: 0.72)
    }

    /// Fill style for the map polygon. A touch lighter than the warm "been" fill
    /// (0.7) so a blue plan ring stays legible over a warm fill on a country that
    /// is both visited and planned.
    var fillColor: Color { color.opacity(self == .none ? 0 : 0.55) }

    /// Outline for the map polygon.
    var strokeColor: Color { self == .none ? Color.gray.opacity(0.25) : color }

    /// The statuses worth showing in a legend (everything except "not planned").
    static var plannedCases: [PlanStatus] { allCases.filter(\.isPlanned) }
}
