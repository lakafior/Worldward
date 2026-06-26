import CoreLocation
import MapKit

/// Minimal async wrapper around `CLLocationManager` so both the intent and the
/// in‑app toolbar button can resolve the current country in a single call.
enum LocationService {

    /// Returns the ISO 3166‑1 alpha‑2 country code for the device's current
    /// location, or `nil` if the reverse geocode produces no result.
    static func currentISOCountryCode() async throws -> String? {
        let location = try await currentLocation()

        guard let request = MKReverseGeocodingRequest(location: location) else {
            return nil
        }

        let mapItems = try await request.mapItems
        // Zastępujemy .placemark nowym API:
        return mapItems.first?.addressRepresentations?.region?.identifier
    }

    // MARK: - Private

    private static func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            // The request retains itself (and its manager) in `active` until it
            // resolves, so neither is deallocated before the async callbacks fire.
            LocationRequest(continuation: continuation).start()
        }
    }

    /// A one‑shot location request that drives `CLLocationManager` through the
    /// authorization prompt (when status is undetermined) and a single location
    /// fix, then resumes the continuation exactly once and discards itself.
    private final class LocationRequest: NSObject, CLLocationManagerDelegate {
        /// Keeps live requests alive for the lifetime of the async call; a bare
        /// local `CLLocationManager` would otherwise be released before its
        /// delegate callbacks arrive, silently dropping the request.
        private static var active: Set<LocationRequest> = []

        private let manager = CLLocationManager()
        private var continuation: CheckedContinuation<CLLocation, Error>?

        init(continuation: CheckedContinuation<CLLocation, Error>) {
            self.continuation = continuation
            super.init()
            manager.delegate = self
        }

        func start() {
            Self.active.insert(self)
            // Act on the current status now; a first‑launch prompt resolves via
            // the authorization delegate callback below.
            proceed(with: manager.authorizationStatus)
        }

        private func proceed(with status: CLAuthorizationStatus) {
            switch status {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                finish(.failure(LocationError.authorizationDenied))
            @unknown default:
                finish(.failure(LocationError.authorizationDenied))
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            // The first callback may still be `.notDetermined` (fired before the
            // user answers); only react once an actual decision is in.
            guard manager.authorizationStatus != .notDetermined else { return }
            proceed(with: manager.authorizationStatus)
        }

        func locationManager(
            _ manager: CLLocationManager,
            didUpdateLocations locations: [CLLocation]
        ) {
            if let location = locations.first {
                finish(.success(location))
            } else {
                finish(.failure(LocationError.noLocation))
            }
        }

        func locationManager(
            _ manager: CLLocationManager,
            didFailWithError error: Error
        ) {
            finish(.failure(error))
        }

        /// Resumes the continuation a single time and releases the self‑retention.
        private func finish(_ result: Result<CLLocation, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
            Self.active.remove(self)
        }
    }

    enum LocationError: Error, LocalizedError {
        case noLocation
        case authorizationDenied
        var errorDescription: String? {
            switch self {
            case .noLocation:
                "Unable to determine current location."
            case .authorizationDenied:
                "Location access is denied. Enable it in Settings to mark where you are."
            }
        }
    }
}
