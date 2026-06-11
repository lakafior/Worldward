# Project: Travel Map (macOS)

## Project Goal
Create a simple, lightweight macOS app for tracking visited countries around the world.

## Technologies and Assumptions
- **Language:** Swift
- **UI:** SwiftUI, with a fully native, modern, minimalist interface
- **Database:** SwiftData, stored locally without iCloud sync for now
- **Map:** MapKit, using Apple's built-in framework with `MapPolygon` for coloring country outlines
- **Dependencies:** No external libraries through CocoaPods or SPM. The app should stay as lightweight and fast as possible.
- **System Version:** Target macOS 14+ (Sonoma) because of the latest declarative MapKit and SwiftData APIs.

## Data Model (SwiftData)
The app has one main data model: `Country`. The database should initially contain all countries from `InitData.json`, and the user only modifies their visited status.

**`Country` model properties:**
- `id`: String, a unique country code such as "PL" or "GR"
- `name`: String, the English country name
- `continent`: String, the continent
- `flag`: String, a flag emoji
- `isVisited`: Bool, whether the country has been visited
- `visitDate`: Date?, the visit date
- `notes`: String, optional user notes

## Required Features
1. **Initial Data Seed:** On first launch, if the database is empty, the app loads all countries from the local `InitData.json` file into SwiftData.
2. **Navigation and Sidebar List:**
   - List all countries.
   - Support searching by name.
   - Show a visited-country counter at the top.
   - Clearly mark countries that have already been visited, such as with a green checkmark.
3. **Details and Editing View:**
   - Selecting a country from the list shows details such as name, flag, and continent.
   - Provide a toggle for marking the country as visited (`isVisited`).
   - When `isVisited == true`, show additional fields: a `DatePicker` for the visit date and a multiline `TextField` for notes.
4. **Interactive Map:**
   - Show a world map using MapKit.
   - Visualize visited countries based on SwiftData.
5. **Statistics:**
   - Summarize visited countries by continent.

## Coding Agent Guidelines
- **Priority:** Keep the code as simple, native, and readable as possible.
- Avoid overengineering. Do not introduce complex architectural patterns when standard SwiftUI approaches such as `@Query` and `@Environment(\.modelContext)` are enough.
- Use the latest recommended APIs, including declarative MapKit and current SwiftData definitions in SwiftUI.
- Remember that the app targets **macOS**, so account for Mac-specific elements such as windows, `NavigationSplitView`, and mouse/keyboard interaction.
// Test
