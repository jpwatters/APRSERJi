import AprsCore
import CoreLocation
import SwiftUI

/** MultiTrack: up to eight small maps, each following one station with its own zoom. */
struct MultiTrackView: View {
    let stations: [StationDetail]
    let tracks: [String: [TrackPoint]]
    let preset: TilePreset
    @Environment(\.dismiss) private var dismiss
    @AppStorage("multiTrackCalls") private var savedCalls = ""
    @AppStorage("multiTrackZooms") private var savedZooms = ""
    @AppStorage("multiTrackTrails") private var trails = true
    @State private var newCall = ""

    private var calls: [String] { savedCalls.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
    private var zooms: [String: Double] {
        Dictionary(savedZooms.split(separator: ",").compactMap { pair -> (String, Double)? in
            let p = pair.split(separator: "=")
            return p.count == 2 ? (String(p[0]), Double(p[1]) ?? 5000) : nil
        }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    TextField("Callsign to follow", text: $newCall)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(calls.count >= 8 || newCall.isEmpty)
                    Toggle("Trails", isOn: $trails)
                }
                .padding(.horizontal)
                if calls.isEmpty {
                    ContentUnavailableView("Follow up to 8 stations", systemImage: "rectangle.split.2x2",
                                           description: Text("Add callsigns above; each gets its own map that stays centered on it."))
                } else {
                    GeometryReader { geo in
                        let columns = calls.count <= 1 ? 1 : calls.count <= 4 ? 2 : (geo.size.width > geo.size.height ? 4 : 2)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                            ForEach(calls, id: \.self) { call in
                                panel(call, height: max(160, geo.size.height / CGFloat((calls.count + columns - 1) / columns) - 8))
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .navigationTitle("MultiTrack")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 650)
        #endif
    }

    private func add() {
        let call = normalizedCallsign(newCall)
        guard !call.isEmpty, !calls.contains(call), calls.count < 8 else { return }
        savedCalls = (calls + [call]).joined(separator: ",")
        newCall = ""
    }

    private func setZoom(_ call: String, _ meters: Double) {
        var z = zooms
        z[call] = meters
        savedZooms = z.map { "\($0.key)=\(Int($0.value))" }.joined(separator: ",")
    }

    private func layers(for call: String) -> MapLayers {
        var layers = MapLayers()
        layers.tracks = trails ? tracks.filter { $0.key == call } : [:]
        layers.showTracks = trails
        return layers
    }

    @ViewBuilder private func panel(_ call: String, height: CGFloat) -> some View {
        let station = stations.first { $0.callsign == call }
        let meters = zooms[call] ?? 5000
        VStack(spacing: 0) {
            HStack {
                Text(call).font(.headline.monospaced())
                if let s = station { Text(Units.age(s.heardAt)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("Zoom", selection: Binding(get: { meters }, set: { setZoom(call, $0) })) {
                    Text("1 km").tag(1000.0); Text("5 km").tag(5000.0); Text("20 km").tag(20000.0); Text("100 km").tag(100000.0)
                }
                .labelsHidden().fixedSize()
                Button { savedCalls = calls.filter { $0 != call }.joined(separator: ",") } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(4)
            if let s = station {
                OSMMap(preset: preset, stations: [s], track: [], follow: false,
                       focus: MapFocus(callsign: call, coordinate: s.coordinate, meters: meters), layers: layers(for: call),
                       origin: s.coordinate, originLabel: call, onDetails: { _ in }, onMessage: { _ in },
                       center: .constant(s.coordinate), selectedStation: .constant(nil), calloutPoint: .constant(nil))
            } else {
                ContentUnavailableView("Not heard yet", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .frame(height: height)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}
