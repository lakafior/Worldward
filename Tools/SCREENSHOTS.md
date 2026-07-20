# App Store screenshot pipeline — runbook

Automated App Store Connect screenshots: **22 languages × light/dark × 10 screens**, per platform,
framed with device bezels, backgrounds and localized captions.

Everything is native — no fastlane, no third-party tooling.

---

## How it works (read this first)

The app ships a **DEBUG-only harness**, `Worldward/ScreenshotSupport.swift`:

| Launch argument | Effect |
|---|---|
| `-UITEST` | Replaces the on-disk store with an **in-memory** one seeded with demo data. The real store is never opened. |
| `-screen <name>` | Routes directly to a screen — no tapping, so it can't break on localized button labels. |
| `-appearance light\|dark` | Forces the colour scheme. |
| `-AppleLanguages "(de)"` | Standard iOS locale override — **verified working**, which is why no XCUITest target is needed. |

Valid `-screen` values (`ScreenshotScreen` enum):
`map`, `been`, `countryDetail`, `going`, `trip`, `packing`, `stats`, `achievements`, `wrapped`, `share`

Where each screen is driven from:

| Screen | Driven by |
|---|---|
| map / been / going / countryDetail / achievements | `ContentView.applyScreenshotRouting()` |
| stats / wrapped / share | `CountryListView` opens the Statistics sheet (gated `browseMode == .been`); `StatisticsView` then sets `wrappedYear` / `showShareSheet` |
| trip / packing | `TripsListView` sets `editingTrip`; `TripDetailView` scrolls to `packingAnchorID` |

Child views call `ScreenshotSupport.isCapturing(_:)` — a static read of the launch args, so no
shared state or observers are needed.

---

## Running a capture

```bash
# 1. Build + install to the simulator
xcodebuild -project Worldward.xcodeproj -scheme Worldward \
  -destination 'id=3BCCA0F0-94B0-4A99-83AA-5333E45B0489' -configuration Debug build
xcrun simctl install <UDID> <DerivedData>/Build/Products/Debug-iphonesimulator/Worldward.app

# 2. Capture (subset first to sanity-check, then the full run)
LANGS="en de" ./Tools/screenshots.sh
./Tools/screenshots.sh                     # ~440 shots, roughly 50 min
```

Output: `~/Desktop/Worldward-Screenshots/raw/iOS/<lang>/<light|dark>/NN-<screen>.png`
at **1320×2868** (the ASC 6.9" iPhone size).

> `raw/` is the backup. The framing step reads from it and writes elsewhere — never overwrite it,
> or the whole matrix has to be recaptured.

## Framing

`Tools/frame_screenshot.swift` (Swift + CoreGraphics/CoreText/CoreImage, no dependencies):

```bash
swift Tools/frame_screenshot.swift <bezel.png> <screenshot.png> <out.png> "<headline>" "<subhead>" [background.jpg]
```

It auto-detects the bezel's transparent screen cutout via the alpha channel, aspect-fills the
screenshot into it, then composites onto a designed background with the caption.

Assets: bezels in `~/Downloads/Bezels/`, backgrounds in `~/Downloads/Backgrounds/`.
Device→canvas mapping: iPhone 17 Pro Max bezel (1470×3000, cutout 1319×2867) → 1320×2868 canvas ·
iPad A16 → 2064×2752 · MacBook Pro M5 → 2880×1800 · Watch Ultra 3 → 410×502.

---

## Status

**Done — iOS, all 10 screens verified capturing cleanly in light + dark.**
Locale switching verified (German). Compositor prototype produces an approved hero frame.

### Remaining, in order

1. **Country-detail polish** *(easy)* — the sheet opens on Status/Facts; add a scroll anchor to the
   visits list, same pattern as `TripDetailView.packingAnchorID`.
2. **Photos in country detail** *(medium — needs care)* — the photo strip is empty because the sim's
   library is. Plan: `xcrun simctl addmedia <UDID> <images>`, `xcrun simctl privacy <UDID> grant photos <BID>`,
   then in the seed fetch those `PHAsset.localIdentifier`s and assign to `Visit.photoIdentifiers`.
3. **Run the full iOS matrix** *(easy, mechanical)* — `./Tools/screenshots.sh`.
4. **iPad** *(easy)* — same script, `UDID=<iPad Pro 13" sim> OUT=.../raw/iPadOS ./Tools/screenshots.sh`.
   Verify the routing still lands correctly (iPad uses the same `ContentView`).
5. **macOS** *(medium)* — same launch args, but launch the Mac app with arguments and capture the
   window; `simctl` does not apply.
6. **watchOS** *(hardest — genuinely new code)* — watchOS has **no XCUITest and no `-screen` harness**.
   The watch views are pure SwiftUI with no MapKit, so render them with `ImageRenderer` at 410×502
   across `.locale` × `.colorScheme` instead of screenshotting a running app.
7. **Productionize the compositor** *(medium, design judgement)* — per-screen templates varying bezel
   colour, tilt, zoom, caption position and background (see the locked look below), plus
   **auto-fit for localized captions** — several of the 22 languages run much longer than English and
   will overflow at the current fixed sizes. This is the main unsolved problem in the framing step.

---

## Locked design decisions

- **Captions**: 10 headline/subhead pairs (English source) — see the project memory file; translate via
  `Tools/locman.py`. Map subhead carries the privacy angle: *"Private by design — all on your device"*.
- **Backgrounds**: per-screen thematic — map photos behind Map/Been/Country, `Backgrounds/Trip/*`
  behind Going/Itinerary/Packing, brand gradient behind Stats/Achievements/Wrapped/Share.
- **Treatment**: light blur (r≈9) + royal-blue tint (~0.30) + caption-only top scrim + floor scrim,
  so the photo reads through. Device ~0.92 of canvas width, 4° tilt, bleeds off the bottom.
  Headline 100pt heavy, subhead 54pt semibold. **No dotted arc** (tried, rejected).
- **Variety**: do *not* frame all 10 identically — vary bezel colour (Deep Blue / Cosmic Orange /
  Silver), tilt direction, zoom (full vs close-crop), and caption position.

## Domain rules the seed must respect

- An itinerary **stop is a whole country**, never a city. The app's `addStop(country:)` creates an
  *untitled* stop bound to a `Country` and flips it to `.planning`; sights live inside as
  `StopPlace` places-to-see. Screenshots must not show capabilities the app lacks.
  (City-level stops are on the README roadmap as a future feature.)
- Trip dates must be **relative to now** (`daysFromNow`), or trips fall into collapsed "Past Trips".
- Seed data must be **rich enough to look good**: ~30 visits with one standout year (2024 = 8
  countries) so Wrapped and the charts read well, and 3 upcoming trips so Going isn't a stub.

## Known quirks

- Country and continent names stay **English in every language** — they come from the bundled
  Natural Earth geometry, not the String Catalog. Expected, but worth a product decision.
- The achievement-unlock toast is suppressed under `-UITEST` (seeding unlocks 15 badges at once,
  and the toast covered the map).
- Xcode 27 moved `SimulatorKit.framework` to `Contents/SharedFrameworks/`, so MCP UI-automation
  tools that look in the old path fail. Irrelevant here — this pipeline never uses them.
