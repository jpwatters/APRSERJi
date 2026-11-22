import CoreLocation
import SwiftUI

final class GPSTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var tracking = false
    @Published private(set) var track: [CLLocation] = []
    @Published private(set) var status: String?
    /** Most recent usable fix, even when it is too close to the last one to extend the trail. */
    @Published private(set) var latest: CLLocation?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start() {
        tracking = true
        track = []
        updateAuthorization()
    }

    func stop() {
        tracking = false
        latest = nil
        manager.stopUpdatingLocation()
        status = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if tracking { updateAuthorization() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard tracking else { return }
        if let fix = locations.last(where: { $0.horizontalAccuracy >= 0 }) { latest = fix }
        var points = track
        for fix in locations where fix.horizontalAccuracy >= 0 && abs(fix.timestamp.timeIntervalSinceNow) < 30 {
            if let last = points.last, fix.timestamp <= last.timestamp || fix.distance(from: last) < 5 { continue }
            points.append(fix)
        }
        guard points.count != track.count else { return }
        track = Array(points.suffix(2_000))
        status = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard tracking else { return }
        if (error as? CLError)?.code == .locationUnknown {
            status = "Waiting for location"
        } else {
            stop()
            status = "Location unavailable"
        }
    }

    private func updateAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Waiting for location permission"
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            status = "Waiting for location"
            manager.startUpdatingLocation()
        case .denied, .restricted:
            stop()
            status = "Allow location access in Settings to track your position."
        @unknown default:
            stop()
            status = "Location unavailable"
        }
    }
}
