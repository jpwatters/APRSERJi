#if os(macOS)
import Darwin
#endif
import Foundation
import Network
import SwiftUI

// MARK: - The radio APRSERJi pretends to be

/** Modes as Hamlib names them; the Kenwood TS-480 MD number for each. */
enum RigMode: String, CaseIterable, Identifiable {
    case lsb = "LSB", usb = "USB", cw = "CW", cwr = "CWR", am = "AM", fm = "FM"
    case rtty = "RTTY", rttyr = "RTTYR", pktusb = "PKTUSB", pktlsb = "PKTLSB", pktfm = "PKTFM"
    var id: String { rawValue }

    var kenwood: Int {
        switch self {
        case .lsb, .pktlsb: return 1
        case .usb, .pktusb: return 2
        case .cw: return 3
        case .fm, .pktfm: return 4
        case .am: return 5
        case .rtty: return 6
        case .cwr: return 7
        case .rttyr: return 9
        }
    }

    static func fromKenwood(_ n: Int) -> RigMode? {
        switch n {
        case 1: return .lsb
        case 2: return .usb
        case 3: return .cw
        case 4: return .fm
        case 5: return .am
        case 6: return .rtty
        case 7: return .cwr
        case 9: return .rttyr
        default: return nil
        }
    }
}

/**
 A virtual radio for CAT programs (WSJT-X, loggers, satellite trackers, Hamlib).
 On iPhone and iPad, programs on other devices on the local network connect to its TCP port.
 Besides Kenwood and Hamlib, it takes APRSERJi's own commands (MP zoom, MC channel, MF frequencies
 and tone, MT track, MZ zoom to, MB beacon) — see `extensionCommand`.
 Other programs on this Mac connect over TCP on the IPv6 loopback [::1] (and
 127.0.0.1), or open a pseudo-terminal serial device, and send Kenwood TS-480
 commands (FA; MD; IF; TX; …) or Hamlib rigctld commands (f, F, m, M, t, T,
 \dump_state …). APRSERJi answers like a rig: it remembers the frequency, mode,
 VFO, split and PTT the programs set, shows them, and can put the frequency in
 its beacon comment. Nothing is transmitted because of a CAT command.
 */
final class VirtualRig: ObservableObject {
    static let shared = VirtualRig()

    struct State: Equatable {
        var freqA = 144_390_000
        var freqB = 144_390_000
        var mode: RigMode = .fm
        var passband = 0            // Hz; 0 = the mode's normal width
        var onB = false             // receive VFO is B
        var split = false           // transmit on the other VFO
        var ptt = false
        /** CTCSS tone for transmit, Hz; 0 = none. */
        var toneHz = 0.0
        /** The channel last tuned with MC (0 = none, tuned by frequency). */
        var channel = 0
        /** The channel in use before that, for MC=-1. */
        var previousChannel = 0
        /** The callsign MT is tracking on the map ("" = none). */
        var tracking = ""
        var frequency: Int { onB ? freqB : freqA }
        /** Transmit frequency: the other VFO when split. */
        var txFrequency: Int { split ? (onB ? freqA : freqB) : frequency }
    }

    @Published private(set) var shown = State()
    @Published private(set) var clients = 0
    @Published private(set) var status = "Off"
    @Published private(set) var lastCommand = ""

    private let lock = NSLock()
    private var state = State()
    private let queue = DispatchQueue(label: "aprserji.cat")
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    #if os(macOS)
    private var pty: CatPty?
    #endif
    private var config: Config?

    struct Config: Equatable {
        var enabled: Bool
        var port: Int
        var pty: Bool
        var ptyPath: String
    }

    /** True on iPhone and iPad: the port is reached from other devices on the local network. */
    static let acceptsNetwork: Bool = {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }()

    private init() {
        let d = UserDefaults.standard
        if let f = d.object(forKey: "catFrequencyA") as? Int, f > 0 { state.freqA = f }
        if let f = d.object(forKey: "catFrequencyB") as? Int, f > 0 { state.freqB = f }
        if let m = RigMode(rawValue: d.string(forKey: "catMode") ?? "") { state.mode = m }
        state.toneHz = d.double(forKey: "catToneHz")
        state.channel = d.integer(forKey: "catChannel")
        state.split = d.bool(forKey: "catSplit")
        shown = state
    }

    /** The frequency other code (the beacon) may use, read safely from any thread; 0 when the rig is off. */
    var beaconFrequencyHz: Int {
        lock.lock(); defer { lock.unlock() }
        return config?.enabled == true ? state.frequency : 0
    }

    // MARK: settings → listeners

