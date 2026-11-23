import AprsCore
import CoreLocation
import SwiftUI

enum BeaconSource: String, CaseIterable, Identifiable {
    case gps = "GPS", fixed = "Fixed position"
    var id: String { rawValue }
}

enum BeaconMode: String, CaseIterable, Identifiable {
    case interval = "Fixed interval", genius = "GeniusBeaconing"
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

    private static func int(_ key: String, _ fallback: Int, _ d: UserDefaults) -> Int { d.object(forKey: key) as? Int ?? fallback }
    private static func double(_ key: String, _ fallback: Double, _ d: UserDefaults) -> Double { d.object(forKey: key) as? Double ?? fallback }

    static func apply(core: AppleAprs, gps: GPSTracker, defaults d: UserDefaults = .standard) {
        let enabled = d.bool(forKey: "beaconEnabled")
        let genius = (BeaconMode(rawValue: d.string(forKey: "beaconMode") ?? "") ?? .interval) == .genius
        let key = d.string(forKey: "beaconSymbol") ?? "/>"
        let comment = d.string(forKey: "beaconComment") ?? "APRSERJi"
        let source = BeaconSource(rawValue: d.string(forKey: "beaconSource") ?? "") ?? .gps
        let maximum = genius ? int("geniusMaxMinutes", 30, d) * 60 : max(1, int("beaconMinutes", 10, d)) * 60
        let applied = core.configureBeacon(
            enabled: enabled, genius: genius,
            minimumSeconds: Int32(int("geniusMinSeconds", 30, d)), maximumSeconds: Int32(maximum),
            forecastErrorMeters: double("geniusForecastMeters", 160.9344, d),
            distanceMeters: double("geniusDistanceMeters", 1609.344, d),
            headingDegrees: double("geniusHeading", 30, d),
            symbolTable: String(key.prefix(1)), symbol: String(key.dropFirst().prefix(1)), comment: comment,
            viaRadio: d.bool(forKey: "beaconViaRadio"), radioPath: d.string(forKey: "beaconRadioPath") ?? "WIDE1-1,WIDE2-1")
        if !applied && !enabled {
            // Keep the core's last valid settings, but never keep beaconing with ones the user turned off.
            _ = core.configureBeacon(enabled: false, genius: false, minimumSeconds: 60, maximumSeconds: 600,
                                     forecastErrorMeters: 160, distanceMeters: 1609, headingDegrees: 30,
                                     symbolTable: "/", symbol: ">", comment: "", viaRadio: false, radioPath: "")
        }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        switch source {
        case .fixed:
            if let c = fixedCoordinate(d) {
                core.updateBeaconPosition(latitude: c.latitude, longitude: c.longitude, accuracyMeters: 0,
                                          timeMillis: nowMillis, speedKnots: -1, courseDegrees: -1,
                                          altitudeMeters: .nan, moving: false)
            } else {
                core.clearBeaconPosition()
            }
        case .gps:
            // Core Location only reports again after moving, so a fix stays current while tracking is on.
            if gps.tracking, let fix = gps.latest {
                core.updateBeaconPosition(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                          accuracyMeters: max(0, fix.horizontalAccuracy), timeMillis: nowMillis,
                                          speedKnots: fix.speed >= 0 ? fix.speed * 1.943844 : -1,
                                          courseDegrees: fix.course >= 0 ? fix.course : -1,
                                          altitudeMeters: fix.verticalAccuracy >= 0 ? fix.altitude : .nan,
                                          moving: true)
            } else {
                core.clearBeaconPosition()
            }
        }
    }
}

/** The beacon sections of the Setup tab. */
struct BeaconSections: View {
    let core: AppleAprs
    let mapCenter: CLLocationCoordinate2D
    let now: Date
    @ObservedObject var gps: GPSTracker
    @AppStorage("beaconEnabled") private var enabled = false
    @AppStorage("beaconMode") private var mode: BeaconMode = .interval
    @AppStorage("beaconSource") private var source: BeaconSource = .gps
    @AppStorage("beaconMinutes") private var minutes = 10
    @AppStorage("geniusMinSeconds") private var minSeconds = 30
    @AppStorage("geniusMaxMinutes") private var maxMinutes = 30
    @AppStorage("geniusForecastMeters") private var forecastMeters = 160.9344
    @AppStorage("geniusDistanceMeters") private var distanceMeters = 1609.344
    @AppStorage("geniusHeading") private var heading = 30.0
    @AppStorage("beaconSymbol") private var symbolKey = "/>"
    @AppStorage("beaconComment") private var comment = "APRSERJi"
    @AppStorage("beaconLatitude") private var latitude = ""
    @AppStorage("beaconLongitude") private var longitude = ""
    @AppStorage("beaconViaRadio") private var viaRadio = false
    @AppStorage("beaconRadioPath") private var radioPath = "WIDE1-1,WIDE2-1"
    @AppStorage("useMetric") private var metric = false
    @AppStorage("callsign") private var callsign = ""

    private let intervals = [1, 2, 5, 10, 15, 20, 30, 60]

