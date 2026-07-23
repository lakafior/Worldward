/// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if DEBUG
    import Foundation
    import SwiftData
    import SwiftUI

    /// The App Store screenshot targets. A launch argument (`-screen <name>`) picks
    /// one; the app then renders directly to that screen so a headless XCUITest run
    /// can capture it without tapping through localized UI. See `ScreenshotSupport`.
    enum ScreenshotScreen: String {
        case map, been, going, countryDetail, trip, packing, stats, achievements, wrapped, share
        /// watchOS-only: the "Now" glance page. The watch reuses `been` (its Been
        /// page), `going` (its trips list) and `trip` (a trip's detail), so the
        /// two platforms name the same screens the same way.
        case now
    }

    /// DEBUG-only harness that turns launch arguments into a seeded, deterministic
    /// app state for App Store screenshot automation. Never touches the user's real
    /// store — it builds a throwaway in-memory container populated with demo data.
    ///
    /// Launch arguments:
    ///   `-UITEST`                 activate the harness (in-memory seeded store)
    ///   `-screen <name>`          which `ScreenshotScreen` to open
    ///   `-appearance light|dark`  force the color scheme
    enum ScreenshotSupport {
        static let launchFlag = "-UITEST"

        /// The country opened for the `countryDetail` screen (a rich, multi-visit one).
        static let demoCountryID = "JP"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(launchFlag)
        }

        static var screen: ScreenshotScreen? {
            argValue("-screen").flatMap(ScreenshotScreen.init(rawValue:))
        }

        /// `true` when this run is capturing exactly `target`. Child views that own
        /// a deeper presentation (Statistics, the trip editor, Wrapped, Share) call
        /// this on appear to present themselves — no tapping, no localized lookups.
        static func isCapturing(_ target: ScreenshotScreen) -> Bool {
            isActive && screen == target
        }

        /// `true` for any screen reached *through* the Statistics sheet.
        static var needsStatistics: Bool {
            isCapturing(.stats) || isCapturing(.wrapped) || isCapturing(.share)
        }

        static var forcedColorScheme: ColorScheme? {
            switch argValue("-appearance") {
            case "dark": .dark
            case "light": .light
            default: nil
            }
        }

        private static func argValue(_ key: String) -> String? {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        // MARK: - Seeded container

        /// An in-memory container seeded with the demo dataset. Replaces the real
        /// store entirely for the run, so nothing on disk is read or written.
        static func makeSeededContainer(schema: Schema) -> ModelContainer {
            let config = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let container = try! ModelContainer(for: schema, configurations: [config])
            seed(container)
            return container
        }

        private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
        }

        /// A date `days` from today. The demo trip is anchored relative to *now* so
        /// it always lands in "Upcoming" no matter when the screenshots are run.
        private static func daysFromNow(_ days: Int) -> Date {
            Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        }

        /// Populate the container: the full country catalog (so the map draws and the
        /// lists are complete), a well-travelled set of statuses, dated visits across
        /// several years (for Statistics / Timeline / Wrapped), and one polished
        /// upcoming trip with an itinerary and a grouped packing list.
        static func seed(_ container: ModelContainer) {
            let ctx = ModelContext(container)

            // 1) Full catalog — mirror ContentView.seedDatabase so ids/continents match.
            var byID: [String: Country] = [:]
            #if os(watchOS)
                // The watch app doesn't bundle `countries.wmgb` — 675 KB of polygons
                // for a map it never draws — so the catalog comes from the ISO →
                // continent table the geo seed is filtered against anyway. Only ids
                // and continents matter here: `Country.localizedName` resolves the
                // display name from Foundation's region catalogue, and the flag is
                // derived from the id, so nothing visible is lost.
                for (id, continent) in Continents.byISO {
                    let c = Country(id: id, name: id, continent: continent)
                    ctx.insert(c)
                    byID[id] = c
                }
            #else
                if let bundled = loadBundledGeo() {
                    for s in bundled.seeds where Continents.byISO[s.id] != nil {
                        let c = Country(
                            id: s.id, iso3: s.iso3, name: s.name,
                            continent: Continents.name(for: s.id))
                        ctx.insert(c)
                        byID[s.id] = c
                    }
                }
            #endif

            // 2) Statuses — a believable, well-filled traveller.
            func set(_ id: String, _ status: CountryStatus) { byID[id]?.status = status }
            func plan(_ id: String, _ p: PlanStatus) { byID[id]?.planStatus = p }
            [
                "FR", "DE", "ES", "IT", "NL", "CZ", "AT", "CH", "PT", "GR", "HR", "SE",
                "NO", "DK", "FI", "IE", "BE", "HU", "SK", "SI", "US", "CA", "JP", "TH",
                "MA", "TR", "AE", "EG", "MX", "AU",
            ].forEach { set($0, .visited) }
            set("PL", .living)
            set("GB", .lived)
            ["LU", "LI", "VA", "SM"].forEach { set($0, .crossed) }
            ["IS", "NZ", "PE", "KR", "IN"].forEach { plan($0, .wishlist) }
            ["CR", "ZA"].forEach { plan($0, .planning) }

            // 3) Dated visits across years — feeds charts, streaks, timeline, Wrapped.
            func visit(_ id: String, _ y: Int, _ m: Int, _ d: Int, _ note: String = "") {
                guard let c = byID[id] else { return }
                ctx.insert(Visit(date: date(y, m, d), notes: note, country: c))
            }
            visit("FR", 2019, 6, 12, "Paris — the Louvre at dusk.")
            visit("IT", 2019, 9, 3, "Rome, then Florence by train.")
            visit("BE", 2019, 11, 16, "Bruges in the fog.")
            visit("HR", 2020, 8, 22, "Sailing the Dalmatian coast.")
            visit("ES", 2021, 7, 20, "Barcelona in the summer heat.")
            visit("PT", 2021, 10, 5, "Lisbon miradouros.")
            visit("NL", 2021, 4, 18, "Tulip season outside Amsterdam.")
            visit("JP", 2022, 4, 2, "Cherry blossoms in Kyoto.")
            visit("CZ", 2022, 6, 11, "Prague, a long weekend.")
            visit("AT", 2022, 9, 27, "Vienna coffee houses.")
            visit("US", 2022, 12, 24, "New York for the holidays.")
            visit("TH", 2023, 2, 15, "Island-hopping in the south.")
            visit("CH", 2023, 7, 4, "Hiking above Lauterbrunnen.")
            visit("SI", 2023, 8, 19, "Lake Bled at sunrise.")
            visit("JP", 2023, 11, 8, "Autumn colours — second time back.")
            // 2024 is the standout year — Wrapped and the charts lead with it.
            visit("MA", 2024, 2, 9, "Getting lost in the Marrakech medina.")
            visit("EG", 2024, 3, 21, "Sunrise over the Valley of the Kings.")
            visit("TR", 2024, 5, 6, "Istanbul, both sides of the water.")
            visit("GR", 2024, 7, 1, "Cyclades, one ferry at a time.")
            visit("HU", 2024, 8, 14, "Budapest thermal baths.")
            visit("SK", 2024, 9, 2, "Tatras on foot.")
            visit("AE", 2024, 10, 12, "A long layover that became a trip.")
            visit("MX", 2024, 11, 2, "Día de los Muertos in Oaxaca.")
            visit("DE", 2025, 5, 18, "Berlin long weekend.")
            visit("SE", 2025, 6, 30, "Midsummer in Stockholm.")
            visit("DK", 2025, 7, 9, "Copenhagen by bike.")
            visit("NO", 2025, 8, 3, "Fjords in the rain.")
            visit("IE", 2025, 10, 21, "Dublin and the west coast.")
            visit("CA", 2026, 3, 14, "Skiing in the Rockies.")
            visit("AU", 2026, 5, 28, "East coast road trip.")

            // 4) Shared packing containers (catalog spans all trips).
            let carryOn = PackingContainer(name: "Carry-on", symbolName: "bag.fill", sortOrder: 0)
            let camera = PackingContainer(name: "Camera bag", symbolName: "camera.fill", sortOrder: 1)
            let toiletries = PackingContainer(
                name: "Toiletries", symbolName: "cross.case.fill", sortOrder: 2)
            [carryOn, camera, toiletries].forEach { ctx.insert($0) }

            // 5) Trips. A stop **is a country** — mirroring the app's own
            //    `addStop(country:)`, which creates an untitled stop bound to a
            //    country (so it renders the country's name) and moves that country
            //    into the blue "planning" layer. The sights within a country are
            //    the stop's places-to-see, not separate stops.
            @discardableResult
            func makeTrip(
                _ title: String, startingIn start: Int, lasting length: Int, _ notes: String,
                stops: [(country: String, day: Int, places: [(String, Double, Double)])]
            ) -> Trip {
                let t = Trip(
                    title: title, startDate: daysFromNow(start),
                    endDate: daysFromNow(start + length), notes: notes)
                ctx.insert(t)
                // Flat itinerary: each country is a stop, and every place under it
                // is a sibling stop carrying that country and its own coordinate.
                var order = 0
                for s in stops {
                    let country = byID[s.country]
                    ctx.insert(
                        ItineraryItem(
                            date: daysFromNow(start + s.day), order: order, country: country,
                            trip: t))
                    order += 1
                    for p in s.places {
                        ctx.insert(
                            ItineraryItem(
                                title: p.0, order: order, country: country, trip: t,
                                latitude: p.1, longitude: p.2))
                        order += 1
                    }
                    if let country, country.planStatus == .none { country.planStatus = .planning }
                }
                return t
            }

            // The flagship trip is deliberately multi-country — that's the feature.
            let trip = makeTrip(
                "Nordic Loop", startingIn: 30, lasting: 12,
                "Three countries in one loop — waterfalls, fjords and, if we're lucky, the northern lights.",
                stops: [
                    (
                        "IS", 0,
                        [
                            ("Hallgrímskirkja", 64.1417, -21.9266),
                            ("Reynisfjara Beach", 63.4030, -19.0448),
                            ("Jökulsárlón Glacier Lagoon", 64.0784, -16.2306),
                        ]
                    ),
                    (
                        "NO", 5,
                        [("Preikestolen", 58.9864, 6.1904), ("Bryggen, Bergen", 60.3971, 5.3245)]
                    ),
                    (
                        "DK", 9,
                        [("Nyhavn", 55.6797, 12.5913), ("Tivoli Gardens", 55.6736, 12.5681)]
                    ),
                ])

            func pack(
                _ title: String, _ container: PackingContainer?, _ packed: Bool, _ order: Int,
                _ qty: Int = 1
            ) {
                ctx.insert(
                    PackingItem(
                        title: title, isPacked: packed, quantity: qty, order: order, trip: trip,
                        container: container))
            }
            pack("Passport", carryOn, true, 0)
            pack("Rain shell", carryOn, true, 1)
            pack("Wool sweater", carryOn, false, 2, 2)
            pack("Swimsuit", carryOn, false, 3)
            pack("Mirrorless camera", camera, true, 0)
            pack("Lenses — wide + tele", camera, true, 1, 2)
            pack("Tripod", camera, false, 2)
            pack("Spare batteries", camera, false, 3, 4)
            pack("Toothbrush", toiletries, true, 0)
            pack("Sunscreen", toiletries, false, 1)

            // 6) Two more upcoming trips so the Going tab reads as a real plan
            //    rather than a single stub row.
            makeTrip(
                "Cherry Blossom in Japan", startingIn: 120, lasting: 11,
                "Chasing the blossom front north.",
                stops: [
                    (
                        "JP", 0,
                        [
                            ("Fushimi Inari Taisha", 34.9671, 135.7727),
                            ("Arashiyama Bamboo Grove", 35.0170, 135.6716),
                            ("Kiyomizu-dera", 34.9949, 135.7850),
                        ]
                    )
                ])
            makeTrip(
                "Peru: the Inca Trail", startingIn: 210, lasting: 13,
                "Cusco, the Sacred Valley, then four days on the trail.",
                stops: [
                    (
                        "PE", 0,
                        [
                            ("Machu Picchu", -13.1631, -72.5450),
                            ("Sacred Valley", -13.3200, -72.0800),
                            ("Cusco Cathedral", -13.5163, -71.9785),
                        ]
                    )
                ])

            try? ctx.save()
        }
    }

    #if os(macOS)
        import AppKit

        extension ScreenshotSupport {
            /// Fixed logical size for the pinned capture window: 1512×982 points is
            /// 3024×1964 px on a 2x display, which matches the MacBook Pro M5 bezel's
            /// screen cutout (3023×1963, aspect 1.540 — a real 14" MacBook display).
            ///
            /// This was previously 1440×900 (2880×1800), on the mistaken assumption that
            /// the cutout matched the App Store canvas size. It does not: 2880×1800 is
            /// 16:10, so the framing step's aspect-fill cropped ~27pt off each side —
            /// enough to clip the sidebar's search field and the trailing toolbar icons.
            /// The canvas size is a separate concern, handled in `Tools/frame_all.sh`.
            ///
            /// Position is irrelevant: the capture script grabs this window *by id*,
            /// not by screen region.
            static let macWindowSize = CGSize(width: 1512, height: 982)

            /// Where `Tools/screenshots_macos.sh` reads the window id to capture.
            /// Writing it to a fixed path (rather than enumerating windows from the
            /// shell) sidesteps Screen Recording/Accessibility permission entirely —
            /// only the system `screencapture` binary needs that grant, and it
            /// already has it.
            static let macWindowIDPath = "/tmp/worldward_mac_window_id.txt"

            /// Pins the app's main window to a fixed frame and publishes its window
            /// id for the capture script. No-op unless `-UITEST` is active.
            ///
            /// A plain launch of a `WindowGroup` app (not a Dock double-click) can
            /// leave AppKit with zero *ordered* windows — and SwiftUI defers
            /// evaluating that window's content (including `ContentView`'s own
            /// `.task`) until it's key/visible. So calling this from within the
            /// view hierarchy deadlocks: the code that would show the window never
            /// runs because the window isn't shown yet. Call it from
            /// `applicationDidFinishLaunching` instead (see `ScreenshotAppDelegate`
            /// below), which runs at the AppKit level regardless of SwiftUI's view
            /// scheduling — the same level a real Dock click operates at. Polls
            /// briefly since the window may not exist the instant launch finishes.
            @MainActor
            static func pinMacWindow() async {
                guard isActive else { return }

                // The delegate switches to .regular activation and the shell
                // script activates via `open -a`.  Once the window server
                // publishes our window, resize, strip chrome, and publish the
                // real CGWindowID for screencapture.
                //
                // Note: NSWindow.windowNumber is permanently 0x1_0000_0000 on
                // macOS ≥27 when MenuBarExtra co-exists with WindowGroup, so
                // we query CGWindowList directly to get the real CGWindowID.
                for _ in 0..<160 {
                    if let wid = Self.findOwnWindowID() {
                        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
                            window.setContentSize(macWindowSize)
                            window.center()
                            window.styleMask = .borderless
                            window.hasShadow = false
                            window.isOpaque = true
                            window.level = .normal
                        }
                        try? String(wid).write(
                            toFile: macWindowIDPath, atomically: true, encoding: .utf8)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }

            /// Query the window server for our own on-screen window ID.
            private static func findOwnWindowID() -> Int? {
                let pid = ProcessInfo.processInfo.processIdentifier
                guard let list = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements],
                    kCGNullWindowID) as? [[String: Any]]
                else { return nil }
                for info in list {
                    guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                          ownerPID == pid,
                          let layer = info[kCGWindowLayer as String] as? Int,
                          layer == 0,
                          let wid = info[kCGWindowNumber as String] as? Int,
                          wid > 0
                    else { continue }
                    return wid
                }
                return nil
            }
        }

        /// Forces the main window visible at launch when `-UITEST` is active.
        /// `applicationDidFinishLaunching` runs at the AppKit level — see the long
        /// comment on `pinMacWindow()` for why that placement (rather than
        /// anywhere in the SwiftUI view hierarchy) is required.
        final class ScreenshotAppDelegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                guard ScreenshotSupport.isActive else { return }

                // The app ships a MenuBarExtra alongside WindowGroup — SwiftUI
                // defaults to .accessory activation, suppressing all windows.
                // .regular restores normal window behaviour.  The shell script
                // handles actual activation via `open -a` (Dock-click path).
                NSApp.setActivationPolicy(.regular)

                Task { @MainActor in
                    await ScreenshotSupport.pinMacWindow()
                }
            }
        }
    #endif
#endif
