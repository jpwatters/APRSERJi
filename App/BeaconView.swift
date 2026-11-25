import AprsCore
import CoreLocation
import SwiftUI

enum BeaconSource: String, CaseIterable, Identifiable {
    case gps = "GPS", fixed = "Fixed position"
    var id: String { rawValue }
}

enum BeaconMode: String, CaseIterable, Identifiable {
    case interval = "Fixed interval", genius = "GeniusBeaconing", smart = "SmartBeaconing"
    var id: String { rawValue }
    var code: String {
        switch self {
        case .interval: return "interval"
        case .genius: return "genius"
        case .smart: return "smart"
        }
    }
}

/** Position precision: ambiguity hides digits, DAO adds them. */
enum BeaconPrecision: Int, CaseIterable, Identifiable {
    case degree = -4, tenMinutes = -3, minute = -2, tenthMinute = -1, normal = 0, daoTenth = 1, daoHundredth = 2, daoBase91 = 4
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .degree: return "Ambiguous: nearest degree (~60 mi)"
        case .tenMinutes: return "Ambiguous: 10 minutes (~10 mi)"
        case .minute: return "Ambiguous: 1 minute (~1 mi)"
        case .tenthMinute: return "Ambiguous: 0.1 minute (~600 ft)"
        case .normal: return "Normal (0.01 minute, ~60 ft)"
        case .daoTenth: return "DAO extra digit (~6 ft)"
        case .daoHundredth: return "DAO two digits (~1 ft)"
        case .daoBase91: return "DAO base-91 (finest)"
        }
    }
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
        let mode = BeaconMode(rawValue: d.string(forKey: "beaconMode") ?? "") ?? .interval
        let key = d.string(forKey: "beaconSymbol") ?? "/>"
        var comment = d.string(forKey: "beaconComment") ?? "APRSERJi"
        #if os(macOS)
        // The virtual radio's frequency at the start of the comment, in the APRS "FFF.FFFMHz" form.
        let rigHz = VirtualRig.shared.beaconFrequencyHz
        if d.bool(forKey: "catFreqInBeacon"), rigHz > 0, rigHz < 1_000_000_000 {
            let tag = String(format: "%07.3fMHz", Double(rigHz) / 1_000_000)
            comment = tag + (comment.isEmpty ? "" : " " + String(comment.prefix(43 - tag.count - 1)))
        }
        #endif
        let source = BeaconSource(rawValue: d.string(forKey: "beaconSource") ?? "") ?? .gps
        let maximum: Int
        switch mode {
        case .interval: maximum = max(1, int("beaconMinutes", 10, d)) * 60
        case .genius: maximum = int("geniusMaxMinutes", 30, d) * 60
        case .smart: maximum = int("smartSlowSeconds", 1800, d)
        }
        let applied = core.configureBeacon(
            enabled: enabled, mode: mode.code,
            minimumSeconds: Int32(mode == .smart ? int("smartMinSeconds", 30, d) : int("geniusMinSeconds", 30, d)),
            maximumSeconds: Int32(maximum),
            forecastErrorMeters: double("geniusForecastMeters", 160.9344, d),
            distanceMeters: double("geniusDistanceMeters", 1609.344, d),
            headingDegrees: mode == .smart ? double("smartTurnDegrees", 28, d) : double("geniusHeading", 30, d),
            slowKnots: double("smartSlowMph", 5, d) / 1.150779, fastKnots: double("smartFastMph", 60, d) / 1.150779,
            fastSeconds: Int32(int("smartFastSeconds", 180, d)), turnSlope: double("smartTurnSlope", 255, d),
            turnSeconds: Int32(int("smartTurnSeconds", 15, d)),
            symbolTable: String(key.prefix(1)), symbol: String(key.dropFirst().prefix(1)), comment: comment,
            micE: d.bool(forKey: "beaconMicE"), micEStatus: d.string(forKey: "beaconMicEStatus") ?? "!ENROUTE!",
            compressed: d.bool(forKey: "beaconCompressed"), precision: Int32(int("beaconPrecision", 0, d)),
            timestamp: d.string(forKey: "beaconTimestamp") ?? "none",
            altitude: d.object(forKey: "beaconAltitude") as? Bool ?? true,
            courseSpeed: d.object(forKey: "beaconCourseSpeed") as? Bool ?? true)
        if !applied && !enabled {
            // Keep the core's last valid settings, but never keep beaconing with ones the user turned off.
            _ = core.configureBeacon(enabled: false, mode: "interval", minimumSeconds: 60, maximumSeconds: 600,
                                     forecastErrorMeters: 160, distanceMeters: 1609, headingDegrees: 30,
                                     slowKnots: 5, fastKnots: 60, fastSeconds: 180, turnSlope: 255, turnSeconds: 15,
                                     symbolTable: "/", symbol: ">", comment: "", micE: false, micEStatus: "",
                                     compressed: false, precision: 0, timestamp: "none", altitude: true, courseSpeed: true)
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
            if gps.tracking || gps.external, let fix = gps.latest {
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
    @AppStorage("smartSlowMph") private var smartSlowMph = 5.0
    @AppStorage("smartFastMph") private var smartFastMph = 60.0
    @AppStorage("smartSlowSeconds") private var smartSlowSeconds = 1800
    @AppStorage("smartFastSeconds") private var smartFastSeconds = 180
    @AppStorage("smartTurnDegrees") private var smartTurnDegrees = 28.0
    @AppStorage("smartTurnSlope") private var smartTurnSlope = 255.0
    @AppStorage("smartTurnSeconds") private var smartTurnSeconds = 15
    @AppStorage("smartMinSeconds") private var smartMinSeconds = 30
    @AppStorage("beaconMicE") private var micE = false
    @AppStorage("beaconMicEStatus") private var micEStatus = "!ENROUTE!"
    @AppStorage("beaconCompressed") private var compressed = false
    @AppStorage("beaconPrecision") private var precision = 0
    @AppStorage("beaconTimestamp") private var timestamp = "none"
    @AppStorage("beaconAltitude") private var includeAltitude = true
    @AppStorage("beaconCourseSpeed") private var includeCourseSpeed = true
    @State private var showSymbols = false
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
            Text("Beacons go out as \(callsign.isEmpty ? "your callsign" : callsign) over APRS-IS when the login is verified (Enable sending + passcode), and on every radio port set to send beacons. The app must stay open.")
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
            Button {
                showSymbols = true
            } label: {
                LabeledContent("Symbol") {
                    Label(AprsSymbol.info(table: String(symbolKey.prefix(1)), symbol: String(symbolKey.dropFirst().prefix(1))).name,
                          systemImage: AprsSymbol.info(table: String(symbolKey.prefix(1)), symbol: String(symbolKey.dropFirst().prefix(1))).image)
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSymbols) { SymbolPicker(selection: $symbolKey) }
            TextField("Comment", text: $comment)
            Text("\(comment.count)/60 characters").font(.caption)
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
            if mode == .smart {
                LabeledContent("Slow below") { TextField("mph", value: $smartSlowMph, format: .number).frame(width: 60) }
                LabeledContent("Fast above") { TextField("mph", value: $smartFastMph, format: .number).frame(width: 60) }
                Picker("Slow rate", selection: $smartSlowSeconds) {
                    ForEach([600, 900, 1200, 1800, 3600], id: \.self) { Text("every \($0 / 60) minutes").tag($0) }
                }
                Picker("Fast rate", selection: $smartFastSeconds) {
                    ForEach([60, 90, 120, 180, 240], id: \.self) { Text("every \($0) seconds").tag($0) }
                }
                Picker("Minimum turn", selection: $smartTurnDegrees) {
                    ForEach([15.0, 20.0, 28.0, 35.0, 45.0], id: \.self) { Text("\(Int($0))°").tag($0) }
                }
                LabeledContent("Turn slope") { TextField("slope", value: $smartTurnSlope, format: .number).frame(width: 60) }
                Picker("Turn time", selection: $smartTurnSeconds) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
        } header: {
            Text("Report")
        } footer: {
            Text(mode == .smart
                 ? "SmartBeaconing beacons at the slow rate below the slow speed and the fast rate above the fast speed, scaling between, and \"corner pegs\" after turning more than the minimum turn plus slope ÷ speed (no sooner than the turn time)."
                 : mode == .genius
                 ? "GeniusBeaconing predicts where you are from your last beacon's course and speed, and beacons when the real position strays by the forecast error, after the distance traveled, or after the heading change — never faster than At most every, and at least every At least every. A fixed position beacons at the At least every interval."
                 : (source == .fixed
                    ? "A fixed station rarely needs to beacon more often than every 30 minutes."
                    : "Mobile stations usually beacon every 2–10 minutes. Shorter intervals add load to APRS-IS."))
        }
        formatSection
    }

    /** How the position report is encoded: Mic-E, compressed, ambiguity or DAO precision, timestamp. */
    @ViewBuilder var formatSection: some View {
        Section {
            Toggle("Mic-E (compact, used by Kenwood and Yaesu radios)", isOn: $micE)
            if micE {
                Picker("Mic-E status", selection: $micEStatus) {
                    ForEach(["!OFF-DUTY!", "!ENROUTE!", "!INSERVICE!", "!RETURNING!", "!COMMITTED!", "!SPECIAL!", "!PRIORITY!", "!EMERGENCY!"], id: \.self) {
                        Text($0.trimmingCharacters(in: CharacterSet(charactersIn: "!")).capitalized).tag($0)
                    }
                }
                if micEStatus == "!EMERGENCY!" {
                    Text("Emergency alerts every station that hears you. Use it only for a real emergency.").font(.caption).foregroundStyle(.red)
                }
            } else {
                Toggle("Compressed (base-91)", isOn: $compressed)
            }
            Picker("Precision", selection: $precision) {
                ForEach(BeaconPrecision.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Timestamp", selection: $timestamp) {
                Text("None").tag("none")
                Text("Hours-minutes-seconds (UTC)").tag("hms")
                Text("Day-hours-minutes (UTC)").tag("dhm")
            }
            Toggle("Include course and speed", isOn: $includeCourseSpeed)
            Toggle("Include altitude", isOn: $includeAltitude)
        } header: {
            Text("Report format")
        } footer: {
            Text("Ambiguity hides your exact position (useful at home). DAO adds precision beyond 0.01 minute. Compressed reports fall back to normal ones when they would lose course, speed or altitude.")
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
