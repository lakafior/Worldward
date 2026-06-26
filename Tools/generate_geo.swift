#!/usr/bin/env swift
//
//  generate_geo.swift
//
//  Dev-time tool — NOT part of the app target.
//
//  Produces `countries.wmgb`, the packed-binary country geometry the app bundles
//  and reads at launch (see `loadBundledGeo` in ContentView.swift). Doing the
//  expensive Natural Earth decode + Douglas-Peucker simplification here, once per
//  release, means no user device ever pays that cost and no one ever downloads the
//  source data — the app ships the small, pre-simplified result.
//
//  Borders change rarely, so re-run this only when you want fresh map data or
//  change the simplification, then drop the new `countries.wmgb` into
//  WorldMap/WorldMap/ (the synchronized folder bundles it automatically).
//
//  Usage:
//      swift Tools/generate_geo.swift                       # download from nvkelso
//      swift Tools/generate_geo.swift --local path.geojson  # use a local file
//      swift Tools/generate_geo.swift --out path.wmgb       # custom output path
//
//  Requires macOS (uses MapKit's MKGeoJSONDecoder).
//
//  Binary format ("WMGB" v1), little-endian — kept in sync with loadBundledGeo():
//      magic   : 4 bytes  'W','M','G','B'
//      version : UInt32   = 1
//      count   : UInt32   number of countries
//      per country:
//          id      : UInt8 length  + UTF-8 bytes   (ISO 3166-1 alpha-2)
//          iso3    : UInt8 length  + UTF-8 bytes
//          name    : UInt16 length + UTF-8 bytes
//          ringCnt : UInt16
//          per ring:
//              ptCount : UInt32
//              points  : ptCount × (Float32 x, Float32 y)   map-point coordinates
//

import Foundation
import MapKit

// MARK: - Config

/// Authoritative upstream the bundled data derives from. The `_EH` ("Europe-
/// centric, hostile-aware") ISO fields resolve real codes where the plain
/// `ISO_A2` ships `-99` (France, Norway, …), so most fallbacks below are belt
/// and suspenders.
let defaultURL =
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_countries.geojson"

// MARK: - Argument parsing

var localPath: String?
var urlString = defaultURL
var outPath = "WorldMap/countries.wmgb"

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--local": localPath = argIterator.next()
    case "--url": urlString = argIterator.next() ?? urlString
    case "--out": outPath = argIterator.next() ?? outPath
    default:
        FileHandle.standardError.write(Data("Unknown argument: \(arg)\n".utf8))
        exit(2)
    }
}

// MARK: - ID resolution (mirrors WorldMap.swift)

let isoFallbacks: [String: String] = [
    "France": "FR",
    "Norway": "NO",
    "Kosovo": "XK",
    "Indian Ocean Territories": "IO",
    "Clipperton Island": "CP",
]

/// Resolves a usable ISO alpha-2 id, or `nil` for non-countries shipped with a
/// `-99` placeholder and no fallback (reefs, bases, disputed zones).
func resolvedID(isoA2: String, name: String) -> String? {
    guard isoA2 == "-99" else { return isoA2 }
    return isoFallbacks[name]
}

/// First non-empty string value among the candidate keys. Natural Earth and the
/// older converted file disagree on property names, so we try both vocabularies.
func firstString(_ props: [String: Any], _ keys: [String]) -> String? {
    for key in keys {
        if let value = props[key] as? String, !value.isEmpty { return value }
    }
    return nil
}

// MARK: - Douglas-Peucker simplification (mirrors the former app-side code)

extension MKMapRect {
    var area: Double { width * height }
}

func perpendicularDistance(_ point: MKMapPoint, from a: MKMapPoint, to b: MKMapPoint) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let magnitude = (dx * dx + dy * dy).squareRoot()
    guard magnitude > 0 else {
        return ((point.x - a.x) * (point.x - a.x) + (point.y - a.y) * (point.y - a.y)).squareRoot()
    }
    let cross = abs((point.x - a.x) * dy - (point.y - a.y) * dx)
    return cross / magnitude
}

func douglasPeucker(_ points: [MKMapPoint], tolerance: Double) -> [MKMapPoint] {
    let n = points.count
    guard n > 2 else { return points }

    var keep = [Bool](repeating: false, count: n)
    keep[0] = true
    keep[n - 1] = true

    var stack: [(Int, Int)] = [(0, n - 1)]
    while let (first, last) = stack.popLast() {
        guard last > first + 1 else { continue }

        let start = points[first]
        let end = points[last]
        var maxDistance = 0.0
        var farthest = first

        for i in (first + 1)..<last {
            let distance = perpendicularDistance(points[i], from: start, to: end)
            if distance > maxDistance {
                maxDistance = distance
                farthest = i
            }
        }

        if maxDistance > tolerance {
            keep[farthest] = true
            stack.append((first, farthest))
            stack.append((farthest, last))
        }
    }

    return (0..<n).compactMap { keep[$0] ? points[$0] : nil }
}

func simplifiedOutline(of polygon: MKPolygon) -> [MKMapPoint] {
    let count = polygon.pointCount
    let points = Array(UnsafeBufferPointer(start: polygon.points(), count: count))
    guard count > 2 else { return points }

    let rect = polygon.boundingMapRect
    let diagonal = (rect.width * rect.width + rect.height * rect.height).squareRoot()
    let tolerance = diagonal * 0.005
    return douglasPeucker(points, tolerance: tolerance)
}

