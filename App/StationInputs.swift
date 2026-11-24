import AprsCore
import Foundation
import SwiftUI

/** Where your own weather readings come from. */
enum WeatherSource: String, CaseIterable, Identifiable {
    case off = "Off"
    case tempestLocal = "Tempest (local network)"
    case tempestCloud = "Tempest (WeatherFlow cloud)"
    case url = "Web address (wxnow.txt or JSON)"
    case file = "File (wxnow.txt or JSON)"
    case serial = "Ultimeter / Peet Bros (serial)"
    var id: String { rawValue }

    static var available: [WeatherSource] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .file && $0 != .serial }
        #endif
    }
}

/** Feeds the engine with weather readings from the chosen source. */
@MainActor
final class WeatherStation: ObservableObject {
    static let shared = WeatherStation()
    static let tokenAccount = "WEATHERFLOW-TOKEN"
    @Published private(set) var problem: String?
    private var lastFetch = Date.distantPast
    private var appliedSource: WeatherSource?
    #if os(macOS)
    private var serial: SerialPort?
    private var serialBuffer = ""
    #endif

    private var offsetMinutes: Int32 { Int32(TimeZone.current.secondsFromGMT() / 60) }

    func tick(core: AppleAprs, defaults d: UserDefaults = .standard) {
        let source = WeatherSource(rawValue: d.string(forKey: "wxSource") ?? "") ?? .off
        if source != appliedSource {
            core.configureTempest(enabled: source == .tempestLocal, utcOffsetMinutes: offsetMinutes)
            #if os(macOS)
            serial?.close()
            serial = nil
            if source == .serial, let path = d.string(forKey: "wxSerialDevice"), !path.isEmpty {
                let port = SerialPort(path: path, baud: d.object(forKey: "wxSerialBaud") as? Int ?? 2400)
                port.onData = { [weak self] data in self?.serialData(data, core: core) }
                port.onState = { [weak self] ok, error in self?.problem = ok ? nil : error }
                port.open()
                serial = port
            }
            #endif
            appliedSource = source
            lastFetch = .distantPast
        }
        core.setWeatherElevation(meters: d.double(forKey: "wxElevationMeters"))
        guard Date().timeIntervalSince(lastFetch) >= 60 else { return }
        switch source {
        case .tempestCloud:
            lastFetch = Date()
            let station = (d.string(forKey: "tempestStationId") ?? "").trimmingCharacters(in: .whitespaces)
            guard !station.isEmpty, let token = PasscodeKeychain.load(for: Self.tokenAccount),
                  let url = URL(string: "https://swd.weatherflow.com/swd/rest/observations/station/\(station)?token=\(token)") else {
                problem = "Enter your Tempest station ID and access token."
                return
            }
            fetch(url, kind: "tempest-rest", core: core)
        case .url:
            lastFetch = Date()
            guard let url = URL(string: d.string(forKey: "wxUrl") ?? "") else { problem = "Enter a web address."; return }
            fetch(url, kind: nil, core: core)
        case .file:
            lastFetch = Date()
            let path = (d.string(forKey: "wxFilePath") ?? "").trimmingCharacters(in: .whitespaces)
            guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else {
                problem = "Can't read \(path)"
                return
            }
            let ok = core.weatherInput(kind: text.hasPrefix("{") ? "json" : "text", text: text, utcOffsetMinutes: offsetMinutes)
            problem = ok ? nil : "The file isn't wxnow.txt or JSON weather."
        default:
            break
        }
    }

