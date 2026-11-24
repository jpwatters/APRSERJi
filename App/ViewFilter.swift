import AprsCore
import CoreLocation
import SwiftUI

enum ViewSource: String, CaseIterable, Identifiable {
    case all = "All sources", internet = "APRS-IS only", radio = "RF only"
    var id: String { rawValue }
}

/**
 * Callsigns that are always shown on the map. They are added to the APRS-IS filter as a buddy list (b/), so the
 * server sends their packets wherever they are — even far outside the receive ranges. A trailing * matches any
 * SSID or suffix, e.g. KC9KKO* or W9*.
 */
enum WatchList {
    static let maximum = 12

    static func parse(_ text: String) -> [String] {
        let calls = text.uppercased()
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0.isNewline })
            .map(String.init)
            .filter { call in
                (1...9).contains(call.count) && call.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "*" }
                    && call.first != "*"
            }
        var unique: [String] = []
        for call in calls where !unique.contains(call) { unique.append(call) }
        return Array(unique.prefix(maximum))
    }

    /** The javAPRSSrvr buddy-list term, e.g. "b/KC9KKO-9/W9ABC*", or "" for none. */
    static func serverFilter(_ calls: [String]) -> String {
        calls.isEmpty ? "" : "b/" + calls.joined(separator: "/")
    }

    static func matches(_ callsign: String, _ patterns: [String]) -> Bool {
        let call = callsign.uppercased()
        return patterns.contains { pattern in
            pattern.hasSuffix("*") ? call.hasPrefix(pattern.dropLast()) : call == pattern
        }
    }
}

/** Which stations the map shows. Watched callsigns are always shown. Every choice is saved across restarts. */
struct ViewFilter {
    var stations = true
    var weather = true
    var objects = true
    var source: ViewSource = .all
    var maxAgeMinutes = 0
    var maxMiles = 0
    var movingOnly = false
    var hideInfrastructure = false
    var watched: [String] = []
    /** "", or one of: messaging, frequency, mice, igate, telemetry, altitude, status. */
    var only = ""

    func includes(_ s: StationDetail, origin: CLLocationCoordinate2D, now: Date) -> Bool {
        if WatchList.matches(s.callsign, watched) { return true }
        switch s.kind {
        case "weather": if !weather { return false }
        case "object", "item": if !objects { return false }
        default: if !stations { return false }
        }
        switch source {
        case .internet: if s.heardOnRadio { return false }
        case .radio: if !s.heardOnRadio { return false }
        case .all: break
        }
        if maxAgeMinutes > 0, now.timeIntervalSince(s.heardAt) > Double(maxAgeMinutes) * 60 { return false }
        if maxMiles > 0, Geo.distance(origin, s.coordinate) > Double(maxMiles) * 1609.344 { return false }
        if movingOnly, (s.speedKnots?.doubleValue ?? 0) < 1 { return false }
        if hideInfrastructure, s.symbol == "#" || s.symbol == "&" { return false }
        switch only {
        case "messaging": if !s.messageCapable { return false }
        case "frequency": if s.frequencyText == nil { return false }
        case "mice": if s.micEStatus == nil { return false }
        case "igate": if !s.isIgate { return false }
        case "telemetry": if !s.hasTelemetry { return false }
        case "altitude": if s.altitudeMeters == nil { return false }
        case "status": if s.statusText == nil { return false }
        default: break
        }
        return true
    }
}

/** The View row under the receive ranges: a filter menu and the watch list. Every choice is saved. */
struct ViewSettingsRow: View {
    /** Watch list as applied to the current connection, to know when Apply is needed. */
    let appliedWatch: [String]
    let connected: Bool
    let onApplyWatch: () -> Void
    @AppStorage("viewStations") private var stations = true
    @AppStorage("viewWeather") private var weather = true
    @AppStorage("viewObjects") private var objects = true
    @AppStorage("viewMovingOnly") private var movingOnly = false
    @AppStorage("viewHideInfrastructure") private var hideInfrastructure = false
    @AppStorage("viewSource") private var source: ViewSource = .all
    @AppStorage("viewMaxAgeMinutes") private var maxAgeMinutes = 0
    @AppStorage("viewMaxMiles") private var maxMiles = 0
    @AppStorage("viewWatchList") private var watchText = ""
    @AppStorage("viewOnly") private var only = ""
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("View").font(.caption.bold())
                Menu {
                    Section("Show") {
                        Toggle("Stations", isOn: $stations)
                        Toggle("Weather stations", isOn: $weather)
                        Toggle("Objects and items", isOn: $objects)
                        Toggle("Moving stations only", isOn: $movingOnly)
                        Toggle("Hide digipeaters and gateways", isOn: $hideInfrastructure)
                    }
                    Picker("Heard on", selection: $source) {
                        ForEach(ViewSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Heard within", selection: $maxAgeMinutes) {
                        Text("Any time").tag(0)
                        ForEach([5, 10, 15, 20], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Picker("Only stations that", selection: $only) {
                        Text("Any").tag("")
                        Text("can receive messages").tag("messaging")
                        Text("advertise a frequency").tag("frequency")
                        Text("send Mic-E").tag("mice")
                        Text("are IGates").tag("igate")
                        Text("send telemetry").tag("telemetry")
                        Text("report altitude").tag("altitude")
                        Text("sent a status").tag("status")
                    }
                    Picker("Within distance of you", selection: $maxMiles) {
                        Text("Any distance").tag(0)
                        ForEach([10, 25, 50, 100, 250], id: \.self) { Text("\($0) mi").tag($0) }
                    }
                    Divider()
                    Button("Show everything") { reset() }
                } label: {
                    Label(summary, systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
            }
            HStack(spacing: 6) {
                Text("Always show").font(.caption)
                // One line that scrolls sideways: the arrow keys (and Home/End) move through text that doesn't fit.
                TextField("Callsigns, e.g. KJ4DXK*, KC9KKO*, W9ABC-9", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .onSubmit(save)
                Button(connected ? "Apply" : "Save") {
                    save()
                    if connected { onApplyWatch() }
                }
                .disabled(WatchList.parse(draft) == WatchList.parse(watchText)
                          && (!connected || WatchList.parse(watchText) == appliedWatch))
            }
            Text("Watched stations are requested from APRS-IS wherever they are, always shown, and marked in yellow. Up to \(WatchList.maximum) callsigns; end with * to match any SSID.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .onAppear { draft = watchText }
    }

    private func save() {
        watchText = WatchList.parse(draft).joined(separator: ", ")
        draft = watchText
    }

    private var summary: String {
        var parts: [String] = []
        if !(stations && weather && objects) {
            let kinds = [stations ? "stations" : nil, weather ? "weather" : nil, objects ? "objects" : nil].compactMap { $0 }
            parts.append(kinds.isEmpty ? "none" : kinds.joined(separator: "+"))
        }
        if source != .all { parts.append(source == .radio ? "RF" : "APRS-IS") }
        if maxAgeMinutes > 0 { parts.append("\(maxAgeMinutes) min") }
        if maxMiles > 0 { parts.append("\(maxMiles) mi") }
        if movingOnly { parts.append("moving") }
        if hideInfrastructure { parts.append("no digis") }
        if !only.isEmpty { parts.append(only) }
        let watched = WatchList.parse(watchText).count
        if watched > 0 { parts.append("\(watched) watched") }
        return parts.isEmpty ? "All stations" : parts.joined(separator: " · ")
    }

    private func reset() {
        stations = true; weather = true; objects = true; movingOnly = false; hideInfrastructure = false
        source = .all; maxAgeMinutes = 0; maxMiles = 0; only = ""
    }
}
