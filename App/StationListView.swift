import AprsCore
import CoreLocation
import SwiftUI

enum StationFilter: String, CaseIterable, Identifiable {
    case all = "All", stations = "Stations", weather = "Weather", objects = "Objects"
    var id: String { rawValue }

    func includes(_ station: StationDetail) -> Bool {
        switch self {
        case .all: return true
        case .stations: return station.kind == "station"
        case .weather: return station.kind == "weather" || station.hasWeather
        case .objects: return station.kind == "object" || station.kind == "item"
        }
    }
}

enum StationSort: String, CaseIterable, Identifiable {
    case distance = "Distance", recent = "Last heard", callsign = "Callsign"
    var id: String { rawValue }
}

struct StationListView: View {
    let stations: [StationDetail]
    /** Distances are measured from here: your GPS fix when available, otherwise the map center. */
    let origin: CLLocationCoordinate2D
    let originLabel: String
    let connected: Bool
    let onMessage: (String) -> Void
    let onShowOnMap: (StationDetail) -> Void
    let telemetry: [String: TelemetryReport]
    @AppStorage("useMetric") private var metric = false
    @AppStorage("stationSort") private var sort: StationSort = .distance
    @AppStorage("stationFilter") private var filter: StationFilter = .all
    @Binding var path: [String]
    @State private var search = ""

    private var visible: [StationDetail] {
        let query = search.trimmingCharacters(in: .whitespaces).uppercased()
        let matching = stations.filter { station in
            filter.includes(station) && (query.isEmpty || station.callsign.uppercased().contains(query)
                || station.comment.uppercased().contains(query) || (station.owner?.uppercased().contains(query) ?? false))
        }
        switch sort {
        case .distance:
            return matching.sorted { Geo.distance(origin, $0.coordinate) < Geo.distance(origin, $1.coordinate) }
        case .recent:
            return matching.sorted { $0.heardAtMillis > $1.heardAtMillis }
        case .callsign:
            return matching.sorted { $0.callsign < $1.callsign }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 6) {
                Picker("Show", selection: $filter) {
                    ForEach(StationFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                content
            }
            .navigationTitle("Stations")
            .searchable(text: $search, prompt: "Callsign or comment")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(StationSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .navigationDestination(for: String.self) { callsign in
                StationDetailView(callsign: callsign, stations: stations, origin: origin,
                                  originLabel: originLabel, onMessage: onMessage, onShowOnMap: onShowOnMap,
                                  telemetry: telemetry[callsign])
            }
        }
    }

    @ViewBuilder private var content: some View {
        if stations.isEmpty {
            ContentUnavailableView(connected ? "Listening…" : "Not connected", systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text(connected ? "Stations appear here as they are heard."
                                                               : "Connect to APRS-IS to see stations near the map."))
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                List(visible, id: \.callsign) { station in
                    NavigationLink(value: station.callsign) {
                        StationRow(station: station, origin: origin, metric: metric, now: context.date)
                    }
                }
            }
            Text("\(visible.count) of \(stations.count) · distances from \(originLabel)")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
        }
    }
}

private struct StationRow: View {
    let station: StationDetail
    let origin: CLLocationCoordinate2D
    let metric: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            StationBadge(station: station)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(station.callsign).font(.headline.monospaced())
                    if station.kind != "station" {
                        Text(station.kindLabel).font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(station.tint.opacity(0.18), in: Capsule())
                    }
                    Spacer()
                    Text(Units.age(station.heardAt, now: now)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    let meters = Geo.distance(origin, station.coordinate)
                    Text("\(Units.distance(meters, metric: metric)) \(Units.compass(Geo.bearing(from: origin, to: station.coordinate)))")
                    if let t = station.temperatureC?.doubleValue {
                        Text("· \(Units.temperature(t, metric: metric))")
                    }
                    if let knots = station.speedKnots?.doubleValue, knots >= 1 {
                        Text("· \(Units.speed(knots: knots, metric: metric))")
                    }
                }
                .font(.caption)
                if !station.comment.isEmpty {
                    Text(station.comment).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct StationBadge: View {
    let station: StationDetail
    var body: some View {
        Image(systemName: station.symbolInfo.image)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(station.tint, in: Circle())
            .accessibilityLabel(station.symbolInfo.name)
    }
}

extension StationDetail {
    var tint: Color {
        switch kind {
        case "weather": return .teal
        case "object": return .orange
        case "item": return .purple
        default: return .red
        }
    }
}

struct StationDetailView: View {
    let callsign: String
    let stations: [StationDetail]
    let origin: CLLocationCoordinate2D
    let originLabel: String
    let onMessage: (String) -> Void
    let onShowOnMap: (StationDetail) -> Void
    let telemetry: TelemetryReport?
    @AppStorage("useMetric") private var metric = false
    @AppStorage("nicknames") private var nicknameStore = ""
    @AppStorage("pathStations") private var pathStore = ""
    @State private var showWhoIs = false
    @State private var nickname = ""

    var body: some View {
        if let station = stations.first(where: { $0.callsign == callsign }) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Form {
                    header(station)
                    position(station)
                    if station.courseDegrees != nil || station.speedKnots != nil || station.altitudeMeters != nil {
                        motion(station)
                    }
                    if station.hasWeather { weather(station) }
                    if let telemetry { telemetrySection(telemetry) }
                    info(station, now: context.date)
                }
                .formStyle(.grouped)
            }
            .navigationTitle(station.callsign)
        } else {
            ContentUnavailableView("\(callsign) is no longer in range", systemImage: "antenna.radiowaves.left.and.right.slash",
                                   description: Text("Stations drop off after 30 minutes without a packet."))
        }
    }

