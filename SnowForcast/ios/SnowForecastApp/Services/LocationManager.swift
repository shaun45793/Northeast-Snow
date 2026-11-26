import CoreLocation
import Foundation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = manager.authorizationStatus
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    func distanceMiles(toLatitude lat: Double, longitude lon: Double) -> Double? {
        guard let loc = currentLocation else { return nil }
        let target = CLLocation(latitude: lat, longitude: lon)
        let meters = loc.distance(from: target)
        return meters / 1609.344
    }

    /// Rough Northeast driving estimate (~1.25x road winding factor at ~52 mph avg).
    func estimatedDriveHours(miles: Double) -> Double {
        (miles * 1.25) / 52.0
    }

    func formattedDriveEstimate(toLatitude lat: Double, longitude lon: Double) -> String? {
        guard let miles = distanceMiles(toLatitude: lat, longitude: lon) else { return nil }
        let hours = estimatedDriveHours(miles: miles)
        let wholeHours = Int(hours)
        let mins = Int((hours - Double(wholeHours)) * 60.0)
        if wholeHours > 0 {
            return "\(Int(round(miles))) mi · ~\(wholeHours)h \(mins)m"
        }
        return "\(Int(round(miles))) mi · ~\(mins)m"
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = latest
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient location errors gracefully
    }
}
