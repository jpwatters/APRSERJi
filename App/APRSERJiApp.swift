import AprsCore
import MapKit
import SwiftUI

@main
@MainActor
struct APRSERJiApp: App {
    @StateObject private var model = AprsModel()

    init() {
        // Become the notification delegate before any notification tap is delivered.
        _ = MessageNotifier.shared
    }

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
    @Published private(set) var stations: [StationDetail] = []
    @Published private(set) var status = "Disconnected"
    @Published private(set) var revision: Int64 = 0
    @Published private(set) var chatError: String?
    @Published private(set) var loginReply: String?

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

    private(set) var areas: [CoverageArea] = []
    private var session: (account: String, passcode: String, host: String, port: Int32)?
    private var lastAreaChange = Date.distantPast

    func connect(account: String, passcode: String, host: String, port: Int32,
                 areas: [CoverageArea]) -> Bool {
        guard let core, !areas.isEmpty,
              core.startAreas(callsign: account, passcode: passcode, host: host, port: port,
                              areas: Self.encode(areas)) else { return false }
        session = (account, passcode, host, port)
        self.areas = areas
        lastAreaChange = Date()
        status = "Connecting"
        running = true
        return true
    }

    /**
     * Reconnects with new areas when a wanted area is not well inside an area already covered (its center
     * more than half that area's radius away, or a larger radius wanted), at most once every two minutes.
     * [force] applies edited ranges at once. The server filter is fixed at login.
     */
    func updateCoverage(_ wanted: [CoverageArea], force: Bool = false) {
        guard running, let session, !wanted.isEmpty else { return }
        if !force {
            guard Date().timeIntervalSince(lastAreaChange) >= 120 else { return }
            let uncovered = wanted.contains { want in
                !areas.contains { have in
                    have.radiusMiles >= want.radiusMiles
                        && Geo.distance(want.coordinate, have.coordinate) <= Double(have.radiusMiles) * 1609.344 / 2
                }
            }
            guard uncovered else { return }
        }
        _ = connect(account: session.account, passcode: session.passcode, host: session.host,
                    port: session.port, areas: wanted)
    }

    private static func encode(_ areas: [CoverageArea]) -> String {
        areas.map { area in
            let km = min(2000, max(1, Int((Double(area.radiusMiles) * 1.609344).rounded())))
            return String(format: "%.4f,%.4f,%d", area.coordinate.latitude, area.coordinate.longitude, km)
        }.joined(separator: ";")
    }

    func disconnect() {
        core?.stop()
        session = nil
        areas = []
        running = false
        stations = []
        loginReply = nil
        status = "Disconnected"
        chatError = nil
    }

