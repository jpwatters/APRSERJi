import CoreLocation
import Foundation
import SwiftUI

/** One active National Weather Service alert. Storm-based warnings carry polygons; zone-based alerts do not. */
struct NWSAlert: Identifiable, Equatable {
    let id: String
    let event: String
    let headline: String
    let severity: String
    let area: String
    let expires: Date?
    let polygons: [[CLLocationCoordinate2D]]

    static func == (a: NWSAlert, b: NWSAlert) -> Bool { a.id == b.id && a.headline == b.headline }

    /** Map colors follow the usual NWS warning palette. */
    var color: Color {
        let e = event.lowercased()
        if e.contains("tornado") { return .red }
        if e.contains("severe thunderstorm") { return .orange }
        if e.contains("flash flood") || e.contains("flood") { return .green }
        if e.contains("winter") || e.contains("blizzard") || e.contains("ice") { return .blue }
        if e.contains("watch") { return .yellow }
        return .purple
    }
}

/**
 * Active NWS alerts from api.weather.gov (US only), refreshed every five minutes while enabled:
 * every alert with a polygon within reach of the map areas, and every alert covering your location.
 */
@MainActor
final class NWSWarnings: ObservableObject {
    static let shared = NWSWarnings()

    @Published private(set) var mapped: [NWSAlert] = []
    @Published private(set) var atLocation: [NWSAlert] = []
    @Published private(set) var updated: Date?
    @Published private(set) var problem: String?
    private var lastFetch = Date.distantPast
    private var lastPoint: CLLocationCoordinate2D?
    private var busy = false

    /** Called once a second; fetches when enabled and five minutes have passed or the location moved far. */
    func refreshIfNeeded(enabled: Bool, location: CLLocationCoordinate2D, reachMeters: Double) {
        guard enabled else {
            if !mapped.isEmpty || !atLocation.isEmpty { mapped = []; atLocation = [] }
            return
        }
        let moved = lastPoint.map { Geo.distance($0, location) > 50_000 } ?? true
        guard !busy, moved || Date().timeIntervalSince(lastFetch) >= 300 else { return }
        busy = true
        lastFetch = Date()
        lastPoint = location
        Task {
            defer { busy = false }
            do {
                async let all = Self.fetch("https://api.weather.gov/alerts/active?status=actual&message_type=alert,update")
                async let here = Self.fetch(String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f",
                                                   location.latitude, location.longitude))
                let (allAlerts, localAlerts) = try await (all, here)
                mapped = allAlerts.filter { alert in
                    alert.polygons.contains { ring in ring.contains { Geo.distance($0, location) <= reachMeters } }
                }
                atLocation = localAlerts
                updated = Date()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private static func fetch(_ address: String) async throws -> [NWSAlert] {
        guard let url = URL(string: address) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 30)
        // api.weather.gov asks every client to identify itself with a contact.
        request.setValue("APRSERJi/1.0 (KC9KKO, github.com/jpwatters/APRSERJi)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return features.compactMap { feature in
            guard let p = feature["properties"] as? [String: Any] else { return nil }
            let id = p["id"] as? String ?? feature["id"] as? String ?? UUID().uuidString
            return NWSAlert(id: id, event: p["event"] as? String ?? "Alert",
                            headline: p["headline"] as? String ?? "", severity: p["severity"] as? String ?? "",
                            area: p["areaDesc"] as? String ?? "",
                            expires: (p["ends"] as? String ?? p["expires"] as? String).flatMap(iso.date(from:)),
                            polygons: polygons(feature["geometry"] as? [String: Any]))
        }
    }

    /** GeoJSON Polygon / MultiPolygon outer rings ([longitude, latitude] pairs). */
    private static func polygons(_ geometry: [String: Any]?) -> [[CLLocationCoordinate2D]] {
        guard let geometry, let type = geometry["type"] as? String else { return [] }
        func ring(_ any: Any?) -> [CLLocationCoordinate2D] {
            (any as? [[Double]] ?? []).compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
        }
        switch type {
        case "Polygon":
            return [(geometry["coordinates"] as? [Any])?.first].map(ring).filter { $0.count >= 3 }
        case "MultiPolygon":
            return (geometry["coordinates"] as? [[Any]] ?? []).map { ring($0.first) }.filter { $0.count >= 3 }
        default:
            return []
        }
    }
}