    /** Called once a second from the app's main loop: starts or stops the server to match Setup. */
    func apply(defaults d: UserDefaults = .standard) {
        let wanted = Config(enabled: d.bool(forKey: "catEnabled"),
                            port: d.object(forKey: "catPort") as? Int ?? 4532,
                            pty: d.object(forKey: "catPty") as? Bool ?? true,
                            ptyPath: d.string(forKey: "catPtyPath") ?? "~/cu.APRSERJi")
        queue.async { [weak self] in
            guard let self, wanted != self.config else { return }
            self.stop()
            self.lock.lock(); self.config = wanted; self.lock.unlock()
            if wanted.enabled { self.start(wanted) } else { self.publishStatus("Off") }
        }
    }

    private func start(_ c: Config) {
        guard (1...65535).contains(c.port), let port = NWEndpoint.Port(rawValue: UInt16(c.port)) else {
            publishStatus("Port \(c.port) is not valid")
            return
        }
        var listening: [String] = []
        var problems: [String] = []
        // Mac: only this Mac's loopback addresses. iPhone/iPad: every interface (Wi-Fi, hotspot), IPv6 and IPv4.
        let endpoints: [(NWEndpoint.Host?, String)] = Self.acceptsNetwork
            ? [(nil, "port")]
            : [(.ipv6(.loopback), "[::1]"), (.ipv4(.loopback), "127.0.0.1")]
        for (host, label) in endpoints {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let host { params.requiredLocalEndpoint = .hostPort(host: host, port: port) }
            do {
                let l = host == nil ? try NWListener(using: params, on: port) : try NWListener(using: params)
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.stateUpdateHandler = { [weak self] st in
                    if case .failed(let e) = st { self?.publishStatus("\(label):\(c.port) failed: \(e)") }
                }
                l.start(queue: queue)
                listeners.append(l)
                listening.append("\(label):\(c.port)")
            } catch {
                problems.append("\(label): \(error.localizedDescription)")
            }
        }
        var text = listening.isEmpty ? "Not listening" : "Listening on " + listening.joined(separator: " and ")
        if Self.acceptsNetwork, !listening.isEmpty {
            let addresses = Self.localAddresses()
            text += addresses.isEmpty ? " (no network address yet)" : " · connect to " + addresses.map { $0.contains(":") ? "[\($0)]:\(c.port)" : "\($0):\(c.port)" }.joined(separator: " or ")
        }
        #if os(macOS)
        if c.pty {
            let p = CatPty(linkPath: c.ptyPath, queue: queue) { [weak self] cmd in self?.handle(cmd) ?? Data() }
            do {
                try p.open()
                pty = p
                text += " · serial device \(p.displayPath)"
            } catch {
                problems.append("serial device: \(error)")
            }
        }
        #endif
        if !problems.isEmpty { text += " · " + problems.joined(separator: "; ") }
        publishStatus(text)
    }

