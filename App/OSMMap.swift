import AprsCore
import MapKit
import SwiftUI

enum TilePreset: String, CaseIterable, Identifiable {
    case project = "pdeffenb"
    case community = "OpenStreetMap"

    var id: String { rawValue }
    var template: String {
        switch self {
        case .project: return "http://pdeffenb.homeip.net:82/raster/light/{z}/{x}/{y}.png"
        case .community: return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        }
    }
}

private final class OSMTiles: MKTileOverlay {
    let preset: TilePreset

    init(preset: TilePreset) {
        self.preset = preset
        super.init(urlTemplate: preset.template)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        // A recently cached tile is used as is; an older one only when the network fails (offline use).
        let cached = TileCache.read(preset, z: path.z, x: path.x, y: path.y)
        if let cached, cached.age < TileCache.freshSeconds {
            result(cached.data, nil)
            return
        }
        TileCache.download(preset, z: path.z, x: path.x, y: path.y, url: url(forTilePath: path)) { data in
            if let data {
                result(data, nil)
            } else if let cached {
                result(cached.data, nil)
            } else {
                result(nil, URLError(.notConnectedToInternet))
            }
        }
    }
}

/** Where the map is looking, for the offline-map preloader. Updated whenever the map moves. */
enum MapViewport {
    static var region: MKCoordinateRegion?
    static var zoom: Int = 10
}

/** A request to center the map on a station; a new id re-triggers even for the same station. */
struct MapFocus: Equatable {
    let id = UUID()
    let callsign: String
    let coordinate: CLLocationCoordinate2D
    /** Zoom to this many meters across; nil keeps the current zoom (capped at about 20 km). */
    var meters: Double? = nil

    static func == (a: MapFocus, b: MapFocus) -> Bool { a.id == b.id }
}

final class StationAnnotation: MKPointAnnotation {
    var callsign = ""
    var kind = "station"
    var image = "mappin"
    var watched = false
}

/** Something else drawn as a marker: a satellite, an imported waypoint or a digital-mode spot. */
final class ExtraAnnotation: MKPointAnnotation {
    var kind = "waypoint"
    var image = "mappin"
    var tint: PlatformColor = .systemGray
}

/** A marker the map shows besides stations. */
struct MapMarker: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let kind: String
    let image: String

    static func == (a: MapMarker, b: MapMarker) -> Bool {
        a.id == b.id && a.title == b.title && a.subtitle == b.subtitle && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude && a.image == b.image
    }
}

/** A line or polygon drawn over the map (imported tracks, measure line, DF bearings, shapes). */
struct MapShape {
    let id: String
    let points: [CLLocationCoordinate2D]
    let closed: Bool
    let color: PlatformColor
    var dashed = false
    var width: CGFloat = 2
    var fillAlpha: CGFloat = 0.12

    var signature: String {
        "\(closed)|\(dashed)|\(width)|\(fillAlpha)|\(color.description)|" + points.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ";")
    }
}

/** A circle drawn over the map (satellite footprints, radio horizons). */
struct MapCircle {
    let id: String
    let center: CLLocationCoordinate2D
    let radius: Double
    let color: PlatformColor
    var dashed = false
    var fillAlpha: CGFloat = 0.05

    var signature: String { String(format: "%.4f,%.4f,%.0f|\(dashed)|\(color.description)", center.latitude, center.longitude, radius) }
}

enum StationLabels: String, CaseIterable, Identifiable {
    case off = "No labels", callsign = "Callsign", full = "Callsign and details"
    var id: String { rawValue }
}