    /** Updates published state and returns chat messages that arrived since the last call. */
    @discardableResult
    func refresh() -> [IncomingAlert] {
        guard let core else { return [] }
        if revision != core.revision { revision = core.revision }
        if chatError != core.chatError { chatError = core.chatError }
        guard running else { return [] }
        if loginReply != core.loginReply { loginReply = core.loginReply }
        let snapshot = core.stationDetails
        if stations != snapshot { stations = snapshot }
        let nextStatus: String
        switch core.connectionState {
        case "VERIFIED": nextStatus = "Verified"
        case "RECEIVING": nextStatus = "Receiving"
        case "RECONNECTING": nextStatus = "Reconnecting"
        default: nextStatus = "Connecting"
        }
        if status != nextStatus { status = nextStatus }
        return core.takeIncomingAlerts()
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
    @AppStorage("enableSending") private var enableSending = false
    @State private var passcode = ""
    /** Passcode used for the current connection, saved to the Keychain once the server verifies it. */
    @State private var pendingPasscode: String?
    @State private var hasSavedPasscode = false
    @State private var validationError = false
    @State private var recipient = ""
    @State private var selectedStation: String?
    @State private var tab = 0
    @AppStorage("mapLatitude") private var savedLatitude = 42.36
    @AppStorage("mapLongitude") private var savedLongitude = -71.06
    @State private var center = StationMap.savedCenter()
    @State private var focus: MapFocus?
    @State private var stationPath: [String] = []
    @AppStorage("rangeGPSMiles") private var rangeGPS = 500
    @AppStorage("rangeLastFixMiles") private var rangeLastFix = 500
    @AppStorage("rangeCenterMiles") private var rangeCenter = 500
    @State private var showWeather = true
    @State private var showObjects = true
    @State private var unread = 0
    @AppStorage("notifyMessages") private var notify = true
    @ObservedObject private var notifier = MessageNotifier.shared

    var body: some View {
        if let core = model.core {
            VStack(spacing: 12) {
                connectionSettings
                TabView(selection: $tab) {
                    stationMap
                        .tabItem { Label("Map", systemImage: "map") }
                        .tag(0)
                    StationListView(stations: model.stations, origin: origin.coordinate, originLabel: origin.label,
                                    connected: model.running,
                                    onMessage: { openChat(with: $0) },
                                    onShowOnMap: { station in
                                        followGPS = false
                                        focus = MapFocus(callsign: station.callsign, coordinate: station.coordinate)
                                        selectedStation = station.callsign
                                        tab = 0
                                    },
                                    path: $stationPath)
                        .tabItem { Label("Stations", systemImage: "list.bullet") }
                        .tag(2)
                    ChatView(core: core, account: normalizedCallsign(callsign), revision: model.revision,
                             transportError: model.chatError, recipient: $recipient)
                        .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                        .badge(unread)
                        .tag(1)
                    BeaconView(core: core, connected: model.running, mapCenter: center, gps: gps)
                        .tabItem { Label("Beacon", systemImage: "dot.radiowaves.up.forward") }
                        .tag(3)
                }
            }
            .onAppear {
                if notify { MessageNotifier.shared.requestAuthorization() }
            }
            .onAppear { refreshSavedPasscode() }
            .onChange(of: callsign) { _, _ in refreshSavedPasscode() }
            .onChange(of: model.status) { _, status in
                // Only a passcode the server has verified is ever stored.
                guard status == "Verified", let verified = pendingPasscode else { return }
                pendingPasscode = nil
                PasscodeKeychain.save(verified, for: normalizedCallsign(callsign))
                refreshSavedPasscode()
            }
            .onChange(of: center.latitude) { _, _ in
                savedLatitude = center.latitude
                savedLongitude = center.longitude
            }
            .onChange(of: tab) { _, selected in
                if selected == 1 { clearUnread() }
            }
            .onChange(of: notifier.openConversation) { _, sender in
                if let sender {
                    openChat(with: sender)
                    notifier.openConversation = nil
                }
            }
            .task {
                while !Task.isCancelled {
                    handle(model.refresh())
                    BeaconSync.apply(core: core, gps: gps)
                    model.updateCoverage(coverageAreas)
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { gps.stop() }
                if phase == .active && tab == 1 { clearUnread() }
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
                        HStack {
                            SecureField(hasSavedPasscode ? "Saved in Keychain (type to replace)" : "APRS-IS passcode",
                                        text: $passcode)
                            if hasSavedPasscode {
                                Button("Forget") {
                                    PasscodeKeychain.delete(for: normalizedCallsign(callsign))
                                    refreshSavedPasscode()
                                }
                            }
                        }
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
                if model.running {
                    Text(coverageText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !enableSending && !model.running {
                    Text("Receive only").foregroundStyle(.secondary)
                }
            }
            if let reply = model.loginReply {
                let unverified = reply.localizedCaseInsensitiveContains("unverified")
                Text(unverified && enableSending
                     ? "Server did not accept the passcode: \(reply)"
                     : "Server: \(reply)")
                    .font(.caption)
                    .foregroundStyle(unverified && enableSending ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
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
            rangeSettings
            if let status = gps.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle(isOn: $showWeather) { Label("Weather", systemImage: "cloud.sun") }
                Toggle(isOn: $showObjects) { Label("Objects", systemImage: "flag") }
                Spacer()
                Text("\(mapStations.count) on map").font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.button)
            .padding(.horizontal)
            OSMMap(preset: tilePreset, stations: mapStations, track: gps.track,
                   follow: gps.tracking && followGPS, focus: focus, center: $center, selectedStation: $selectedStation)
                .overlay(alignment: .bottomTrailing) {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2)
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            if let selectedStation, let station = model.stations.first(where: { $0.callsign == selectedStation }) {
                HStack {
                    Button("Details") {
                        stationPath = [selectedStation]
                        tab = 2
                    }
                    if station.canMessage {
                        Button("Message \(selectedStation)") { openChat(with: selectedStation) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    static func savedCenter() -> CLLocationCoordinate2D {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "mapLatitude") != nil else { return CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06) }
        return CLLocationCoordinate2D(latitude: defaults.double(forKey: "mapLatitude"),
                                      longitude: defaults.double(forKey: "mapLongitude"))
    }

    private var mapStations: [StationDetail] {
        model.stations.filter { station in
            switch station.kind {
            case "weather": return showWeather
            case "object", "item": return showObjects
            default: return true
            }
        }
    }

    /** Distances in the station list are measured from your GPS fix, else the map center. */
    private var origin: (coordinate: CLLocationCoordinate2D, label: String) {
        if let fix = gps.latest { return (fix.coordinate, "your position") }
        return (center, "map center")
    }

    /**
     * Where to receive stations: around the current GPS fix, the last known GPS fix and the map center, each
     * with its own range from the Map page. A point within 50 miles of one already listed is merged into it,
     * keeping the larger range.
     */
    private var coverageAreas: [CoverageArea] {
        let candidates: [CoverageArea?] = [
            gps.latest.map { CoverageArea(name: "GPS", coordinate: $0.coordinate, radiusMiles: RangeSetting.clamp(rangeGPS)) },
            GPSTracker.lastKnown().map { CoverageArea(name: "last fix", coordinate: $0, radiusMiles: RangeSetting.clamp(rangeLastFix)) },
            CoverageArea(name: "map center", coordinate: center, radiusMiles: RangeSetting.clamp(rangeCenter)),
        ]
        var result: [CoverageArea] = []
        for area in candidates.compactMap({ $0 }) where CLLocationCoordinate2DIsValid(area.coordinate) {
            if let index = result.firstIndex(where: { Geo.distance($0.coordinate, area.coordinate) <= 80_467 }) {
                if area.radiusMiles > result[index].radiusMiles { result[index].radiusMiles = area.radiusMiles }
                result[index].name += " + " + area.name
            } else {
                result.append(area)
            }
        }
        return result
    }

    private var coverageText: String {
        "Receiving " + model.areas.map { "\($0.radiusMiles) mi around \($0.name)" }.joined(separator: " · ")
    }

    private var rangesChanged: Bool {
        model.running && coverageAreas.map(\.radiusMiles) != model.areas.map(\.radiusMiles)
    }

    private var rangeSettings: some View {
        // Scrolls sideways on a narrow iPhone screen instead of truncating the fields.
        ScrollView(.horizontal, showsIndicators: false) { rangeRow }
    }

    private var rangeRow: some View {
        HStack(spacing: 10) {
            Text("Range (mi)").font(.caption.bold())
            RangeField(label: "GPS", value: $rangeGPS)
            RangeField(label: "Last fix", value: $rangeLastFix)
            RangeField(label: "Map center", value: $rangeCenter)
            if model.running {
                Button("Apply") { model.updateCoverage(coverageAreas, force: true) }
                    .disabled(!rangesChanged)
            } else {
                Text("Used when you connect").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private func openChat(with callsign: String) {
        recipient = callsign
        tab = 1
        clearUnread()
    }

    private func clearUnread() {
        unread = 0
        MessageNotifier.shared.setBadge(0)
    }

    private func handle(_ alerts: [IncomingAlert]) {
        guard !alerts.isEmpty else { return }
        let viewing = scenePhase == .active && tab == 1
        for alert in alerts {
            let open = viewing && normalizedCallsign(recipient) == alert.sender
            if !open { unread += 1 }
            if notify && !open { MessageNotifier.shared.post(sender: alert.sender, text: alert.text) }
        }
        MessageNotifier.shared.setBadge(unread)
    }

    private func refreshSavedPasscode() {
        hasSavedPasscode = PasscodeKeychain.load(for: normalizedCallsign(callsign)) != nil
    }

    private func connect() {
        let account = normalizedCallsign(callsign)
        let typed = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        // A newly typed passcode takes precedence over the saved one and replaces it once verified.
        let credential = typed.isEmpty ? (PasscodeKeychain.load(for: account) ?? "") : typed
        guard let tcpPort = Int32(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              !enableSending || (!credential.isEmpty && credential != "-1"),
              model.connect(account: account, passcode: enableSending ? credential : "-1",
                            host: server.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: tcpPort, areas: coverageAreas) else {
            validationError = true
            return
        }
        callsign = account
        pendingPasscode = enableSending && !typed.isEmpty ? typed : nil
        passcode = ""
    }
}

/** One receive circle: a point and its range in miles. */
struct CoverageArea: Equatable {
    var name: String
    var coordinate: CLLocationCoordinate2D
    var radiusMiles: Int

    static func == (a: CoverageArea, b: CoverageArea) -> Bool {
        a.name == b.name && a.radiusMiles == b.radiusMiles
            && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

enum RangeSetting {
    /** APRS-IS range filters are limited here to 1–1000 miles (about 1609 km). */
    static func clamp(_ miles: Int) -> Int { min(1000, max(1, miles)) }
}

/** A compact miles field for the Map page. Out-of-range entries snap to 1–1000 when you finish editing. */
private struct RangeField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption)
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit { value = RangeSetting.clamp(value) }
                .accessibilityLabel("\(label) range in miles")
        }
    }
}
