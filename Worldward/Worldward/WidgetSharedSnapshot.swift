import AppIntents
import CoreGraphics
import Foundation
import MapKit
import SwiftUI
import WidgetKit

/// A tiny, `Codable` summary of the user's travels, written by the app into the
/// shared App Group container and read by the widgets. Keeping the widget on a
/// snapshot — rather than opening SwiftData inside the extension — keeps it
/// lightweight and avoids relocating the app's store. Everything the widgets draw
/// is a plain value here (counts, flag emoji, and per-country tints), so the
/// extension never touches the model.
///
/// This file is a member of BOTH the app and the widget extension targets.
struct WidgetSnapshot: Codable, Hashable {
    var visitedCountries: Int
    var totalCountries: Int
    var visitedContinents: Int
    var totalContinents: Int

    /// Visited-country flag emoji, strongest bond first then alphabetical — the
    /// same order the dashboard uses for its flag strip.
    var flags: [String]

    /// ISO 3166-1 alpha-2 id → status rank for every visited country, so the map
    /// widget can tint each one. The rank is the country's `CountryStatus` index
    /// (1 = crossed … 4 = living); only visited countries appear.
    var tints: [String: Int]

    /// The user's appearance preference: "system", "light", or "dark".
    /// Written by the app so widgets can adapt their tint to match.
    var appTheme: String = "system"

    /// Share of the world's countries visited, `0...1`.
    var fraction: Double {
        totalCountries > 0 ? Double(visitedCountries) / Double(totalCountries) : 0
    }

    /// A friendly empty state for a fresh install, or when the app group isn't
    /// readable yet.
    static let placeholder = WidgetSnapshot(
        visitedCountries: 0, totalCountries: 195,
        visitedContinents: 0, totalContinents: 7, flags: [], tints: [:])

    /// A populated example used for the widget gallery and Xcode previews.
    static let sample = WidgetSnapshot(
        visitedCountries: 24, totalCountries: 195,
        visitedContinents: 4, totalContinents: 7,
        flags: [
            "🇯🇵", "🇫🇷", "🇮🇹", "🇪🇸", "🇩🇪", "🇵🇹", "🇬🇷", "🇳🇱", "🇧🇪", "🇨🇭",
            "🇺🇸", "🇨🇦", "🇲🇽", "🇧🇷", "🇦🇷", "🇿🇦", "🇪🇬", "🇲🇦", "🇦🇺", "🇹🇭",
            "🇻🇳", "🇰🇷", "🇮🇸", "🇳🇴",
        ],
        tints: [
            "JP": 2, "FR": 4, "IT": 2, "ES": 3, "DE": 2, "PT": 2, "GR": 2, "NL": 2,
            "US": 3, "CA": 2, "MX": 2, "BR": 2, "AR": 2, "ZA": 2, "EG": 1, "MA": 1,
            "AU": 2, "TH": 2, "VN": 1, "KR": 2, "IS": 2, "NO": 2,
        ])
}

extension WidgetSnapshot {
    private enum CodingKeys: String, CodingKey {
        case visitedCountries, totalCountries, visitedContinents, totalContinents, flags, tints,
            appTheme
    }

    /// Custom decoding so a snapshot written by an older app build (without
    /// `tints` or `appTheme`) still loads — new fields default to sensible
    /// values until the app rewrites the snapshot.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visitedCountries = try c.decode(Int.self, forKey: .visitedCountries)
        totalCountries = try c.decode(Int.self, forKey: .totalCountries)
        visitedContinents = try c.decode(Int.self, forKey: .visitedContinents)
        totalContinents = try c.decode(Int.self, forKey: .totalContinents)
        flags = try c.decode([String].self, forKey: .flags)
        tints = try c.decodeIfPresent([String: Int].self, forKey: .tints) ?? [:]
        appTheme = try c.decodeIfPresent(String.self, forKey: .appTheme) ?? "system"
    }
}

/// Reads and writes the shared `WidgetSnapshot`. The app writes after any change
/// to the catalog; the widgets read on every timeline refresh.
enum WidgetSnapshotStore {
    /// Must match the `com.apple.security.application-groups` entitlement on both
    /// the app and the widget extension.
    nonisolated static let appGroupID = "group.net.smigi.worldward"

    private static let fileName = "widget-snapshot.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Persist the latest snapshot and ask WidgetKit to redraw. A missing
    /// container — e.g. the app group isn't provisioned on a free team — is
    /// ignored so the app keeps working without widgets.
    static func write(_ snapshot: WidgetSnapshot) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The last snapshot the app wrote, or `.placeholder` if none is available.
    static func read() -> WidgetSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .placeholder }
        return snapshot
    }
}

