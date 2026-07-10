#!/usr/bin/env swift
//
//  generate_geo.swift
//
//  Dev-time tool — NOT part of the app target.
//
//  Produces the packed-binary geometry files the app bundles and reads at
//  launch. Doing the expensive Natural Earth decode + Douglas-Peucker
//  simplification here, once per release, means no user device ever pays that
//  cost and no one ever downloads the source data — the app ships the small,
//  pre-simplified result.
//
//  Two modes:
//    default   — countries (admin-0) → `countries.wmgb`, read by
//                `loadBundledGeo` in GeoLoading.swift.
//    --admin1  — states/provinces (admin-1) → `regions.wmgb`, an *indexed*
//                file so the app can decode a single country's regions lazily
//                without parsing the whole file.
//
//  Borders change rarely, so re-run this only when you want fresh map data or
//  change the simplification, then drop the new file into Worldward/Worldward/
//  (the synchronized folder bundles it automatically).
//
//  Usage:
//      swift Tools/generate_geo.swift                       # countries, download from nvkelso
//      swift Tools/generate_geo.swift --admin1              # regions, download from nvkelso
//      swift Tools/generate_geo.swift --local path.geojson  # use a local file
//      swift Tools/generate_geo.swift --out path.wmgb       # custom output path
//      swift Tools/generate_geo.swift --admin1 --only US,GR # subset, for experiments
//      swift Tools/generate_geo.swift --admin1 --tolerance 0.005
//                                                           # DP tolerance as a fraction of
//                                                           # each ring's bbox diagonal
//      swift Tools/generate_geo.swift --island-km 25        # keep islands ≥ 25 km across
//
//  Requires macOS (uses MapKit's MKGeoJSONDecoder).
//
//  Country format ("WMGB" v1), little-endian — kept in sync with loadBundledGeo():
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
//  Region format ("WMRB" v1), little-endian — indexed for lazy per-country reads:
//      magic   : 4 bytes  'W','M','R','B'
//      version : UInt32   = 1
//      count   : UInt32   number of countries in the index
//      index, per country (sorted by id):
//          id      : 2 bytes  ASCII ISO 3166-1 alpha-2
//          offset  : UInt32   absolute file offset of this country's block
//          length  : UInt32   byte length of the block
//      per country block:
//          regionCnt : UInt16
//          per region:
//              code    : UInt8 length  + UTF-8 bytes   (ISO 3166-2, e.g. "US-HI")
//              name    : UInt16 length + UTF-8 bytes
//              ringCnt : UInt16
//              per ring:
//                  ptCount : UInt32
//                  points  : ptCount × (Float32 x, Float32 y)   map-point coordinates
//

import Foundation
import MapKit

// MARK: - Config

/// Authoritative upstream the bundled data derives from. The `_EH` ("Europe-
/// centric, hostile-aware") ISO fields resolve real codes where the plain
/// `ISO_A2` ships `-99` (France, Norway, …), so most fallbacks below are belt
/// and suspenders.
let defaultCountriesURL =
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_countries.geojson"
let defaultRegionsURL =
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_1_states_provinces.geojson"

// MARK: - Argument parsing

var localPath: String?
var urlOverride: String?
var outOverride: String?
var admin1Mode = false
var relativeTolerance = 0.005
var onlyCountries: Set<String>?

/// Islands at least this many km across (bbox diagonal) are always kept, however
/// small they are relative to their country's mainland. The purely relative 0.5%
/// rule alone erased whole territories of large countries — Hawaii, Kaliningrad,
/// most Greek islands — leaving un-tappable blank spots on the map. 25 km keeps
/// every inhabited territory of note while dropping thousands of specks;
/// the countries file grows from ~345 KB to ~675 KB.
var islandFloorKm = 25.0

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--local": localPath = argIterator.next()
    case "--url": urlOverride = argIterator.next()
    case "--out": outOverride = argIterator.next()
    case "--admin1": admin1Mode = true
    case "--tolerance":
        guard let raw = argIterator.next(), let value = Double(raw), value > 0 else {
            FileHandle.standardError.write(Data("--tolerance needs a positive number\n".utf8))
            exit(2)
        }
        relativeTolerance = value
    case "--island-km":
        guard let raw = argIterator.next(), let value = Double(raw), value >= 0 else {
            FileHandle.standardError.write(Data("--island-km needs a non-negative number\n".utf8))
            exit(2)
        }
        islandFloorKm = value
    case "--only":
        guard let raw = argIterator.next() else {
            FileHandle.standardError.write(Data("--only needs a comma-separated ISO2 list\n".utf8))
            exit(2)
        }
        onlyCountries = Set(raw.split(separator: ",").map { $0.uppercased() })
    default:
        FileHandle.standardError.write(Data("Unknown argument: \(arg)\n".utf8))
        exit(2)
    }
}

