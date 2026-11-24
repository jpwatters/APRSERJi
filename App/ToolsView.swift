import AprsCore
import Charts
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/** The Tools tab: monitors, lists and utilities. */
struct ToolsView: View {
    let core: AppleAprs
    let stations: [StationDetail]
    let origin: CLLocationCoordinate2D
    let originLabel: String
    let mapCenter: CLLocationCoordinate2D
    let myPosition: CLLocationCoordinate2D?
    let telemetry: [String: TelemetryReport]
    let onShowOnMap: (CLLocationCoordinate2D, String?) -> Void
    let onMessage: (String) -> Void
    let onMultiTrack: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Your station") {
                    NavigationLink { ObjectsView(core: core, mapCenter: mapCenter, myPosition: myPosition) } label: {
                        Label("Objects, items & bulletins", systemImage: "flag")
                    }
                    NavigationLink { BeaconJournalView(core: core) } label: { Label("Beacon journal", systemImage: "list.bullet.rectangle") }
                    NavigationLink { PacketMonitorView(core: core) } label: { Label("Packet monitor", systemImage: "waveform.path.ecg") }
                    NavigationLink { EmailView(core: core) } label: { Label("Send email", systemImage: "envelope") }
                }
                Section("Stations") {
                    NavigationLink { FrequencyView(stations: stations, origin: origin, onShowOnMap: onShowOnMap) } label: {
                        Label("Frequencies", systemImage: "dot.radiowaves.left.and.right")
                    }
                    NavigationLink { PlatformsView(stations: stations, onShowOnMap: onShowOnMap) } label: {
                        Label("Platforms (radios & software)", systemImage: "cpu")
                    }
                    NavigationLink { DxView(core: core, onShowOnMap: onShowOnMap) } label: { Label("RF DX", systemImage: "scope") }
                    NavigationLink { HistoryView(core: core, telemetry: telemetry, onShowOnMap: onShowOnMap) } label: {
                        Label("Station history & telemetry graphs", systemImage: "chart.xyaxis.line")
                    }
                    Button { onMultiTrack() } label: { Label("MultiTrack (follow up to 8 stations)", systemImage: "rectangle.split.2x2") }
                }
                Section("Map") {
                    NavigationLink { SatellitesView(core: core, observer: origin) } label: { Label("Satellites", systemImage: "globe.americas") }
                    NavigationLink { DirectionFindingView(origin: origin, originLabel: originLabel) } label: {
                        Label("Direction finding", systemImage: "location.north.line")
                    }
                    NavigationLink { DigitalLogsView(onShowOnMap: onShowOnMap) } label: {
                        Label("Digital-mode logs (FT8, JS8Call, JT65)", systemImage: "waveform")
                    }
                    NavigationLink { ImportedLayersView() } label: { Label("Imported GPX & OSM layers", systemImage: "square.3.layers.3d.down.right") }
                }
            }
            .navigationTitle("Tools")
        }
    }
}

struct PacketMonitorView: View {
    let core: AppleAprs
    @State private var paused = false
    @State private var shown: [PacketLogEntry] = []
    @State private var search = ""
    @State private var port = "All"
    @State private var direction = "Both"
    @State private var exportText: String?

    private var ports: [String] { ["All"] + Array(Set(core.packetLogEntries.map(\.port))).sorted() }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Port", selection: $port) { ForEach(ports, id: \.self) { Text($0).tag($0) } }.fixedSize()
                Picker("Direction", selection: $direction) {
                    Text("RX + TX").tag("Both"); Text("RX").tag("RX"); Text("TX").tag("TX")
                }
                .pickerStyle(.segmented).fixedSize()
                Toggle(paused ? "Paused" : "Live", isOn: $paused).toggleStyle(.button)
                Spacer()
                ShareLink(item: shown.map { "\(Self.time($0.timeMillis)) \($0.port) \($0.direction) \($0.line)" }.joined(separator: "\n")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            .padding(.horizontal)
            List(shown.reversed(), id: \.sequence) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Self.time(entry.timeMillis)) · \(entry.port) · \(entry.direction)")
                        .font(.caption2).foregroundStyle(entry.direction == "TX" ? Color.orange : Color.secondary)
                    Text(entry.line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Packet monitor")
        .searchable(text: $search, prompt: "Callsign or text")
        .task {
            while !Task.isCancelled {
                if !paused { refresh() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        let q = search.uppercased()
        shown = core.packetLogEntries.filter { e in
            (port == "All" || e.port == port) && (direction == "Both" || e.direction == direction) &&
                (q.isEmpty || e.line.uppercased().contains(q))
        }.suffix(1000)
    }

    static func time(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .omitted, time: .standard)
    }
}

struct BeaconJournalView: View {
    let core: AppleAprs
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            List(core.beaconJournal.reversed(), id: \.self) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.kind).font(.headline)
                        Text(entry.reason).font(.caption).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                        Spacer()
                        Text(PacketMonitorView.time(entry.timeMillis)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("via \(entry.routes)").font(.caption).foregroundStyle(.secondary)
                    Text(entry.packet).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .overlay { if core.beaconJournal.isEmpty { ContentUnavailableView("Nothing sent yet", systemImage: "antenna.radiowaves.left.and.right") } }
        }
        .navigationTitle("Beacon journal")
    }
}