/** Everything drawn over the map besides station markers. */
struct MapLayers {
    var tracks: [String: [TrackPoint]] = [:]
    var showTracks = true
    var showCoverage = false
    var showDeadReckoning = true
    /** Range rings: a center and the ring radii in meters (empty for none). */
    var ringCenter: CLLocationCoordinate2D?
    var ringRadii: [Double] = []
    var alerts: [NWSAlert] = []
    /** Watched callsign patterns, drawn in yellow and never hidden by MapKit's decluttering. */
    var watched: [String] = []
    var labels: StationLabels = .callsign
    /** Your names for stations, shown instead of the callsign. */
    var nicknames: [String: String] = [:]
    /** Draw the route each RF packet took (station → digipeaters → IGate) for these stations. */
    var pathStations: Set<String> = []
    var showDF = true
    var showHorizons = false
    var showAmbiguity = true
    var showShapes = true
    /** Weather radar overlay opacity (0 hides it). */
    var radarOpacity: Double = 0
    /** State and county boundaries and roads, online and imported. */
    var reference = ReferenceSettings()
    var markers: [MapMarker] = []
    var shapes: [MapShape] = []
    var circles: [MapCircle] = []
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

/** Overlays that carry their own drawing style. */
final class StyledPolyline: MKPolyline {
    var color: PlatformColor = .systemBlue
    var width: CGFloat = 2
    var dashed = false
}

final class StyledCircle: MKCircle {
    var color: PlatformColor = .systemBlue
    var fillAlpha: CGFloat = 0
    var dashed = false
}

final class StyledPolygon: MKPolygon {
    var color: PlatformColor = .systemRed
    var fillAlpha: CGFloat = 0.18
    var dashed = false
}

/** NEXRAD composite reflectivity tiles from Iowa Environmental Mesonet (USA), refreshed every five minutes. */
final class RadarTiles: MKTileOverlay {
    var opacity: CGFloat = 0.5
    init() {
        let stamp = Int(Date().timeIntervalSince1970 / 300)
        super.init(urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/{z}/{x}/{y}.png?\(stamp)")
        canReplaceMapContent = false
        maximumZ = 12
    }
}

/** Keeps a keyed set of overlays in step with what should be drawn, replacing only what changed. */
final class OverlayGroup {
    private var current: [String: (signature: String, overlay: MKOverlay)] = [:]

    func sync(_ map: MKMapView, wanted: [String: (signature: String, make: () -> MKOverlay)]) {
        for (key, entry) in current where wanted[key]?.signature != entry.signature {
            map.removeOverlay(entry.overlay)
            current[key] = nil
        }
        for (key, want) in wanted where current[key] == nil {
            let overlay = want.make()
            map.addOverlay(overlay, level: .aboveLabels)
            current[key] = (want.signature, overlay)
        }
    }
}

#if os(macOS)
typealias NativeMapRepresentable = NSViewRepresentable
#else
typealias NativeMapRepresentable = UIViewRepresentable
#endif

struct OSMMap: NativeMapRepresentable {
    let preset: TilePreset
    let stations: [StationDetail]
    let track: [CLLocation]
    let follow: Bool
    let focus: MapFocus?
    let layers: MapLayers
    /** Where the bubble measures distance from: your GPS fix, else the map center. */
    let origin: CLLocationCoordinate2D
    let originLabel: String
    let onDetails: (String) -> Void
    let onMessage: (String) -> Void
    @Binding var center: CLLocationCoordinate2D
    @Binding var selectedStation: String?
    /** Where the selected station's marker is on screen (top-left origin), for positioning its bubble. */
    @Binding var calloutPoint: CGPoint?

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMap(context.coordinator) }
    func updateNSView(_ map: MKMapView, context: Context) { context.coordinator.update(map, with: self) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMap(context.coordinator) }
    func updateUIView(_ map: MKMapView, context: Context) { context.coordinator.update(map, with: self) }
    #endif

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func makeMap(_ coordinator: Coordinator) -> MKMapView {
        let map = MKMapView()
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 120_000, longitudinalMeters: 120_000),
                      animated: false)
        map.delegate = coordinator
        coordinator.update(map, with: self)
        return map
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var parent: OSMMap
        private var source: TilePreset?
        private var tiles: OSMTiles?
        private var markers: [String: StationAnnotation] = [:]
        private var focusID: UUID?
        private weak var mapView: MKMapView?
        private var previousSelection: String?
        /** The label mode the marker views were last drawn with. */
        private var appliedLabels: StationLabels?
        private var trackOverlays: [String: (count: Int, line: StyledPolyline)] = [:]
        private var coverageOverlays: [String: (key: String, circle: StyledCircle)] = [:]
        private var reckoningOverlays: [String: (key: String, line: StyledPolyline)] = [:]
        private var ringOverlays: (key: String, circles: [StyledCircle])?
        private var alertOverlays: (key: String, polygons: [StyledPolygon])?
        private let pathGroup = OverlayGroup()
        private let dfGroup = OverlayGroup()
        private let horizonGroup = OverlayGroup()
        private let ambiguityGroup = OverlayGroup()
        private let shapeGroup = OverlayGroup()
        private let extraShapeGroup = OverlayGroup()
        private let extraCircleGroup = OverlayGroup()
        private var radar: RadarTiles?
        /** Boundary and road layers in drawing order (boundaries, roads, imported), with what each was made from. */
        private var referenceLayers: [(signature: String, overlay: MKTileOverlay)] = []
        private var radarStamp = 0
        private var extraMarkers: [String: ExtraAnnotation] = [:]
        private var trail: MKPolyline?
        private var position: MKPointAnnotation?
        private var previousFix: Date?
        private var wasFollowing = false