// MARK: - World map geometry

/// One country's outline rings in MKMapPoint space (north-up, y increases south),
/// ready to be projected into a drawing rectangle.
struct CountryShape {
    let iso: String
    let rings: [[CGPoint]]
}

/// The decoded world outline plus the bounding box of every point, so a renderer
/// can fit the whole map into any rectangle.
struct WorldMap {
    let shapes: [CountryShape]
    let bounds: CGRect
}

/// Bridges the bundled `countries.wmgb` geometry to the widget. The widget can't
/// read the app's bundle, so the app copies the file into the shared App Group
/// container once; the widget decodes it from there and caches the result for the
/// life of the process.
enum WorldMapStore {
    nonisolated private static let fileName = "countries.wmgb"

    nonisolated private static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// App side: copy the bundled geometry into the shared container so the widget
    /// can draw the map. Re-copies only when the bundled file's size differs from
    /// the cached copy (i.e. a new release shipped new geometry), so it's a cheap
    /// no-op on every launch after the first.
    nonisolated static func cacheFromAppBundle() {
        guard let containerURL,
            let bundleURL = Bundle.main.url(forResource: "countries", withExtension: "wmgb"),
            let data = try? Data(contentsOf: bundleURL)
        else { return }
        let cachedSize = (try? containerURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard cachedSize != data.count else { return }
        try? data.write(to: containerURL, options: .atomic)
    }

    /// Widget side: the decoded geometry, cached for the lifetime of the
    /// extension process. Accessed only from the main actor (SwiftUI View bodies
    /// and TimelineProvider callbacks); the widget renders one timeline and exits,
    /// so concurrent access is impossible in practice.
    nonisolated(unsafe) private static var cached: WorldMap?
    static var shared: WorldMap? {
        if let cached { return cached }
        guard let containerURL, let data = try? Data(contentsOf: containerURL) else { return nil }
        cached = decode(data)
        return cached
    }

    /// Decodes the "WMGB" v1 binary into per-country `CGPoint` rings, mirroring the
    /// app's own reader. Coordinates are MKMapPoint values; the caller normalises
    /// them against `WorldMap.bounds` when drawing.
    private static func decode(_ data: Data) -> WorldMap? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> WorldMap? in
            var offset = 0
            let total = raw.count
            func need(_ n: Int) -> Bool { offset + n <= total }
            func readU8() -> UInt8? {
                guard need(1) else { return nil }
                defer { offset += 1 }
                return raw.load(fromByteOffset: offset, as: UInt8.self)
            }
            func readU16() -> UInt16? {
                guard need(2) else { return nil }
                defer { offset += 2 }
                return UInt16(
                    littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
            func readU32() -> UInt32? {
                guard need(4) else { return nil }
                defer { offset += 4 }
                return UInt32(
                    littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
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

            var shapes: [CountryShape] = []
            shapes.reserveCapacity(Int(count))
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude

            for _ in 0..<count {
                guard let idLen = readU8(), let id = readString(Int(idLen)),
                    let iso3Len = readU8(), readString(Int(iso3Len)) != nil,
                    let nameLen = readU16(), readString(Int(nameLen)) != nil,
                    let ringCount = readU16()
                else { return nil }

                var rings: [[CGPoint]] = []
                rings.reserveCapacity(Int(ringCount))
                for _ in 0..<ringCount {
                    guard let pointCount = readU32() else { return nil }
                    var points: [CGPoint] = []
                    points.reserveCapacity(Int(pointCount))
                    for _ in 0..<pointCount {
                        guard let x = readFloat(), let y = readFloat() else { return nil }
                        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        points.append(point)
                        minX = min(minX, point.x)
                        maxX = max(maxX, point.x)
                        minY = min(minY, point.y)
                        maxY = max(maxY, point.y)
                    }
                    rings.append(points)
                }
                shapes.append(CountryShape(iso: id, rings: rings))
            }

            guard maxX > minX, maxY > minY else { return nil }
            return WorldMap(
                shapes: shapes,
                bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
    }
}

// MARK: - Control Center actions

/// A one-shot request raised by the Control Center control (which runs in the
/// widget extension, outside the app) and consumed by the app on its next
/// activation. It travels through the App Group's shared `UserDefaults`; the app
/// then runs its own location + status-picker flow, which needs permissions and
/// the model the extension doesn't have.
enum WidgetActionStore {
    private nonisolated static let markHereKey = "pendingMarkHere"

    private nonisolated static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupID)
    }

    /// Extension side: ask the app to mark the user's current country. Called from
    /// the control's nonisolated `perform()`, so it must not require the main actor;
    /// it only touches thread-safe `UserDefaults`.
    nonisolated static func requestMarkHere() {
        defaults?.set(true, forKey: markHereKey)
    }

    /// App side: returns `true` once when a request is pending, then clears it.
    static func consumeMarkHere() -> Bool {
        guard let defaults, defaults.bool(forKey: markHereKey) else { return false }
        defaults.removeObject(forKey: markHereKey)
        return true
    }
}

/// The action the Control Center control opens the app to perform. `OpenIntent`
/// requires a target parameter even when there's only one choice.
enum ControlTarget: String, AppEnum {
    case markHere

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Action")
    static let caseDisplayRepresentations: [ControlTarget: DisplayRepresentation] = [
        .markHere: "Mark where I am"
    ]
}

/// Opens Worldward and asks it to mark the user's current country. A Control
/// Center control only launches the app when its action is an `OpenIntent` (not
/// merely `openAppWhenRun`), and the type must belong to BOTH the app and the
/// widget extension — hence it lives in this shared file. The heavy lifting
/// (location + status picker) happens app-side once `WidgetActionStore` is read.
struct MarkHereOpenIntent: OpenIntent {
    static let title: LocalizedStringResource = "Mark where I am"
    static let description = IntentDescription("Marks your current country in Worldward.")

    @Parameter(title: "Action")
    var target: ControlTarget

    init() { self.target = .markHere }
    init(target: ControlTarget) { self.target = target }

    func perform() async throws -> some IntentResult {
        WidgetActionStore.requestMarkHere()
        return .result()
    }
}

// MARK: - Shared map view

/// The map's yellow-to-orange status scale (mirrors `CountryStatus.color`), keyed
/// by the status rank in `WidgetSnapshot.tints`. Rank 0 — or any country with no
/// recorded status — draws as quiet, unvisited land.
func worldwardLandColor(rank: Int) -> Color {
    switch rank {
    case 1: Color(red: 1.00, green: 0.87, blue: 0.40)  // crossed
    case 2: Color(red: 1.00, green: 0.72, blue: 0.20)  // visited
    case 3: Color(red: 0.96, green: 0.51, blue: 0.09)  // lived
    case 4: Color(red: 0.84, green: 0.30, blue: 0.05)  // living
    default: Color(red: 0.82, green: 0.85, blue: 0.88)  // unvisited
    }
}

/// Draws the world tinted by where you've been, from the shared geometry. Mercator
/// stretches the poles, so it fits a latitude band (≈83°N to 68°S) and clips to it
/// — keeping the inhabited world large while still showing the northern rim of
/// Antarctica. Ocean is transparent so the caller's background shows through.
/// Shared by the map widget and the shareable map card.
struct WorldMapCanvas: View {
    /// ISO 3166-1 alpha-2 id → status rank for visited countries.
    let tints: [String: Int]

    var body: some View {
        Canvas { context, size in
            guard let map = WorldMapStore.shared else { return }
            let northY = MKMapPoint(CLLocationCoordinate2D(latitude: 83, longitude: 0)).y
            let southY = MKMapPoint(CLLocationCoordinate2D(latitude: -68, longitude: 0)).y
            let region = CGRect(
                x: map.bounds.minX, y: northY,
                width: map.bounds.width, height: southY - northY)

            let scale = min(size.width / region.width, size.height / region.height)
            let drawWidth = region.width * scale
            let drawHeight = region.height * scale
            let originX = (size.width - drawWidth) / 2
            let originY = (size.height - drawHeight) / 2
            let offsetX = originX - region.minX * scale
            let offsetY = originY - region.minY * scale

            func project(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x * scale + offsetX, y: point.y * scale + offsetY)
            }

            context.clip(
                to: Path(CGRect(x: originX, y: originY, width: drawWidth, height: drawHeight)))

            for shape in map.shapes {
                var path = Path()
                for ring in shape.rings where ring.count >= 3 {
                    path.move(to: project(ring[0]))
                    for point in ring.dropFirst() { path.addLine(to: project(point)) }
                    path.closeSubpath()
                }
                context.fill(path, with: .color(worldwardLandColor(rank: tints[shape.iso] ?? 0)))
            }
        }
    }
}
