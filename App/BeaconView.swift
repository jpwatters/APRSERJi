import AprsCore
import CoreLocation
import SwiftUI

enum BeaconSource: String, CaseIterable, Identifiable {
    case gps = "GPS", fixed = "Fixed position"
    var id: String { rawValue }
}

/** Pushes the saved beacon settings and the current position to the core. Called once a second. */
enum BeaconSync {
    static func fixedCoordinate(_ defaults: UserDefaults = .standard) -> CLLocationCoordinate2D? {
        guard let lat = Double((defaults.string(forKey: "beaconLatitude") ?? "").trimmingCharacters(in: .whitespaces)),
              let lon = Double((defaults.string(forKey: "beaconLongitude") ?? "").trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func apply(core: AppleAprs, gps: GPSTracker, defaults: UserDefaults = .standard) {
        let enabled = defaults.bool(forKey: "beaconEnabled")
        let minutes = defaults.object(forKey: "beaconMinutes") as? Int ?? 10
        let key = defaults.string(forKey: "beaconSymbol") ?? "/>"
        let comment = defaults.string(forKey: "beaconComment") ?? "APRSERJi"
        let source = BeaconSource(rawValue: defaults.string(forKey: "beaconSource") ?? "") ?? .gps
        let applied = core.configureBeacon(enabled: enabled, intervalSeconds: Int32(max(1, minutes) * 60),
                                           symbolTable: String(key.prefix(1)), symbol: String(key.dropFirst().prefix(1)),
                                           comment: comment)
        if !applied {
            // Keep the core's last valid settings, but never keep beaconing with ones the user turned off.
            if !enabled { _ = core.configureBeacon(enabled: false, intervalSeconds: 600, symbolTable: "/", symbol: ">", comment: "") }
        }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        switch source {
        case .fixed:
            if let c = fixedCoordinate(defaults) {
                core.updateBeaconPosition(latitude: c.latitude, longitude: c.longitude, accuracyMeters: 0, timeMillis: nowMillis)
            } else {
                core.clearBeaconPosition()
            }
        case .gps:
            // Core Location only reports again after moving, so a fix stays current while tracking is on.
            if gps.tracking, let fix = gps.latest {
                core.updateBeaconPosition(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                          accuracyMeters: max(0, fix.horizontalAccuracy), timeMillis: nowMillis)
            } else {
                core.clearBeaconPosition()
            }
        }
    }
}

struct BeaconView: View {
    let core: AppleAprs
    let connected: Bool
    let mapCenter: CLLocationCoordinate2D
    @ObservedObject var gps: GPSTracker
    @AppStorage("beaconEnabled") private var enabled = false
    @AppStorage("beaconSource") private var source: BeaconSource = .gps
    @AppStorage("beaconMinutes") private var minutes = 10
    @AppStorage("beaconSymbol") private var symbolKey = "/>"
    @AppStorage("beaconComment") private var comment = "APRSERJi"
    @AppStorage("beaconLatitude") private var latitude = ""
    @AppStorage("beaconLongitude") private var longitude = ""
    @AppStorage("useMetric") private var metric = false
    @AppStorage("notifyMessages") private var notify = true
    @AppStorage("callsign") private var callsign = ""

    private let intervals = [1, 2, 5, 10, 15, 20, 30, 60]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                Section {
                    Toggle("Beacon my position", isOn: $enabled)
                    LabeledContent("Status") {
                        Text(statusText(now: context.date)).foregroundStyle(statusColor)
                    }
                    Button("Beacon now") { core.beaconNow() }
                        .disabled(core.beaconState == "NOT_CONNECTED" || core.beaconState == "NOT_VERIFIED")
                } footer: {
                    Text("Beacons go out over APRS-IS as \(callsign.isEmpty ? "your callsign" : callsign). Sending needs **Enable sending** with your APRS-IS passcode, and the app must stay open.")
                }

                Section("Position") {
                    Picker("Source", selection: $source) {
                        ForEach(BeaconSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if source == .gps {
                        if let fix = gps.latest {
                            LabeledContent("GPS fix", value: "\(Geo.format(fix.coordinate)) ±\(Int(fix.horizontalAccuracy)) m")
                            LabeledContent("Grid square", value: Geo.grid(fix.coordinate))
                        } else {
                            LabeledContent("GPS fix", value: gps.tracking ? (gps.status ?? "Waiting for location") : "GPS is off")
                        }
                        if !gps.tracking {
                            Button("Start GPS") { gps.start() }
                        }
                    } else {
                        TextField("Latitude (e.g. 41.3576)", text: $latitude)
                        TextField("Longitude (e.g. -88.4212)", text: $longitude)
                        HStack {
                            Button("Use map center") { setFixed(mapCenter) }
                            if let fix = gps.latest {
                                Button("Use GPS fix") { setFixed(fix.coordinate) }
                            }
                        }
                        .buttonStyle(.bordered)
                        if let fixed = fixedCoordinate {
                            LabeledContent("Grid square", value: Geo.grid(fixed))
                        } else {
                            Text("Enter decimal degrees; west and south are negative.").font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Picker("Symbol", selection: $symbolKey) {
                        ForEach(AprsSymbol.beaconChoices, id: \.label) { choice in
                            Label(choice.label, systemImage: AprsSymbol.info(table: choice.table, symbol: choice.symbol).image)
                                .tag(choice.table + choice.symbol)
                        }
                    }
                    TextField("Comment", text: $comment)
                    Text("\(comment.count)/43 characters").font(.caption)
                        .foregroundStyle(commentValid ? Color.secondary : Color.red)
                    Picker("Interval", selection: $minutes) {
                        ForEach(intervals, id: \.self) { Text($0 == 1 ? "1 minute" : "\($0) minutes").tag($0) }
                    }
                } header: {
                    Text("Report")
                } footer: {
                    Text(source == .fixed
                         ? "A fixed station rarely needs to beacon more often than every 30 minutes."
                         : "Mobile stations usually beacon every 2–10 minutes. Shorter intervals add load to APRS-IS.")
                }

                Section("Display & alerts") {
                    Toggle("Metric units", isOn: $metric)
                    Toggle("Notify me of new messages", isOn: $notify)
                        .onChange(of: notify) { _, on in if on { MessageNotifier.shared.requestAuthorization() } }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: enabled) { _, on in
            if on && source == .gps && !gps.tracking { gps.start() }
        }
    }

    private var fixedCoordinate: CLLocationCoordinate2D? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private var commentValid: Bool {
        comment.count <= 43 && comment.allSatisfy { $0.isASCII && !"|~{".contains($0) && ($0.asciiValue ?? 0) >= 32 }
    }

    private func setFixed(_ c: CLLocationCoordinate2D) {
        latitude = String(format: "%.5f", c.latitude)
        longitude = String(format: "%.5f", c.longitude)
    }

    private var statusColor: Color {
        switch core.beaconState {
        case "SENT", "SCHEDULED": return .green
        case "FAILED", "TOO_SOON": return .red
        case "OFF": return .secondary
        default: return .orange
        }
    }

    private func statusText(now: Date) -> String {
        let last = core.lastBeaconMillis > 0 ? Date(timeIntervalSince1970: Double(core.lastBeaconMillis) / 1000) : nil
        let next = core.nextBeaconMillis > 0 ? Date(timeIntervalSince1970: Double(core.nextBeaconMillis) / 1000) : nil
        let lastText = last.map { " · last sent \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        switch core.beaconState {
        case "OFF": return "Off" + lastText
        case "NOT_CONNECTED": return "Waiting to connect"
        case "NOT_VERIFIED": return "Needs a verified login (Enable sending + passcode)"
        case "NO_POSITION": return source == .gps ? "Waiting for a GPS fix" : "Enter a valid fixed position"
        case "LOW_ACCURACY": return "Waiting for GPS accuracy under 100 m"
        case "TOO_SOON": return "Wait 30 seconds between beacons"
        case "FAILED": return "Send failed; will retry" + lastText
        case "SENT": return "Sent" + lastText
        case "SCHEDULED":
            guard let next else { return "Scheduled" + lastText }
            let seconds = max(0, Int(next.timeIntervalSince(now)))
            return "Next in \(seconds / 60):\(String(format: "%02d", seconds % 60))" + lastText
        default: return core.beaconState
        }
    }
}