        init(parent: OSMMap) { self.parent = parent }

        func update(_ map: MKMapView, with parent: OSMMap) {
            self.parent = parent
            if source != parent.preset {
                let overlay = OSMTiles(preset: parent.preset)
                overlay.canReplaceMapContent = true
                overlay.maximumZ = 19
                if let tiles { map.removeOverlay(tiles) }
                map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                tiles = overlay
                source = parent.preset
            }
            mapView = map
            updateReference(on: map)
            updateStations(on: map)
            if appliedLabels != parent.layers.labels {
                appliedLabels = parent.layers.labels
                for case let marker as StationAnnotation in map.annotations {
                    guard let view = map.view(for: marker) as? MKMarkerAnnotationView else { continue }
                    applyLabels(to: view)
                }
            }
            updateTrack(on: map)
            updateLayers(on: map)
            // Closing the bubble clears the selection in SwiftUI; mirror that on the map. Only act on a change
            // from a station to none, because a click's own selection reaches SwiftUI a moment later.
            if parent.selectedStation == nil, previousSelection != nil {
                for selected in map.selectedAnnotations where selected is StationAnnotation {
                    map.deselectAnnotation(selected, animated: false)
                }
            }
            previousSelection = parent.selectedStation
            updateCalloutPoint(map)
            if let focus = parent.focus, focus.id != focusID {
                focusID = focus.id
                if let meters = focus.meters {
                    map.setRegion(MKCoordinateRegion(center: focus.coordinate, latitudinalMeters: meters,
                                                     longitudinalMeters: meters), animated: true)
                } else {
                    let span = min(map.region.span.latitudeDelta, 0.2)
                    map.setRegion(MKCoordinateRegion(center: focus.coordinate,
                                                     span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)),
                                  animated: true)
                }
                if let marker = markers[focus.callsign] { map.selectAnnotation(marker, animated: true) }
            }
        }

        private func updateStations(on map: MKMapView) {
            let names = Set(parent.stations.map(\.callsign))
            for old in Set(markers.keys).subtracting(names) {
                if let marker = markers.removeValue(forKey: old) { map.removeAnnotation(marker) }
            }
            for station in parent.stations {
                let point = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
                let image = station.symbolInfo.image
                let subtitle = Self.subtitle(for: station)
                let watched = WatchList.matches(station.callsign, parent.layers.watched)
                let title = parent.layers.nicknames[station.callsign].map { "\($0) (\(station.callsign))" } ?? station.callsign
                if let marker = markers[station.callsign], marker.kind == station.kind, marker.image == image,
                   marker.watched == watched {
                    if marker.coordinate.latitude != point.latitude || marker.coordinate.longitude != point.longitude {
                        marker.coordinate = point
                    }
                    if marker.subtitle != subtitle { marker.subtitle = subtitle }
                    if marker.title != title { marker.title = title }
                } else {
                    if let old = markers[station.callsign] { map.removeAnnotation(old) }
                    let marker = StationAnnotation()
                    marker.callsign = station.callsign
                    marker.coordinate = point
                    marker.title = title
                    marker.subtitle = subtitle
                    marker.kind = station.kind
                    marker.image = image
                    marker.watched = watched
                    markers[station.callsign] = marker
                    map.addAnnotation(marker)
                }
            }
        }

        private static func subtitle(for station: StationDetail) -> String {
            let metric = UserDefaults.standard.bool(forKey: "useMetric")
            var parts: [String] = []
            if let t = station.temperatureC?.doubleValue { parts.append(Units.temperature(t, metric: metric)) }
            if let wind = station.windKph?.doubleValue { parts.append("wind \(Units.speed(kph: wind, metric: metric))") }
            if let knots = station.speedKnots?.doubleValue, knots >= 1 { parts.append(Units.speed(knots: knots, metric: metric)) }
            if let altitude = station.altitudeMeters?.doubleValue, altitude > 0 { parts.append(Units.altitude(altitude, metric: metric)) }
            if parts.isEmpty { parts.append(station.comment.isEmpty ? station.symbolInfo.name : station.comment) }
            return parts.joined(separator: " · ")
        }

        private static let trackPalette: [PlatformColor] = [.systemRed, .systemOrange, .systemPurple, .systemPink,
                                                             .systemBrown, .systemIndigo, .systemTeal, .systemGreen]

        /** Applies the map layers, replacing only the overlays whose data changed. */
        private func updateLayers(on map: MKMapView) {
            let layers = parent.layers
            let shown = Dictionary(uniqueKeysWithValues: parent.stations.map { ($0.callsign, $0) })

            // Paths of travel for other stations.
            let wantedTracks = layers.showTracks ? layers.tracks.filter { shown[$0.key] != nil } : [:]
            for (call, entry) in trackOverlays where wantedTracks[call]?.count != entry.count {
                map.removeOverlay(entry.line)
                trackOverlays[call] = nil
            }
            for (call, points) in wantedTracks where trackOverlays[call] == nil {
                let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let line = StyledPolyline(coordinates: coordinates, count: coordinates.count)
                line.color = Self.trackPalette[Int(call.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ $1.value } % UInt32(Self.trackPalette.count))]
                line.width = 2
                map.addOverlay(line, level: .aboveLabels)
                trackOverlays[call] = (points.count, line)
            }

            // PHG / RNG coverage circles.
            var wantedCoverage: [String: (String, CLLocationCoordinate2D, Double)] = [:]
            if layers.showCoverage {
                for station in parent.stations {
                    guard let radius = station.coverageMeters?.doubleValue, radius > 0 else { continue }
                    wantedCoverage[station.callsign] = ("\(station.latitude),\(station.longitude),\(Int(radius))", station.coordinate, radius)
                }
            }
            for (call, entry) in coverageOverlays where wantedCoverage[call]?.0 != entry.key {
                map.removeOverlay(entry.circle)
                coverageOverlays[call] = nil
            }
            for (call, want) in wantedCoverage where coverageOverlays[call] == nil {
                let circle = StyledCircle(center: want.1, radius: want.2)
                circle.color = .systemGreen
                circle.fillAlpha = 0.06
                map.addOverlay(circle, level: .aboveLabels)
                coverageOverlays[call] = (want.0, circle)
            }

            // Dead reckoning: a dashed line from the last report to the projected position.
            var wantedReckoning: [String: (String, [CLLocationCoordinate2D])] = [:]
            if layers.showDeadReckoning {
                for station in parent.stations {
                    guard let lat = station.predictedLatitude?.doubleValue, let lon = station.predictedLongitude?.doubleValue else { continue }
                    let predicted = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    guard Geo.distance(station.coordinate, predicted) > 20 else { continue }
                    wantedReckoning[station.callsign] = (String(format: "%.5f,%.5f", lat, lon), [station.coordinate, predicted])
                }
            }
            for (call, entry) in reckoningOverlays where wantedReckoning[call]?.0 != entry.key {
                map.removeOverlay(entry.line)
                reckoningOverlays[call] = nil
            }
            for (call, want) in wantedReckoning where reckoningOverlays[call] == nil {
                let line = StyledPolyline(coordinates: want.1, count: want.1.count)
                line.color = .systemGray
                line.width = 2
                line.dashed = true
                map.addOverlay(line, level: .aboveLabels)
                reckoningOverlays[call] = (want.0, line)
            }

            // Range rings around you.
            let ringKey = layers.ringCenter.map { String(format: "%.4f,%.4f|", $0.latitude, $0.longitude) + layers.ringRadii.map { "\(Int($0))" }.joined(separator: ",") } ?? ""
            if ringOverlays?.key != ringKey {
                ringOverlays?.circles.forEach { map.removeOverlay($0) }
                var circles: [StyledCircle] = []
                if let center = layers.ringCenter {
                    for radius in layers.ringRadii where radius > 0 {
                        let circle = StyledCircle(center: center, radius: radius)
                        circle.color = .systemBlue
                        circle.dashed = true
                        map.addOverlay(circle, level: .aboveLabels)
                        circles.append(circle)
                    }
                }
                ringOverlays = (ringKey, circles)
            }

            // NWS warning polygons.
            let alertKey = layers.alerts.map(\.id).joined(separator: "|")
            if alertOverlays?.key != alertKey {
                alertOverlays?.polygons.forEach { map.removeOverlay($0) }
                var polygons: [StyledPolygon] = []
                for alert in layers.alerts {
                    for ring in alert.polygons {
                        let polygon = StyledPolygon(coordinates: ring, count: ring.count)
                        polygon.color = PlatformColor(alert.color)
                        polygon.title = alert.event
                        map.addOverlay(polygon, level: .aboveLabels)
                        polygons.append(polygon)
                    }
                }
                alertOverlays = (alertKey, polygons)
            }
            updateExtras(on: map, shown: shown)
        }

        private static func color(hex: String) -> PlatformColor {
            let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard digits.count == 6, let v = Int(digits, radix: 16) else { return .systemRed }
            return PlatformColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                                 blue: CGFloat(v & 255) / 255, alpha: 1)
        }

        private static func points(_ text: String) -> [CLLocationCoordinate2D] {
            text.split(separator: ";").compactMap { pair in
                let v = pair.split(separator: ",").compactMap { Double($0) }
                return v.count == 2 ? CLLocationCoordinate2D(latitude: v[0], longitude: v[1]) : nil
            }
        }

        private static func project(_ from: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
            let r = 6_371_000.0, d = meters / r, b = bearing * .pi / 180
            let lat1 = from.latitude * .pi / 180, lon1 = from.longitude * .pi / 180
            let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
            let lon2 = lon1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
            return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
        }

        /** Boundaries and roads: the Census Bureau's online layers and imported files, just above the base map. */
        private func updateReference(on map: MKMapView) {
            let settings = parent.layers.reference
            var wanted: [(signature: String, make: () -> MKTileOverlay)] = []
            if settings.drawsOnline {
                let states = settings.kinds.contains(.states), counties = settings.kinds.contains(.counties)
                if states || counties {
                    let content = TigerTiles.Content.boundaries(states: states, counties: counties, names: settings.names)
                    wanted.append(("online \(content)", { TigerTiles(content: content) }))
                }
                let roads = settings.kinds.filter(\.isRoad)
                if !roads.isEmpty {
                    let content = TigerTiles.Content.roads(roads)
                    wanted.append(("online roads " + roads.map(\.rawValue).sorted().joined(separator: ","), { TigerTiles(content: content) }))
                }
            }
            let visible = Set(ReferenceStore.shared.files.filter(\.visible).map(\.id))
            if settings.drawsImported, !visible.isEmpty {
                let kinds = settings.kinds
                let signature = "imported " + kinds.map(\.rawValue).sorted().joined(separator: ",")
                    + " \(settings.importedRevision) " + visible.map(\.uuidString).sorted().joined(separator: ",")
                wanted.append((signature, { ImportedReferenceTiles(kinds: kinds, visible: visible) }))
            }
            guard wanted.map(\.signature) != referenceLayers.map(\.signature) else { return }
            for layer in referenceLayers { map.removeOverlay(layer.overlay) }
            referenceLayers = []
            var below: MKOverlay? = tiles
            for want in wanted {
                let overlay = want.make()
                if let below { map.insertOverlay(overlay, above: below) } else { map.addOverlay(overlay, level: .aboveLabels) }
                referenceLayers.append((want.signature, overlay))
                below = overlay
            }
        }

        /** Packet paths, DF beams, radio horizons, ambiguity cells, shapes, radar, and the app's own markers and lines. */
        private func updateExtras(on map: MKMapView, shown: [String: StationDetail]) {
            let layers = parent.layers

            // The route a packet took: station → digipeaters → IGate, where their positions are known.
            var paths: [String: (signature: String, make: () -> MKOverlay)] = [:]
            for call in layers.pathStations {
                guard let station = shown[call] ?? parent.stations.first(where: { $0.callsign == call }) else { continue }
                let nodes = station.pathNodes.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                var coordinates = [station.coordinate]
                for node in nodes.dropFirst() where !node.isEmpty {
                    if let hop = shown[node] ?? parent.stations.first(where: { $0.callsign == node }) { coordinates.append(hop.coordinate) }
                }
                guard coordinates.count >= 2 else { continue }
                let sig = coordinates.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: ";")
                paths[call] = (sig, {
                    let line = StyledPolyline(coordinates: coordinates, count: coordinates.count)
                    line.color = .systemIndigo
                    line.width = 2.5
                    return line
                })
            }
            pathGroup.sync(map, wanted: paths)

            // Direction finding: a beam from the reporting station along its bearing.
            var beams: [String: (signature: String, make: () -> MKOverlay)] = [:]
            if layers.showDF {
                for station in parent.stations {
                    guard let bearing = station.dfBearing?.doubleValue else { continue }
                    let length = station.dfRangeMeters?.doubleValue ?? 30_000
                    let spread = station.dfAccuracy?.doubleValue ?? 0
                    let start = station.coordinate
                    let sig = String(format: "%.4f,%.4f,%.0f,%.0f,%.0f", start.latitude, start.longitude, bearing, length, spread)
                    beams[station.callsign] = (sig, {
                        if spread > 1 {
                            let ring = [start, Self.project(start, bearing: bearing - spread, meters: length),
                                        Self.project(start, bearing: bearing + spread, meters: length)]
                            let wedge = StyledPolygon(coordinates: ring, count: ring.count)
                            wedge.color = .systemPink
                            wedge.fillAlpha = 0.1
                            return wedge
                        }
                        let ends = [start, Self.project(start, bearing: bearing, meters: length)]
                        let line = StyledPolyline(coordinates: ends, count: 2)
                        line.color = .systemPink
                        line.width = 2
                        return line
                    })
                }
            }
            dfGroup.sync(map, wanted: beams)

            // Radio horizon for aircraft and balloons (4/3-earth, receiver 2 m up, ground at sea level).
            var horizons: [String: (signature: String, make: () -> MKOverlay)] = [:]
            if layers.showHorizons {
                for station in parent.stations {
                    guard let altitude = station.altitudeMeters?.doubleValue, altitude >= 300 else { continue }
                    let radius = 4120 * (altitude.squareRoot() + 2.0.squareRoot())
                    let center = station.coordinate
                    horizons[station.callsign] = (String(format: "%.3f,%.3f,%.0f", center.latitude, center.longitude, radius), {
                        let c = StyledCircle(center: center, radius: radius)
                        c.color = .systemCyan
                        c.dashed = true
                        c.fillAlpha = 0.03
                        return c
                    })
                }
            }
            horizonGroup.sync(map, wanted: horizons)

            // Ambiguous positions: the cell the station could be anywhere in.
            var cells: [String: (signature: String, make: () -> MKOverlay)] = [:]
            if layers.showAmbiguity {
                for station in parent.stations where station.ambiguityDigits > 0 {
                    let half: Double = [0.0, 0.1, 1, 10, 60][Int(min(4, station.ambiguityDigits))] / 60 / 2
                    let c = station.coordinate
                    let ring = [CLLocationCoordinate2D(latitude: c.latitude - half, longitude: c.longitude - half),
                                CLLocationCoordinate2D(latitude: c.latitude - half, longitude: c.longitude + half),
                                CLLocationCoordinate2D(latitude: c.latitude + half, longitude: c.longitude + half),
                                CLLocationCoordinate2D(latitude: c.latitude + half, longitude: c.longitude - half)]
                    cells[station.callsign] = (String(format: "%.4f,%.4f,%d", c.latitude, c.longitude, station.ambiguityDigits), {
                        let p = StyledPolygon(coordinates: ring, count: ring.count)
                        p.color = .systemGray
                        p.fillAlpha = 0.12
                        p.dashed = true
                        return p
                    })
                }
            }
            ambiguityGroup.sync(map, wanted: cells)

            // Multiline and area objects.
            var objectShapes: [String: (signature: String, make: () -> MKOverlay)] = [:]
            if layers.showShapes {
                for station in parent.stations where !station.shapePoints.isEmpty {
                    let coordinates = Self.points(station.shapePoints)
                    guard coordinates.count >= 2 else { continue }
                    let color = Self.color(hex: station.shapeColor)
                    let closed = station.shapeClosed, filled = station.shapeFilled, dashed = station.shapeDashed
                    objectShapes[station.callsign] = (station.shapePoints + "|\(station.shapeColor)|\(closed)|\(filled)|\(dashed)", {
                        if closed {
                            let p = StyledPolygon(coordinates: coordinates, count: coordinates.count)
                            p.color = color
                            p.fillAlpha = filled ? 0.25 : 0.05
                            p.dashed = dashed
                            return p
                        }
                        let line = StyledPolyline(coordinates: coordinates, count: coordinates.count)
                        line.color = color
                        line.width = 3
                        line.dashed = dashed
                        return line
                    })
                }
            }
            shapeGroup.sync(map, wanted: objectShapes)

            // The app's own lines and areas, and circles.
            var lines: [String: (signature: String, make: () -> MKOverlay)] = [:]
            for shape in layers.shapes where shape.points.count >= 2 {
                lines[shape.id] = (shape.signature, {
                    if shape.closed {
                        let p = StyledPolygon(coordinates: shape.points, count: shape.points.count)
                        p.color = shape.color
                        p.fillAlpha = shape.fillAlpha
                        p.dashed = shape.dashed
                        return p
                    }
                    let line = StyledPolyline(coordinates: shape.points, count: shape.points.count)
                    line.color = shape.color
                    line.width = shape.width
                    line.dashed = shape.dashed
                    return line
                })
            }
            extraShapeGroup.sync(map, wanted: lines)
            var rings: [String: (signature: String, make: () -> MKOverlay)] = [:]
            for circle in layers.circles where circle.radius > 0 {
                rings[circle.id] = (circle.signature, {
                    let c = StyledCircle(center: circle.center, radius: circle.radius)
                    c.color = circle.color
                    c.dashed = circle.dashed
                    c.fillAlpha = circle.fillAlpha
                    return c
                })
            }
            extraCircleGroup.sync(map, wanted: rings)

            // Weather radar.
            let stamp = Int(Date().timeIntervalSince1970 / 300)
            if layers.radarOpacity > 0 {
                if radar == nil || radarStamp != stamp {
                    if let radar { map.removeOverlay(radar) }
                    let overlay = RadarTiles()
                    overlay.opacity = layers.radarOpacity
                    map.addOverlay(overlay, level: .aboveRoads)
                    radar = overlay
                    radarStamp = stamp
                } else if let radar, radar.opacity != layers.radarOpacity {
                    radar.opacity = layers.radarOpacity
                    if let renderer = map.renderer(for: radar) { renderer.alpha = layers.radarOpacity }
                }
            } else if let radar {
                map.removeOverlay(radar)
                self.radar = nil
            }

            // Satellites, waypoints and digital-mode spots.
            let wanted = Dictionary(layers.markers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, marker) in extraMarkers where wanted[id] == nil {
                map.removeAnnotation(marker)
                extraMarkers[id] = nil
            }
            for (id, want) in wanted {
                if let marker = extraMarkers[id], marker.image == want.image, marker.kind == want.kind {
                    if marker.coordinate.latitude != want.coordinate.latitude || marker.coordinate.longitude != want.coordinate.longitude {
                        marker.coordinate = want.coordinate
                    }
                    if marker.subtitle != want.subtitle { marker.subtitle = want.subtitle }
                    continue
                }
                if let old = extraMarkers[id] { map.removeAnnotation(old) }
                let marker = ExtraAnnotation()
                marker.coordinate = want.coordinate
                marker.title = want.title
                marker.subtitle = want.subtitle
                marker.kind = want.kind
                marker.image = want.image
                extraMarkers[id] = marker
                map.addAnnotation(marker)
            }
        }

        private func updateTrack(on map: MKMapView) {
            let fix = parent.track.last
            if fix?.timestamp != previousFix {
                if let trail { map.removeOverlay(trail) }
                trail = nil
                if let fix {
                    let marker = position ?? MKPointAnnotation()
                    marker.title = "My location"
                    marker.coordinate = fix.coordinate
                    let isNew = position == nil
                    position = marker
                    if isNew { map.addAnnotation(marker) }
                    let points = parent.track.map(\.coordinate)
                    if points.count > 1 {
                        let line = MKPolyline(coordinates: points, count: points.count)
                        trail = line
                        map.addOverlay(line, level: .aboveLabels)
                    }
                } else if let position {
                    map.removeAnnotation(position)
                    self.position = nil
                }
            }
            if let fix, parent.follow, !wasFollowing || fix.timestamp != previousFix {
                if previousFix == nil {
                    map.setRegion(MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: 2_000,
                                                     longitudinalMeters: 2_000), animated: true)
                } else {
                    map.setCenter(fix.coordinate, animated: true)
                }
            }
            previousFix = fix?.timestamp
            wasFollowing = parent.follow
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateCalloutPoint(mapView)
            MapViewport.region = mapView.region
            let width = max(1, Double(mapView.bounds.width))
            MapViewport.zoom = max(1, min(19, Int(log2(360 * width / 256 / max(mapView.region.span.longitudeDelta, 1e-6)).rounded())))
            let location = mapView.centerCoordinate
            DispatchQueue.main.async { [weak self] in self?.parent.center = location }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? RadarTiles {
                let renderer = MKTileOverlayRenderer(tileOverlay: overlay)
                renderer.alpha = overlay.opacity
                return renderer
            }
            if let overlay = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: overlay) }
            if let line = overlay as? StyledPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = line.color.withAlphaComponent(0.8)
                renderer.lineWidth = line.width
                if line.dashed { renderer.lineDashPattern = [6, 5] }
                return renderer
            }
            if let circle = overlay as? StyledCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = circle.color.withAlphaComponent(0.7)
                renderer.fillColor = circle.color.withAlphaComponent(circle.fillAlpha)
                renderer.lineWidth = 1.5
                if circle.dashed { renderer.lineDashPattern = [8, 6] }
                return renderer
            }
            if let polygon = overlay as? StyledPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = polygon.color.withAlphaComponent(0.9)
                renderer.fillColor = polygon.color.withAlphaComponent(polygon.fillAlpha)
                renderer.lineWidth = 2
                if polygon.dashed { renderer.lineDashPattern = [6, 4] }
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        /** Shows the callsign (and, for "Callsign and details", the summary line) under a station marker. */
        private func applyLabels(to view: MKMarkerAnnotationView) {
            view.titleVisibility = parent.layers.labels == .off ? .hidden : .visible
            view.subtitleVisibility = parent.layers.labels == .full ? .visible : .hidden
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let station = annotation as? StationAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "station") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: station, reuseIdentifier: "station")
                view.annotation = station
                // The station bubble is drawn in SwiftUI, so MapKit's own callout stays off.
                view.canShowCallout = false
                view.glyphImage = makeGlyph(station.image)
                view.displayPriority = station.watched ? .required : .defaultHigh
                applyLabels(to: view)
                switch station.watched ? "watched" : station.kind {
                case "watched": view.markerTintColor = .systemYellow
                case "weather": view.markerTintColor = .systemTeal
                case "object": view.markerTintColor = .systemOrange
                case "item": view.markerTintColor = .systemPurple
                default: view.markerTintColor = .systemRed
                }
                return view
            }
            if let extra = annotation as? ExtraAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "extra") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: extra, reuseIdentifier: "extra")
                view.annotation = extra
                view.canShowCallout = true
                view.glyphImage = makeGlyph(extra.image)
                view.titleVisibility = .visible
                switch extra.kind {
                case "satellite": view.markerTintColor = .systemIndigo
                case "digital": view.markerTintColor = .systemMint
                case "measure": view.markerTintColor = .systemBlue
                default: view.markerTintColor = .systemBrown
                }
                view.displayPriority = extra.kind == "satellite" ? .required : .defaultLow
                return view
            }
            guard let point = annotation as? MKPointAnnotation, point === position else { return nil }
            let marker = MKMarkerAnnotationView(annotation: point, reuseIdentifier: "gps")
            marker.markerTintColor = .systemBlue
            marker.glyphImage = makeLocationGlyph()
            return marker
        }

        /** Publishes the selected marker's screen position; the SwiftUI bubble is drawn there. */
        private func updateCalloutPoint(_ map: MKMapView) {
            var point: CGPoint?
            if let marker = map.selectedAnnotations.first(where: { $0 is StationAnnotation }) {
                let raw = map.convert(marker.coordinate, toPointTo: map)
                #if os(macOS)
                point = map.isFlipped ? raw : CGPoint(x: raw.x, y: map.bounds.height - raw.y)
                #else
                point = raw
                #endif
                if let p = point, !map.bounds.insetBy(dx: -40, dy: -40).contains(p) {
                    point = nil
                }
            }
            let current = parent.calloutPoint
            let changed: Bool
            switch (current, point) {
            case (nil, nil): changed = false
            case let (a?, b?): changed = abs(a.x - b.x) > 0.5 || abs(a.y - b.y) > 0.5
            default: changed = true
            }
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.calloutPoint = point }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { updateCalloutPoint(mapView) }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            updateCalloutPoint(mapView)
            let callsign = (view.annotation as? StationAnnotation)?.callsign
            DispatchQueue.main.async { [weak self] in
                self?.parent.selectedStation = callsign.flatMap { self?.markers[$0] != nil ? $0 : nil }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            updateCalloutPoint(mapView)
            let callsign = (view.annotation as? StationAnnotation)?.callsign
            DispatchQueue.main.async { [weak self] in
                if self?.parent.selectedStation == callsign { self?.parent.selectedStation = nil }
            }
        }

        #if os(macOS)
        private func makeLocationGlyph() -> NSImage? { NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil) }
        private func makeGlyph(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        #else
        private func makeLocationGlyph() -> UIImage? { UIImage(systemName: "location.fill") }
        private func makeGlyph(_ name: String) -> UIImage? { UIImage(systemName: name) }
        #endif
    }
}
