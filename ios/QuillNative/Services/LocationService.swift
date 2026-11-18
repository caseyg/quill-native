import CoreLocation
import Observation

@MainActor @Observable
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var coordinate: CLLocationCoordinate2D?
    var error: String?
    var loading = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func request() {
        loading = true; error = nil
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else { error = "Location access is off for Quill."; loading = false }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if loading && (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways) { manager.requestLocation() }
        else if manager.authorizationStatus == .denied { loading = false; error = "Location access is off for Quill." }
    }
    func locationManager(_ manager: CLLocationManager,didUpdateLocations locations: [CLLocation]) { coordinate = locations.last?.coordinate; loading = false }
    func locationManager(_ manager: CLLocationManager,didFailWithError error: Error) { self.error = error.localizedDescription; loading = false }
}
