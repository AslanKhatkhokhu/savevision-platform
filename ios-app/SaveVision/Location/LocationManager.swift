import CoreLocation
import Foundation

/// Reads the wearer's GPS position via CoreLocation and publishes the latest fix.
/// The app shares this with the operator over Matrix during a call (see
/// `AppModel`). Authorization is requested lazily when sharing starts.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var current: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus

    /// Fired for each new fix while updating — used to forward position to the operator.
    var onUpdate: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        self.authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10 // metres — avoid spamming the operator
    }

    /// Begin reading location, requesting When-In-Use permission if needed.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break // denied/restricted — nothing to do
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.current = location
            self.onUpdate?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[Location] update failed: %@", error.localizedDescription)
    }
}
