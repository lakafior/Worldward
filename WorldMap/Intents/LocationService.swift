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
        let manager = CLLocationManager()

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = SingleUpdateDelegate(continuation: continuation)
            manager.delegate = delegate
            objc_setAssociatedObject(
                manager, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            manager.requestLocation()
        }
    }

    private static var delegateKey: UInt8 = 0

    /// A one‑shot `CLLocationManagerDelegate` that resumes the continuation with
    /// the first location or error and then discards itself.
    private final class SingleUpdateDelegate: NSObject, CLLocationManagerDelegate {
        let continuation: CheckedContinuation<CLLocation, Error>

        init(continuation: CheckedContinuation<CLLocation, Error>) {
            self.continuation = continuation
        }

        func locationManager(
            _ manager: CLLocationManager,
            didUpdateLocations locations: [CLLocation]
        ) {
            if let location = locations.first {
                continuation.resume(returning: location)
            } else {
                continuation.resume(
                    throwing: LocationError.noLocation)
            }
        }

        func locationManager(
            _ manager: CLLocationManager,
            didFailWithError error: Error
        ) {
            continuation.resume(throwing: error)
        }
    }

    enum LocationError: Error, LocalizedError {
        case noLocation
        var errorDescription: String? {
            "Unable to determine current location."
        }
    }
}
