import AprsCore
import CoreLocation
import Foundation
import MapKit
import SwiftUI

/** A bearing you took (manual direction finding), drawn from where you took it. */
struct ManualBearing: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var label = ""
    var latitude: Double
    var longitude: Double
    var bearing: Double
    var lengthKm: Double = 30
    var time = Date()
}

/** A station spotted in a digital-mode log (WSJT-X FT8, JS8Call, JT65-HF), placed at its grid square. */
struct DigitalSpot: Codable, Identifiable, Equatable {
    var id: String { callsign }
    var callsign: String
    var grid: String
    var mode: String
    var time: Date
    var latitude: Double
    var longitude: Double
}

/** An imported GPX or OSM layer. */
struct ImportedLayer: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var visible = true
    var lines: [[[Double]]] = []
    var waypoints: [Waypoint] = []

    struct Waypoint: Codable, Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
    }
}

/** Map content that isn't a station: satellites, bearings, imports, digital spots, the measuring line. */
@MainActor
final class MapExtras: ObservableObject {
    static let shared = MapExtras()

    @Published var bearings: [ManualBearing] = MapExtras.loadList("manualBearings") { didSet { MapExtras.saveList(bearings, "manualBearings") } }
    @Published var spots: [DigitalSpot] = MapExtras.loadList("digitalSpots") { didSet { MapExtras.saveList(spots, "digitalSpots") } }
    @Published var layers: [ImportedLayer] = MapExtras.loadLayers() { didSet { MapExtras.saveLayers(layers) } }
    @Published var satellites: [SatellitePosition] = []
    @Published var trackedSatellites: [String] = UserDefaults.standard.stringArray(forKey: "trackedSatellites") ?? ["ISS (ZARYA)"] {
        didSet { UserDefaults.standard.set(trackedSatellites, forKey: "trackedSatellites") }
    }
    /** Measuring tool: point A and B (set from the map center). */
    @Published var measureA: CLLocationCoordinate2D?
    @Published var measureB: CLLocationCoordinate2D?
    @Published var showSpots = true

    private static func loadList<T: Decodable>(_ key: String) -> [T] { SavedList.load(key) }
    private static func saveList<T: Encodable>(_ list: [T], _ key: String) { SavedList.save(list, key) }