// MARK: - Load source GeoJSON

let sourceData: Data
if let localPath {
    print("Reading local GeoJSON: \(localPath)")
    guard let data = FileManager.default.contents(atPath: localPath) else {
        FileHandle.standardError.write(Data("Could not read \(localPath)\n".utf8))
        exit(1)
    }
    sourceData = data
} else {
    print("Downloading: \(urlString)")
    guard let url = URL(string: urlString), let data = try? Data(contentsOf: url) else {
        FileHandle.standardError.write(Data("Download failed: \(urlString)\n".utf8))
        exit(1)
    }
    sourceData = data
}
print("Source size: \(sourceData.count / 1_000_000) MB")

guard let features = try? MKGeoJSONDecoder().decode(sourceData) as? [MKGeoJSONFeature] else {
    FileHandle.standardError.write(Data("GeoJSON decode failed\n".utf8))
    exit(1)
}

// MARK: - Pass 1: collect raw exterior rings + seed metadata per country

struct Seed {
    var id: String
    var iso3: String
    var name: String
}

var rawPolygons: [String: [MKPolygon]] = [:]
var seedByID: [String: Seed] = [:]

for feature in features {
    guard let propsData = feature.properties,
        let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any]
    else { continue }

    // Accept both Natural Earth (`ISO_A2_EH`, `NAME`) and the older converted
    // file (`ISO3166-1-Alpha-2`, `name`) property vocabularies.
    let rawID =
        firstString(props, ["ISO_A2_EH", "ISO_A2", "ISO3166-1-Alpha-2"]) ?? "-99"
    guard let name = firstString(props, ["NAME", "NAME_EN", "ADMIN", "name"]) else { continue }
    guard let id = resolvedID(isoA2: rawID, name: name) else { continue }

    let iso3 = firstString(props, ["ISO_A3_EH", "ISO_A3", "ISO3166-1-Alpha-3", "ADM0_A3"]) ?? ""

    if seedByID[id] == nil {
        seedByID[id] = Seed(id: id, iso3: iso3, name: name)
    }

    for geometry in feature.geometry {
        if let polygon = geometry as? MKPolygon {
            rawPolygons[id, default: []].append(
                MKPolygon(points: polygon.points(), count: polygon.pointCount))
        } else if let multiPolygon = geometry as? MKMultiPolygon {
            for poly in multiPolygon.polygons {
                rawPolygons[id, default: []].append(
                    MKPolygon(points: poly.points(), count: poly.pointCount))
            }
        }
    }
}

// MARK: - Pass 2: drop tiny islands, simplify the rest

struct Country {
    let id: String
    let iso3: String
    let name: String
    let rings: [[MKMapPoint]]
}

var countries: [Country] = []

for (id, polygons) in rawPolygons {
    guard let largest = polygons.max(by: { $0.boundingMapRect.area < $1.boundingMapRect.area })
    else { continue }

    // Keep the mainland plus any island at least 0.5% of its size.
    let minIslandArea = largest.boundingMapRect.area * 0.005

    var rings: [[MKMapPoint]] = []
    for polygon in polygons {
        if polygon !== largest, polygon.boundingMapRect.area < minIslandArea { continue }
        let points = simplifiedOutline(of: polygon)
        guard points.count >= 3 else { continue }
        rings.append(points)
    }

    guard !rings.isEmpty, let seed = seedByID[id] else { continue }
    countries.append(Country(id: id, iso3: seed.iso3, name: seed.name, rings: rings))
}

countries.sort { $0.id < $1.id }  // deterministic output

// MARK: - Encode WMGB binary

func appendU16(_ data: inout Data, _ value: UInt16) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

func appendU32(_ data: inout Data, _ value: UInt32) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

func appendStr8(_ data: inout Data, _ string: String) {
    let bytes = Array(string.utf8.prefix(255))
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
}

func appendStr16(_ data: inout Data, _ string: String) {
    let bytes = Array(string.utf8.prefix(65535))
    appendU16(&data, UInt16(bytes.count))
    data.append(contentsOf: bytes)
}

var out = Data()
out.append(contentsOf: [0x57, 0x4D, 0x47, 0x42])  // "WMGB"
appendU32(&out, 1)  // version
appendU32(&out, UInt32(countries.count))

var totalPoints = 0
for country in countries {
    appendStr8(&out, country.id)
    appendStr8(&out, country.iso3)
    appendStr16(&out, country.name)
    appendU16(&out, UInt16(country.rings.count))
    for ring in country.rings {
        appendU32(&out, UInt32(ring.count))
        totalPoints += ring.count
        for point in ring {
            appendU32(&out, Float(point.x).bitPattern)
            appendU32(&out, Float(point.y).bitPattern)
        }
    }
}

let outURL = URL(fileURLWithPath: outPath)
do {
    try out.write(to: outURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Write failed: \(error)\n".utf8))
    exit(1)
}

print("Wrote \(countries.count) countries, \(totalPoints) points")
print("Output: \(outPath) (\(out.count / 1024) KB)")
