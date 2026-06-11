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

    /// Populates an empty store from the bundled GeoJSON, or reconciles an
    /// existing one so every country has the correct English continent.
    nonisolated private static func prepareDatabase(in container: ModelContainer) {
        let context = ModelContext(container)
        var existing = (try? context.fetch(FetchDescriptor<Country>())) ?? []

        if existing.contains(where: { $0.id == "-99" }) {
            for country in existing {
                context.delete(country)
            }
            try? context.save()
            existing = []
        }

        guard existing.isEmpty else {
            // Already seeded: fix continents written by an earlier seed
            // (e.g. localized or missing values). Idempotent and cheap.
            var changed = false
            for country in existing {
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
                var id = props["ISO3166-1-Alpha-2"] as? String,
                let name = props["name"] as? String
            else { continue }

            if id == "-99" {
                let fallbacks: [String: String] = [
                    "France": "FR",
                    "Norway": "NO",
                    "Kosovo": "XK",
                    "Indian Ocean Territories": "IO",
                    "Clipperton Island": "CP"
                ]
                id = fallbacks[name] ?? name
            }

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
