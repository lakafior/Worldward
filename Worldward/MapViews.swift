/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftData
import SwiftUI

// MARK: - Map views

/// A subview that renders a single country's polygons. By isolating this into its
/// own view with a dependency on the `Country` object, SwiftUI can efficiently
/// observe changes to that specific country's status and redraw only these polygons.
struct CountryMapPolygons: MapContent {
    let country: Country
    let status: CountryStatus
    let planStatus: PlanStatus
    let polygons: [MKPolygon]

    /// Fill shows where you've *been* (warm); a country that's only planned shows
    /// its blue plan fill instead.
    private var fillColor: Color {
        status.isVisited ? status.fillColor : planStatus.fillColor
    }

    /// A planned country gets a blue outline — thicker so it reads as a ring even
    /// over a warm fill (a country that's both visited and on your list).
    private var strokeColor: Color {
        planStatus.isPlanned ? planStatus.strokeColor : status.strokeColor
    }

    private var lineWidth: CGFloat { planStatus.isPlanned ? 1.2 : 0.5 }

    var body: some MapContent {
        ForEach(polygons.indices, id: \.self) { index in
            MapPolygon(polygons[index])
                .foregroundStyle(fillColor)
                .stroke(strokeColor, lineWidth: lineWidth)
        }
    }
}

/// Draws a trip's itinerary on the world map: a dashed line connecting its stops
/// in order, a numbered flag badge per stop, and a small pin for each saved
/// place. A stop anchors on its first saved place when it has one (a real
/// coordinate from search), else on its country's centroid; stops with neither
/// are skipped.
struct TripRouteContent: MapContent {
    let trip: Trip
    let centroids: [String: CLLocationCoordinate2D]

    /// One drawable stop: its itinerary position and resolved coordinate.
    struct RoutePoint: Identifiable {
        let id: PersistentIdentifier
        let index: Int
        let title: String
        let flag: String
        let coordinate: CLLocationCoordinate2D
    }

    /// Resolves each stop to a coordinate, in itinerary order. Shared with
    /// `ContentView`, which uses the same points to frame the camera.
    static func routePoints(
        for trip: Trip, centroids: [String: CLLocationCoordinate2D]
    ) -> [RoutePoint] {
        var points: [RoutePoint] = []
        for stop in trip.sortedStops {
            let coordinate =
                stop.sortedPlaces.compactMap(\.coordinate).first
                ?? stop.country.flatMap { centroids[$0.id] }
            guard let coordinate else { continue }
            points.append(
                RoutePoint(
                    id: stop.persistentModelID, index: points.count,
                    title: stop.displayTitle, flag: stop.country?.flagEmoji ?? "📍",
                    coordinate: coordinate))
        }
        return points
    }

    private var points: [RoutePoint] {
        Self.routePoints(for: trip, centroids: centroids)
    }

    /// Every saved place with a real coordinate, for the fine-grained pins.
    private var places: [StopPlace] {
        trip.sortedStops.flatMap(\.sortedPlaces).filter { $0.coordinate != nil }
    }

    var body: some MapContent {
        if points.count > 1 {
            MapPolyline(coordinates: points.map(\.coordinate))
                .stroke(
                    Color.brand,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5]))
        }

        ForEach(places, id: \.persistentModelID) { place in
            if let coordinate = place.coordinate {
                Annotation(place.title, coordinate: coordinate, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(Color.brand, .white)
                }
            }
        }

        ForEach(points) { point in
            Annotation(point.title, coordinate: point.coordinate, anchor: .bottom) {
                HStack(spacing: 4) {
                    Text("\(point.index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.brand, in: Capsule())
                    Text(point.flag)
                }
                .padding(4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Compact key explaining the warm "been" shades and the blue "going" shades.
/// Adapts its background to bright or dark map styles.
struct MapLegend: View {
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(CountryStatus.visitedCases) { status in
                swatch(color: status.color, label: status.label)
            }
            Divider().frame(maxWidth: 90)
            ForEach(PlanStatus.plannedCases) { plan in
                swatch(color: plan.color, label: plan.label)
            }
        }
        .padding(8)
        .background(in: RoundedRectangle(cornerRadius: 8))
        .backgroundStyle(
            isDark ? AnyShapeStyle(Color.black.opacity(0.6)) : AnyShapeStyle(.ultraThinMaterial)
        )
        .foregroundStyle(isDark ? .white : .primary)
    }

    private func swatch(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.caption2)
        }
    }
}

/// Full-screen launch splash shown while the country geometry is being built.
/// A branded, opaque cover (rather than a bare spinner over an empty gray map)
/// makes the one-time first-run setup read as deliberate progress, not a freeze.
struct MapLoadingView: View {
    let message: String

    var body: some View {
        ZStack {
            // Matches the app icon's blue gradient (Display P3) to keep launch and
            // home screen in one color scheme.
            LinearGradient(
                colors: [
                    Color(.displayP3, red: 0.52287, green: 0.80649, blue: 0.98183),
                    Color(.displayP3, red: 0.16138, green: 0.35032, blue: 0.83176),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)

                Text("Worldward")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.white)
                    .controlSize(.large)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Country row

struct CountryRow: View {
    let country: Country

    var body: some View {
        HStack(spacing: 6) {
            Text(country.flagEmoji)
            Text(country.name)
            Spacer()
            if country.isPlanned {
                Image(systemName: country.planStatus.symbolName)
                    .foregroundStyle(country.planStatus.tint)
            }
            if country.status.isVisited {
                Image(systemName: country.status.symbolName)
                    .foregroundStyle(country.status.color)
            }
        }
        // Make the whole row tappable, not just the drawn content (the Spacer gap
        // wouldn't register taps under a plain button otherwise).
        .contentShape(Rectangle())
    }
}
