/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit
import SwiftData
import SwiftUI

// MARK: - World map

/// The interactive world map, extracted from `ContentView` so unrelated parent
/// state can't re-evaluate the Map content builder.
///
/// Diffing is explicit (`Equatable` + `.equatable()` at the use site) and cheap:
/// the country arrays are pointer-compared (their membership only changes on
/// insert/delete), the load-once geometry dictionaries by count, and the rest by
/// value. A country's *status* changing doesn't need to fail `==` — the body
/// reads `country.status`, so Observation invalidates this view directly.
struct WorldMapView: View, Equatable {
    /// The full catalog, for resolving tap hit-tests to a country.
    let allCountries: [Country]
    let visibleCountries: [Country]
    let polygons: [String: [MKPolygon]]
    let detailPolygons: [String: [MKPolygon]]
    let paths: [String: [CGPath]]
    let boundingRects: [String: MKMapRect]
    let hitRects: [String: MKMapRect]
    let centroids: [String: CLLocationCoordinate2D]
    let hitTestIndex: GeoGridIndex?
    let mapStyle: MapStyleOption
    /// The trip whose itinerary route is drawn, if any.
    let mapTrip: Trip?
    @Binding var selectedCountry: Country?
    @Binding var cameraPosition: MapCameraPosition
    /// Called once, when the map delivers its first camera callback.
    let onFirstLive: () -> Void

    /// The viewport when the camera is zoomed in enough for minor islands to be
    /// visible; `nil` at world zoom. Updated by `onMapCameraChange`. Owned here
    /// so a pan at deep zoom re-evaluates only this view.
    @State private var detailMapRect: MKMapRect? = nil
    /// Whether the map has delivered its first camera callback.
    @State private var becameLive = false

    /// With Reduce Motion on, tapping a country jumps the camera instead of flying.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visibleCountries.elementsEqual(rhs.visibleCountries, by: ===)
            && lhs.allCountries.elementsEqual(rhs.allCountries, by: ===)
            && lhs.polygons.count == rhs.polygons.count
            && lhs.detailPolygons.count == rhs.detailPolygons.count
            && lhs.mapStyle == rhs.mapStyle
            && lhs.mapTrip === rhs.mapTrip
            && lhs.selectedCountry === rhs.selectedCountry
            && lhs.cameraPosition == rhs.cameraPosition
    }

    /// Polygons to draw for one country: the major rings always, plus the minor
    /// islands only when the camera is zoomed in and they intersect the viewport.
    /// Minor islands are sub-pixel at world zoom, and drawing all ~1,000 of them
    /// unconditionally made MapKit's initial overlay build take seconds. Tap
    /// accuracy is unaffected — `paths` always contains every ring.
    private func mapPolygons(for id: String) -> [MKPolygon] {
        let majors = polygons[id] ?? []
        guard let detailMapRect, let minors = detailPolygons[id] else { return majors }
        let visible = minors.filter { $0.boundingMapRect.intersects(detailMapRect) }
        return visible.isEmpty ? majors : majors + visible
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                ForEach(visibleCountries) { country in
                    CountryMapPolygons(
                        country: country,
                        status: country.status,
                        planStatus: country.planStatus,
                        polygons: mapPolygons(for: country.id))
                }

                if let sel = selectedCountry {
                    if let centroid = centroids[sel.id] {
                        Annotation(sel.name, coordinate: centroid, anchor: .bottom) {
                            Text(sel.flagEmoji)
                                .font(.title)
                                .padding(4)
                                .background(
                                    .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // The active trip's itinerary route. The modelContext check guards
                // against drawing a trip deleted while its route was showing.
                if let trip = mapTrip, trip.modelContext != nil {
                    TripRouteContent(trip: trip, centroids: centroids)
                }
            }
            .mapStyle(mapStyle.mapStyle)
            // Track when the camera is zoomed in past a quarter of the world's
            // width (~90° of longitude — a continent-ish view). Only then are
            // minor islands drawn; the rect is padded so islands just off-screen
            // are already filled when a pan ends on them. `.onEnd` keeps the
            // overlay set stable during the gesture itself.
            .onMapCameraChange(frequency: .onEnd) { context in
                if !becameLive {
                    becameLive = true
                    onFirstLive()
                }
                if context.rect.width < MKMapSize.world.width / 4 {
                    detailMapRect = context.rect.insetBy(
                        dx: -context.rect.width * 0.25, dy: -context.rect.height * 0.25)
                } else if detailMapRect != nil {
                    detailMapRect = nil
                }
            }
            .mapControls {
                // MapZoomStepper is macOS-only; iOS zooms via pinch gesture.
                #if os(macOS)
                    MapZoomStepper()
                #endif
                MapCompass()
                MapScaleView()
            }
            // Use `simultaneousGesture` rather than `.onTapGesture`: attaching a
            // plain tap recognizer directly to `Map` competes with MapKit's own
            // pan/pinch recognizers, which intermittently swallows taps and turns
            // drags into zooms. A simultaneous SpatialTapGesture runs alongside the
            // map's gestures instead of fighting them for each touch.
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    if let coordinate = proxy.convert(event.location, from: .local) {
                        handleTap(at: coordinate)
                    }
                }
            )
            // Prevent CAMetalLayer zero-size warnings during sheet transitions.
            .frame(minWidth: 1, minHeight: 1)
        }
    }

    /// Resolves a tap to a country — spatial grid index first (typically 5-15
    /// candidates instead of all ~250), then per-ring path hit-testing — and
    /// selects it, centering the camera on its mainland.
    private func handleTap(at coordinate: CLLocationCoordinate2D) {
        let mapPoint = MKMapPoint(coordinate)
        let cgPoint = CGPoint(x: mapPoint.x, y: mapPoint.y)

        let candidates = hitTestIndex?.candidates(for: mapPoint) ?? allCountries.map(\.id)
        for id in candidates {
            guard let countryRect = hitRects[id], countryRect.contains(mapPoint) else { continue }

            for path in paths[id] ?? [] {
                if path.contains(cgPoint) {
                    if let country = allCountries.first(where: { $0.id == id }) {
                        selectedCountry = country
                        // Animate the map to center on the tapped country.
                        if let rect = boundingRects[id] {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                                cameraPosition = .region(MKCoordinateRegion(rect))
                            }
                        }
                    }
                    return
                }
            }
        }
    }
}
