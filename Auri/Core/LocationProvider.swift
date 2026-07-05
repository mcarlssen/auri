import CoreLocation
import Foundation

private func LocationLog(_ message: @autoclosure () -> String) {
    RecognitionLogger.log(message(), category: "Location")
}

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
            LocationLog("created CLLocationManager")
        }

        authorizationStatus = manager.authorizationStatus
        LocationLog("requestWhenInUseAuthorization (current status: \(Self.describe(manager.authorizationStatus)))")
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        if manager != nil {
            LocationLog("stopping location updates and releasing manager")
        }
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            LocationLog(String(
                format: "received location %.5f, %.5f (±%.0f m)",
                location.coordinate.latitude,
                location.coordinate.longitude,
                location.horizontalAccuracy
            ))
            lastKnownLocation = location
            manager.stopUpdatingLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            LocationLog("authorization changed to \(Self.describe(status))")
            authorizationStatus = status
            // macOS reports a granted "when in use" request as .authorizedWhenInUse
            // (and .authorizedAlways); the deprecated .authorized alias alone missed
            // both, so location updates never restarted after the user granted
            // access — leaving lastKnownLocation nil and regional filtering inert.
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            default:
                break
            }
        }
    }

    private static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