    private func fetch(_ url: URL, kind: String?, core: AppleAprs) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let text = String(decoding: data, as: UTF8.self)
                let k = kind ?? (text.trimmingCharacters(in: .whitespaces).hasPrefix("{") ? "json" : "text")
                let ok = core.weatherInput(kind: k, text: text, utcOffsetMinutes: offsetMinutes)
                problem = ok ? nil : "The reply didn't contain weather readings."
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    #if os(macOS)
    private func serialData(_ data: Data, core: AppleAprs) {
        serialBuffer += String(decoding: data, as: UTF8.self)
        while let end = serialBuffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let line = String(serialBuffer[..<end])
            serialBuffer = String(serialBuffer[serialBuffer.index(after: end)...])
            if !line.isEmpty { _ = core.weatherInput(kind: "text", text: line, utcOffsetMinutes: offsetMinutes) }
        }
        if serialBuffer.count > 4096 { serialBuffer = "" }
    }
    #endif
}

/** Setup ▸ Weather station: input, your weather reports, and CWOP. */
struct WeatherStationSections: View {
    let core: AppleAprs
    @ObservedObject private var station = WeatherStation.shared
    @AppStorage("wxSource") private var source: WeatherSource = .off
    @AppStorage("tempestStationId") private var tempestStation = ""
    @State private var token = ""
    @AppStorage("wxUrl") private var url = ""
    @AppStorage("wxFilePath") private var filePath = "~/wxnow.txt"
    @AppStorage("wxSerialDevice") private var serialDevice = ""
    @AppStorage("wxSerialBaud") private var serialBaud = 2400
    @AppStorage("wxElevationMeters") private var elevation = 0.0
    @AppStorage("wxBeaconEnabled") private var beaconEnabled = false
    @AppStorage("wxBeaconMinutes") private var beaconMinutes = 10
    @AppStorage("wxObjectName") private var objectName = ""
    @AppStorage("wxIS") private var toInternet = true
    @AppStorage("wxRF") private var toRadio = false
    @AppStorage("cwopEnabled") private var cwop = false
    @AppStorage("cwopCallsign") private var cwopCallsign = ""
    @AppStorage("cwopServer") private var cwopServer = "cwop.aprs.net:14580"
    @AppStorage("cwopPasscode") private var cwopPasscode = "-1"
    @AppStorage("useMetric") private var metric = false