let urlString = urlOverride ?? (admin1Mode ? defaultRegionsURL : defaultCountriesURL)
let outPath = outOverride ?? (admin1Mode ? "Worldward/regions.wmgb" : "Worldward/countries.wmgb")

// MARK: - ID resolution (mirrors Worldward.swift)

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

/// A plausible ISO 3166-1 alpha-2 country id.
func isValidISO2(_ value: String) -> Bool {
    value.count == 2 && value.allSatisfy { ("A"..."Z").contains($0) }
}

/// A plausible ISO 3166-2 region code ("US-HI", "FR-ARA", "GB-ENG", …).
func isValidRegionCode(_ value: String) -> Bool {
    value.range(of: "^[A-Z]{2}-[A-Z0-9]{1,3}$", options: .regularExpression) != nil
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
    let tolerance = diagonal * relativeTolerance
    return douglasPeucker(points, tolerance: tolerance)
}

/// Extracts every polygon from a feature's geometry, copied so it owns its points.
func extractPolygons(from feature: MKGeoJSONFeature) -> [MKPolygon] {
    var result: [MKPolygon] = []
    for geometry in feature.geometry {
        if let polygon = geometry as? MKPolygon {
            result.append(MKPolygon(points: polygon.points(), count: polygon.pointCount))
        } else if let multiPolygon = geometry as? MKMultiPolygon {
            for poly in multiPolygon.polygons {
                result.append(MKPolygon(points: poly.points(), count: poly.pointCount))
            }
        }
    }
    return result
}

/// True when the polygon's bbox diagonal is at least `islandFloorKm` — an
/// absolute keep-threshold that doesn't scale with the country's mainland, so
/// big countries don't lose whole distant territories to the relative rule.
func meetsAbsoluteFloor(_ polygon: MKPolygon) -> Bool {
    guard islandFloorKm > 0 else { return false }
    let rect = polygon.boundingMapRect
    let diagonalPts = (rect.width * rect.width + rect.height * rect.height).squareRoot()
    let midLat = MKMapPoint(x: rect.midX, y: rect.midY).coordinate.latitude
    let diagonalMeters = diagonalPts * MKMetersPerMapPointAtLatitude(midLat)
    return diagonalMeters >= islandFloorKm * 1000
}

/// Culls tiny islands (below `islandFraction` of the largest polygon's bbox area
/// *and* below the absolute `islandFloorKm` floor) and simplifies the survivors.
/// Shared by both modes so a country and its regions get the same treatment.
func culledSimplifiedRings(from polygons: [MKPolygon], islandFraction: Double = 0.005)
    -> [[MKMapPoint]]
{
    guard let largest = polygons.max(by: { $0.boundingMapRect.area < $1.boundingMapRect.area })
    else { return [] }

    let minIslandArea = largest.boundingMapRect.area * islandFraction

    var rings: [[MKMapPoint]] = []
    for polygon in polygons {
        if polygon !== largest, polygon.boundingMapRect.area < minIslandArea,
            !meetsAbsoluteFloor(polygon)
        { continue }
        let points = simplifiedOutline(of: polygon)
        guard points.count >= 3 else { continue }
        rings.append(points)
    }
    return rings
}

// MARK: - Binary encoding helpers

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