struct EmailView: View {
    let core: AppleAprs
    @AppStorage("callsign") private var callsign = ""
    @AppStorage("emailGateway") private var gateway = "EMAIL-2"
    @State private var address = ""
    @State private var bodyText = ""
    @State private var result: String?

    var body: some View {
        Form {
            TextField("To (email address)", text: $address)
            TextField("Message", text: $bodyText, axis: .vertical).lineLimit(3...8)
            Text("\(bodyText.count)/300").font(.caption).foregroundStyle(.secondary)
            TextField("Gateway", text: $gateway)
            Button("Send") {
                Task {
                    let ok = (try? await core.email(account: normalizedCallsign(callsign), gateway: gateway, address: address, body: bodyText))?.boolValue ?? false
                    result = ok ? "Queued in Messages (to \(gateway))." : "Check the address and text (up to 300 printable characters, no { | ~)."
                    if ok { bodyText = "" }
                }
            }
            .disabled(address.isEmpty || bodyText.isEmpty || callsign.isEmpty)
            if let result { Text(result).font(.caption) }
            Section {
                Text("Long messages are split into numbered parts, each carrying the address. EMAIL-2 replies come back as messages; they need a verified login or a radio port.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Send email")
    }
}

struct FrequencyView: View {
    let stations: [StationDetail]
    let origin: CLLocationCoordinate2D
    let onShowOnMap: (CLLocationCoordinate2D, String?) -> Void
    @AppStorage("useMetric") private var metric = false

    var body: some View {
        let advertised = stations.filter { $0.frequencyText != nil }
            .sorted { Geo.distance(origin, $0.coordinate) < Geo.distance(origin, $1.coordinate) }
        let malformed = stations.filter(\.frequencyMalformed)
        List {
            Section("Advertised frequencies (\(advertised.count))") {
                ForEach(advertised, id: \.callsign) { s in
                    Button { onShowOnMap(s.coordinate, s.callsign) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.frequencyText ?? "").font(.headline.monospaced())
                                Text("\(s.callsign) · \(Units.distance(Geo.distance(origin, s.coordinate), metric: metric)) \(Units.compass(Geo.bearing(from: origin, to: s.coordinate)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if !malformed.isEmpty {
                Section("Mentions MHz but not in the standard form") {
                    ForEach(malformed, id: \.callsign) { s in
                        VStack(alignment: .leading) {
                            Text(s.callsign).font(.headline.monospaced())
                            Text(s.comment).font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Frequencies")
    }
}

struct PlatformsView: View {
    let stations: [StationDetail]
    let onShowOnMap: (CLLocationCoordinate2D, String?) -> Void
    @State private var search = ""

    var body: some View {
        let groups = Dictionary(grouping: stations.filter { search.isEmpty || ($0.platform ?? "").localizedCaseInsensitiveContains(search) || $0.callsign.localizedCaseInsensitiveContains(search.uppercased()) }) { $0.platform ?? "Unknown (\($0.destination))" }
        List {
            ForEach(groups.keys.sorted { (groups[$0]?.count ?? 0) > (groups[$1]?.count ?? 0) }, id: \.self) { platform in
                DisclosureGroup("\(platform) — \(groups[platform]?.count ?? 0)") {
                    ForEach(groups[platform] ?? [], id: \.callsign) { s in
                        Button("\(s.callsign)  \(s.destination)") { onShowOnMap(s.coordinate, s.callsign) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Platform or callsign")
        .navigationTitle("Platforms")
        .safeAreaInset(edge: .bottom) {
            Text("Device identification © aprs.fi / OH7LZB, CC BY-SA 2.0 (github.com/aprsorg/aprs-deviceid)")
                .font(.caption2).foregroundStyle(.secondary).padding(4)
        }
    }
}

struct DxView: View {
    let core: AppleAprs
    let onShowOnMap: (CLLocationCoordinate2D, String?) -> Void
    @State private var entries: [DxEntry] = []
    @AppStorage("useMetric") private var metric = false

    var body: some View {
        List(entries, id: \.callsign) { e in
            Button { onShowOnMap(CLLocationCoordinate2D(latitude: e.latitude, longitude: e.longitude), e.callsign) } label: {
                HStack {
                    Text(e.callsign).font(.headline.monospaced())
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("\(Units.distance(e.distanceMeters, metric: metric)) \(Units.compass(e.bearing))")
                        Text("\(e.port) · \(Date(timeIntervalSince1970: Double(e.timeMillis) / 1000).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .overlay { if entries.isEmpty { ContentUnavailableView("No direct RF stations yet", systemImage: "scope", description: Text("Stations heard on a radio port with no digipeater in the path are listed by distance from you.")) } }
        .toolbar { Button("Clear") { Task { _ = try? await core.clearDx(); entries = [] } } }
        .navigationTitle("RF DX")
        .task { entries = (try? await core.dxList(limit: 100)) ?? [] }
    }
}

/** Archived tracks with GPX export, and telemetry graphs. */
struct HistoryView: View {
    let core: AppleAprs
    let telemetry: [String: TelemetryReport]
    let onShowOnMap: (CLLocationCoordinate2D, String?) -> Void
    @State private var calls: [String] = []
    @State private var search = ""

    var body: some View {
        List(calls.filter { search.isEmpty || $0.contains(search.uppercased()) }, id: \.self) { call in
            NavigationLink(call) { HistoryDetail(core: core, callsign: call, report: telemetry[call], onShowOnMap: onShowOnMap) }
        }
        .searchable(text: $search)
        .navigationTitle("Station history")
        .task { calls = (try? await core.archivedCallsigns()) ?? [] }
    }
}

struct HistoryDetail: View {
    let core: AppleAprs
    let callsign: String
    let report: TelemetryReport?
    let onShowOnMap: (CLLocationCoordinate2D, String?) -> Void
    @State private var points: [HistoryPoint] = []
    @State private var samples: [TelemetryPoint] = []
    @State private var days = 1
    @State private var showOnMap = false

    var body: some View {
        Form {
            Picker("Period", selection: $days) {
                Text("Day").tag(1); Text("Week").tag(7); Text("Month").tag(30)
            }
            .pickerStyle(.segmented)
            Section("Track — \(points.count) positions") {
                if let last = points.last {
                    Button("Show last position on map") { onShowOnMap(CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude), callsign) }
                    Button(showOnMap ? "Remove track from map" : "Draw track on map") { toggleLayer() }
                    ShareLink(item: GpxFile(text: core.gpx(callsign: callsign, points: points), name: callsign),
                              preview: SharePreview("\(callsign).gpx")) { Label("Export GPX", systemImage: "square.and.arrow.up") }
                }
                if points.contains(where: { $0.altitudeMeters != nil }) {
                    Chart(points.filter { $0.altitudeMeters != nil }, id: \.timeMillis) { p in
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: Double(p.timeMillis) / 1000)),
                                 y: .value("Altitude (m)", p.altitudeMeters?.doubleValue ?? 0))
                    }
                    .frame(height: 140)
                }
            }
            if !samples.isEmpty {
                ForEach(0..<5, id: \.self) { channel in
                    let values = samples.compactMap { s -> (Date, Double)? in
                        guard channel < s.analog.count, let raw = (s.analog[channel] as? NSNumber)?.doubleValue else { return nil }
                        return (Date(timeIntervalSince1970: Double(s.timeMillis) / 1000), scaled(raw, channel))
                    }
                    if !values.isEmpty {
                        Section(channelName(channel)) {
                            Chart(values, id: \.0) { v in
                                LineMark(x: .value("Time", v.0), y: .value(channelName(channel), v.1))
                                PointMark(x: .value("Time", v.0), y: .value(channelName(channel), v.1)).symbolSize(12)
                            }
                            .frame(height: 140)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(callsign)
        .task(id: days) {
            let since = Int64((Date().timeIntervalSince1970 - Double(days) * 86_400) * 1000)
            points = (try? await core.history(callsign: callsign, sinceMillis: since, limit: 5000)) ?? []
            samples = (try? await core.telemetryHistory(callsign: callsign, sinceMillis: since, limit: 5000)) ?? []
            showOnMap = MapExtras.shared.layers.contains { $0.name == "History \(callsign)" }
        }
    }

    private func channelName(_ i: Int) -> String {
        guard let report, i < report.channels.count else { return "A\(i + 1)" }
        let c = report.channels[i]
        return c.unit.isEmpty ? c.name : "\(c.name) (\(c.unit))"
    }

    /** Applies the station's EQNS (a·x² + b·x + c) when known. */
    private func scaled(_ raw: Double, _ i: Int) -> Double {
        guard let report, i < report.channels.count, let value = report.channels[i].value?.doubleValue,
              let r = report.channels[i].raw?.doubleValue, r != 0 else { return raw }
        return raw * value / r
    }

    private func toggleLayer() {
        let name = "History \(callsign)"
        if let i = MapExtras.shared.layers.firstIndex(where: { $0.name == name }) {
            MapExtras.shared.layers.remove(at: i)
            showOnMap = false
        } else {
            MapExtras.shared.layers.append(ImportedLayer(name: name, lines: [points.map { [$0.latitude, $0.longitude] }]))
            showOnMap = true
        }
    }
}

/** A GPX document for sharing and saving. */
struct GpxFile: Transferable {
    let text: String
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "gpx") ?? .xml) { file in Data(file.text.utf8) }
            .suggestedFileName { "\($0.name).gpx" }
    }
}

struct SatellitesView: View {
    let core: AppleAprs
    let observer: CLLocationCoordinate2D
    @ObservedObject private var extras = MapExtras.shared
    @State private var loading = false
    @State private var problem: String?
    @State private var selected: String?
    @State private var passes: [SatellitePass] = []
    @AppStorage("tleUrl") private var tleUrl = "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=tle"
    @AppStorage("tleUpdated") private var tleUpdated = 0.0

    var body: some View {
        Form {
            Section {
                TextField("TLE source", text: $tleUrl)
                Button(loading ? "Downloading…" : "Download elements") { Task { await download() } }.disabled(loading)
                if tleUpdated > 0 {
                    Text("Elements from \(Date(timeIntervalSince1970: tleUpdated).formatted(date: .abbreviated, time: .shortened)); refresh them every few days.")
                        .font(.caption).foregroundStyle(tleUpdated < Date().timeIntervalSince1970 - 7 * 86_400 ? .orange : .secondary)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            } header: { Text("Elements") } footer: {
                Text("Satellite positions use SGP4 from these two-line elements. Tracked satellites show on the map with their footprint (green while above your horizon). The ISS APRS digipeater is on 145.825 MHz — check ARISS for its current status.")
            }
            Section("Satellites (\(core.satelliteList.count))") {
                ForEach(core.satelliteList.filter(\.nearEarth), id: \.name) { sat in
                    HStack {
                        Toggle(sat.name, isOn: Binding(get: { extras.trackedSatellites.contains(sat.name) }, set: { on in
                            extras.trackedSatellites.removeAll { $0 == sat.name }
                            if on { extras.trackedSatellites.append(sat.name) }
                        }))
                        Button("Passes") { selected = sat.name; computePasses(sat.name) }
                    }
                }
            }
            if let selected {
                Section("Next passes of \(selected)") {
                    if passes.isEmpty { Text("No passes above 5° in the next 24 hours.").foregroundStyle(.secondary) }
                    ForEach(passes, id: \.aosMillis) { p in
                        VStack(alignment: .leading) {
                            Text("\(date(p.aosMillis)) – \(time(p.losMillis))").font(.headline)
                            Text(String(format: "Max %.0f° at %@ · rises %@ sets %@", p.maxElevation, time(p.maxMillis),
                                        Units.compass(p.aosAzimuth), Units.compass(p.losAzimuth)))
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Satellites")
        .task { await loadCached() }
    }

    private func date(_ ms: Int64) -> String { Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened) }
    private func time(_ ms: Int64) -> String { Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened) }

    private func computePasses(_ name: String) {
        passes = core.satellitePasses(name: name, latitude: observer.latitude, longitude: observer.longitude,
                                      altitudeMeters: 0, hours: 24, minimumElevation: 5, maximum: 8)
    }

    private static var cacheFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("APRSERJi/amateur.tle")
    }

    private func loadCached() async {
        if core.satelliteList.isEmpty, let text = try? String(contentsOf: Self.cacheFile, encoding: .utf8) {
            _ = core.loadSatellites(tle: text)
        }
    }

    private func download() async {
        guard let url = URL(string: tleUrl) else { return }
        loading = true
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(decoding: data, as: UTF8.self)
            if core.loadSatellites(tle: text) > 0 {
                try? FileManager.default.createDirectory(at: Self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: Self.cacheFile, atomically: true, encoding: .utf8)
                tleUpdated = Date().timeIntervalSince1970
                problem = nil
            } else {
                problem = "No valid elements in that file."
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /** Loads cached elements at launch so tracked satellites appear without opening this screen. */
    static func loadAtLaunch(core: AppleAprs) {
        if core.satelliteList.isEmpty, let text = try? String(contentsOf: cacheFile, encoding: .utf8) { _ = core.loadSatellites(tle: text) }
    }
}

struct DirectionFindingView: View {
    let origin: CLLocationCoordinate2D
    let originLabel: String
    @ObservedObject private var extras = MapExtras.shared
    @State private var bearing = 0.0
    @State private var label = ""
    @State private var length = 30.0

    var body: some View {
        Form {
            Section {
                TextField("Label (what you heard)", text: $label)
                HStack {
                    Text("Bearing")
                    Slider(value: $bearing, in: 0...359, step: 1)
                    Text("\(Int(bearing))° \(Units.compass(bearing))").monospacedDigit().frame(width: 80)
                }
                Picker("Line length", selection: $length) {
                    ForEach([5.0, 15.0, 30.0, 60.0, 120.0], id: \.self) { Text("\(Int($0)) km").tag($0) }
                }
                Button("Add bearing from \(originLabel)") {
                    extras.bearings.append(ManualBearing(label: label, latitude: origin.latitude, longitude: origin.longitude,
                                                         bearing: bearing, lengthKm: length))
                }
            } header: { Text("New bearing") } footer: {
                Text("Take bearings from two or three places; where the lines cross is the transmitter. DF reports from other stations (DFS/BRG/NRQ) are drawn too when Direction finding is on in Layers.")
            }
            Section("Bearings") {
                ForEach(extras.bearings) { b in
                    VStack(alignment: .leading) {
                        Text("\(Int(b.bearing))° \(Units.compass(b.bearing))" + (b.label.isEmpty ? "" : " · \(b.label)")).font(.headline)
                        Text("from \(Geo.format(CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude))) · \(b.time.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { extras.bearings.remove(atOffsets: $0) }
                if !extras.bearings.isEmpty { Button("Clear all", role: .destructive) { extras.bearings = [] } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Direction finding")
    }
}

struct DigitalLogsView: View {
    let onShowOnMap: (CLLocationCoordinate2D, String?) -> Void
    @ObservedObject private var extras = MapExtras.shared
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button("Import a log file…") { importing = true }
                Toggle("Show spots on the map", isOn: $extras.showSpots)
                if !extras.spots.isEmpty { Button("Clear spots", role: .destructive) { extras.spots = [] } }
                if let message { Text(message).font(.caption) }
            } footer: {
                Text("WSJT-X ALL.TXT, JS8Call DIRECTED.TXT/ALL.TXT and JT65-HF logs: every station that sent a grid square (CQ … GRID, replies, JS8 GRID) is placed at its grid square.")
            }
            Section("Spots (\(extras.spots.count))") {
                ForEach(extras.spots) { s in
                    Button { onShowOnMap(CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude), nil) } label: {
                        HStack { Text(s.callsign).font(.headline.monospaced()); Spacer(); Text("\(s.mode) · \(s.grid)").foregroundStyle(.secondary) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Digital-mode logs")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            var added = 0
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { continue }
                for spot in DigitalLogParser.spots(in: text) {
                    extras.spots.removeAll { $0.callsign == spot.callsign }
                    extras.spots.append(spot)
                    added += 1
                }
            }
            message = "Placed \(added) stations."
        }
    }
}

struct ImportedLayersView: View {
    @ObservedObject private var extras = MapExtras.shared
    @State private var importing = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Button("Import GPX or OSM file…") { importing = true }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("GPX tracks, routes and waypoints, or OpenStreetMap XML ways (trails, roads, boundaries) are drawn over the map and kept until you remove them.")
            }
            Section("Layers") {
                ForEach($extras.layers) { $layer in
                    Toggle(isOn: $layer.visible) {
                        VStack(alignment: .leading) {
                            Text(layer.name)
                            Text("\(layer.lines.count) lines · \(layer.waypoints.count) waypoints").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { extras.layers.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Imported layers")
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, UTType(filenameExtension: "osm") ?? .xml, .xml],
                      allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), data.count < 60_000_000,
                      let layer = LayerParser.parse(data, name: url.deletingPathExtension().lastPathComponent) else {
                    problem = "\(url.lastPathComponent) has no tracks, routes, waypoints or ways."
                    continue
                }
                extras.layers.append(layer)
                problem = nil
            }
        }
    }
}
