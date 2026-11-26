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
        #if os(macOS)
        AppQuitSaver.shared.install()
        #endif
    }

    var body: some Scene {
        WindowGroup(AppInfo.title) {
            StationMap(model: model)
                #if os(macOS)
                .background(WindowAccessor())
                #endif
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .windowSize) {
                Button("Reset Window Size") { MainWindow.resetSize() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
        #endif
    }
}

/** The app's name and version, as shown in the title bar: "APRSERJi 0.5.5". */
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let title = version.isEmpty ? "APRSERJi" : "APRSERJi \(version)"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    /** "APRSERJi 0.5.5 (build 9)", at the bottom of Setup. */
    static let versionLine = title + (build.isEmpty ? "" : " (build \(build))")
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
    @Published private(set) var tracks: [String: [TrackPoint]] = [:]
    @Published private(set) var telemetry: [String: TelemetryReport] = [:]
    @Published private(set) var bulletins: [AprsBulletin] = []

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
    /** Watched callsigns in the current connection's buddy filter. */
    private(set) var watch: [String] = []
    private var session: (account: String, passcode: String, host: String, port: Int32)?
    private var lastAreaChange = Date.distantPast

    func connect(account: String, passcode: String, host: String, port: Int32,
                 areas: [CoverageArea], watch: [String]) -> Bool {
        guard let core, !areas.isEmpty,
              core.startAreas(callsign: account, passcode: passcode, host: host, port: port,
                              areas: Self.encode(areas), extraFilter: WatchList.serverFilter(watch),
                              backupServers: UserDefaults.standard.string(forKey: "backupServers") ?? "") else { return false }
        session = (account, passcode, host, port)
        self.areas = areas
        self.watch = watch
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
    func updateCoverage(_ wanted: [CoverageArea], watch wantedWatch: [String], force: Bool = false) {
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
                    port: session.port, areas: wanted, watch: wantedWatch)
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
        watch = []
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
        // Stations heard on the radio arrive even without an APRS-IS connection.
        let snapshot = core.stationDetails
        if stations != snapshot { stations = snapshot }
        let nextTracks = core.stationTracks
        if tracks != nextTracks { tracks = nextTracks }
        let nextTelemetry = core.telemetryReports
        if telemetry != nextTelemetry { telemetry = nextTelemetry }
        let nextBulletins = core.bulletins
        if bulletins != nextBulletins { bulletins = nextBulletins }
        guard running else { return [] }
        if loginReply != core.loginReply { loginReply = core.loginReply }
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
    @State private var showMapControls = false
    @State private var calloutPoint: CGPoint?
    @State private var whoIsCallsign: String?
    @ObservedObject private var warnings = NWSWarnings.shared
    @AppStorage("layerTracks") private var layerTracks = true
    @AppStorage("layerCoverage") private var layerCoverage = false
    @AppStorage("layerDeadReckoning") private var layerDeadReckoning = true
    @AppStorage("layerRings") private var layerRings = false
    @AppStorage("ringSpacingMiles") private var ringSpacing = 10.0
    @AppStorage("ringCount") private var ringCount = 4
    @AppStorage("nwsEnabled") private var nwsEnabled = true
    /** Set at launch when a verified passcode is saved; the app connects on its own at this time. */
    @State private var autoConnectAt: Date?
    /** Seconds left when the countdown was paused; nil while it runs or when there is none. */
    @State private var autoConnectPaused: TimeInterval?
    @State private var autoConnectChecked = false
    @AppStorage("rangeGPSMiles") private var rangeGPS = 500
    @AppStorage("rangeLastFixMiles") private var rangeLastFix = 500
    @AppStorage("rangeCenterMiles") private var rangeCenter = 500
    @AppStorage("viewStations") private var viewStations = true
    @AppStorage("viewWeather") private var viewWeather = true
    @AppStorage("viewObjects") private var viewObjects = true
    @AppStorage("viewMovingOnly") private var viewMovingOnly = false
    @AppStorage("viewHideInfrastructure") private var viewHideInfrastructure = false
    @AppStorage("viewSource") private var viewSource: ViewSource = .all
    @AppStorage("viewMaxAgeMinutes") private var viewMaxAgeMinutes = 0
    @AppStorage("viewMaxMiles") private var viewMaxMiles = 0
    @AppStorage("viewWatchList") private var viewWatchList = ""
    /** The station a CAT program asked to track (MT=CALL); the map follows it. */
    @State private var trackedCall: String?
    @State private var trackedCoordinate: CLLocationCoordinate2D?
    /** One-shot zoom steps from a CAT program (MP=01 / MP=-01). */
    @State private var mapZoom: MapZoom?
    /** A short note about a CAT command, shown on the map for a few seconds. */
    @State private var remoteNote: String?
    @AppStorage("viewOnly") private var viewOnly = ""
    @AppStorage("layerLabels") private var layerLabels: StationLabels = .callsign
    // Boundary and road switches (read through ReferenceSettings; declared here so the map redraws when they change).
    @AppStorage("ref_states") private var refStates = true
    @AppStorage("ref_counties") private var refCounties = true
    @AppStorage("ref_interstates") private var refInterstates = true
    @AppStorage("ref_usHighways") private var refUSHighways = true
    @AppStorage("ref_stateRoads") private var refStateRoads = false
    @AppStorage("ref_countyRoads") private var refCountyRoads = false
    @AppStorage("refSource") private var refSource = ReferenceSource.online.rawValue
    @ObservedObject private var referenceStore = ReferenceStore.shared
    /** The spot shown in "About this place" (right-click or press and hold on the map). */
    @State private var aboutPlace: PlaceQuery?
    @AppStorage("layerDF") private var layerDF = true
    @AppStorage("layerHorizons") private var layerHorizons = false
    @AppStorage("layerAmbiguity") private var layerAmbiguity = true
    @AppStorage("layerShapes") private var layerShapes = true
    @AppStorage("layerPathsRF") private var layerPathsRF = false
    @AppStorage("radarOpacity") private var radarOpacity = 0.0
    @AppStorage("nicknames") private var nicknameStore = ""
    @AppStorage("pathStations") private var pathStore = ""
    @ObservedObject private var extras = MapExtras.shared
    @State private var showGoTo = false
    @State private var goToText = ""
    @State private var goToProblem = false
    @State private var showMultiTrack = false
    @State private var tick = 0
    @State private var unread = 0
    @AppStorage("notifyMessages") private var notify = true
    @ObservedObject private var notifier = MessageNotifier.shared

    var body: some View {
        if let core = model.core {
            VStack(spacing: tab == 0 ? 0 : 12) {
                // On the Map tab the settings move into the map's floating panel so the map fills the window.
                if tab != 0 { connectionSettings }
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
                                    telemetry: model.telemetry,
                                    path: $stationPath)
                        .tabItem { Label("Stations", systemImage: "list.bullet") }
                        .tag(2)
                    ChatView(core: core, account: normalizedCallsign(callsign), revision: model.revision,
                             transportError: model.chatError, recipient: $recipient, myPosition: gps.latest?.coordinate)
                        .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                        .badge(unread)
                        .tag(1)
                    BulletinsView(core: core, account: normalizedCallsign(callsign), bulletins: model.bulletins,
                                  revision: model.revision, warnings: warnings)
                        .tabItem { Label("Bulletins", systemImage: "megaphone") }
                        .badge(warnings.atLocation.count)
                        .tag(4)
                    SetupView(core: core, mapCenter: center, gps: gps)
                        .tabItem { Label("Setup", systemImage: "gearshape") }
                        .tag(3)
                    ToolsView(core: core, stations: model.stations, origin: origin.coordinate, originLabel: origin.label,
                              mapCenter: center, myPosition: gps.latest?.coordinate ?? BeaconSync.fixedCoordinate(),
                              telemetry: model.telemetry,
                              onShowOnMap: { coordinate, call in
                                  followGPS = false
                                  focus = MapFocus(callsign: call ?? "", coordinate: coordinate)
                                  if let call { selectedStation = call }
                                  tab = 0
                              },
                              onMessage: { openChat(with: $0) },
                              onMultiTrack: { showMultiTrack = true })
                        .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                        .tag(5)
                }
            }
            .onAppear {
                if notify { MessageNotifier.shared.requestAuthorization() }
            }
            .sheet(isPresented: $showMultiTrack) {
                MultiTrackView(stations: model.stations, tracks: model.tracks, preset: tilePreset)
            }
            .onAppear {
                SatellitesView.loadAtLaunch(core: core)
                DispatchQueue.global(qos: .utility).async { TileCache.prune(maxBytes: TileCache.budgetBytes) }
                startBeaconGPSIfNeeded()
                refreshSavedPasscode()
                scheduleAutoConnect()
            }
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
                    let station = normalizedCallsign(callsign)
                    core.setStation(callsign: station)
                    #if os(macOS)
                    ExternalGps.shared.tick(core: core, gps: gps)
                    MainWindow.keepTitle()
                    #endif
                    VirtualRig.shared.apply()
                    followTrackedStation()
                    let here = gps.latest?.coordinate ?? BeaconSync.fixedCoordinate()
                    core.setOwnPosition(latitude: here?.latitude ?? 0, longitude: here?.longitude ?? 0,
                                        altitudeMeters: gps.latest.map { $0.verticalAccuracy >= 0 ? $0.altitude : .nan } ?? .nan,
                                        valid: here != nil)
                    BeaconSync.apply(core: core, gps: gps)
                    PortStore.apply(core: core)
                    ReportsSync.apply(core: core)
                    WeatherStation.shared.tick(core: core)
                    AnsrvrKeepalive.tick(core: core, account: station)
                    WatchAlerts.shared.tick(stations: model.stations, origin: origin.coordinate)
                    TrackLogger.shared.tick(tracks: model.tracks, own: gps.latest, ownCall: station)
                    warnings.updateAprs(bulletins: model.bulletins.map {
                        AprsBulletinText(sender: $0.sender, destination: $0.destination, text: $0.text)
                    })
                    if tick % 5 == 0 { extras.updateSatellites(core: core, observer: origin.coordinate) }
                    tick += 1
                    warnings.refreshIfNeeded(enabled: nwsEnabled, location: origin.coordinate,
                                             reachMeters: Double(max(rangeCenter, rangeGPS)) * 1609.344)
                    model.updateCoverage(coverageAreas, watch: watchCalls)
                    if let due = autoConnectAt, Date() >= due {
                        autoConnectAt = nil
                        if !model.running {
                            enableSending = true
                            connect()
                        }
                    }
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .aprserjiRemote)) { note in
                if let action = note.object as? RemoteAction { handleRemote(action, core: core) }
            }
            .onChange(of: followGPS) { _, following in
                if following, trackedCall != nil { stopTracking() }
            }
            .onAppear { keepScreenOn(scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in
                keepScreenOn(phase == .active)
                if phase == .background { gps.stop() }
                if phase == .active { startBeaconGPSIfNeeded() }
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
                    cancelAutoConnect()
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
            autoConnectNotice
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
        OSMMap(preset: tilePreset, stations: mapStations, track: gps.track,
               follow: gps.tracking && followGPS, focus: focus, layers: mapLayers,
               origin: origin.coordinate, originLabel: origin.label,
               onDetails: { callsign in
                   stationPath = [callsign]
                   tab = 2
               },
               onMessage: { openChat(with: $0) },
               center: $center, selectedStation: $selectedStation, calloutPoint: $calloutPoint,
               onAboutPlace: { aboutPlace = PlaceQuery(coordinate: $0) }, zoom: mapZoom)
            .overlay { stationBubble }
            .sheet(item: $aboutPlace) { PlaceInfoView(query: $0) }
            .overlay(alignment: .bottomTrailing) {
                Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    .font(.caption2)
                    .padding(5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
            .overlay(alignment: .top) { mapOverlay }
            .overlay {
                if extras.measureA != nil && extras.measureB == nil {
                    Image(systemName: "plus").font(.title2.weight(.light)).foregroundStyle(.blue).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let a = extras.measureA {
                    let b = extras.measureB ?? center
                    Text("A→\(extras.measureB == nil ? "center" : "B"): \(Units.distance(Geo.distance(a, b), metric: UserDefaults.standard.bool(forKey: "useMetric"))) at \(Int(Geo.bearing(from: a, to: b).rounded()))° \(Units.compass(Geo.bearing(from: a, to: b)))")
                        .font(.callout.monospacedDigit())
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
            .overlay(alignment: .bottom) { remoteBanner }
            .alert("Go to", isPresented: $showGoTo) {
                TextField("41.5, -88.1 · EN51 · KC9KKO-9", text: $goToText)
                Button("Go") { goTo() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter decimal latitude and longitude, a grid square, or a callsign on the map.")
            }
            .alert("Couldn't find that", isPresented: $goToProblem) { Button("OK", role: .cancel) {} }
            .sheet(isPresented: Binding(get: { whoIsCallsign != nil }, set: { if !$0 { whoIsCallsign = nil } })) {
                WhoIsView(callsign: whoIsCallsign ?? "")
            }
        // Station details, zoom and messaging live in the map's station bubble.
    }

    /**
     * The selected station's information bubble, pinned to its marker. It opens above the marker, or below
     * when the marker is near the top, and slides sideways to stay inside the map.
     */
    @ViewBuilder private var stationBubble: some View {
        if let point = calloutPoint, let callsign = selectedStation,
           let station = model.stations.first(where: { $0.callsign == callsign }) {
            GeometryReader { geo in
                let half: CGFloat = 145
                let x = min(max(point.x, half + 8), max(half + 8, geo.size.width - half - 8))
                let above = point.y > 300
                let bubble = CalloutBubble(pointsDown: above, pointerOffset: point.x - x) {
                    StationCallout(
                        station: station, origin: origin.coordinate, originLabel: origin.label,
                        onZoom: { focus = MapFocus(callsign: callsign, coordinate: station.coordinate, meters: 3_000) },
                        onDetails: {
                            stationPath = [callsign]
                            tab = 2
                        },
                        onMessage: { openChat(with: callsign) },
                        onWhoIs: { whoIsCallsign = station.owner ?? callsign },
                        onClose: { selectedStation = nil })
                }
                .fixedSize()
                if above {
                    // The marker's pin is about 40 points tall; the pointer sits just above its head.
                    bubble.frame(width: geo.size.width, height: max(0, point.y - 40), alignment: .bottom)
                        .offset(x: x - geo.size.width / 2)
                } else {
                    bubble.frame(width: geo.size.width, alignment: .top)
                        .offset(x: x - geo.size.width / 2, y: point.y + 6)
                }
            }
        }
    }

    /** A slim status bar floating over the map; the full controls open as a panel beneath it. */
    private var mapOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(model.status).font(.callout.bold())
                    .help("Connection status" + Self.resetHint)
                Text("· \(mapStations.count) on map").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { if gps.tracking { gps.stop() } else { gps.start() } } label: {
                    Image(systemName: gps.tracking ? "location.fill" : "location")
                }
                .help(gps.tracking ? "Stop GPS" : "Start GPS")
                if gps.tracking {
                    Toggle(isOn: $followGPS) { Image(systemName: "scope") }
                        .toggleStyle(.button)
                        .help("Follow GPS")
                }
                Menu {
                    Button("Go to place, grid or callsign…") { showGoTo = true }
                    Divider()
                    Button("Measure: set A at map center") { extras.measureA = center; extras.measureB = nil }
                    if extras.measureA != nil {
                        Button("Measure: set B at map center") { extras.measureB = center }
                        Button("Clear measurement") { extras.measureA = nil; extras.measureB = nil }
                    }
                    Divider()
                    Button("MultiTrack…") { showMultiTrack = true }
                    Toggle("Weather radar", isOn: Binding(get: { radarOpacity > 0 }, set: { radarOpacity = $0 ? 0.5 : 0 }))
                } label: {
                    Image(systemName: "location.magnifyingglass")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Go to, measure, MultiTrack, radar")
                Button { withAnimation(.snappy) { showMapControls.toggle() } } label: {
                    Image(systemName: showMapControls ? "chevron.up" : "slider.horizontal.3")
                }
                .help(showMapControls ? "Hide settings" : "Connection and map settings" + Self.resetHint)
            }
            .buttonStyle(.borderless)
            if !showMapControls { autoConnectNotice }
            if showMapControls {
                Divider()
                // The app's name, version and build, at the top of Map Settings (outside the scroll view so it always shows).
                Text(AppInfo.versionLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                // Scrolls only when the window is too short to show every setting.
                ViewThatFits(in: .vertical) {
                    mapControls
                    ScrollView { mapControls }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 3, y: 1)
        .padding(10)
    }

    private var mapControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            connectionSettings.padding(.horizontal, -16).padding(.top, -16)
            Divider()
            HStack {
                Picker("Tiles", selection: $tilePreset) {
                    ForEach(TilePreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Menu {
                    Toggle("Paths of travel", isOn: $layerTracks)
                    Toggle("Dead reckoning", isOn: $layerDeadReckoning)
                    Toggle("PHG coverage", isOn: $layerCoverage)
                    Toggle("Range rings", isOn: $layerRings)
                    Toggle("NWS warnings", isOn: $nwsEnabled)
                    Divider()
                    Picker("Station labels", selection: $layerLabels) {
                        ForEach(StationLabels.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    ReferenceLayerToggles()
                } label: {
                    Label("Layers", systemImage: "square.3.layers.3d")
                }
                .fixedSize()
            }
            .toggleStyle(.button)
            rangeSettings.padding(.horizontal, -16)
            ViewSettingsRow(appliedWatch: model.watch, connected: model.running,
                            onApplyWatch: { model.updateCoverage(coverageAreas, watch: watchCalls, force: true) })
                .padding(.horizontal, -16)
            if let status = gps.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /** Tracks, coverage, dead reckoning, range rings and NWS polygons for the map. */
    private var mapLayers: MapLayers {
        var layers = MapLayers()
        layers.tracks = model.tracks
        layers.showTracks = layerTracks
        layers.showCoverage = layerCoverage
        layers.showDeadReckoning = layerDeadReckoning
        if layerRings {
            layers.ringCenter = origin.coordinate
            layers.ringRadii = (1...max(1, ringCount)).map { Double($0) * ringSpacing * 1609.344 }
        }
        layers.alerts = nwsEnabled ? warnings.mapped + warnings.aprsMapped : []
        layers.watched = watchCalls
        layers.labels = layerLabels
        layers.nicknames = Nicknames.load(nicknameStore)
        var paths = Set(pathStore.split(separator: ",").map(String.init))
        if let selected = selectedStation { paths.insert(selected) }
        if layerPathsRF { for s in mapStations where s.heardOnRadio { paths.insert(s.callsign) } }
        layers.pathStations = paths
        layers.showDF = layerDF
        layers.showHorizons = layerHorizons
        layers.showAmbiguity = layerAmbiguity
        layers.showShapes = layerShapes
        layers.radarOpacity = radarOpacity
        layers.reference = ReferenceSettings.load(revision: referenceStore.revision)
        extras.apply(to: &layers, metric: UserDefaults.standard.bool(forKey: "useMetric"))
        return layers
    }

    /** Hover reminder of the Mac's reset-window shortcut. */
    private static var resetHint: String {
        #if os(macOS)
        return " · Reset window size: ⌥⌘0"
        #else
        return ""
        #endif
    }

    private var statusColor: Color {
        switch model.status {
        case "Verified": return .green
        case "Receiving": return .blue
        case "Disconnected": return .gray
        default: return .orange
        }
    }

    static func savedCenter() -> CLLocationCoordinate2D {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "mapLatitude") != nil else { return CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06) }
        return CLLocationCoordinate2D(latitude: defaults.double(forKey: "mapLatitude"),
                                      longitude: defaults.double(forKey: "mapLongitude"))
    }

    /** The View settings, saved across restarts. */
    private var viewFilter: ViewFilter {
        ViewFilter(stations: viewStations, weather: viewWeather, objects: viewObjects, source: viewSource,
                   maxAgeMinutes: viewMaxAgeMinutes, maxMiles: viewMaxMiles, movingOnly: viewMovingOnly,
                   hideInfrastructure: viewHideInfrastructure, watched: watchCalls, only: viewOnly)
    }

    private var mapStations: [StationDetail] {
        let filter = viewFilter
        let here = origin.coordinate
        let now = Date()
        return model.stations.filter { filter.includes($0, origin: here, now: now) }
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
                Button("Apply") { model.updateCoverage(coverageAreas, watch: watchCalls, force: true) }
                    .disabled(!rangesChanged)
            } else {
                Text("Used when you connect").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    /** Every callsign fetched from anywhere: the Always show list plus a station tracked with MT. */
    private var watchCalls: [String] {
        let list = WatchList.parse(viewWatchList)
        guard let t = trackedCall, !list.contains(t) else { return list }
        return list + [t]
    }

    /** A heard station by callsign; "KC9XYZ" also finds "KC9XYZ-9" when there's no plain one. */
    private func station(named call: String) -> StationDetail? {
        let call = call.uppercased()
        return model.stations.first { $0.callsign == call } ?? model.stations.first { $0.callsign.hasPrefix(call + "-") }
    }

    /** MP, MZ, MT and MB from a CAT program. */
    private func handleRemote(_ action: RemoteAction, core: AppleAprs) {
        switch action {
        case .zoom(let steps):
            mapZoom = MapZoom(steps: steps)
        case .zoomTo(let call):
            if let s = station(named: call) {
                followGPS = false
                focus = MapFocus(callsign: s.callsign, coordinate: s.coordinate, meters: 3_000)
                selectedStation = s.callsign
            } else {
                note("\(call) hasn't been heard yet")
            }
        case .track(let call):
            if let call {
                trackedCall = call
                trackedCoordinate = nil
                followGPS = false
                note(station(named: call) == nil ? "Tracking \(call) — waiting to hear it" : "Tracking \(call)")
                followTrackedStation()
            } else {
                stopTracking()
            }
        case .beaconNow:
            core.beaconNow()
            note("Beacon sent")
        }
    }

    /** Keeps the map on a station tracked with MT, moving only when it reports a new position. */
    private func followTrackedStation() {
        guard let call = trackedCall, let s = station(named: call) else { return }
        let c = s.coordinate
        if let last = trackedCoordinate, abs(last.latitude - c.latitude) < 1e-6, abs(last.longitude - c.longitude) < 1e-6 { return }
        trackedCoordinate = c
        focus = MapFocus(callsign: s.callsign, coordinate: c)
    }

    private func stopTracking() {
        trackedCall = nil
        trackedCoordinate = nil
        VirtualRig.shared.stopTracking()
    }

    private func note(_ text: String) {
        remoteNote = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if remoteNote == text { remoteNote = nil }
        }
    }

    /** "Tracking KC9XYZ-1" (with a stop button) and short notes about CAT commands. */
    @ViewBuilder private var remoteBanner: some View {
        if trackedCall != nil || remoteNote != nil {
            HStack(spacing: 8) {
                if let call = trackedCall {
                    Image(systemName: "scope")
                    Text(remoteNote ?? "Tracking \(call)")
                    Button { stopTracking() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop tracking \(call)")
                } else if let remoteNote {
                    Text(remoteNote)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 28)
        }
    }

    /** iPhone and iPad: the map stays on screen while APRSERJi is open (CarPlay can't show it). */
    private func keepScreenOn(_ active: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = active
        #endif
    }

    private func goTo() {
        let text = goToText.trimmingCharacters(in: .whitespaces)
        if let station = model.stations.first(where: { $0.callsign == text.uppercased() }) {
            followGPS = false
            focus = MapFocus(callsign: station.callsign, coordinate: station.coordinate)
            selectedStation = station.callsign
        } else if let point = Geo.parse(text) {
            followGPS = false
            focus = MapFocus(callsign: "", coordinate: point, meters: 20_000)
        } else {
            goToProblem = true
        }
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

    /** Once per launch: with a valid callsign and a server-verified passcode saved, connect in 15 seconds. */
    private func scheduleAutoConnect() {
        guard !autoConnectChecked else { return }
        autoConnectChecked = true
        let account = normalizedCallsign(callsign)
        guard !model.running, AprsProtocol.shared.validCallsign(value: account),
              PasscodeKeychain.load(for: account) != nil else { return }
        autoConnectAt = Date().addingTimeInterval(15)
    }

    /**
     * "Connecting automatically in 12 s" with Connect now and Cancel. Clicking the countdown text pauses it;
     * clicking again resumes from the same number of seconds.
     */
    @ViewBuilder private var autoConnectNotice: some View {
        if !model.running, autoConnectAt != nil || autoConnectPaused != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Button(action: toggleAutoConnectPause) {
                        if let remaining = autoConnectPaused {
                            Label("Auto-connect paused at \(Int(remaining.rounded(.up))) s — click to resume",
                                  systemImage: "play.circle")
                        } else if let due = autoConnectAt {
                            Label("Connecting automatically in \(max(0, Int(due.timeIntervalSince(context.date).rounded(.up)))) s",
                                  systemImage: "pause.circle")
                        }
                    }
                    .foregroundStyle(autoConnectPaused == nil ? Color.primary : Color.orange)
                    .help(autoConnectPaused == nil ? "Pause the countdown" : "Resume the countdown")
                    Button("Connect now") {
                        cancelAutoConnect()
                        enableSending = true
                        connect()
                    }
                    Button("Cancel") { cancelAutoConnect() }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }

    private func toggleAutoConnectPause() {
        if let remaining = autoConnectPaused {
            autoConnectPaused = nil
            autoConnectAt = Date().addingTimeInterval(max(1, remaining))
        } else if let due = autoConnectAt {
            autoConnectPaused = max(1, due.timeIntervalSinceNow)
            autoConnectAt = nil
        }
    }

    private func cancelAutoConnect() {
        autoConnectAt = nil
        autoConnectPaused = nil
    }

    /**
     * Beaconing from GPS needs GPS running. The beacon setting survives restarts, so start GPS at launch and on
     * returning to the foreground instead of only when the switch is turned on.
     */
    private func startBeaconGPSIfNeeded() {
        let defaults = UserDefaults.standard
        let source = BeaconSource(rawValue: defaults.string(forKey: "beaconSource") ?? "") ?? .gps
        if defaults.bool(forKey: "beaconEnabled"), source == .gps, !gps.tracking { gps.start() }
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
                            port: tcpPort, areas: coverageAreas, watch: watchCalls) else {
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