func appendRings(_ data: inout Data, _ rings: [[MKMapPoint]]) -> Int {
    var totalPoints = 0
    appendU16(&data, UInt16(rings.count))
    for ring in rings {
        appendU32(&data, UInt32(ring.count))
        totalPoints += ring.count
        for point in ring {
            appendU32(&data, Float(point.x).bitPattern)
            appendU32(&data, Float(point.y).bitPattern)
        }
    }
    return totalPoints
}

// MARK: - Countries (admin-0) → WMGB v1

func generateCountries(from features: [MKGeoJSONFeature]) -> Data {
    struct Seed {
        var id: String
        var iso3: String
        var name: String
    }

    // Pass 1: collect raw exterior rings + seed metadata per country.
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

        rawPolygons[id, default: []].append(contentsOf: extractPolygons(from: feature))
    }

    // Territorial reassignments. Natural Earth's default "de facto" view places
    // Crimea under Russia; Worldward shows it as part of Ukraine. Any polygon of
    // the `from` country whose bbox centre falls inside the lon/lat box moves to
    // the `to` country before culling, so it fills and hit-tests as `to`. If a
    // future Natural Earth release reassigns the territory upstream, the box
    // simply matches nothing and this is a no-op.
    let reassignments: [(from: String, to: String, minLon: Double, maxLon: Double,
        minLat: Double, maxLat: Double)] = [
        ("RU", "UA", 31.5, 37.5, 43.8, 46.7)  // Crimea
    ]
    for rule in reassignments {
        guard let source = rawPolygons[rule.from] else { continue }
        var kept: [MKPolygon] = []
        var moved: [MKPolygon] = []
        for polygon in source {
            let rect = polygon.boundingMapRect
            let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
            let inside = center.longitude >= rule.minLon && center.longitude <= rule.maxLon
                && center.latitude >= rule.minLat && center.latitude <= rule.maxLat
            if inside { moved.append(polygon) } else { kept.append(polygon) }
        }
        guard !moved.isEmpty else { continue }
        rawPolygons[rule.from] = kept
        rawPolygons[rule.to, default: []].append(contentsOf: moved)
        print("Reassigned \(moved.count) polygon(s) \(rule.from) → \(rule.to)")
    }

    // Pass 2: drop tiny islands, simplify the rest.
    struct Country {
        let id: String
        let iso3: String
        let name: String
        let rings: [[MKMapPoint]]
    }

    var countries: [Country] = []
    for (id, polygons) in rawPolygons {
        let rings = culledSimplifiedRings(from: polygons)
        guard !rings.isEmpty, let seed = seedByID[id] else { continue }
        countries.append(Country(id: id, iso3: seed.iso3, name: seed.name, rings: rings))
    }

    countries.sort { $0.id < $1.id }  // deterministic output

    var out = Data()
    out.append(contentsOf: [0x57, 0x4D, 0x47, 0x42])  // "WMGB"
    appendU32(&out, 1)  // version
    appendU32(&out, UInt32(countries.count))

    var totalPoints = 0
    for country in countries {
        appendStr8(&out, country.id)
        appendStr8(&out, country.iso3)
        appendStr16(&out, country.name)
        totalPoints += appendRings(&out, country.rings)
    }

    print("Wrote \(countries.count) countries, \(totalPoints) points")
    return out
}

// MARK: - Regions (admin-1) → WMRB v1

