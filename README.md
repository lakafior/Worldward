# Worldward 🌍

**Track your travels. Explore your world.**

Worldward is a native macOS / iOS app that visualises every country you've visited — crossed, lived in, or simply passed through — on an interactive world map. Built entirely with SwiftUI, MapKit, and SwiftData.

---

## Features

### Interactive Map
- Every country rendered as a tap-able map polygon from Natural Earth data (~250 countries).
- Warm yellow-to-orange fill per country status: **Crossed** → **Visited** → **Lived** → **Living**.
- A cool-blue **planning layer** on the same map — **Wishlist** and **Planning** countries tinted blue, with a blue ring on places you've both visited *and* want to return to.
- Tap any country to see its visits, flag, and notes.

### Travel Log
- Record visits with dates and notes for every country you've been to.
- Attach photo thumbnails fetched live from your Photo Library — no image data is ever stored.
- Multiple visits per country, each with its own date and photo set.

### Trip Planning
- A **plan axis** independent of where you've been: mark any country **Wishlist** or **Planning** — a country can be both visited *and* on your list.
- **Map / Been / Going** live as a Liquid Glass tab bar (a bottom bar on iPhone, a sidebar on iPad & Mac), all backed by the one shared world map.
- An "On your list" stats card tracks your wishlist and planning counts without touching your visited totals.
- The **Been** and **Going** tabs each list their countries grouped by continent, with sort (by name or most recently visited) and a continent / visit-year filter. Discovery and adding happen on the Map — tap any country to set its status or plan.

### Statistics & Achievements
- Live dashboard: total countries, continents covered, busiest year, most-visited country.
- Gamified achievement badges (First Steps, Globetrotter, Centurion, Seven Summits, etc.).
- Per-continent completion tracking.
- Year-in-review breakdown with per-year charts.
- Smart "next destinations" — nearest unvisited countries by geographic proximity.

### Apple Intelligence ✨
- **Travel Chat** – ask free-form questions about your own travels in natural language ("Which European countries haven't I been to?", "Where did I go in 2023?"). Everything runs on-device via the Foundation Models framework.
- **AI Insights** – auto-generated year-in-review recaps and smart destination recommendations with rationale, powered by on-device inference.

### Photo Import
- Scan your Photo Library to automatically detect countries from geotagged photos.
- Configurable merge gap and "Lived" threshold.
- Suggests country statuses based on photo duration.
- Mark your most-present country as "home."

### Siri & Shortcuts
- `MarkCountryStatusIntent` – set a country's status via Shortcuts.
- `LogVisitIntent` / `LogVisitsFromDescriptionIntent` – log visits by name or description.
- `SearchCountriesIntent` – Spotlight-integrated country search.
- `GetVisitCountIntent` / `GetContinentProgressIntent` – query your stats.
- `MarkCurrentLocationIntent` – mark your current location's country.

### Share
- Generate a beautiful share card (rasterised image) with your travel stats.
- Customisable headline, caption, metrics, and gradient theme — optionally featuring your tinted world map.
- Share as image or plain-text summary.

### Widgets & Controls
- **Home Screen / desktop widgets**: Travel Snapshot (countries, continents, % of the world), Flags Visited, and a tinted World Map.
- **Lock Screen accessories**: a circular progress gauge, a rectangular summary, and an inline count.
- **Control Center / Action button**: a "Mark where I am" control that opens the app to log your current country.
- Widgets read a small snapshot the app writes to a shared **App Group** (plus a copy of the map geometry) — no SwiftData runs in the extension.

### Reminders
- Optional on-device local notifications: "on this day" travel memories, a December year-in-review nudge, and a gentle prompt if you haven't logged a trip in a while.
- **Off by default** — opt in from Settings; nothing is scheduled until you do.

### Data Portability
- **Export / Import** your travel data as a portable JSON file.
- Only your personal data is exported (statuses, visits, notes) — the country catalog re-seeds from the bundled geometry file.

### Appearance
- System / Light / Dark theme preference.
- Unified sky-to-royal-blue brand palette throughout.

---

## Tech Stack