    private func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        #if os(macOS)
        pty?.close()
        pty = nil
        #endif
        publishClients()
    }

    // MARK: TCP connections

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        publishClients()
        let parser = CatParser()
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[key] = nil; self?.publishClients() }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(conn, parser)
    }

    private func receive(_ conn: NWConnection, _ parser: CatParser) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var quit = false
                let reply = parser.feed(data, handler: { self.handle($0) }, quit: &quit)
                if !reply.isEmpty { conn.send(content: reply, completion: .contentProcessed { _ in }) }
                if quit { conn.cancel(); return }
            }
            if done || error != nil { conn.cancel(); return }
            self.receive(conn, parser)
        }
    }

    private func publishClients() {
        let n = connections.count
        DispatchQueue.main.async { self.clients = n }
    }

    private func publishStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: commands

    /** One complete command in either dialect → the reply bytes. Runs on `queue`. */
    func handle(_ command: CatCommand) -> Data {
        lock.lock()
        let before = state
        let reply: String
        var action: RemoteAction?
        switch command {
        case .kenwood(let c): reply = kenwood(c)
        case .hamlib(let c, let extended): reply = hamlib(c, extended: extended)
        case .extension(let c, let newline):
            let (text, todo) = extensionCommand(c)
            reply = text + (newline ? "\n" : ";")
            action = todo
        }
        let after = state
        lock.unlock()
        if after != before { saved(after) }
        let text: String
        switch command {
        case .kenwood(let c): text = c + ";"
        case .hamlib(let c, _): text = c
        case .extension(let c, _): text = c
        }
        if let action {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .aprserjiRemote, object: action) }
        }
        DispatchQueue.main.async {
            self.lastCommand = text
            if after != self.shown { self.shown = after }
        }
        return Data(reply.utf8)
    }

    /** Set from the Setup tab (typed frequency or mode). */
    func setFromUI(frequencyHz: Int? = nil, mode: RigMode? = nil) {
        lock.lock()
        if let f = frequencyHz, f > 0 { if state.onB { state.freqB = f } else { state.freqA = f } }
        if let mode { state.mode = mode }
        let now = state
        lock.unlock()
        saved(now)
        DispatchQueue.main.async { self.shown = now }
    }

    /** The map stopped tracking (the user pressed Follow or the ✕): forget the MT callsign. */
    func stopTracking() {
        lock.lock(); state.tracking = ""; let now = state; lock.unlock()
        DispatchQueue.main.async { self.shown = now }
    }

    /** Tune a channel from Setup's channel list. */
    func tune(_ channel: Channel) {
        lock.lock(); apply(channel); let now = state; lock.unlock()
        saved(now)
        DispatchQueue.main.async { self.shown = now }
    }

    private func saved(_ s: State) {
        let d = UserDefaults.standard
        d.set(s.freqA, forKey: "catFrequencyA")
        d.set(s.freqB, forKey: "catFrequencyB")
        d.set(s.mode.rawValue, forKey: "catMode")
        d.set(s.toneHz, forKey: "catToneHz")
        d.set(s.channel, forKey: "catChannel")
        d.set(s.split, forKey: "catSplit")
    }

    // MARK: APRSERJi's own commands

    /** The two-letter codes of APRSERJi's own commands. */
    static let extensionCodes: Set<String> = ["MP", "MC", "MF", "MT", "MZ", "MB"]

    /**
     APRSERJi's own commands, each answered with its result (or "?" when it can't be done):

     - `MP=01` zooms the map in one step, `MP=-01` out one step (up to ±20).
     - `MC=0012` tunes channel 12 from the channel list, `MC=X+1` / `MC=X-1` the next / previous channel
       in the list, `MC=-1` back to the channel in use before; `MC` alone reports the current channel.
     - `MF=145.610/107.2/145.610` sets the transmit frequency, transmit CTCSS tone and receive frequency
       (MHz); a tone that isn't a number (`MF=145.610/xz/145.610`) means no tone. `MF` alone reports them.
     - `MT=KC9XYZ-01` tracks that station on the map, `MT=OFF` stops; `MT` alone reports it.
     - `MZ=KC9XYZ-01` zooms the map to that station once.
     - `MB` sends a beacon now, `MB=60S` (or `5M`) beacons on a fixed interval, `MB=SMART` (or `GENIUS`)
       switches to SmartBeaconing (GeniusBeaconing), `MB=OFF` / `MB=ON` stops / starts beaconing.

     Runs on `queue` with `lock` held.
     */
    private func extensionCommand(_ c: String) -> (String, RemoteAction?) {
        let code = String(c.prefix(2)).uppercased()
        var arg = String(c.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        var isSet = !arg.isEmpty
        if arg.hasPrefix("=") { arg.removeFirst(); arg = arg.trimmingCharacters(in: .whitespaces); isSet = true }
        if arg == "?" { isSet = false; arg = "" }
        let upper = arg.uppercased()
        let bad = "?"
        switch code {
        case "MP":
            guard isSet, let n = Int(upper.replacingOccurrences(of: "+", with: "")), n != 0, abs(n) <= 20 else { return (bad, nil) }
            return ("MP=" + (n < 0 ? String(format: "-%02ld", -n) : String(format: "%02ld", n)), .zoom(n))

        case "MC":
            if !isSet { return ("MC=" + String(format: "%04ld", state.channel), nil) }
            let channels = ChannelStore.shared.snapshot()
            var target: Channel?
            if upper == "-1" {
                target = channels.first { $0.number == state.previousChannel }
            } else if upper.hasPrefix("X") {
                let step = Int(upper.dropFirst().replacingOccurrences(of: "+", with: "")) ?? 0
                guard step != 0, !channels.isEmpty else { return (bad, nil) }
                if let i = channels.firstIndex(where: { $0.number == state.channel }) {
                    let n = channels.count
                    target = channels[((i + step) % n + n) % n]
                } else {
                    target = step > 0 ? channels.first : channels.last
                }
            } else if let n = Int(upper), n >= 0 {
                target = channels.first { $0.number == n }
            }
            guard let target else { return (bad, nil) }
            apply(target)
            return ("MC=" + String(format: "%04ld", target.number), nil)

        case "MF":
            if !isSet { return ("MF=" + mfText(), nil) }
            let parts = upper.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let tx = Self.parseHz(parts[0]) else { return (bad, nil) }
            let rx = parts.count >= 3 ? Self.parseHz(parts[2]) : tx
            guard let rx else { return (bad, nil) }
            let tone = parts.count >= 2 ? Double(parts[1]) ?? 0 : 0
            state.freqA = rx; state.freqB = tx; state.onB = false; state.split = tx != rx
            state.toneHz = (60...260).contains(tone) ? tone : 0
            if state.channel != 0 { state.previousChannel = state.channel }
            state.channel = 0
            return ("MF=" + mfText(), nil)

        case "MT":
            if !isSet { return ("MT=" + (state.tracking.isEmpty ? "OFF" : state.tracking), nil) }
            if ["OFF", "0", "NONE", ""].contains(upper) {
                state.tracking = ""
                return ("MT=OFF", .track(nil))
            }
            guard Self.isCallsign(upper) else { return (bad, nil) }
            state.tracking = upper
            return ("MT=" + upper, .track(upper))

        case "MZ":
            guard isSet, Self.isCallsign(upper) else { return (bad, nil) }
            return ("MZ=" + upper, .zoomTo(upper))

        case "MB":
            let d = UserDefaults.standard
            if !isSet { return ("MB", .beaconNow) }
            switch upper {
            case "SMART", "SMARTBEACONING":
                d.set("SmartBeaconing", forKey: "beaconMode"); d.set(true, forKey: "beaconEnabled")
                return ("MB=SMART", nil)
            case "GENIUS", "GENIUSBEACONING":
                d.set("GeniusBeaconing", forKey: "beaconMode"); d.set(true, forKey: "beaconEnabled")
                return ("MB=GENIUS", nil)
            case "OFF", "0":
                d.set(false, forKey: "beaconEnabled")
                return ("MB=OFF", nil)
            case "ON":
                d.set(true, forKey: "beaconEnabled")
                return ("MB=ON", nil)
            default:
                // 60S, 90S, 5M, or a number of seconds. The beacon runs in whole minutes, at least one.
                var number = upper
                var multiplier = 1
                if number.hasSuffix("S") { number.removeLast() } else if number.hasSuffix("M") { number.removeLast(); multiplier = 60 }
                guard let n = Int(number), n > 0 else { return (bad, nil) }
                let minutes = min(60, max(1, Int((Double(n * multiplier) / 60).rounded(.up))))
                d.set("Fixed interval", forKey: "beaconMode")
                d.set(minutes, forKey: "beaconMinutes")
                d.set(true, forKey: "beaconEnabled")
                return ("MB=\(minutes * 60)S", nil)
            }

        default:
            return (bad, nil)
        }
    }

    /** Tunes a channel: receive on VFO A, transmit on B (split when they differ), its tone and mode. */
    private func apply(_ ch: Channel) {
        if state.channel != ch.number, state.channel != 0 { state.previousChannel = state.channel }
        state.channel = ch.number
        state.freqA = ch.rxHz
        state.freqB = ch.txHz
        state.onB = false
        state.split = ch.txHz != ch.rxHz
        state.toneHz = ch.toneHz
        state.mode = ch.mode
    }

    /** "145.610/107.2/145.610": transmit MHz / tone (OFF for none) / receive MHz. */
    private func mfText() -> String {
        let tone = state.toneHz > 0 ? String(format: "%.1f", state.toneHz) : "OFF"
        return "\(Self.mhz(state.txFrequency))/\(tone)/\(Self.mhz(state.frequency))"
    }

    /** 145610000 → "145.610"; 14074000 → "14.074"; 146520500 → "146.5205". */
    static func mhz(_ hz: Int) -> String {
        var s = String(format: "%.6f", Double(hz) / 1_000_000)
        while s.hasSuffix("0"), let dot = s.firstIndex(of: "."), s.distance(from: dot, to: s.endIndex) > 4 { s.removeLast() }
        return s
    }

    /** "145.610" (MHz) or "145610000" (Hz) → Hz. */
    static func parseHz(_ text: String) -> Int? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        let hz = v < 100_000 ? v * 1_000_000 : v
        return hz >= 100_000 && hz <= 10_000_000_000 ? Int(hz.rounded()) : nil
    }

    static func isCallsign(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 12 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "/") }
    }

    /** This device's Wi-Fi/hotspot addresses, for telling other devices where to connect. */
    static func localAddresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap"),
                  let addr = p.pointee.ifa_addr, (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text.hasPrefix("fe80") || text.hasPrefix("169.254") { continue } // link-local
            out.append(text)
        }
        return out.sorted { !$0.contains(":") && $1.contains(":") }
    }

    // Kenwood TS-480 (the subset Hamlib's TS-480 backend, WSJT-X and loggers use).
    private func kenwood(_ c: String) -> String {
        let cmd = String(c.prefix(2)).uppercased()
        let arg = String(c.dropFirst(2))
        func freq(_ f: Int) -> String { String(format: "%011ld", f) }
        switch cmd {
        case "ID": return "ID020;"
        case "FA":
            if let f = Int(arg), f > 0 { state.freqA = f; return "" }
            return "FA\(freq(state.freqA));"
        case "FB":
            if let f = Int(arg), f > 0 { state.freqB = f; return "" }
            return "FB\(freq(state.freqB));"
        case "FR":
            if let v = Int(arg) { state.onB = v == 1; return "" }
            return "FR\(state.onB ? 1 : 0);"
        case "FT":
            if let v = Int(arg) { state.split = (v == 1) != state.onB; return "" }
            return "FT\((state.split != state.onB) ? 1 : 0);"
        case "MD":
            if let n = Int(arg) { if let m = RigMode.fromKenwood(n) { state.mode = m }; return "" }
            return "MD\(state.mode.kenwood);"
        case "TX": state.ptt = true; return ""
        case "RX": state.ptt = false; return ""
        case "IF":
            // P1 freq(11) P2 step(5) P3 RIT(5) P4 RIT P5 XIT P6 0 P7 mem(2) P8 TX P9 mode
            // P10 VFO P11 scan P12 split P13 tone P14 tone no.(2) P15 0  → 35 characters.
            return "IF\(freq(state.frequency))     +000000000\(state.ptt ? 1 : 0)\(state.mode.kenwood)\(state.onB ? 1 : 0)0\(state.split ? 1 : 0)\(state.toneHz > 0 ? 1 : 0)000;"
        case "AI": return arg.isEmpty ? "AI0;" : ""
        case "PS": return arg.isEmpty ? "PS1;" : ""
        case "KS": return arg.isEmpty ? "KS020;" : ""
        case "SM": return "SM00000;"
        case "PC": return arg.isEmpty ? "PC050;" : ""
        case "FW": return arg.isEmpty ? "FW0000;" : ""
        case "RT", "XT", "RC", "NB", "NR", "BC", "PA", "RA", "LK", "VX", "GT", "AN", "SQ", "AG", "RG", "MG", "SH", "SL":
            // Accepted and ignored when set; read as "off"/0 in the radio's own format.
            if !arg.isEmpty { return "" }
            switch cmd {
            case "AG", "RG", "MG", "SQ": return "\(cmd)000;"
            case "SH", "SL": return "\(cmd)00;"
            case "PA", "RA": return "\(cmd)00;"
            case "GT": return "GT000;"
            case "AN": return "AN1;"
            default: return "\(cmd)0;"
            }
        default: return "?;"
        }
    }

    // Hamlib rigctld network protocol (what "Hamlib NET rigctl", model 2, speaks).
    private static let longNames: [String: String] = [
        "get_freq": "f", "set_freq": "F", "get_mode": "m", "set_mode": "M", "get_vfo": "v", "set_vfo": "V",
        "get_ptt": "t", "set_ptt": "T", "get_split_vfo": "s", "set_split_vfo": "S", "get_split_freq": "i",
        "set_split_freq": "I", "get_split_mode": "x", "set_split_mode": "X", "get_level": "l", "set_level": "L",
        "get_func": "u", "set_func": "U", "get_rit": "j", "set_rit": "J", "get_xit": "z", "set_xit": "Z",
        "get_info": "_", "get_ctcss_tone": "c", "set_ctcss_tone": "C", "get_powerstat": "get_powerstat", "set_powerstat": "set_powerstat",
        "dump_state": "dump_state", "chk_vfo": "chk_vfo", "get_lock_mode": "get_lock_mode",
        "set_lock_mode": "set_lock_mode", "quit": "q",
    ]
    private static let keyNames: [String: (long: String, keys: [String])] = [
        "f": ("get_freq", ["Frequency"]), "m": ("get_mode", ["Mode", "Passband"]), "v": ("get_vfo", ["VFO"]),
        "t": ("get_ptt", ["PTT"]), "s": ("get_split_vfo", ["Split", "TX VFO"]), "i": ("get_split_freq", ["TX Frequency"]),
        "x": ("get_split_mode", ["TX Mode", "TX Passband"]),
    ]

    private func hamlib(_ line: String, extended: Bool) -> String {
        var parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard var name = parts.first else { return "" }
        parts.removeFirst()
        if name.hasPrefix("\\") { name = Self.longNames[String(name.dropFirst())] ?? String(name.dropFirst()) }
        let ok = "RPRT 0\n", unsupported = "RPRT -11\n", invalid = "RPRT -1\n"
        func vfoName(_ b: Bool) -> String { b ? "VFOB" : "VFOA" }
        var values: [String]? = nil          // a get: the value lines
        var result = ok                       // a set: the report
        switch name {
        case "f": values = ["\(state.frequency)"]
        case "F":
            guard let s = parts.last, let f = Double(s), f > 0 else { return invalid }
            if state.onB { state.freqB = Int(f.rounded()) } else { state.freqA = Int(f.rounded()) }
        case "m": values = [state.mode.rawValue, "\(state.passband)"]
        case "M":
            guard let m = parts.first.flatMap({ RigMode(rawValue: $0.uppercased()) }) else { return invalid }
            state.mode = m
            if parts.count > 1, let pb = Int(parts[1]), pb >= 0 { state.passband = pb }
        case "v": values = [vfoName(state.onB)]
        case "V":
            guard let v = parts.first?.uppercased() else { return invalid }
            if v == "VFOA" || v == "MAIN" { state.onB = false } else if v == "VFOB" || v == "SUB" { state.onB = true }
        case "t": values = [state.ptt ? "1" : "0"]
        case "T":
            guard let p = parts.first.flatMap({ Int($0) }) else { return invalid }
            state.ptt = p != 0
        case "s": values = [state.split ? "1" : "0", vfoName(!state.onB)]
        case "S":
            guard let s = parts.first.flatMap({ Int($0) }) else { return invalid }
            state.split = s != 0
        case "i": values = ["\(state.onB ? state.freqA : state.freqB)"]
        case "I":
            guard let s = parts.last, let f = Double(s), f > 0 else { return invalid }
            if state.onB { state.freqA = Int(f.rounded()) } else { state.freqB = Int(f.rounded()) }
        case "x": values = [state.mode.rawValue, "\(state.passband)"]
        case "X", "L", "U", "J", "Z", "set_powerstat", "set_lock_mode": break
        case "c": values = ["\(Int((state.toneHz * 10).rounded()))"]
        case "C":
            guard let t = parts.first.flatMap({ Double($0) }) else { return invalid }
            state.toneHz = t >= 600 ? t / 10 : 0
        case "l", "u", "j", "z", "get_lock_mode": values = ["0"]
        case "get_powerstat": values = ["1"]
        case "_": values = ["APRSERJi virtual radio"]
        case "chk_vfo": return extended ? "ChkVFO: 0\nRPRT 0\n" : "0\n"
        case "dump_state": return Self.dumpState
        case "q", "Q": return ""
        default: result = unsupported
        }
        if extended {
            let info = Self.keyNames[name]
            let long = info?.long ?? Self.longNames.first(where: { $0.value == name })?.key ?? name
            var out = "\(long):"
            if values == nil, !parts.isEmpty { out += " " + parts.joined(separator: " ") }
            out += "\n"
            for (i, v) in (values ?? []).enumerated() {
                let key = info.map { i < $0.keys.count ? $0.keys[i] : "Value" } ?? "Value"
                out += "\(key): \(v)\n"
            }
            return out + (values == nil ? result : ok)
        }
        if let values { return values.map { $0 + "\n" }.joined() }
        return result
    }

    /** Hamlib's dump_state, protocol 0: what netrigctl reads when a program opens model 2 (NET rigctl). */
    private static let dumpState = [
        "0", "2", "2",
        "100000.000000 1300000000.000000 0xef -1 -1 0x3 0x3",       // receive range, all modes
        "0 0 0 0 0 0 0",
        "1800000.000000 450000000.000000 0xef 5000 100000 0x3 0x3", // transmit range
        "0 0 0 0 0 0 0",
        "0xef 1", "0xef 0", "0 0",                                  // tuning steps
        "0x82 500", "0x82 200", "0x82 2000", "0x221 2400", "0x221 1800", "0x221 3000",
        "0x0c 2400", "0x40 12000", "0x10 6000", "0 0",              // filters
        "0", "0", "0", "0",                                         // max RIT, XIT, IF shift, announces
        "0 ", "0 ",                                                 // preamp, attenuator
        "0x0", "0x0", "0x0", "0x0", "0x0", "0x0",                   // get/set func, level, parm
    ].map { $0 + "\n" }.joined()
}

