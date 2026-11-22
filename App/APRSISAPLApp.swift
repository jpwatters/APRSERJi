import AprsCore
import MapKit
import SwiftUI

@main
struct APRSISAPLApp: App {
    var body: some Scene {
        WindowGroup {
            StationMap()
        }
    }
}

private struct StationMap: View {
    @AppStorage("callsign") private var callsign = ""
    @AppStorage("server") private var server = "rotate.aprs2.net"
    @AppStorage("port") private var port = "14580"
    @State private var feed = StationFeed()
    @State private var stations: [AprsStation] = []
    @State private var status = "Disconnected"
    @State private var validationError = false
    @State private var running = false
    @State private var center = CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06)
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06),
        latitudinalMeters: 120_000,
        longitudinalMeters: 120_000
    ))

    var body: some View {
        VStack(spacing: 12) {
            Grid(alignment: .leading) {
                GridRow {
                    Text("Callsign")
                    TextField("Your callsign", text: $callsign)
                }
                GridRow {
                    Text("Server")
                    TextField("APRS-IS host", text: $server)
                }
                GridRow {
                    Text("Port")
                    TextField("APRS-IS port", text: $port)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(running)
            .padding([.horizontal, .top])

            HStack {
                Button(running ? "Disconnect" : "Connect") {
                    if running {
                        disconnect()
                    } else {
                        connect()
                    }
                }
                Text(status).accessibilityIdentifier("connectionStatus")
                Spacer()
                Text("Receive only")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Map(position: $camera) {
                ForEach(stations, id: \.callsign) { station in
                    Marker(station.callsign, coordinate: CLLocationCoordinate2D(
                        latitude: station.latitude, longitude: station.longitude
                    ))
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                center = context.region.center
            }
        }
        .task {
            while !Task.isCancelled {
                if running {
                    stations = feed.stations
                    switch feed.connectionState {
                    case "RECEIVING": status = "Receiving"
                    case "RECONNECTING": status = "Reconnecting"
                    case "STOPPED": status = "Connecting"
                    default: status = "Connecting"
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .onDisappear(perform: disconnect)
        .alert("Check connection settings", isPresented: $validationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter a valid APRS callsign, host and TCP port.")
        }
    }

    private func connect() {
        let account = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let host = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tcpPort = Int32(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              feed.start(callsign: account, host: host, port: tcpPort,
                         latitude: center.latitude, longitude: center.longitude) else {
            validationError = true
            return
        }
        callsign = account
        status = "Connecting"
        running = true
    }

    private func disconnect() {
        feed.stop()
        running = false
        stations = []
        status = "Disconnected"
    }
}