| Layer | Technology |
|---|---|
| UI | SwiftUI (Liquid Glass `TabView`, `.sidebarAdaptable`) |
| Mapping | MapKit (`MKPolygon`, `MKMapView`) |
| Persistence | SwiftData (`ModelContainer`, `@Model`) |
| Geo data | Natural Earth, pre-simplified to `countries.wmgb` (~340 KB) |
| PhotoKit | `PHAsset` / `PHImageManager` thumbnails |
| AI | `FoundationModels` (on-device, Apple Intelligence) |
| Intents | `AppIntents` framework (Shortcuts, Siri, Control Center controls) |
| Widgets | `WidgetKit` (Home/Lock Screen, accessories, controls) over an App Group |
| Notifications | `UserNotifications` (local, opt-in) |
| Share | `ImageRenderer` → `ShareLink` |
| Platforms | macOS 15+, iOS 18+ |

---

## Project Structure

```
Worldward/
├── Worldward.swift              # App entry point, ModelContainer, ISO fallbacks
├── ContentView.swift           # Map/Been/Going tab shell, map view, country list, geometry reader
├── Country.swift               # SwiftData model for a country (been + plan axes)
├── Visit.swift                 # SwiftData model for a dated visit
├── CountryStatus.swift         # "Been there" status enum (notVisited → living)
├── PlanStatus.swift            # "Going" plan enum (none / wishlist / planning)
├── Continents.swift            # ISO → continent lookup table
├── TravelStats.swift           # All computed statistics + nearest-unvisited helper
├── Achievement.swift           # Gamification badges, derived from TravelStats
├── BrandColor.swift            # Brand palette + ShareCardTheme gradients
├── SettingsView.swift          # Appearance, reminders toggle, export/import
├── StatisticsView.swift        # Dashboard, achievements, charts, AI insights
├── ShareCard.swift             # Rasterised share-card view (with optional map)
├── ShareCustomizationView.swift # Live card preview + share flow
├── NotificationManager.swift   # Opt-in local travel reminders
├── WidgetSharedSnapshot.swift  # Shared snapshot/geometry + control intent (app ∩ widget)
├── PhotoImporter.swift         # Photo Library scan → proposed trips
├── ImportPreviewView.swift     # Scan configuration & results UI
├── VisitPhotosView.swift       # Photo thumbnail strip + full-size viewer
├── TravelDataTransfer.swift    # JSON backup/restore
├── Intents/
│   ├── WorldwardIntents.swift   # AppIntents + Shortcuts provider
│   ├── CountryEntity.swift     # AppEntity for countries
│   ├── IntentSnippets.swift    # Snippet views for intent results
│   ├── LocationService.swift   # CoreLocation helper for MarkCurrentLocation
│   ├── LogVisitsView.swift     # Bulk log-visits sheet
│   ├── TravelChatView.swift    # On-device AI chat sheet
│   ├── TravelInsights.swift    # AI year recaps + destination picks
│   ├── TravelIntelligence.swift # Conversational travel Q&A service
│   └── VisitLogParser.swift    # Natural-language visit parser
├── Assets.xcassets/            # App icon, launch screen, brand colors
├── countries.wmgb             # Pre-simplified country geometry (~239 countries)
└── Info.plist                  # Launch screen config

WorldwardWidgets/               # Widget extension target (Home/Lock Screen + Control Center)
├── WorldwardWidgetsBundle.swift # @main WidgetBundle (widgets + control)
└── WorldwardWidgets.swift      # Snapshot/Flags/Map widgets, accessories, "Mark where I am" control
```

> The app and the widget extension share data through an **App Group** (`group.net.smigi.worldward`): the app writes a small `WidgetSnapshot` and a copy of the map geometry; the widgets read them. `WidgetSharedSnapshot.swift` is a member of both targets.

---

## Getting Started

1. Open `Worldward.xcodeproj` in Xcode 16+.
2. Select your target (macOS or iOS).
3. Build and run.
4. The first launch seeds the database from the bundled geometry file — this happens once.
5. Tap a country on the map, set its status, and start tracking your travels.

> **Note**: Photo Import requires Photo Library access. AI features require Apple Intelligence on a supported device.

---

## Data

- All travel data is stored locally on-device via SwiftData. Nothing is sent to a server.
- AI inference runs entirely on-device via `FoundationModels` — no network calls.
- Country geometry is loaded from the bundled `countries.wmgb` — Natural Earth data (public domain), pre-simplified at build time by `Tools/generate_geo.swift` so the app ships ~340 KB instead of a 14 MB GeoJSON and never decodes map data on-device.
- Photo identifiers (`PHAsset.localIdentifier`) are stored instead of image data, so the library is the source of truth and the app stays lightweight.

---

## License

Private project.
