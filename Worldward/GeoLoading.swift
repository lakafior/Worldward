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
/// time (not on-device), the app ships ~340 KB instead of a 14 MB GeoJSON and the
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

/// Rebuilds the drawable polygons, hit-test paths, and per-country bounding rects
/// from simplified rings. Shared by both the cache and fresh-decode paths so the
/// map and tap targets are identical whichever produced the rings.
func buildGeo(
    from rings: [String: [[MKMapPoint]]]
) -> ([String: [MKPolygon]], [String: [CGPath]], [String: MKMapRect], [String: MKMapRect]) {
    var polys: [String: [MKPolygon]] = [:]
    var paths: [String: [CGPath]] = [:]
    var rects: [String: MKMapRect] = [:]
    var hitRects: [String: MKMapRect] = [:]

    for (id, ringList) in rings {
        var polygons: [MKPolygon] = []
        var cgPaths: [CGPath] = []
        var largestRect: MKMapRect?
        var unionRect: MKMapRect?

        for points in ringList {
            guard points.count >= 3 else { continue }

            let polygon = MKPolygon(points: points, count: points.count)
            polygons.append(polygon)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()
            cgPaths.append(path)

            let rect = polygon.boundingMapRect
            if largestRect == nil || rect.area > largestRect!.area { largestRect = rect }
            unionRect = unionRect.map { $0.union(rect) } ?? rect
        }

        guard !polygons.isEmpty, let largestRect, let unionRect else { continue }
        polys[id] = polygons
        paths[id] = cgPaths
        rects[id] = largestRect
        hitRects[id] = unionRect
    }
    return (polys, paths, rects, hitRects)
}

extension MKMapRect {
    /// Area in squared map points; a cheap proxy for comparing landmass sizes.
    nonisolated var area: Double { width * height }
}
