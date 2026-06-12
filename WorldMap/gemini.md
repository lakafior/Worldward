# Project: WorldMap (macOS / multiplatform SwiftUI)

## Project Goal
A lightweight, fully native app for tracking the countries you've travelled to.
Started as a simple "tick the countries you've visited" tool and has grown into a
small personal travel journal — richer status levels, an automatic photo importer,
statistics, achievements, and shareable cards — while keeping the original spirit:
**native, fast, no external dependencies, no cloud.**

## Guiding Principles (unchanged)
- **Keep it native and lightweight.** SwiftUI + SwiftData + MapKit only. No
  CocoaPods, no SPM, no third-party libraries.
- **No iCloud / no account.** Everything is stored locally. The user owns their
  data and moves it themselves via JSON export/import.
- **Standard SwiftUI, not architecture astronautics.** Use `@Query`,
  `@Environment(\.modelContext)`, `@Observable`, `@AppStorage`. Avoid Combine —
  prefer `async`/`await`. Don't add MVVM/coordinator layers when a view and a
  model will do.
- **Grow in the same spirit.** New features are welcome when they stay native,
  local, and simple to reason about. Prefer deriving data on the fly (stats,
  achievements) over persisting more state than necessary.
- **Latest recommended APIs.** Declarative MapKit (`Map`, `MapPolygon`), current
  SwiftData, `ImageRenderer`, `fileExporter`/`fileImporter`, PhotoKit.

## Technologies
- **Language:** Swift
- **UI:** SwiftUI — native, modern, minimalist. macOS-first (`NavigationSplitView`,
  `Settings` scene / ⌘,, window sizing) with `#if os(macOS)` guards so the same
  views work on iOS/iPadOS.
- **Persistence:** SwiftData, local store only (`isStoredInMemoryOnly: false`,
  no CloudKit).
- **Map:** MapKit with `MapPolygon` for colouring country outlines. Country
  geometry comes from the bundled `countries.geojson` (Natural Earth), decoded
  with `MKGeoJSONDecoder`.
- **Photos:** PhotoKit (`PHAsset`) for the optional location-based import.
- **Target:** macOS 14+ (Sonoma) for declarative MapKit and current SwiftData.

## Data Model (SwiftData)
Two `@Model` types. The country catalogue is seeded from the bundled GeoJSON and
is *not* user-authored; only travel status and visits belong to the user.

### `Country`
- `id`: String — ISO 3166-1 alpha-2 (e.g. "PL", "GR"), unique. Primary key for
  flags, map polygons, continent lookup, and export matching.
- `iso3`: String — ISO alpha-3.
- `name`: String — English country name.
- `continent`: String — English continent, derived from `Continents.byISO`
  (the GeoJSON has no continent field).
- `statusRaw`: String — backing store for `status`. Persisted as a primitive
  because a stored enum can crash SwiftData migrations; `status` exposes it as
  the typed `CountryStatus`.
- `statusIsImported`: Bool — `true` when the photo importer set the status, so a
  re-scan can clear its own data without touching manual entries.
- `visits`: `[Visit]` — cascade relationship; the primary record of travel.
- `visitDate`, `notes`: legacy single-visit fields, kept for backward
  compatibility and round-tripping. New code uses `visits`.
- Derived (not stored): `status`, `isVisited`, `flagEmoji` (computed from the id).

### `Visit`
- `date`: Date, `notes`: String, `country`: `Country?`.
- `isImported`: Bool — distinguishes importer-created visits from manual ones.
- `photoIdentifiers`: `[String]` — capped PhotoKit `localIdentifier`s, so
  thumbnails can be re-fetched on demand **without ever storing image data**.

### `CountryStatus` (enum)
Five mutually-exclusive levels, ordered weakest→strongest:
`notVisited → crossed → visited → lived → living`. Drives the yellow→orange map
shading, list symbols, and legend. (This replaced the original `isVisited: Bool`;
`isVisited` survives as a convenience computed property.)

## Features
1. **Initial data seed.** On first launch a background task seeds the store from
   `countries.geojson`. Seeding is self-healing: it drops non-country `-99`
   records, repairs stale ids (via `WorldMap.isoFallbacks`), and reconciles
   continents idempotently on every launch.
2. **Sidebar + map (`ContentView`).** Searchable country list with a visited
   counter and per-status symbols, alongside the interactive MapKit world map that
   colours countries by `status`. Selecting a country shows details and editing.
3. **Details & editing.** Set a country's `status`; add dated visits with notes;
   view imported trip photos (`VisitPhotosView`).
4. **Photo import (`PhotoImporter`, `ImportPreviewView`).** Optional. Scans Apple
   Photos by GPS location, point-in-polygon tests each photo into a country, merges
   nearby dates into trips, and proposes a status per country (with a configurable
   merge gap, a "lived" day threshold, and optional "home" detection). Re-scan
   modes — Fill blanks / Overwrite / Add new only — reconcile against existing
   data without clobbering manual entries. A preview sheet lets the user confirm
   before anything is written.
5. **Statistics (`TravelStats`, `StatisticsView`).** A pure value type computed in
   one pass over the countries (no persisted stats, no SwiftData on a background
   thread): per-continent tallies, per-year breakdown, most-visited, first/last
   visit, nearest unvisited suggestions.
6. **Achievements (`Achievement`).** Gamified badges derived on the fly from
   `TravelStats` — nothing persisted; the grid recomputes instantly on any change.
7. **Sharing (`ShareCard`).** A fixed-size card (overall or year-in-review)
   rasterised with `ImageRenderer`, plus a plain-text summary.
8. **Settings (`SettingsView`).** Appearance theme (`AppTheme` via `@AppStorage`)
   and JSON **export/import** of travel data (`TravelDataTransfer`). Export only
   includes countries that have user data; import matches by id and replaces
   travel data idempotently. The catalogue itself is never exported — it's
   re-seeded from the bundle.

## Coding Agent Guidelines
- Match the existing style: clear naming, descriptive comments for non-obvious
  logic, 4-space indentation, simple imports.
- Keep new persisted state minimal — derive instead of store where practical.
- Respect the importer's invariants: imports only ever *raise* a country's status,
  and never overwrite manually-entered data.
- Keep things working on macOS first; guard platform-specific code with
  `#if os(macOS)` rather than forking views.
- When unsure about a newer API (Liquid Glass, FoundationModels, latest SwiftUI/
  SwiftData/MapKit), look it up rather than assuming.

## Roadmap
- macOS 27 Siri / Shortcuts integration (App Intents) is the next planned area.
