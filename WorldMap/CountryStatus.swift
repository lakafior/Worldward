import SwiftUI

/// A country's single travel relationship. The cases are mutually exclusive and
/// ordered from the strongest bond (`living`) to the weakest (`crossed`); this
/// ordering drives the green shade used on the map.
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

    /// Representative green. `living` is the darkest, `crossed` the palest;
    /// `notVisited` is clear so unvisited countries show the bare map.
    var color: Color {
        switch self {
        case .notVisited: .clear
        case .crossed:    Color(red: 0.62, green: 0.87, blue: 0.62)
        case .visited:    Color(red: 0.35, green: 0.72, blue: 0.38)
        case .lived:      Color(red: 0.15, green: 0.50, blue: 0.20)
        case .living:     Color(red: 0.00, green: 0.30, blue: 0.08)
        }
    }

    /// Fill style for the map polygon (translucent so the map stays legible).
    var fillColor: Color { color.opacity(self == .notVisited ? 0 : 0.6) }

    /// Outline for the map polygon.
    var strokeColor: Color { self == .notVisited ? Color.gray.opacity(0.25) : color }

    /// The statuses worth showing in a legend (everything except "not visited").
    static var visitedCases: [CountryStatus] { allCases.filter(\.isVisited) }
}