    /** Imported layers live in Application Support (they can be large). */
    private static var layersFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APRSERJi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layers.json")
    }

    private static func loadLayers() -> [ImportedLayer] {
        guard let data = try? Data(contentsOf: layersFile) else { return [] }
        return (try? JSONDecoder().decode([ImportedLayer].self, from: data)) ?? []
    }

    private static func saveLayers(_ layers: [ImportedLayer]) {
        if let data = try? JSONEncoder().encode(layers) { try? data.write(to: layersFile, options: .atomic) }
    }

    /** Markers, lines and circles for the map. */
    func apply(to layers: inout MapLayers, metric: Bool) {
        for sat in satellites {
            layers.markers.append(MapMarker(id: "sat:" + sat.name, title: sat.name,
                                            subtitle: String(format: "%.0f km up · el %.0f° az %.0f°", sat.altitudeKm, sat.elevation, sat.azimuth),
                                            coordinate: CLLocationCoordinate2D(latitude: sat.latitude, longitude: sat.longitude),
                                            kind: "satellite", image: "antenna.radiowaves.left.and.right.circle"))
            layers.circles.append(MapCircle(id: "foot:" + sat.name,
                                            center: CLLocationCoordinate2D(latitude: sat.latitude, longitude: sat.longitude),
                                            radius: sat.footprintKm * 1000, color: sat.elevation > 0 ? .systemGreen : .systemIndigo,
                                            dashed: true, fillAlpha: sat.elevation > 0 ? 0.06 : 0.02))
        }
        for b in bearings {
            let start = CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)
            layers.shapes.append(MapShape(id: "df:" + b.id, points: [start, Geo.project(start, bearing: b.bearing, meters: b.lengthKm * 1000)],
                                          closed: false, color: .systemPink, dashed: false, width: 2))
        }
        if showSpots {
            for s in spots {
                layers.markers.append(MapMarker(id: "spot:" + s.callsign, title: s.callsign, subtitle: "\(s.mode) · \(s.grid)",
                                                coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                                                kind: "digital", image: "waveform"))
            }
        }
        for layer in self.layers where layer.visible {
            for (i, line) in layer.lines.enumerated() {
                let points = line.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
                layers.shapes.append(MapShape(id: "gpx:\(layer.id):\(i)", points: points, closed: false, color: .systemBrown, width: 3))
            }
            for (i, w) in layer.waypoints.enumerated() {
                layers.markers.append(MapMarker(id: "wpt:\(layer.id):\(i)", title: w.name, subtitle: layer.name,
                                                coordinate: CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude),
                                                kind: "waypoint", image: "mappin.and.ellipse"))
            }
        }
        if let a = measureA {
            layers.markers.append(MapMarker(id: "measure:a", title: "A", subtitle: "", coordinate: a, kind: "measure", image: "a.circle"))
            if let b = measureB {
                layers.markers.append(MapMarker(id: "measure:b", title: "B",
                                                subtitle: "\(Units.distance(Geo.distance(a, b), metric: metric)) at \(Int(Geo.bearing(from: a, to: b).rounded()))°",
                                                coordinate: b, kind: "measure", image: "b.circle"))
                layers.shapes.append(MapShape(id: "measure", points: [a, b], closed: false, color: .systemBlue, dashed: true, width: 2))
            }
        }
    }

    /** Recomputes satellite positions; call every few seconds. */
    func updateSatellites(core: AppleAprs, observer: CLLocationCoordinate2D) {
        guard !trackedSatellites.isEmpty else { satellites = []; return }
        satellites = core.satellitePositions(names: trackedSatellites, latitude: observer.latitude,
                                             longitude: observer.longitude, altitudeMeters: 0)
    }
}

extension Geo {
    /** The point [meters] away from [from] along [bearing] degrees. */
    static func project(_ from: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let r = 6_371_000.0, d = meters / r, b = bearing * .pi / 180
        let lat1 = from.latitude * .pi / 180, lon1 = from.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        let lon2 = lon1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /** The center of a 4- or 6-character Maidenhead grid square. */
    static func center(ofGrid grid: String) -> CLLocationCoordinate2D? {
        let g = Array(grid.uppercased())
        guard g.count == 4 || g.count == 6,
              let a = g[0].asciiValue, let b = g[1].asciiValue, (65...82).contains(a), (65...82).contains(b),
              let c = g[2].wholeNumberValue, let d = g[3].wholeNumberValue else { return nil }
        var lon = Double(a - 65) * 20 - 180 + Double(c) * 2
        var lat = Double(b - 65) * 10 - 90 + Double(d)
        if g.count == 6, let e = g[4].asciiValue, let f = g[5].asciiValue, (65...88).contains(e), (65...88).contains(f) {
            lon += Double(e - 65) * (2.0 / 24) + 1.0 / 24
            lat += Double(f - 65) * (1.0 / 24) + 0.5 / 24
        } else {
            lon += 1
            lat += 0.5
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /**
     * Reads "41.5, -88.1", "41°30'N 88°06'W"-style decimal pairs, or a grid square. Returns nil when it can't.
     */
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let grid = center(ofGrid: t) { return grid }
        let numbers = t.replacingOccurrences(of: ",", with: " ").split(separator: " ").compactMap { Double($0) }
        if numbers.count == 2, (-90...90).contains(numbers[0]), (-180...180).contains(numbers[1]) {
            return CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1])
        }
        return nil
    }
}

