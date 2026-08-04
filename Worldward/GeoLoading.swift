/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MapKit

// MARK: - Bundled geometry

/// One country's seed metadata, parsed from the GeoJSON alongside its geometry.
struct CountrySeed: Sendable {
    let id: String
    let iso3: String
    let name: String
}

/// Decodes the bundled `countries.wmgb` — the pre-simplified country outlines and
/// seed metadata produced once per release by `Tools/generate_geo.swift`. Because
/// the heavy GeoJSON decode and Douglas-Peucker simplification happen at build
/// time (not on-device), the app ships ~675 KB instead of a 14 MB GeoJSON and the
/// first launch is as fast as every later one — no download, no on-device decode.
///
/// Binary format ("WMGB" v1), little-endian — kept in sync with the writer in
/// `Tools/generate_geo.swift`:
///   magic 'WMGB' · UInt32 version · UInt32 country count, then per country:
///   UInt8-prefixed id · UInt8-prefixed iso3 · UInt16-prefixed name ·
///   UInt16 ring count, then per ring: UInt32 point count · point × (Float32 x, y).
func loadBundledGeo() -> (
    rings: [String: [[MKMapPoint]]], seeds: [CountrySeed]
)? {
    guard let url = Bundle.main.url(forResource: "countries", withExtension: "wmgb"),
        let data = try? Data(contentsOf: url)
    else { return nil }

    return data.withUnsafeBytes {
        (raw: UnsafeRawBufferPointer) -> (
            rings: [String: [[MKMapPoint]]], seeds: [CountrySeed]
        )? in
        var offset = 0
        let total = raw.count

        func need(_ count: Int) -> Bool { offset + count <= total }
        func readU8() -> UInt8? {
            guard need(1) else { return nil }
            defer { offset += 1 }
            return raw.load(fromByteOffset: offset, as: UInt8.self)
        }
        func readU16() -> UInt16? {
            guard need(2) else { return nil }
            defer { offset += 2 }
            return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
        func readU32() -> UInt32? {
            guard need(4) else { return nil }
            defer { offset += 4 }
            return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func readFloat() -> Float? {
            guard let bits = readU32() else { return nil }
            return Float(bitPattern: bits)
        }
        func readString(_ length: Int) -> String? {
            guard need(length) else { return nil }
            defer { offset += length }
            return String(
                bytes: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + length]),
                encoding: .utf8)
        }

        guard let m0 = readU8(), let m1 = readU8(), let m2 = readU8(), let m3 = readU8(),
            m0 == 0x57, m1 == 0x4D, m2 == 0x47, m3 == 0x42,  // "WMGB"
            let version = readU32(), version == 1,
            let count = readU32()
        else { return nil }

        var rings: [String: [[MKMapPoint]]] = [:]
        var seeds: [CountrySeed] = []
        rings.reserveCapacity(Int(count))
        seeds.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let idLen = readU8(), let id = readString(Int(idLen)),
                let iso3Len = readU8(), let iso3 = readString(Int(iso3Len)),
                let nameLen = readU16(), let name = readString(Int(nameLen)),
                let ringCount = readU16()
            else { return nil }

            var countryRings: [[MKMapPoint]] = []
            countryRings.reserveCapacity(Int(ringCount))
            for _ in 0..<ringCount {
                guard let pointCount = readU32() else { return nil }
                var points: [MKMapPoint] = []
                points.reserveCapacity(Int(pointCount))
                for _ in 0..<pointCount {
                    guard let x = readFloat(), let y = readFloat() else { return nil }
                    points.append(MKMapPoint(x: Double(x), y: Double(y)))
                }
                countryRings.append(points)
            }

            rings[id] = countryRings
            seeds.append(CountrySeed(id: id, iso3: iso3, name: name))
        }

        return (rings, seeds)
    }
}

/// The hit-test paths, in a form that can be handed to a `@concurrent` scan.
///
/// `CGPath` predates `Sendable` and isn't marked as such, so the table can't
/// cross an isolation boundary on its own. Safe here: `buildGeo` copies each
/// `CGMutablePath` into an immutable `CGPath` and never touches it again, and
/// `contains(_:)` is a pure read — the same trade `ReminderSync.ReminderBatch`
/// makes. Without this the photo scanners can't leave the main actor at all
/// (see `PhotoImporter.scanPhotos`).
///
/// `nonisolated` because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would
/// otherwise pin the members to the main actor, which is exactly what the box
/// exists to escape.
nonisolated struct CountryPaths: @unchecked Sendable {
    let byCountry: [String: [CGPath]]

    init(_ byCountry: [String: [CGPath]]) { self.byCountry = byCountry }

    subscript(id: String) -> [CGPath]? { byCountry[id] }
}