    var body: some View {
        Section {
            Picker("Source", selection: $source) {
                ForEach(WeatherSource.available) { Text($0.rawValue).tag($0) }
            }
            switch source {
            case .tempestLocal:
                Text("Listening for your Tempest hub's broadcasts on UDP port 50222 — \(core.tempestState.lowercased()). The hub must be on the same network.")
                    .font(.caption).foregroundStyle(.secondary)
            case .tempestCloud:
                TextField("Station ID (tempestwx.com ▸ Settings ▸ Stations)", text: $tempestStation)
                SecureField(PasscodeKeychain.load(for: WeatherStation.tokenAccount) == nil ? "Personal access token" : "Token saved in Keychain (type to replace)", text: $token)
                    .onSubmit { saveToken() }
                Button("Save token") { saveToken() }.disabled(token.isEmpty)
            case .url:
                TextField("https://…/wxnow.txt", text: $url)
            case .file:
                TextField("File path", text: $filePath)
            case .serial:
                #if os(macOS)
                Picker("Device", selection: $serialDevice) {
                    Text("Choose…").tag("")
                    ForEach(SerialPort.devices(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Speed", selection: $serialBaud) {
                    ForEach([1200, 2400, 4800, 9600], id: \.self) { Text("\($0) baud").tag($0) }
                }
                #endif
            case .off:
                EmptyView()
            }
            if source == .tempestLocal || source == .tempestCloud {
                LabeledContent("Station elevation (m)") {
                    TextField("meters", value: $elevation, format: .number).frame(width: 80)
                }
            }
            if let w = core.localWeather {
                LabeledContent("Latest (\(w.source))") {
                    Text(summary(w)).multilineTextAlignment(.trailing)
                }
            }
            if let problem = station.problem, source != .off {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        } header: { Text("Weather station") } footer: {
            Text("A Tempest hub broadcasts every minute on your network — no account needed. The cloud option uses your WeatherFlow personal access token instead (for when the app isn't on the same network).")
        }

        Section {
            Toggle("Send my weather reports", isOn: $beaconEnabled)
            Picker("Every", selection: $beaconMinutes) {
                ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            TextField("As an object named (blank: as my station)", text: $objectName)
            Toggle("APRS-IS", isOn: $toInternet)
            Toggle("Radio ports", isOn: $toRadio)
            Button("Send weather now") { core.sendWeatherNow() }.disabled(core.localWeather == nil)
            Toggle("Upload to CWOP", isOn: $cwop)
            if cwop {
                TextField("CWOP ID (e.g. CW1234) or your callsign", text: $cwopCallsign)
                TextField("Server", text: $cwopServer)
                TextField("Passcode (-1 for CW/DW/EW IDs)", text: $cwopPasscode)
                if !core.cwopStatus.isEmpty { Text(core.cwopStatus).font(.caption).foregroundStyle(.secondary) }
            }
        } header: { Text("Weather reports") } footer: {
            Text("Reports use your beacon position (GPS or fixed). The Citizen Weather Observer Program (wxqa.com) shares your readings with NOAA; uploads go out no more than every 5 minutes.")
        }
    }

    private func saveToken() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        PasscodeKeychain.save(t, for: WeatherStation.tokenAccount)
        token = ""
    }

    private func summary(_ w: LocalWeather) -> String {
        var parts: [String] = []
        if let t = w.temperatureC?.doubleValue { parts.append(Units.temperature(t, metric: metric)) }
        if let h = w.humidity?.intValue { parts.append("\(h)%") }
        if let s = w.windMps?.doubleValue {
            parts.append("wind \(Units.speed(kph: s * 3.6, metric: metric))" + (w.windDegrees.map { " \(Units.compass(Double($0.intValue)))" } ?? ""))
        }
        if let p = w.pressureHpa?.doubleValue { parts.append(Units.pressure(p, metric: metric)) }
        if let r = w.rainMidnightMm?.doubleValue { parts.append("rain \(Units.rain(r, metric: metric)) today") }
        return parts.joined(separator: " · ")
    }
}

/** Setup ▸ Automatic answers and services. */
struct ServicesSections: View {
    let core: AppleAprs
    @AppStorage("respQueries") private var queries = true
    @AppStorage("autoReplyEnabled") private var autoReply = false
    @AppStorage("autoReplyText") private var autoReplyText = "Away from the radio; I'll reply later."
    @AppStorage("autoReplyMinutes") private var autoReplyMinutes = 30
    @AppStorage("qruEnabled") private var qru = false
    @AppStorage("qruRadiusKm") private var qruRadius = 50
    @AppStorage("qruMax") private var qruMax = 5
    @AppStorage("kioskEnabled") private var kiosk = false
    @AppStorage("kioskText") private var kioskText = ""
    @AppStorage("backupServers") private var backupServers = "noam.aprs2.net:14580, euro.aprs2.net:14580"
    @AppStorage("isServerEnabled") private var serverEnabled = false
    @AppStorage("isServerPort") private var serverPort = 14580
    @AppStorage("isServerLocalOnly") private var serverLocal = true
    @AppStorage("isServerToIS") private var serverToIS = false
    @AppStorage("isServerToRF") private var serverToRF = false
    @AppStorage("udpEnabled") private var udpEnabled = false
    @AppStorage("udpPort") private var udpPort = 2025
    @AppStorage("udpAllowed") private var udpAllowed = ""
    @AppStorage("syslogEnabled") private var syslogEnabled = false
    @AppStorage("syslogHost") private var syslogHost = ""
    @AppStorage("syslogPort") private var syslogPort = 514
    @AppStorage("archiveDays") private var archiveDays = 30

    var body: some View {
        Section {
            Toggle("Answer APRS queries (?APRS?, ?APRSP, ?PING?, ?VER …)", isOn: $queries)
            Toggle("Away message", isOn: $autoReply)
            if autoReply {
                TextField("Reply text", text: $autoReplyText)
                Picker("At most once per sender every", selection: $autoReplyMinutes) {
                    ForEach([10, 30, 60, 240], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
            Toggle("QRU object server", isOn: $qru)
            if qru {
                Stepper("Default radius \(qruRadius) km", value: $qruRadius, in: 5...500, step: 5)
                Stepper("Up to \(qruMax) objects per answer", value: $qruMax, in: 1...10)
            }
            Toggle("Information kiosk (answers INFO, HELP or ?)", isOn: $kiosk)
            if kiosk { TextField("Kiosk text (up to 3 messages)", text: $kioskText, axis: .vertical).lineLimit(2...5) }
        } header: { Text("Automatic answers") } footer: {
            Text("Away replies start with \"AA:\" and never go to services such as ANSRVR or EMAIL-2, or to other away messages, so two stations can't answer each other forever.")
        }

        Section {
            TextField("Backup servers (host:port, comma separated)", text: $backupServers)
            Picker("Keep station history", selection: $archiveDays) {
                ForEach([1, 7, 30, 90, 365], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
            }
        } header: { Text("APRS-IS and history") } footer: {
            Text("When the main server can't be reached, APRSERJi tries the backup servers in turn. Station history (positions and telemetry) is kept on this device for the chosen time.")
        }

        Section {
            Toggle("Local APRS-IS server", isOn: $serverEnabled)
            if serverEnabled {
                TextField("Port", value: $serverPort, format: .number.grouping(.never))
                Toggle("Only programs on this device", isOn: $serverLocal)
                Toggle("Forward their packets to APRS-IS", isOn: $serverToIS)
                Toggle("Forward their packets to radio ports", isOn: $serverToRF)
                Text(core.serverState).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("UDP packet input", isOn: $udpEnabled)
            if udpEnabled {
                TextField("UDP port", value: $udpPort, format: .number.grouping(.never))
                TextField("Also accept from (IP addresses)", text: $udpAllowed)
                Text(core.udpInputState).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Copy packets to a syslog server", isOn: $syslogEnabled)
            if syslogEnabled {
                TextField("Syslog host", text: $syslogHost)
                TextField("Syslog port", value: $syslogPort, format: .number.grouping(.never))
            }
        } header: { Text("Services for other programs") } footer: {
            Text("Xastir, YAAC, PinPoint and similar programs can connect to the local server like APRS-IS and see everything this station hears. They log in with their callsign and passcode; only verified clients may send packets, and those are forwarded only where you allow.")
        }
    }
}

#if os(macOS)
/** Where the Mac gets its position. */
enum GpsSource: String, CaseIterable, Identifiable {
    case coreLocation = "Location Services"
    case serial = "Serial / USB NMEA GPS"
    case tcp = "Network NMEA (TCP)"
    case gpsd = "gpsd"
    var id: String { rawValue }
}

/** Runs a serial NMEA GPS and keeps the network GPS setting applied. */
@MainActor
final class ExternalGps {
    static let shared = ExternalGps()
    private var applied = ""
    private var serial: SerialPort?
    private var buffer = ""

    func tick(core: AppleAprs, gps: GPSTracker, defaults d: UserDefaults = .standard) {
        let source = GpsSource(rawValue: d.string(forKey: "gpsSource") ?? "") ?? .coreLocation
        let device = d.string(forKey: "gpsSerialDevice") ?? ""
        let baud = d.object(forKey: "gpsSerialBaud") as? Int ?? 4800
        let host = d.string(forKey: "gpsHost") ?? "127.0.0.1"
        let port = d.object(forKey: "gpsPort") as? Int ?? (source == .gpsd ? 2947 : 10110)
        let signature = "\(source.rawValue)|\(device)|\(baud)|\(host)|\(port)"
        if signature != applied {
            applied = signature
            serial?.close()
            serial = nil
            core.configureGpsNetwork(enabled: source == .tcp || source == .gpsd, host: host, port: Int32(port), gpsd: source == .gpsd)
            if source == .serial, !device.isEmpty {
                let s = SerialPort(path: device, baud: baud)
                s.onData = { [weak self] data in self?.serialData(data, core: core) }
                s.open()
                serial = s
            }
            if source == .coreLocation { gps.endExternal() }
        }
        if source != .coreLocation, let fix = core.externalFix { gps.ingest(fix) }
    }

    private func serialData(_ data: Data, core: AppleAprs) {
        buffer += String(decoding: data, as: UTF8.self)
        while let end = buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let line = String(buffer[..<end])
            buffer = String(buffer[buffer.index(after: end)...])
            if line.hasPrefix("$") { core.gpsLine(line: line) }
        }
        if buffer.count > 4096 { buffer = "" }
    }
}

/** Setup ▸ GPS (Mac): the position source, and a sky plot of the satellites an NMEA receiver sees. */
struct GpsSourceSection: View {
    let core: AppleAprs
    @AppStorage("gpsSource") private var source: GpsSource = .coreLocation
    @AppStorage("gpsSerialDevice") private var device = ""
    @AppStorage("gpsSerialBaud") private var baud = 4800
    @AppStorage("gpsHost") private var host = "127.0.0.1"
    @AppStorage("gpsPort") private var port = 2947

    var body: some View {
        Section {
            Picker("Position from", selection: $source) {
                ForEach(GpsSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: source) { _, s in
                if s == .gpsd && port == 10110 { port = 2947 }
                if s == .tcp && port == 2947 { port = 10110 }
            }
            switch source {
            case .serial:
                Picker("Device", selection: $device) {
                    Text("Choose…").tag("")
                    ForEach(SerialPort.devices(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Speed", selection: $baud) {
                    ForEach([4800, 9600, 19200, 38400, 115200], id: \.self) { Text("\($0) baud").tag($0) }
                }
            case .tcp, .gpsd:
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                Text(core.gpsNetworkState).font(.caption).foregroundStyle(.secondary)
            case .coreLocation:
                EmptyView()
            }
            if source != .coreLocation, let sky = core.gpsSky {
                SkyPlot(sky: sky).frame(height: 240)
                LabeledContent("Fix", value: "\(sky.fixType == 3 ? "3D" : sky.fixType == 2 ? "2D" : "none") · \(sky.satellites.filter(\.used).count) used of \(sky.satellites.count)" +
                               (sky.hdop.map { String(format: " · HDOP %.1f", $0.doubleValue) } ?? ""))
            }
        } header: { Text("GPS") } footer: {
            Text("An external GPS can be a USB receiver (NMEA), a phone app or Bluetooth GPS sharing NMEA over TCP, or gpsd (port 2947).")
        }
    }
}

/** Polar sky plot: north up, the horizon at the edge, the zenith in the middle; filled dots are used in the fix. */
struct SkyPlot: View {
    let sky: GpsSkyInfo

    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2 - 14
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for ring in [1.0, 2.0 / 3.0, 1.0 / 3.0] {
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r * ring, y: c.y - r * ring, width: 2 * r * ring, height: 2 * r * ring)),
                               with: .color(.secondary.opacity(0.4)))
            }
            context.draw(Text("N").font(.caption2), at: CGPoint(x: c.x, y: c.y - r - 8))
            for s in sky.satellites {
                guard let el = s.elevation?.doubleValue, let az = s.azimuth?.doubleValue else { continue }
                let d = r * (90 - el) / 90
                let a = (az - 90) * .pi / 180
                let p = CGPoint(x: c.x + d * cos(a), y: c.y + d * sin(a))
                let snr = s.snr?.doubleValue ?? 0
                let color: Color = snr >= 35 ? .green : snr >= 25 ? .yellow : snr > 0 ? .orange : .gray
                let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                if s.used { context.fill(dot, with: .color(color)) } else { context.stroke(dot, with: .color(color)) }
                context.draw(Text("\(s.constellation)\(s.id)").font(.system(size: 8)), at: CGPoint(x: p.x, y: p.y + 10))
            }
        }
    }
}
#endif
