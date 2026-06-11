import SwiftUI
import SwiftData
import MapKit

@main
struct WorldMap: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Country.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            
            // Initialize from GeoJSON in the background so UI remains responsive
            Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<Country>()
                
                // Check whether the database is empty on a background context
                if let existingCountries = try? context.fetch(descriptor), existingCountries.isEmpty {
                    
                    // InitData.json only fills metadata that GeoJSON does not provide.
                    var countryContinents: [String: String] = [:]
                    if let metaUrl = Bundle.main.url(forResource: "InitData", withExtension: "json"),
                       let metaData = try? Data(contentsOf: metaUrl),
                       let decodedMeta = try? JSONDecoder().decode([InitDataDTO].self, from: metaData) {
                        for item in decodedMeta {
                            countryContinents[item.id] = item.continent
                        }
                    }

                    // Load the main list from GeoJSON, which is the map source of truth
                    let geoJSONPath = "/Volumes/wew/Git/WorldMap/WorldMap/countries.geojson"
                    let geoUrl = Bundle.main.url(forResource: "countries", withExtension: "geojson") ?? URL(fileURLWithPath: geoJSONPath)
                    
                    if let geoData = try? Data(contentsOf: geoUrl) {
                        let decoder = MKGeoJSONDecoder()
                        if let features = try? decoder.decode(geoData) as? [MKGeoJSONFeature] {
                            var insertedIDs = Set<String>()
                            
                            for feature in features {
                                guard let propsData = feature.properties,
                                      let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any],
                                      let id = props["ISO3166-1-Alpha-2"] as? String,
                                      let iso3 = props["ISO3166-1-Alpha-3"] as? String,
                                      let name = props["name"] as? String else { continue }
                                
                                // GeoJSON often has multiple records for one country, such as islands.
                                // Filter duplicates with a Set, which is much faster than fetching each country.
                                if insertedIDs.contains(id) { continue }
                                insertedIDs.insert(id)

                                let country = Country(
                                    id: id,
                                    iso3: iso3,
                                    name: name,
                                    continent: countryContinents[id] ?? "Unknown",
                                    isVisited: false
                                )
                                context.insert(country)
                            }
                            try? context.save()
                        }
                    }
                }
            }
            return container
        } catch {
            // During development, schema changes can make the existing store incompatible.
            // Remove the old database and create a new clean one.
            let url = modelConfiguration.url
            try? FileManager.default.removeItem(at: url)
            // Try to create the container again after deleting the store
            if let newContainer = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
                return newContainer
            }
            fatalError("Failed to create ModelContainer after resetting the store: \(error)")
        }
    }()

    struct InitDataDTO: Decodable {
        let id: String
        let continent: String
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
