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
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        var request = URLRequest(url: url(forTilePath: path), timeoutInterval: 15)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        request.setValue("APRSERJi/\(version) (+https://github.com/kj4dxk/APRSERJi)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result(nil, error)
            } else if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let data, !data.isEmpty {
                result(data, nil)
            } else {
                result(nil, URLError(.badServerResponse))
            }
        }.resume()
    }
}

/** A request to center the map on a station; a new id re-triggers even for the same station. */
struct MapFocus: Equatable {
    let id = UUID()
    let callsign: String
    let coordinate: CLLocationCoordinate2D

    static func == (a: MapFocus, b: MapFocus) -> Bool { a.id == b.id }
}

final class StationAnnotation: MKPointAnnotation {
    var kind = "station"
    var image = "mappin"
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
    /** Where the bubble measures distance from: your GPS fix, else the map center. */
    let origin: CLLocationCoordinate2D
    let originLabel: String
    let onDetails: (String) -> Void
    let onMessage: (String) -> Void
    @Binding var center: CLLocationCoordinate2D
    @Binding var selectedStation: String?

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
        private var callout: CalloutHost?
        private var calloutStation: StationDetail?
        private var trail: MKPolyline?
        private var position: MKPointAnnotation?
        private var previousFix: Date?
        private var wasFollowing = false

        init(parent: OSMMap) { self.parent = parent }

        func update(_ map: MKMapView, with parent: OSMMap) {
            self.parent = parent
            if source != parent.preset {
                let overlay = OSMTiles(urlTemplate: parent.preset.template)
                overlay.canReplaceMapContent = true
                overlay.maximumZ = 19
                if let tiles { map.removeOverlay(tiles) }
                map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                tiles = overlay
                source = parent.preset
            }
            mapView = map
            updateStations(on: map)
            updateTrack(on: map)
            refreshCallout()
            if let focus = parent.focus, focus.id != focusID {
                focusID = focus.id
                let span = min(map.region.span.latitudeDelta, 0.2)
                map.setRegion(MKCoordinateRegion(center: focus.coordinate,
                                                 span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)),
                              animated: true)
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
                if let marker = markers[station.callsign], marker.kind == station.kind, marker.image == image {
                    if marker.coordinate.latitude != point.latitude || marker.coordinate.longitude != point.longitude {
                        marker.coordinate = point
                    }
                    if marker.subtitle != subtitle { marker.subtitle = subtitle }
                } else {
                    if let old = markers[station.callsign] { map.removeAnnotation(old) }
                    let marker = StationAnnotation()
                    marker.coordinate = point
                    marker.title = station.callsign
                    marker.subtitle = subtitle
                    marker.kind = station.kind
                    marker.image = image
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
            if parts.isEmpty { parts.append(station.comment.isEmpty ? station.symbolInfo.name : station.comment) }
            return parts.joined(separator: " · ")
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
            let location = mapView.centerCoordinate
            DispatchQueue.main.async { [weak self] in self?.parent.center = location }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: overlay) }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let station = annotation as? StationAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "station") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: station, reuseIdentifier: "station")
                view.annotation = station
                view.canShowCallout = true
                view.detailCalloutAccessoryView = nil
                view.glyphImage = makeGlyph(station.image)
                switch station.kind {
                case "weather": view.markerTintColor = .systemTeal
                case "object": view.markerTintColor = .systemOrange
                case "item": view.markerTintColor = .systemPurple
                default: view.markerTintColor = .systemRed
                }
                return view
            }
            guard let point = annotation as? MKPointAnnotation, point === position else { return nil }
            let marker = MKMarkerAnnotationView(annotation: point, reuseIdentifier: "gps")
            marker.markerTintColor = .systemBlue
            marker.glyphImage = makeLocationGlyph()
            return marker
        }

        private func calloutContent(for station: StationDetail) -> StationCallout {
            let callsign = station.callsign
            return StationCallout(
                station: station, origin: parent.origin, originLabel: parent.originLabel,
                onZoom: { [weak self] in self?.zoom(to: callsign) },
                onDetails: { [weak self] in self?.parent.onDetails(callsign) },
                onMessage: { [weak self] in self?.parent.onMessage(callsign) })
        }

        /** Keeps an open bubble current as new packets arrive. */
        private func refreshCallout() {
            guard let callout, let shown = calloutStation,
                  let latest = parent.stations.first(where: { $0.callsign == shown.callsign }),
                  latest != shown else { return }
            calloutStation = latest
            callout.update(calloutContent(for: latest))
        }

        private func zoom(to callsign: String) {
            guard let map = mapView, let marker = markers[callsign] else { return }
            map.setRegion(MKCoordinateRegion(center: marker.coordinate, latitudinalMeters: 3_000, longitudinalMeters: 3_000),
                          animated: true)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let marker = view.annotation as? StationAnnotation, let callsign = marker.title,
               let station = parent.stations.first(where: { $0.callsign == callsign }) {
                let host = CalloutHost(calloutContent(for: station))
                callout = host
                calloutStation = station
                view.detailCalloutAccessoryView = host.view
            }
            let callsign = (view.annotation as? MKPointAnnotation)?.title
            DispatchQueue.main.async { [weak self] in
                self?.parent.selectedStation = callsign.flatMap { self?.markers[$0] != nil ? $0 : nil }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is StationAnnotation {
                view.detailCalloutAccessoryView = nil
                callout = nil
                calloutStation = nil
            }
            let callsign = (view.annotation as? MKPointAnnotation)?.title
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