func generateRegions(from features: [MKGeoJSONFeature]) -> Data {
    struct RegionSeed {
        var code: String
        var name: String
    }

    // Pass 1: group raw polygons by parent country and region code. A dictionary
    // per country merges the occasional duplicate feature for one code.
    var rawByCountry: [String: [String: [MKPolygon]]] = [:]
    var seedsByCountry: [String: [String: RegionSeed]] = [:]
    var skipped = 0

    for feature in features {
        guard let propsData = feature.properties,
            let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any]
        else { continue }

        // Natural Earth admin-1 uses lowercase keys; accept uppercase variants
        // for safety. Some `iso_3166_2` values carry a trailing "~" marking a
        // Natural Earth-invented subdivision — strip it before validating.
        var code = firstString(props, ["iso_3166_2", "ISO_3166_2"]) ?? ""
        if code.hasSuffix("~") { code = String(code.dropLast()) }

        let isoA2 = firstString(props, ["iso_a2", "ISO_A2", "iso_a2_eh", "ISO_A2_EH"]) ?? ""

        // Parent country: prefer the region code's own prefix, fall back to the
        // feature's country field.
        let parent: String
        if isValidRegionCode(code) {
            parent = String(code.prefix(2))
        } else if isValidISO2(isoA2) {
            parent = isoA2
            // No usable ISO 3166-2 code — fall back to Natural Earth's stable
            // internal id ("USA-3563") so the region still round-trips.
            guard let adm1 = firstString(props, ["adm1_code", "ADM1_CODE"]) else {
                skipped += 1
                continue
            }
            code = adm1
        } else {
            skipped += 1
            continue
        }

        if let only = onlyCountries, !only.contains(parent) { continue }

        guard let name = firstString(props, ["name", "NAME", "name_en", "NAME_EN", "gn_name"])
        else {
            skipped += 1
            continue
        }

        if seedsByCountry[parent]?[code] == nil {
            seedsByCountry[parent, default: [:]][code] = RegionSeed(code: code, name: name)
        }
        rawByCountry[parent, default: [:]][code, default: []].append(
            contentsOf: extractPolygons(from: feature))
    }

    // Pass 2: cull + simplify per region, encode one block per country.
    struct CountryBlock {
        let id: String
        let block: Data
        let regionCount: Int
        let pointCount: Int
    }

    var blocks: [CountryBlock] = []
    for (countryID, regions) in rawByCountry {
        var block = Data()
        var encoded: [(code: String, name: String, rings: [[MKMapPoint]])] = []

        for (code, polygons) in regions {
            let rings = culledSimplifiedRings(from: polygons)
            guard !rings.isEmpty, let seed = seedsByCountry[countryID]?[code] else { continue }
            encoded.append((code, seed.name, rings))
        }
        guard !encoded.isEmpty else { continue }

        encoded.sort { $0.code < $1.code }  // deterministic output

        var points = 0
        appendU16(&block, UInt16(encoded.count))
        for region in encoded {
            appendStr8(&block, region.code)
            appendStr16(&block, region.name)
            points += appendRings(&block, region.rings)
        }
        blocks.append(
            CountryBlock(id: countryID, block: block, regionCount: encoded.count, pointCount: points))
    }

    blocks.sort { $0.id < $1.id }  // deterministic output

    // Header + index, then the blocks at their recorded offsets.
    var out = Data()
    out.append(contentsOf: [0x57, 0x4D, 0x52, 0x42])  // "WMRB"
    appendU32(&out, 1)  // version
    appendU32(&out, UInt32(blocks.count))

    let indexEntrySize = 2 + 4 + 4
    var offset = out.count + blocks.count * indexEntrySize
    for block in blocks {
        out.append(contentsOf: Array(block.id.utf8))  // exactly 2 ASCII bytes
        appendU32(&out, UInt32(offset))
        appendU32(&out, UInt32(block.block.count))
        offset += block.block.count
    }
    for block in blocks {
        out.append(block.block)
    }

    // Size report — the whole point of the first run.
    let totalRegions = blocks.reduce(0) { $0 + $1.regionCount }
    let totalPoints = blocks.reduce(0) { $0 + $1.pointCount }
    print("Wrote \(blocks.count) countries, \(totalRegions) regions, \(totalPoints) points")
    if skipped > 0 { print("Skipped \(skipped) features without a usable country or code") }

    print("\nLargest countries by encoded size:")
    for block in blocks.sorted(by: { $0.block.count > $1.block.count }).prefix(25) {
        let kb = Double(block.block.count) / 1024
        print(
            String(
                format: "  %@  %7.1f KB  %3d regions  %6d points",
                block.id, kb, block.regionCount, block.pointCount))
    }
    return out
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

// MARK: - Generate + write

let out = admin1Mode ? generateRegions(from: features) : generateCountries(from: features)

let outURL = URL(fileURLWithPath: outPath)
do {
    try out.write(to: outURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Write failed: \(error)\n".utf8))
    exit(1)
}

print("\nOutput: \(outPath) (\(out.count / 1024) KB)")