/** Reads GPX (tracks, routes, waypoints) and OpenStreetMap XML (ways) into a layer. */
final class LayerParser: NSObject, XMLParserDelegate {
    private var lines: [[[Double]]] = []
    private var current: [[Double]] = []
    private var waypoints: [ImportedLayer.Waypoint] = []
    private var pendingWaypoint: (Double, Double)?
    private var text = ""
    private var nodes: [String: [Double]] = [:]
    private var inWay = false
    private var pointCount = 0
    private let limit = 200_000

    static func parse(_ data: Data, name: String) -> ImportedLayer? {
        let delegate = LayerParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() || !delegate.lines.isEmpty || !delegate.waypoints.isEmpty else { return nil }
        if delegate.lines.isEmpty && delegate.waypoints.isEmpty { return nil }
        return ImportedLayer(name: name, lines: delegate.lines, waypoints: delegate.waypoints)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        guard pointCount < limit else { parser.abortParsing(); return }
        switch element {
        case "trkseg", "rte": current = []
        case "trkpt", "rtept":
            if let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) {
                current.append([la, lo]); pointCount += 1
            }
        case "wpt":
            if let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) { pendingWaypoint = (la, lo) }
        case "node":
            if let id = attributes["id"], let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) {
                nodes[id] = [la, lo]; pointCount += 1
            }
        case "way": inWay = true; current = []
        case "nd": if inWay, let ref = attributes["ref"], let point = nodes[ref] { current.append(point) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "trkseg", "rte", "way":
            if current.count >= 2 { lines.append(current) }
            current = []
            inWay = false
        case "name":
            if let w = pendingWaypoint { waypoints.append(.init(name: text.trimmingCharacters(in: .whitespacesAndNewlines), latitude: w.0, longitude: w.1)); pendingWaypoint = nil }
        case "wpt":
            if let w = pendingWaypoint { waypoints.append(.init(name: "Waypoint", latitude: w.0, longitude: w.1)); pendingWaypoint = nil }
        default: break
        }
    }
}

/** Finds callsigns and grid squares in WSJT-X ALL.TXT, JS8Call DIRECTED/ALL.TXT and JT65-HF logs. */
enum DigitalLogParser {
    private static let call = "(?:[A-Z0-9]{1,2}/)?[A-Z0-9]{1,3}[0-9][A-Z0-9]{0,3}[A-Z](?:/[A-Z0-9]{1,4})?"
    private static let grid = "[A-R]{2}[0-9]{2}(?:[a-x]{2})?"

    static func spots(in text: String) -> [DigitalSpot] {
        var found: [String: DigitalSpot] = [:]
        let cq = try! NSRegularExpression(pattern: "\\b(?:CQ(?: [A-Z]{2,4})?|DE) (\(call)) (\(grid))\\b", options: [.caseInsensitive])
        let reply = try! NSRegularExpression(pattern: "\\b\(call) (\(call)) (\(grid))\\b")
        let js8 = try! NSRegularExpression(pattern: "\\b(\(call)):? .*?\\b(?:GRID|@APRSIS GRID) (\(grid))\\b", options: [.caseInsensitive])
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            let mode = s.contains("FT8") ? "FT8" : s.contains("FT4") ? "FT4" : s.contains("JT65") ? "JT65" : s.contains("JS8") || s.contains("@") ? "JS8" : "Digital"
            let range = NSRange(s.startIndex..., in: s)
            for regex in [cq, js8, reply] {
                guard let m = regex.firstMatch(in: s, range: range), m.numberOfRanges >= 3,
                      let c = Range(m.range(at: 1), in: s), let g = Range(m.range(at: 2), in: s) else { continue }
                let callsign = s[c].uppercased()
                let square = String(s[g])
                guard square.uppercased() != "RR73", let point = Geo.center(ofGrid: square) else { continue }
                found[callsign] = DigitalSpot(callsign: callsign, grid: square, mode: mode, time: Date(),
                                              latitude: point.latitude, longitude: point.longitude)
                break
            }
        }
        return Array(found.values).sorted { $0.callsign < $1.callsign }
    }
}
