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
    var polygons: [[CLLocationCoordinate2D]]
    /** api.weather.gov zone URLs, for alerts issued by county or forecast zone instead of a polygon. */
    var zones: [String] = []

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
    /** Zone outlines fetched once and kept (they rarely change). */
    private var zoneCache: [String: [[CLLocationCoordinate2D]]] = [:]
    /** APRS NWS bulletins (NWS-WARN, NWS_ADVIS…) heard on the air, resolved to their zones. */
    @Published private(set) var aprsMapped: [NWSAlert] = []
    private var aprsKeys: Set<String> = []

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
                var nearby = allAlerts.filter { alert in
                    alert.polygons.contains { ring in ring.contains { Geo.distance($0, location) <= reachMeters } }
                }
                // Alerts for your location issued by zone or county: draw their zone outlines too.
                for var alert in localAlerts where alert.polygons.isEmpty && !nearby.contains(where: { $0.id == alert.id }) {
                    alert.polygons = await self.outlines(alert.zones.prefix(12).map { $0 })
                    if !alert.polygons.isEmpty { nearby.append(alert) }
                }
                mapped = nearby
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
                            polygons: polygons(feature["geometry"] as? [String: Any]),
                            zones: p["affectedZones"] as? [String] ?? [])
        }
    }

    /** Outlines of api.weather.gov zones, cached. */
    private func outlines(_ urls: [String]) async -> [[CLLocationCoordinate2D]] {
        var rings: [[CLLocationCoordinate2D]] = []
        for address in urls {
            if let cached = zoneCache[address] { rings += cached; continue }
            guard let url = URL(string: address) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("APRSERJi/1.0 (KC9KKO, github.com/jpwatters/APRSERJi)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let shape = Self.polygons(root["geometry"] as? [String: Any])
            zoneCache[address] = shape
            rings += shape
        }
        return rings
    }

    /**
     * Expands UGC codes in an APRS NWS bulletin, e.g. "ILC031>037" or "ILZ013-014-016", into zone ids
     * (ILC031, ILC032 … or ILZ013, ILZ014, ILZ016).
     */
    static func ugcCodes(_ text: String) -> [String] {
        var result: [String] = []
        let regex = try! NSRegularExpression(pattern: "\\b([A-Z]{2}[CZ])(\\d{3})((?:[>-]\\d{3})*)")
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let p = Range(m.range(at: 1), in: text), let n = Range(m.range(at: 2), in: text),
                  let rest = Range(m.range(at: 3), in: text), let first = Int(text[n]) else { continue }
            let prefix = String(text[p])
            var last = first
            result.append(prefix + String(format: "%03d", first))
            var scanner = Substring(text[rest])
            while let op = scanner.first, let value = Int(scanner.dropFirst().prefix(3)) {
                if op == ">" { for v in (last + 1)...max(last + 1, value) where v <= value { result.append(prefix + String(format: "%03d", v)) } }
                else { result.append(prefix + String(format: "%03d", value)) }
                last = value
                scanner = scanner.dropFirst(4)
            }
        }
        return Array(result.prefix(60))
    }

    /** Resolves APRS NWS bulletins heard on the air to zone outlines for the map. */
    func updateAprs(bulletins: [AprsBulletinText]) {
        let wanted = bulletins.filter { $0.destination.hasPrefix("NWS") }
        let keys = Set(wanted.map { $0.sender + "|" + $0.text })
        guard keys != aprsKeys, !busy else { return }
        aprsKeys = keys
        Task {
            var alerts: [NWSAlert] = []
            for b in wanted.prefix(10) {
                let urls = Self.ugcCodes(b.text).map { code in
                    "https://api.weather.gov/zones/" + (code.dropFirst(2).first == "C" ? "county/" : "forecast/") + code
                }
                let rings = await outlines(urls)
                if !rings.isEmpty {
                    alerts.append(NWSAlert(id: "aprs:" + b.sender + b.text, event: b.destination + " " + b.text.prefix(40),
                                           headline: b.text, severity: "", area: Self.ugcCodes(b.text).joined(separator: " "),
                                           expires: nil, polygons: rings))
                }
            }
            aprsMapped = alerts
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

/** The parts of an APRS bulletin the NWS layer needs. */
struct AprsBulletinText {
    let sender: String
    let destination: String
    let text: String
}
