import MapKit
import SwiftData
import SwiftUI

@main
struct WorldMap: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Country.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            // Seed (or reconcile) the database in the background so the UI stays responsive.
            Task.detached(priority: .userInitiated) {
                WorldMap.prepareDatabase(in: container)
            }
            return container
        } catch {
            // During development, schema changes can make the existing store incompatible.
            // Remove the old database and create a new clean one.
            let url = modelConfiguration.url
            try? FileManager.default.removeItem(at: url)
            // Try to create the container again after deleting the store
            if let newContainer = try? ModelContainer(
                for: schema, configurations: [modelConfiguration])
            {
                return newContainer
            }
            fatalError("Failed to create ModelContainer after resetting the store: \(error)")
        }
    }()

    /// Several Natural Earth records ship a `-99` ISO code instead of a real one.
    /// These fallbacks restore the proper ISO 3166-1 alpha-2 id so the country
    /// gets a flag, a map polygon, and a working tap target. Shared with
    /// `ContentView.loadGeoJSON` so both sides key everything by the same id.
    nonisolated static let isoFallbacks: [String: String] = [
        "France": "FR",
        "Norway": "NO",
        "Kosovo": "XK",
        "Indian Ocean Territories": "IO",
        "Clipperton Island": "CP"
    ]

    /// The usable id for a GeoJSON feature, or `nil` for records that should be
    /// dropped. A normal feature keys on its ISO alpha-2 value. A `-99` placeholder
    /// keys on its fallback if it has one (France, Norway, Kosovo…); otherwise it's
    /// a non-country the dataset ships with `-99` and no real code — a reef,
    /// military base, glacier or disputed zone — and is filtered out so it can't
    /// clutter the list or skew the statistics.
    nonisolated static func resolvedID(isoA2: String, name: String) -> String? {
        guard isoA2 == "-99" else { return isoA2 }
        return isoFallbacks[name]
    }

    /// Populates an empty store from the bundled GeoJSON, or reconciles an
    /// existing one so every country has the correct English continent.
    nonisolated private static func prepareDatabase(in container: ModelContainer) {
        let context = ModelContext(container)
        var existing = (try? context.fetch(FetchDescriptor<Country>())) ?? []

        // A store seeded by an older build can hold stale ids — a raw `-99`
        // placeholder, or a country name used as the id (e.g. France saved as
        // "France" instead of "FR"). Those rows can't match a flag or a map
        // polygon, so wipe and re-seed when any known fallback country has the
        // wrong id. The check converges: once re-seeded the ids match and it
        // stops firing, while records legitimately keyed by name are left alone.
        let hasStaleIDs = existing.contains { country in
            if let expected = isoFallbacks[country.name] { return country.id != expected }
            return country.id == "-99"
        }
        if hasStaleIDs {
            for country in existing {
                context.delete(country)
            }
            try? context.save()
            existing = []
        }

        guard existing.isEmpty else {
            // Already seeded: reconcile in place. Idempotent and cheap.
            var changed = false
            for country in existing {
                // Drop non-countries an earlier seed stored — reefs, military
                // bases, glaciers and disputed zones the dataset ships with `-99`
                // and no real ISO code. They aren't in the continent table.
                if Continents.byISO[country.id] == nil {
                    context.delete(country)
                    changed = true
                    continue
                }
                // Fix continents written by an earlier seed (localized or missing).
                let continent = Continents.name(for: country.id)
                if country.continent != continent {
                    country.continent = continent
                    changed = true
                }
            }
            if changed { try? context.save() }
            return
        }

        guard let geoUrl = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
            let geoData = try? Data(contentsOf: geoUrl),
            let features = try? MKGeoJSONDecoder().decode(geoData) as? [MKGeoJSONFeature]
        else { return }

        var insertedIDs = Set<String>()
        for feature in features {
            guard let propsData = feature.properties,
                let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any],
                let rawID = props["ISO3166-1-Alpha-2"] as? String,
                let name = props["name"] as? String
            else { continue }

            guard let id = WorldMap.resolvedID(isoA2: rawID, name: name) else { continue }

            // GeoJSON often has several records per country (islands, territories).
            // Deduplicate with a Set, which is far faster than fetching each country.
            guard insertedIDs.insert(id).inserted else { continue }

            context.insert(
                Country(
                    id: id,
                    iso3: props["ISO3166-1-Alpha-3"] as? String ?? "",
                    name: name,
                    continent: Continents.name(for: id)
                ))
        }
        try? context.save()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