    private func header(_ s: StationDetail) -> some View {
        Section {
            HStack(spacing: 14) {
                StationBadge(station: s)
                VStack(alignment: .leading) {
                    Text(s.callsign).font(.title2.bold().monospaced())
                    Text("\(s.kindLabel) · \(s.symbolInfo.name)").foregroundStyle(.secondary)
                }
            }
            if !s.comment.isEmpty { Text(s.comment).textSelection(.enabled) }
            if let status = s.statusText { Label(status, systemImage: "text.bubble").textSelection(.enabled) }
            HStack {
                TextField("Nickname (shown on the map)", text: $nickname)
                    .onSubmit { saveNickname(s.callsign) }
                Button("Save") { saveNickname(s.callsign) }
            }
            .onAppear { nickname = Nicknames.load(nicknameStore)[s.callsign] ?? "" }
            // On iPhone and iPad the buttons wrap onto more rows instead of squeezing their labels.
            Group {
                #if os(iOS)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 8) { actions(s) }
                #else
                HStack { actions(s) }
                #endif
            }
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .sheet(isPresented: $showWhoIs) { WhoIsView(callsign: s.owner ?? s.callsign) }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func actions(_ s: StationDetail) -> some View {
        if s.canMessage {
            Button { onMessage(s.callsign) } label: { Label("Message", systemImage: "bubble.left") }
        }
        Button { onShowOnMap(s) } label: { Label("Show on map", systemImage: "map") }
        Button { showWhoIs = true } label: { Label("WHO-IS", systemImage: "person.text.rectangle") }
        if !s.pathNodes.isEmpty {
            let showing = pathStore.split(separator: ",").map(String.init).contains(s.callsign)
            Button { togglePath(s.callsign) } label: {
                Label(showing ? "Hide path" : "Show path", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
    }

    private func position(_ s: StationDetail) -> some View {
        Section("Position") {
            LabeledContent("Coordinates", value: Geo.format(s.coordinate))
            LabeledContent("Grid square", value: Geo.grid(s.coordinate))
            LabeledContent("From \(originLabel)",
                           value: "\(Units.distance(Geo.distance(origin, s.coordinate), metric: metric)) at \(Int(Geo.bearing(from: origin, to: s.coordinate).rounded()))° \(Units.compass(Geo.bearing(from: origin, to: s.coordinate)))")
        }
    }

    private func motion(_ s: StationDetail) -> some View {
        Section("Movement") {
            if let course = s.courseDegrees?.doubleValue {
                LabeledContent("Course", value: "\(Int(course))° \(Units.compass(course))")
            }
            if let knots = s.speedKnots?.doubleValue {
                LabeledContent("Speed", value: Units.speed(knots: knots, metric: metric))
            }
            if let altitude = s.altitudeMeters?.doubleValue {
                LabeledContent("Altitude", value: Units.altitude(altitude, metric: metric))
            }
        }
    }

    private func weather(_ s: StationDetail) -> some View {
        Section("Weather") {
            if let t = s.temperatureC?.doubleValue {
                LabeledContent("Temperature", value: Units.temperature(t, metric: metric))
            }
            if let h = s.humidity?.intValue { LabeledContent("Humidity", value: "\(h)%") }
            if let speed = s.windKph?.doubleValue {
                let direction = s.windDegrees.map { "from \(Units.compass(Double($0.intValue))) (\($0.intValue)°) " } ?? ""
                LabeledContent("Wind", value: "\(direction)\(Units.speed(kph: speed, metric: metric))")
            }
            if let gust = s.gustKph?.doubleValue { LabeledContent("Gusts", value: Units.speed(kph: gust, metric: metric)) }
            if let p = s.pressureHpa?.doubleValue { LabeledContent("Pressure", value: Units.pressure(p, metric: metric)) }
            if let r = s.rainHourMm?.doubleValue { LabeledContent("Rain, last hour", value: Units.rain(r, metric: metric)) }
            if let r = s.rainDayMm?.doubleValue { LabeledContent("Rain, last 24 h", value: Units.rain(r, metric: metric)) }
            if let r = s.rainMidnightMm?.doubleValue { LabeledContent("Rain since midnight", value: Units.rain(r, metric: metric)) }
            if s.weatherAtMillis > 0 {
                LabeledContent("Reported", value: Date(timeIntervalSince1970: Double(s.weatherAtMillis) / 1000)
                    .formatted(date: .omitted, time: .shortened))
            }
        }
    }

    private func saveNickname(_ call: String) {
        var names = Nicknames.load(nicknameStore)
        let name = nickname.trimmingCharacters(in: .whitespaces)
        names[call] = name.isEmpty ? nil : name
        nicknameStore = Nicknames.encode(names)
    }

    private func togglePath(_ call: String) {
        var calls = pathStore.split(separator: ",").map(String.init)
        if calls.contains(call) { calls.removeAll { $0 == call } } else { calls.append(call) }
        pathStore = calls.suffix(20).joined(separator: ",")
    }

    private func telemetrySection(_ t: TelemetryReport) -> some View {
        Section(t.title.isEmpty ? "Telemetry" : "Telemetry · \(t.title)") {
            ForEach(Array(t.channels.enumerated()), id: \.offset) { _, channel in
                if let value = channel.value?.doubleValue ?? channel.raw?.doubleValue {
                    LabeledContent(channel.name, value: "\(value.formatted(.number.precision(.fractionLength(0...3)))) \(channel.unit)")
                }
            }
            let named = t.bits.filter { !$0.name.hasPrefix("B") || $0.name.count > 2 }
            if !named.isEmpty {
                ForEach(Array(named.enumerated()), id: \.offset) { _, bit in
                    LabeledContent(bit.name) {
                        Image(systemName: bit.active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(bit.active ? Color.green : Color.secondary)
                    }
                }
            } else {
                LabeledContent("Bits", value: t.bits.map { $0.set ? "1" : "0" }.joined())
            }
            LabeledContent("Sequence", value: "\(t.sequence) at \(Date(timeIntervalSince1970: Double(t.timeMillis) / 1000).formatted(date: .omitted, time: .shortened))")
        }
    }

    private func info(_ s: StationDetail, now: Date) -> some View {
        Section("Packets") {
            if let owner = s.owner { LabeledContent("Owner", value: owner) }
            if let platform = s.platform { LabeledContent("Platform", value: platform) }
            if !s.destination.isEmpty { LabeledContent("Destination", value: s.destination) }
            if let freq = s.frequencyText { LabeledContent("Frequency", value: freq) }
            if let mice = s.micEStatus { LabeledContent("Mic-E status", value: mice) }
            if s.ambiguityDigits > 0 { LabeledContent("Position ambiguity", value: "\(s.ambiguityDigits) digit(s) hidden") }
            if s.messageCapable { LabeledContent("Messaging", value: "Can receive messages") }
            if s.isIgate { LabeledContent("IGate", value: "Gates RF to APRS-IS") }
            if !s.port.isEmpty { LabeledContent("Heard on port", value: s.port) }
            if let bearing = s.dfBearing?.doubleValue {
                LabeledContent("DF bearing", value: "\(Int(bearing))° \(Units.compass(bearing))" + (s.dfRangeMeters.map { " · \(Units.distance($0.doubleValue, metric: metric))" } ?? ""))
            }
            LabeledContent("Last heard", value: "\(s.heardAt.formatted(date: .omitted, time: .standard)) (\(Units.age(s.heardAt, now: now)))")
            LabeledContent("Packets heard", value: "\(s.packetCount)" + (s.heardOnRadio ? " · last on RF" : ""))
            if let coverage = s.coverageMeters?.doubleValue {
                LabeledContent("Radio coverage (PHG)", value: Units.distance(coverage, metric: metric))
            }
            if !s.path.isEmpty { LabeledContent("Path", value: s.path).textSelection(.enabled) }
            if !s.pathNodes.isEmpty {
                LabeledContent("Route", value: s.pathNodes.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "?" : String($0) }.joined(separator: " → "))
            }
            LabeledContent("Symbol", value: "\(s.symbolTable)\(s.symbol)")
        }
    }
}

/** Your names for stations, saved as JSON. */
enum Nicknames {
    static func load(_ text: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
    }
    static func encode(_ names: [String: String]) -> String {
        (try? String(data: JSONEncoder().encode(names), encoding: .utf8)) ?? ""
    }
}
