/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents
import CoreGraphics
import Foundation
import MapKit
import SwiftUI
import WidgetKit

// MARK: - Widget Snapshot

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

    /// The next planned journeys, soonest first, capped at three by the writer.
    /// A short list — rather than just the next trip — lets the widget roll over
    /// to the following journey on its own when one ends, even if the app isn't
    /// launched for weeks. `endDate` lets it show an "underway" state mid-trip.
    var upcomingTrips: [UpcomingTrip] = []

    /// A planned trip as the widget needs it: title, pre-joined flag emoji
    /// (mirroring `Trip.flags`), and the date range.
    struct UpcomingTrip: Codable, Hashable {
        var title: String
        var flags: String
        var startDate: Date
        var endDate: Date
    }

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
        ],
        upcomingTrips: [
            UpcomingTrip(
                title: "Japan & Korea", flags: "🇯🇵 🇰🇷",
                startDate: Date.now.addingTimeInterval(12 * 86_400),
                endDate: Date.now.addingTimeInterval(19 * 86_400))
        ])
}

extension WidgetSnapshot {
    private enum CodingKeys: String, CodingKey {
        case visitedCountries, totalCountries, visitedContinents, totalContinents, flags, tints,
            appTheme, upcomingTrips
    }

    /// Custom decoding so a snapshot written by an older app build (without
    /// `tints`, `appTheme`, or `upcomingTrips`) still loads — new fields default
    /// to sensible values until the app rewrites the snapshot.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visitedCountries = try c.decode(Int.self, forKey: .visitedCountries)
        totalCountries = try c.decode(Int.self, forKey: .totalCountries)
        visitedContinents = try c.decode(Int.self, forKey: .visitedContinents)
        totalContinents = try c.decode(Int.self, forKey: .totalContinents)
        flags = try c.decode([String].self, forKey: .flags)
        tints = try c.decodeIfPresent([String: Int].self, forKey: .tints) ?? [:]
        appTheme = try c.decodeIfPresent(String.self, forKey: .appTheme) ?? "system"
        upcomingTrips = try c.decodeIfPresent([UpcomingTrip].self, forKey: .upcomingTrips) ?? []
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
    /// ignored so the app keeps working without widgets. An unchanged snapshot
    /// is skipped entirely (the app writes once on every launch), preserving
    /// the system's widget-refresh budget.
    static func write(_ snapshot: WidgetSnapshot) {
        guard snapshot != read() else { return }
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
    /// no-op on every launch after the first. A successful copy asks WidgetKit to
    /// redraw, so the map widget fills in as soon as the geometry exists — the
    /// snapshot write no longer reloads unconditionally.
    nonisolated static func cacheFromAppBundle() {
        guard let containerURL,
            let bundleURL = Bundle.main.url(forResource: "countries", withExtension: "wmgb"),
            let data = try? Data(contentsOf: bundleURL)
        else { return }
        let cachedSize = (try? containerURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard cachedSize != data.count else { return }
        try? data.write(to: containerURL, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Widget side: the decoded geometry, cached for the lifetime of the
    /// extension process. Accessed only from the main actor (SwiftUI View bodies
    /// and TimelineProvider callbacks); the widget renders one timeline and exits,
    /// so concurrent access is impossible in practice.
    nonisolated(unsafe) private static var cached: WorldMap?
    static var shared: WorldMap? {
        if let cached { return cached }
        // The App Group copy is written by the app after first launch; fall back
        // to reading the app's own bundle so the launch map preview works on a
        // fresh install too. In the widget process the bundle holds no such
        // resource, so the fallback is a harmless no-op there.
        let data =
            containerURL.flatMap { try? Data(contentsOf: $0) }
            ?? Bundle.main.url(forResource: "countries", withExtension: "wmgb")
                .flatMap { try? Data(contentsOf: $0) }
        guard let data else { return nil }
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

// MARK: - Packing widget

/// The packing list of one trip — the trip underway, else the soonest upcoming
/// one that has a list — as the interactive packing widget needs it. Like
/// `WidgetSnapshot` it's a plain-value stand-in for the model, but this file is
/// written from BOTH sides: the app rewrites it from the model, and the widget's
/// toggle intent rewrites it optimistically so the checkmark appears before the
/// app has run. `PackingToggleStore` carries the toggles back to the model.
struct PackingSnapshot: Codable, Hashable {
    var tripTitle: String = ""
    var tripFlags: String = ""
    /// Lets the widget retire a finished trip's list at render time, since the
    /// app may not run again for weeks after the journey ends.
    var tripEndDate: Date = .distantPast
    /// The app's appearance preference, mirroring `WidgetSnapshot.appTheme`.
    var appTheme: String = "system"
    /// Items in the app's grouped display order (containers, then ungrouped).
    var items: [Item] = []

    /// One checkable row: the `PackingItem.dedupID`, what to pack, and how many.
    struct Item: Codable, Hashable {
        var id: String
        var title: String
        var quantity: Int
        var isPacked: Bool
    }

    var packedCount: Int { items.filter(\.isPacked).count }

    /// A fresh install, or no upcoming trip with a packing list.
    static let empty = PackingSnapshot()

    /// A populated example for the widget gallery and previews.
    static let sample = PackingSnapshot(
        tripTitle: "Japan & Korea", tripFlags: "🇯🇵 🇰🇷",
        tripEndDate: Date.now.addingTimeInterval(19 * 86_400),
        items: [
            Item(id: "1", title: "Passport", quantity: 1, isPacked: true),
            Item(id: "2", title: "Chargers", quantity: 3, isPacked: true),
            Item(id: "3", title: "Rail pass", quantity: 2, isPacked: false),
            Item(id: "4", title: "Camera", quantity: 1, isPacked: false),
            Item(id: "5", title: "Walking shoes", quantity: 1, isPacked: false),
            Item(id: "6", title: "Adapter", quantity: 2, isPacked: false),
            Item(id: "7", title: "Guidebook", quantity: 1, isPacked: false),
        ])
}

/// Reads and writes the shared `PackingSnapshot`. Kept apart from
/// `WidgetSnapshotStore`'s file because the widget extension rewrites this one
/// (optimistic toggles) and must not race the app's launch-time write of the
/// main snapshot.
enum PackingSnapshotStore {
    /// The packing widget's kind, so app-side writes can reload just it.
    nonisolated static let widgetKind = "WorldwardPacking"

    private nonisolated static let fileName = "packing-snapshot.json"

    private nonisolated static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Persist the snapshot, skipping unchanged writes like the main store. The
    /// toggle intent passes `reloadWidget: false` — WidgetKit reloads the tapped
    /// widget on its own after an interactive intent, so a second reload would
    /// only burn refresh budget. Unannotated (not `nonisolated`) on purpose: the
    /// snapshot's Codable conformance is main-actor-isolated in the app target,
    /// and every caller in both targets is already on the right actor.
    static func write(_ snapshot: PackingSnapshot, reloadWidget: Bool = true) {
        guard snapshot != read() else { return }
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
        if reloadWidget { WidgetCenter.shared.reloadTimelines(ofKind: widgetKind) }
    }

    /// The last snapshot written by either side, or `.empty`.
    static func read() -> PackingSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(PackingSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}

/// Toggles made on the widget, awaiting the app. Like `WidgetActionStore`, but
/// keyed: each entry maps a `PackingItem.dedupID` to its *desired* packed state
/// — storing the target rather than "flip" keeps a double-tap idempotent no
/// matter how many queue up before the app next runs. The app consumes the lot
/// on activation and applies them to the model; ids that no longer exist
/// (item deleted, list replaced) are silently dropped.
enum PackingToggleStore {
    private nonisolated static let key = "pendingPackingToggles"

    private nonisolated static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupID)
    }

    /// Extension side: remember that `id` should end up `packed`.
    nonisolated static func record(id: String, packed: Bool) {
        guard let defaults else { return }
        var pending = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        pending[id] = packed
        defaults.set(pending, forKey: key)
    }

    /// App side: all pending toggles, cleared on read.
    static func consume() -> [String: Bool] {
        guard let defaults,
            let pending = defaults.dictionary(forKey: key) as? [String: Bool],
            !pending.isEmpty
        else { return [:] }
        defaults.removeObject(forKey: key)
        return pending
    }
}

/// Checks an item off (or back on) the packing list, straight from the widget.
/// Runs in the widget extension, which deliberately has no SwiftData — so it
/// records the toggle for the app and rewrites the shared snapshot so the row
/// redraws immediately. Hidden from Shortcuts: a raw item id is meaningless as
/// a user-facing action, and the widget is its only caller.
struct TogglePackingItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Packing Item"
    static let description = IntentDescription("Checks an item off a trip's packing list.")
    static let isDiscoverable = false

    @Parameter(title: "Item")
    var itemID: String

    @Parameter(title: "Packed")
    var packed: Bool

    init() {}
    init(itemID: String, packed: Bool) {
        self.itemID = itemID
        self.packed = packed
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PackingToggleStore.record(id: itemID, packed: packed)
        var snapshot = PackingSnapshotStore.read()
        if let index = snapshot.items.firstIndex(where: { $0.id == itemID }) {
            snapshot.items[index].isPacked = packed
            PackingSnapshotStore.write(snapshot, reloadWidget: false)
        }
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
    // Plan-only blues (mirror `PlanStatus.color`), used by the app's launch map
    // preview. Widget snapshots never write these ranks.
    case 5: Color(red: 0.40, green: 0.72, blue: 0.95)  // wishlist
    case 6: Color(red: 0.13, green: 0.42, blue: 0.80)  // planning
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
