import SwiftUI

/// A country's single travel relationship. The cases are mutually exclusive and
/// ordered from the strongest bond (`living`) to the weakest (`crossed`); this
/// ordering drives the yellow-to-orange shade used on the map.
enum CountryStatus: String, CaseIterable, Identifiable, Codable {
    case notVisited
    case crossed
    case visited
    case lived
    case living

    var id: String { rawValue }

    /// Human-readable name for the picker and legend.
    var label: String {
        switch self {
        case .notVisited: "Not visited"
        case .crossed:    "Crossed"
        case .visited:    "Visited"
        case .lived:      "Lived"
        case .living:     "Living"
        }
    }

    /// SF Symbol shown in the country list and status picker.
    var symbolName: String {
        switch self {
        case .notVisited: "circle"
        case .crossed:    "arrow.right.circle"
        case .visited:    "checkmark.circle.fill"
        case .lived:      "house"
        case .living:     "house.fill"
        }
    }

    /// Whether the country counts as "been there" for statistics and filtering.
    var isVisited: Bool { self != .notVisited }

    /// Warm yellow-to-orange scale, chosen to stand out against the green map.
    /// `living` is the deepest orange, `crossed` the palest yellow;
    /// `notVisited` is clear so unvisited countries show the bare map.
    var color: Color {
        switch self {
        case .notVisited: .clear
        case .crossed:    Color(red: 1.00, green: 0.87, blue: 0.40)
        case .visited:    Color(red: 1.00, green: 0.72, blue: 0.20)
        case .lived:      Color(red: 0.96, green: 0.51, blue: 0.09)
        case .living:     Color(red: 0.84, green: 0.30, blue: 0.05)
        }
    }

    /// A always-visible tint for badges and chips. Mirrors `color`, but falls back
    /// to a neutral gray for `notVisited` (whose `color` is intentionally clear).
    var tint: Color { self == .notVisited ? .gray : color }

    /// Fill style for the map polygon (a touch more opaque so it reads on the map).
    var fillColor: Color { color.opacity(self == .notVisited ? 0 : 0.7) }

    /// Outline for the map polygon.
    var strokeColor: Color { self == .notVisited ? Color.gray.opacity(0.25) : color }

    /// The statuses worth showing in a legend (everything except "not visited").
    static var visitedCases: [CountryStatus] { allCases.filter(\.isVisited) }
}
