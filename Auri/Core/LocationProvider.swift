import CoreLocation
import Foundation

@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var lastKnownLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private var manager: CLLocationManager?

    func request() {
        let manager: CLLocationManager
        if let existing = self.manager {
            manager = existing
        } else {
            let created = CLLocationManager()
            created.delegate = self
            self.manager = created
            manager = created
        }

        authorizationStatus = manager.authorizationStatus
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            lastKnownLocation = location
            manager.stopUpdatingLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            // macOS reports a granted "when in use" request as .authorizedWhenInUse
            // (and .authorizedAlways); the deprecated .authorized alias alone missed
            // both, so location updates never restarted after the user granted
            // access — leaving lastKnownLocation nil and regional filtering inert.
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            default:
                break
            }
        }
    }
}
