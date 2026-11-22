import AprsCore
import MapKit
import SwiftUI

@main
@MainActor
struct APRSERJiApp: App {
    @StateObject private var model = AprsModel()

    var body: some Scene {
        WindowGroup {
            StationMap(model: model)
        }
    }
}

@MainActor
private final class AprsModel: ObservableObject {
    let core: AppleAprs?
    @Published private(set) var running = false
    @Published private(set) var stations: [StationMarker] = []
    @Published private(set) var status = "Disconnected"
    @Published private(set) var revision: Int64 = 0
    @Published private(set) var chatError: String?

    init() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("APRSERJi", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
            core = try AppleAprs(
                path: support.appendingPathComponent("chats.sqlite").path, applicationVersion: version
            )
        } catch {
            core = nil
        }
    }

    func connect(account: String, passcode: String, host: String, port: Int32,
                 center: CLLocationCoordinate2D) -> Bool {
        guard let core, core.start(callsign: account, passcode: passcode, host: host, port: port,
                                   latitude: center.latitude, longitude: center.longitude) else { return false }
        status = "Connecting"
        running = true
        return true
    }

    func disconnect() {
        core?.stop()
        running = false
        stations = []
        status = "Disconnected"
        chatError = nil
    }

    func refresh() {
        guard let core else { return }
        if revision != core.revision { revision = core.revision }
        if chatError != core.chatError { chatError = core.chatError }
        guard running else { return }
        let snapshot = core.stations
        if stations != snapshot { stations = snapshot }
        let nextStatus: String
        switch core.connectionState {
        case "VERIFIED": nextStatus = "Verified"
        case "RECEIVING": nextStatus = "Receiving"
        case "RECONNECTING": nextStatus = "Reconnecting"
        default: nextStatus = "Connecting"
        }
        if status != nextStatus { status = nextStatus }
    }
}

private struct StationMap: View {
    @ObservedObject var model: AprsModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("callsign") private var callsign = ""
    @AppStorage("server") private var server = "rotate.aprs2.net"
    @AppStorage("port") private var port = "14580"
    @AppStorage("tilePreset") private var tilePreset: TilePreset = .project
    @StateObject private var gps = GPSTracker()
    @State private var followGPS = true
    @State private var enableSending = false
    @State private var passcode = ""
    @State private var validationError = false
    @State private var recipient = ""
    @State private var selectedStation: String?
    @State private var tab = 0
    @State private var center = CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06)

    var body: some View {
        if let core = model.core {
            VStack(spacing: 12) {
                connectionSettings
                TabView(selection: $tab) {
                    stationMap
                        .tabItem { Label("Map", systemImage: "map") }
                        .tag(0)
                    ChatView(core: core, account: normalizedCallsign(callsign), revision: model.revision,
                             transportError: model.chatError, recipient: $recipient)
                        .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                        .tag(1)
                }
            }
            .task {
                while !Task.isCancelled {
                    model.refresh()
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { gps.stop() }
            }
            .alert("Check connection settings", isPresented: $validationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Enter a valid callsign, server and TCP port. For two-way messaging, enter your APRS-IS passcode.")
            }
        } else {
            ContentUnavailableView("Chat storage unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text("APRSERJi could not open its local chat database."))
        }
    }

    private var connectionSettings: some View {
        VStack(spacing: 10) {
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
                GridRow {
                    Text("Messaging")
                    Toggle("Enable sending", isOn: $enableSending)
                }
                if enableSending {
                    GridRow {
                        Text("Passcode")
                        SecureField("APRS-IS passcode", text: $passcode)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(model.running)

            HStack {
                Button(model.running ? "Disconnect" : "Connect") {
                    if model.running { model.disconnect() } else { connect() }
                }
                Text(model.status).accessibilityIdentifier("connectionStatus")
                Spacer()
                if !enableSending && !model.running {
                    Text("Receive only").foregroundStyle(.secondary)
                }
            }
        }
        .padding([.horizontal, .top])
    }

    private var stationMap: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Tiles", selection: $tilePreset) {
                    ForEach(TilePreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
                }
                .pickerStyle(.menu)
                Spacer()
                Button(gps.tracking ? "Stop GPS" : "Start GPS") {
                    if gps.tracking { gps.stop() } else { gps.start() }
                }
                if gps.tracking {
                    Toggle("Follow", isOn: $followGPS).toggleStyle(.button)
                }
            }
            .padding(.horizontal)
            if let status = gps.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            OSMMap(preset: tilePreset, stations: model.stations, track: gps.track,
                   follow: gps.tracking && followGPS, center: $center, selectedStation: $selectedStation)
                .overlay(alignment: .bottomTrailing) {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2)
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            if let selectedStation, AprsProtocol.shared.validCallsign(value: selectedStation) {
                Button("Message \(selectedStation)") {
                    recipient = selectedStation
                    tab = 1
                }.buttonStyle(.bordered)
            }
        }
    }

    private func connect() {
        let account = normalizedCallsign(callsign)
        let credential = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tcpPort = Int32(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              !enableSending || (!credential.isEmpty && credential != "-1"),
              model.connect(account: account, passcode: enableSending ? credential : "-1",
                            host: server.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: tcpPort, center: center) else {
            validationError = true
            return
        }
        callsign = account
        passcode = ""
    }
}
