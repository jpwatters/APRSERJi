import AprsCore
import CoreLocation
import SwiftUI

final class GPSTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var tracking = false
    @Published private(set) var track: [CLLocation] = []
    @Published private(set) var status: String?
    /** Most recent usable fix, even when it is too close to the last one to extend the trail. */
    @Published private(set) var latest: CLLocation?
    /** True while positions come from an external GPS (serial or network NMEA, gpsd) instead of Core Location. */
    @Published private(set) var external = false
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

    /** A fix from an external GPS. Fixes older than 30 seconds are ignored. */
    func ingest(_ fix: ExternalFix) {
        let time = Date(timeIntervalSince1970: Double(fix.timeMillis) / 1000)
        guard abs(time.timeIntervalSinceNow) < 30, latest?.timestamp != time else { return }
        if !external {
            external = true
            manager.stopUpdatingLocation()
        }
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude),
            altitude: fix.altitudeMeters?.doubleValue ?? 0, horizontalAccuracy: fix.accuracyMeters,
            verticalAccuracy: fix.altitudeMeters == nil ? -1 : 10,
            course: fix.courseDegrees?.doubleValue ?? -1, speed: (fix.speedKnots?.doubleValue).map { $0 / 1.943844 } ?? -1,
            timestamp: time)
        latest = location
        Self.remember(location)
        if let last = track.last, location.distance(from: last) < 5 { return }
        track = Array((track + [location]).suffix(2_000))
        status = nil
    }

    /** Back to Core Location after an external GPS is turned off. */
    func endExternal() {
        guard external else { return }
        external = false
        if tracking { updateAuthorization() }
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
        guard tracking, !external else { return }
        if let fix = locations.last(where: { $0.horizontalAccuracy >= 0 }) {
            latest = fix
            Self.remember(fix)
        }
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

    /** The last GPS fix from any session, kept across launches; nil if there has never been one. */
    static func lastKnown(_ defaults: UserDefaults = .standard) -> CLLocationCoordinate2D? {
        guard defaults.object(forKey: "lastFixLatitude") != nil else { return nil }
        let point = CLLocationCoordinate2D(latitude: defaults.double(forKey: "lastFixLatitude"),
                                           longitude: defaults.double(forKey: "lastFixLongitude"))
        return CLLocationCoordinate2DIsValid(point) ? point : nil
    }

    private static func remember(_ fix: CLLocation, _ defaults: UserDefaults = .standard) {
        defaults.set(fix.coordinate.latitude, forKey: "lastFixLatitude")
        defaults.set(fix.coordinate.longitude, forKey: "lastFixLongitude")
        defaults.set(fix.timestamp.timeIntervalSince1970, forKey: "lastFixTime")
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