// MARK: - Splitting bytes into commands

enum CatCommand {
    case kenwood(String)               // without the ';'
    case hamlib(String, extended: Bool) // one line, without the prefix
    case `extension`(String, newline: Bool) // APRSERJi's own MP/MC/MF/MT/MZ/MB, ended by ';' or a newline
}

/** What an APRSERJi command asks the app (rather than the radio) to do; posted on the main thread. */
enum RemoteAction {
    case zoom(Int)
    case zoomTo(String)
    case track(String?)
    case beaconNow
}

extension Notification.Name {
    /** Posted (object: RemoteAction) when a CAT program sends an MP, MT, MZ or MB command. */
    static let aprserjiRemote = Notification.Name("APRSERJiRemoteAction")
}

/**
 Splits a byte stream into commands, deciding the dialect for each one: two
 capital letters start a Kenwood command ("FA;", "IF;", "MD2;") ending at ';';
 anything else is a rigctld line ("f", "F 14074000", "\get_freq", "+f")
 ending at a newline.
 */
final class CatParser {
    private var buffer = [UInt8]()

    func feed(_ data: Data, handler: (CatCommand) -> Data, quit: inout Bool) -> Data {
        buffer.append(contentsOf: data)
        if buffer.count > 65536 { buffer.removeAll() }
        var out = Data()
        while true {
            while let b = buffer.first, b == 0x0D || b == 0x0A || b == 0x20 || b == 0x09 || b == 0x3B { buffer.removeFirst() }
            guard !buffer.isEmpty else { break }
            let upper: (UInt8) -> Bool = { $0 >= 0x41 && $0 <= 0x5A }
            if buffer.count >= 2 && upper(buffer[0]) && upper(buffer[1]) {
                let semicolon = buffer.firstIndex(of: 0x3B), newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D })
                let code = String(decoding: buffer[0..<2], as: UTF8.self)
                let isOwn = VirtualRig.extensionCodes.contains(code)
                if let nl = newline, semicolon == nil || nl < semicolon! {
                    // A line ending without ';': APRSERJi's own commands may end either way; a rigctld
                    // line can't start with two capitals, so anything else is dropped.
                    let text = String(decoding: buffer[0..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    buffer.removeSubrange(0...nl)
                    if isOwn { out.append(handler(.extension(text, newline: true))) }
                    continue
                }
                guard let end = semicolon else { break }
                let text = String(decoding: buffer[0..<end], as: UTF8.self)
                buffer.removeSubrange(0...end)
                out.append(handler(isOwn ? .extension(text, newline: false) : .kenwood(text)))
            } else if buffer.count == 1 && upper(buffer[0]) {
                break                              // wait: Kenwood or "F …"
            } else {
                guard let end = buffer.firstIndex(of: 0x0A) else { break }
                var text = String(decoding: buffer[0..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(0...end)
                var extended = false
                if let first = text.first, "+;|,".contains(first) { extended = true; text.removeFirst() }
                if text == "q" || text == "Q" || text == "\\quit" { quit = true; break }
                if text.isEmpty { continue }
                out.append(handler(.hamlib(text, extended: extended)))
            }
        }
        return out
    }
}

// MARK: - The serial device

#if os(macOS)
/** A pseudo-terminal linked at a fixed path (default ~/cu.APRSERJi), for programs that can only open a serial port. */
final class CatPty {
    private let link: String
    private let queue: DispatchQueue
    private let handler: (CatCommand) -> Data
    private var master: Int32 = -1
    private var slave: Int32 = -1
    private var device = ""
    private var source: DispatchSourceRead?
    private let parser = CatParser()

    init(linkPath: String, queue: DispatchQueue, handler: @escaping (CatCommand) -> Data) {
        link = (linkPath as NSString).expandingTildeInPath
        self.queue = queue
        self.handler = handler
    }

    var displayPath: String { device.isEmpty ? link : "\((link as NSString).abbreviatingWithTildeInPath) → \(device)" }

    struct Failure: Error, CustomStringConvertible { let description: String }

    func open() throws {
        var m: Int32 = -1, s: Int32 = -1
        guard openpty(&m, &s, nil, nil, nil) == 0 else { throw Failure(description: "openpty: \(String(cString: strerror(errno)))") }
        master = m; slave = s
        var t = termios()
        tcgetattr(slave, &t)
        cfmakeraw(&t)                                   // raw 8-bit, no echo
        tcsetattr(slave, TCSANOW, &t)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        device = String(cString: ttyname(slave))
        // Keep our own handle on the slave open so the device stays while programs come and go.
        let tmp = "\(link).\(getpid()).tmp"
        unlink(tmp)
        guard symlink(device, tmp) == 0, rename(tmp, link) == 0 else {
            let e = String(cString: strerror(errno))
            unlink(tmp)
            throw Failure(description: "cannot link \(link): \(e)")
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        source = src
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(master, &buf, buf.count)
        guard n > 0 else {
            if n < 0 && errno == EIO { usleep(50_000) }  // no program has it open
            return
        }
        var quit = false
        let reply = parser.feed(Data(buf[0..<n]), handler: handler, quit: &quit)
        if !reply.isEmpty {
            reply.withUnsafeBytes { raw in
                guard var p = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let w = Darwin.write(master, p, left)
                    if w <= 0 { return }
                    p += w; left -= w
                }
            }
        }
    }

    func close() {
        source?.cancel()
        source = nil
        var target = [CChar](repeating: 0, count: 1024)
        if readlink(link, &target, 1023) > 0 && String(cString: target) == device { unlink(link) }
        if slave >= 0 { Darwin.close(slave); slave = -1 }
        if master >= 0 { Darwin.close(master); master = -1 }
    }
}
#endif

// MARK: - Setup

struct CatRigSection: View {
    @ObservedObject private var rig = VirtualRig.shared
    @AppStorage("catEnabled") private var enabled = false
    @AppStorage("catPort") private var port = 4532
    @AppStorage("catPty") private var pty = true
    @AppStorage("catPtyPath") private var ptyPath = "~/cu.APRSERJi"
    @AppStorage("catFreqInBeacon") private var inBeacon = false
    @State private var typed = ""

    var body: some View {
        Section {
            Toggle("Virtual radio for CAT programs", isOn: $enabled)
                .onChange(of: enabled) { _, _ in rig.apply() }
            if enabled {
                #if os(macOS)
                TextField("TCP port (IPv6 [::1] and 127.0.0.1)", value: $port, format: .number.grouping(.never))
                    .onSubmit { rig.apply() }
                Toggle("Also a serial device", isOn: $pty)
                    .onChange(of: pty) { _, _ in rig.apply() }
                if pty {
                    TextField("Device path", text: $ptyPath).onSubmit { rig.apply() }
                }
                #else
                TextField("TCP port (local network)", value: $port, format: .number.grouping(.never))
                    .onSubmit { rig.apply() }
                #endif
                Text(rig.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                LabeledContent("Programs connected", value: "\(rig.clients)")
                LabeledContent("Frequency") {
                    HStack {
                        TextField("MHz", text: $typed)
                            .frame(width: 120)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                if let mhz = Double(typed.replacingOccurrences(of: ",", with: ".")), mhz > 0 {
                                    rig.setFromUI(frequencyHz: Int((mhz * 1_000_000).rounded()))
                                }
                            }
                        Text("MHz")
                    }
                }
                Picker("Mode", selection: Binding(get: { rig.shown.mode }, set: { rig.setFromUI(mode: $0) })) {
                    ForEach(RigMode.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("VFO", value: (rig.shown.onB ? "B" : "A") + (rig.shown.split ? " · split, transmit \(VirtualRig.mhz(rig.shown.txFrequency)) MHz" : ""))
                LabeledContent("Tone", value: rig.shown.toneHz > 0 ? String(format: "%.1f Hz", rig.shown.toneHz) : "none")
                if rig.shown.channel > 0 {
                    LabeledContent("Channel", value: String(format: "%04ld", rig.shown.channel)
                        + (ChannelStore.shared.snapshot().first { $0.number == rig.shown.channel }.map { $0.name.isEmpty ? "" : " · " + $0.name } ?? ""))
                }
                if !rig.shown.tracking.isEmpty { LabeledContent("Tracking on the map", value: rig.shown.tracking) }
                LabeledContent("PTT", value: rig.shown.ptt ? "ON (nothing is transmitted)" : "off")
                if !rig.lastCommand.isEmpty {
                    LabeledContent("Last command", value: rig.lastCommand).font(.system(.caption, design: .monospaced))
                }
                Toggle("Put the frequency in my beacon comment", isOn: $inBeacon)
            }
        } header: {
            Text("Virtual radio (CAT)")
        } footer: {
            Text(Self.footer(port: port))
        }
        .onAppear { typed = String(format: "%.6f", Double(rig.shown.frequency) / 1_000_000) }
        .onChange(of: rig.shown.frequency) { _, f in typed = String(format: "%.6f", Double(f) / 1_000_000) }
        ChannelsSection()
    }

    private static let ownCommands = " APRSERJi's own commands: MP=01 / MP=-01 zoom the map in / out, MC=0012 tunes channel 12 (MC=X+1, MC=X-1 step, MC=-1 goes back), MF=145.610/107.2/145.610 sets transmit MHz / tone / receive MHz, MT=KC9XYZ-1 tracks a station on the map (MT=OFF stops), MZ=KC9XYZ-1 zooms to it, MB beacons now, MB=60S every 60 seconds, MB=SMART for SmartBeaconing. End each with ; or a new line."

    private static func footer(port: Int) -> String {
        #if os(macOS)
        return "Lets other programs on this Mac send CAT commands to APRSERJi as if it were a radio. In WSJT-X, a logger or a satellite tracker choose Rig “Hamlib NET rigctl” with server [::1]:\(String(port)) (or localhost:\(String(port))), or a Kenwood TS-480 on the serial device. APRSERJi answers Kenwood (FA; MD; IF; TX; …) and Hamlib rigctld (f, F, m, M, t, T …) commands, keeps the frequency, mode, VFO and PTT they set, and can begin its beacon comment with the frequency (e.g. 146.520MHz). Nothing is transmitted because of a CAT command." + ownCommands
        #else
        return "Lets programs on other devices on this Wi-Fi network or hotspot send CAT commands to APRSERJi as if it were a radio, at the address shown above. It works while APRSERJi is open (the screen stays on while it is). APRSERJi answers Kenwood (FA; MD; IF; …) and Hamlib rigctld (f, F, m, M …) commands and keeps the frequency, mode and tone they set. Nothing is transmitted because of a CAT command." + ownCommands
        #endif
    }
}
