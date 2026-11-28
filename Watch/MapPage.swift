import MapKit
import SwiftUI

/**
 The map around me. Drag to move it, double-tap or turn the Digital Crown to zoom, or use the + and − buttons;
 the scope button centers on me again. Swipe along the right edge of the screen to change pages.
 */
struct MapPage: View {
    @EnvironmentObject var store: WatchStore
    @State private var position: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion?
    @State private var centered = false

    var body: some View {
        NavigationStack {
            if let snapshot = store.snapshot, let lat = snapshot.latitude, let lon = snapshot.longitude {
                let me = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                StationsMap(snapshot: snapshot, me: me, position: $position)
                    .onMapCameraChange(frequency: .onEnd) { context in region = context.region }
                    .ignoresSafeArea(edges: .bottom)
                    .onAppear {
                        if !centered {
                            centered = true
                            position = .region(MapZoom.region(me, level: MapZoom.fit(snapshot.stations)))
                        }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button { zoom(by: 0.5, me: me) } label: { Image(systemName: "plus.magnifyingglass") }
                                .accessibilityLabel("Zoom in")
                            Button {
                                withAnimation { position = .region(MapZoom.region(me, level: MapZoom.fit(snapshot.stations))) }
                            } label: { Image(systemName: "scope") }
                                .accessibilityLabel("Center on me")
                            Button { zoom(by: 2, me: me) } label: { Image(systemName: "minus.magnifyingglass") }
                                .accessibilityLabel("Zoom out")
                        }
                    }
            } else if store.snapshot == nil {
                WaitingForPhone()
            } else {
                Text("No position on the iPhone yet").foregroundStyle(.secondary)
            }
        }
    }

    private func zoom(by factor: Double, me: CLLocationCoordinate2D) {
        let current = region ?? MapZoom.region(me, level: 3)
        let span = MKCoordinateSpan(latitudeDelta: min(80, max(0.002, current.span.latitudeDelta * factor)),
                                    longitudeDelta: min(160, max(0.002, current.span.longitudeDelta * factor)))
        let next = MKCoordinateRegion(center: current.center, span: span)
        region = next
        withAnimation { position = .region(next) }
    }
}

/** Me and the 15 nearest stations. */
private struct StationsMap: View {
    let snapshot: WatchSnapshot
    let me: CLLocationCoordinate2D
    @Binding var position: MapCameraPosition

    var body: some View {
        Map(position: $position) {
            Annotation("Me", coordinate: me) {
                Image(systemName: "location.circle.fill").foregroundStyle(.blue).font(.title3)
            }
            ForEach(snapshot.stations.prefix(15)) { station in
                Annotation(station.callsign,
                           coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)) {
                    Image(systemName: kindIcon(station.kind))
                        .font(.caption2)
                        .padding(3)
                        .background(.red, in: Circle())
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

/** Zoom steps used to size the map, as the width shown in meters. */
enum MapZoom {
    static let levels: [Double] = [500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000]

    static func region(_ center: CLLocationCoordinate2D, level: Int) -> MKCoordinateRegion {
        let meters = levels[min(max(level, 0), levels.count - 1)]
        return MKCoordinateRegion(center: center, latitudinalMeters: meters, longitudinalMeters: meters)
    }

    /** The closest step that shows the five nearest stations. */
    static func fit(_ stations: [WatchSnapshot.Station]) -> Int {
        let reach = (stations.prefix(5).map(\.distanceMeters).max() ?? 2_500) * 2.4
        return levels.firstIndex { $0 >= reach } ?? levels.count - 1
    }
}