    var body: some View {
        Section {
            Toggle("Beacon my position", isOn: $enabled)
            LabeledContent("Status") {
                Text(statusText).foregroundStyle(statusColor).multilineTextAlignment(.trailing)
            }
            Button("Beacon now") { core.beaconNow() }
                .disabled(core.beaconState == "NOT_CONNECTED" || core.beaconState == "NOT_VERIFIED")
        } header: {
            Text("Beacon")
        } footer: {
            Text("Beacons go out as \(callsign.isEmpty ? "your callsign" : callsign) over APRS-IS when the login is verified (Enable sending + passcode), and on RF through the software modem when Also send on RF is on. The app must stay open.")
        }
        .onChange(of: enabled) { _, on in
            if on && source == .gps && !gps.tracking { gps.start() }
        }
        .onChange(of: source) { _, newSource in
            if enabled && newSource == .gps && !gps.tracking { gps.start() }
        }

        Section("Position") {
            Picker("Source", selection: $source) {
                ForEach(BeaconSource.allCases) { Text($0.rawValue).tag($0) }
            }
            if source == .gps {
                if let fix = gps.latest {
                    LabeledContent("GPS fix", value: "\(Geo.format(fix.coordinate)) ±\(Int(fix.horizontalAccuracy)) m")
                    if fix.speed >= 0 {
                        LabeledContent("Moving", value: "\(Units.speed(knots: fix.speed * 1.943844, metric: metric))" +
                                       (fix.course >= 0 ? " \(Units.compass(fix.course))" : ""))
                    }
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
                if let fixed = BeaconSync.fixedCoordinate() {
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
            Picker("Timing", selection: $mode) {
                ForEach(BeaconMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if mode == .interval {
                Picker("Interval", selection: $minutes) {
                    ForEach(intervals, id: \.self) { Text($0 == 1 ? "1 minute" : "\($0) minutes").tag($0) }
                }
            } else {
                Picker("Forecast error", selection: $forecastMeters) {
                    ForEach([80.4672, 160.9344, 402.336, 804.672], id: \.self) { Text(Units.distance($0, metric: metric)).tag($0) }
                }
                Picker("Distance traveled", selection: $distanceMeters) {
                    ForEach([804.672, 1609.344, 3218.688, 8046.72], id: \.self) { Text(Units.distance($0, metric: metric)).tag($0) }
                }
                Picker("Heading change", selection: $heading) {
                    ForEach([15.0, 20.0, 30.0, 45.0, 60.0], id: \.self) { Text("\(Int($0))°").tag($0) }
                }
                Picker("At most every", selection: $minSeconds) {
                    ForEach([10, 20, 30, 60, 120], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("At least every", selection: $maxMinutes) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
            Toggle("Also send on RF", isOn: $viaRadio)
            if viaRadio {
                TextField("RF path", text: $radioPath)
            }
        } header: {
            Text("Report")
        } footer: {
            Text(mode == .genius
                 ? "GeniusBeaconing predicts where you are from your last beacon's course and speed, and beacons when the real position strays by the forecast error, after the distance traveled, or after the heading change — never faster than At most every, and at least every At least every. A fixed position beacons at the At least every interval."
                 : (source == .fixed
                    ? "A fixed station rarely needs to beacon more often than every 30 minutes."
                    : "Mobile stations usually beacon every 2–10 minutes. Shorter intervals add load to APRS-IS."))
        }
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
        case "SENT", "SCHEDULED", "WATCHING": return .green
        case "FAILED", "TOO_SOON": return .red
        case "OFF": return .secondary
        default: return .orange
        }
    }

    private var statusText: String {
        let last = core.lastBeaconMillis > 0 ? Date(timeIntervalSince1970: Double(core.lastBeaconMillis) / 1000) : nil
        let next = core.nextBeaconMillis > 0 ? Date(timeIntervalSince1970: Double(core.nextBeaconMillis) / 1000) : nil
        let lastText = last.map {
            " · last \($0.formatted(date: .omitted, time: .shortened)) via \(core.lastBeaconRoutes)" +
                (core.lastBeaconReason.isEmpty ? "" : " (\(core.lastBeaconReason))")
        } ?? ""
        func countdown(_ next: Date) -> String {
            let seconds = max(0, Int(next.timeIntervalSince(now)))
            return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        }
        switch core.beaconState {
        case "OFF": return "Off" + lastText
        case "NOT_CONNECTED": return "Waiting for APRS-IS or the software modem"
        case "NOT_VERIFIED": return "Needs a verified login (Enable sending + passcode) or Also send on RF"
        case "NO_POSITION": return source == .gps ? "Waiting for a GPS fix" : "Enter a valid fixed position"
        case "LOW_ACCURACY": return "Waiting for GPS accuracy under 100 m"
        case "TOO_SOON": return "Wait 30 seconds between beacons"
        case "FAILED": return "Send failed; will retry" + lastText
        case "SENT": return "Sent" + lastText
        case "WATCHING":
            return "Watching your movement" + (next.map { " · at the latest in \(countdown($0))" } ?? "") + lastText
        case "SCHEDULED":
            return (next.map { "Next in \(countdown($0))" } ?? "Scheduled") + lastText
        default: return core.beaconState
        }
    }
}