/// Rebuilds the drawable polygons, hit-test paths, and per-country bounding rects
/// from simplified rings.
///
/// Polygons come back in two tiers: `polys` holds each country's major rings
/// (mainland plus islands at least 0.5% of its size) and `detailPolys` the minor
/// islands below that — the ones the generator's 25 km floor keeps (Hawaii,
/// Kaliningrad, small archipelagos). The map draws majors always and minors only
/// when zoomed in: minor islands are sub-pixel at world zoom, and the thousands
/// of extra overlays made MapKit's initial build take seconds. `paths` and
/// `hitRects` always cover *every* ring, so tap accuracy never depends on zoom.
func buildGeo(
    from rings: [String: [[MKMapPoint]]]
) -> (
    polys: [String: [MKPolygon]], detailPolys: [String: [MKPolygon]],
    paths: [String: [CGPath]], rects: [String: MKMapRect], hitRects: [String: MKMapRect]
) {
    var polys: [String: [MKPolygon]] = [:]
    var detailPolys: [String: [MKPolygon]] = [:]
    var paths: [String: [CGPath]] = [:]
    var rects: [String: MKMapRect] = [:]
    var hitRects: [String: MKMapRect] = [:]

    for (id, ringList) in rings {
        var built: [(polygon: MKPolygon, rect: MKMapRect)] = []
        var cgPaths: [CGPath] = []
        var largestRect: MKMapRect?
        var unionRect: MKMapRect?

        for points in ringList {
            guard points.count >= 3 else { continue }

            let polygon = MKPolygon(points: points, count: points.count)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()
            cgPaths.append(path)

            let rect = polygon.boundingMapRect
            built.append((polygon, rect))
            if largestRect == nil || rect.area > largestRect!.area { largestRect = rect }
            unionRect = unionRect.map { $0.union(rect) } ?? rect
        }

        guard !built.isEmpty, let largestRect, let unionRect else { continue }

        let minMajorArea = largestRect.area * 0.005
        polys[id] = built.filter { $0.rect.area >= minMajorArea }.map(\.polygon)
        let minors = built.filter { $0.rect.area < minMajorArea }.map(\.polygon)
        if !minors.isEmpty { detailPolys[id] = minors }

        paths[id] = cgPaths
        rects[id] = largestRect
        hitRects[id] = unionRect
    }
    return (polys, detailPolys, paths, rects, hitRects)
}

extension MKMapRect {
    /// Area in squared map points; a cheap proxy for comparing landmass sizes.
    nonisolated var area: Double { width * height }
}

/// A grid-based spatial index mapping a map point to a small set of candidate
/// country ids. The world is divided into ~10° × 10° cells; a lookup only
/// returns the countries whose bounding rect overlaps the queried cell
/// (typically 5-15 candidates instead of all ~250). Shared by the map's tap
/// hit-testing and the photo importer's coordinate matching — `nonisolated`
/// so the importer's off-main scan can build and query it.
nonisolated struct GeoGridIndex: Sendable {
    private let cols: Int
    private let rows: Int
    private let world = MKMapRect.world
    private var cells: [Int: [String]] = [:]

    init(rects: [String: MKMapRect], cols: Int = 36, rows: Int = 18) {
        self.cols = cols
        self.rows = rows
        for (id, rect) in rects {
            let minCol = max(0, Int((rect.minX / world.width) * Double(cols)))
            let maxCol = min(cols - 1, Int((rect.maxX / world.width) * Double(cols)))
            let minRow = max(0, Int((rect.minY / world.height) * Double(rows)))
            let maxRow = min(rows - 1, Int((rect.maxY / world.height) * Double(rows)))
            for col in minCol...maxCol {
                for row in minRow...maxRow {
                    cells[row * cols + col, default: []].append(id)
                }
            }
        }
    }

    /// Country ids whose bounding rect spans the grid cell containing `point`.
    func candidates(for point: MKMapPoint) -> [String] {
        let col = min(cols - 1, max(0, Int((point.x / world.width) * Double(cols))))
        let row = min(rows - 1, max(0, Int((point.y / world.height) * Double(rows))))
        return cells[row * cols + col] ?? []
    }
}
