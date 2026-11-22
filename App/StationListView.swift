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
                                  originLabel: originLabel, onMessage: onMessage, onShowOnMap: onShowOnMap)
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
    @AppStorage("useMetric") private var metric = false

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
            HStack {
                if s.canMessage {
                    Button { onMessage(s.callsign) } label: { Label("Message", systemImage: "bubble.left") }
                }
                Button { onShowOnMap(s) } label: { Label("Show on map", systemImage: "map") }
            }
            .buttonStyle(.bordered)
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

    private func info(_ s: StationDetail, now: Date) -> some View {
        Section("Packets") {
            if let owner = s.owner { LabeledContent("Owner", value: owner) }
            LabeledContent("Last heard", value: "\(s.heardAt.formatted(date: .omitted, time: .standard)) (\(Units.age(s.heardAt, now: now)))")
            LabeledContent("Packets heard", value: "\(s.packetCount)")
            if !s.path.isEmpty { LabeledContent("Path", value: s.path).textSelection(.enabled) }
            LabeledContent("Symbol", value: "\(s.symbolTable)\(s.symbol)")
        }
    }
}
