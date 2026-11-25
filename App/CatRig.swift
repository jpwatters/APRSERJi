#if os(macOS)
import Darwin
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
        var frequency: Int { onB ? freqB : freqA }
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
    private var pty: CatPty?
    private var config: Config?

    struct Config: Equatable {
        var enabled: Bool
        var port: Int
        var pty: Bool
        var ptyPath: String
    }

    private init() {
        let d = UserDefaults.standard
        if let f = d.object(forKey: "catFrequencyA") as? Int, f > 0 { state.freqA = f }
        if let f = d.object(forKey: "catFrequencyB") as? Int, f > 0 { state.freqB = f }
        if let m = RigMode(rawValue: d.string(forKey: "catMode") ?? "") { state.mode = m }
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
        for (host, label) in [(NWEndpoint.Host.ipv6(.loopback), "[::1]"), (NWEndpoint.Host.ipv4(.loopback), "127.0.0.1")] {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: host, port: port)
            do {
                let l = try NWListener(using: params)
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
        if !problems.isEmpty { text += " · " + problems.joined(separator: "; ") }
        publishStatus(text)
    }

    private func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        pty?.close()
        pty = nil
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
        switch command {
        case .kenwood(let c): reply = kenwood(c)
        case .hamlib(let c, let extended): reply = hamlib(c, extended: extended)
        }
        let after = state
        lock.unlock()
        if after != before { saved(after) }
        let text: String
        switch command {
        case .kenwood(let c): text = c + ";"
        case .hamlib(let c, _): text = c
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

    private func saved(_ s: State) {
        let d = UserDefaults.standard
        d.set(s.freqA, forKey: "catFrequencyA")
        d.set(s.freqB, forKey: "catFrequencyB")
        d.set(s.mode.rawValue, forKey: "catMode")
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
            return "IF\(freq(state.frequency))     +000000000\(state.ptt ? 1 : 0)\(state.mode.kenwood)\(state.onB ? 1 : 0)0\(state.split ? 1 : 0)0000;"
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
        "get_info": "_", "get_powerstat": "get_powerstat", "set_powerstat": "set_powerstat",
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
                guard let end = buffer.firstIndex(of: 0x3B) else {
                    // A rigctld line can't start with two capitals; still, don't wait forever for a ';'.
                    if let nl = buffer.firstIndex(of: 0x0A) { buffer.removeSubrange(0...nl) ; continue }
                    break
                }
                let text = String(decoding: buffer[0..<end], as: UTF8.self)
                buffer.removeSubrange(0...end)
                out.append(handler(.kenwood(text)))
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
                TextField("TCP port (IPv6 [::1] and 127.0.0.1)", value: $port, format: .number.grouping(.never))
                    .onSubmit { rig.apply() }
                Toggle("Also a serial device", isOn: $pty)
                    .onChange(of: pty) { _, _ in rig.apply() }
                if pty {
                    TextField("Device path", text: $ptyPath).onSubmit { rig.apply() }
                }
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
                LabeledContent("VFO", value: (rig.shown.onB ? "B" : "A") + (rig.shown.split ? " · split" : ""))
                LabeledContent("PTT", value: rig.shown.ptt ? "ON (nothing is transmitted)" : "off")
                if !rig.lastCommand.isEmpty {
                    LabeledContent("Last command", value: rig.lastCommand).font(.system(.caption, design: .monospaced))
                }
                Toggle("Put the frequency in my beacon comment", isOn: $inBeacon)
            }
        } header: {
            Text("Virtual radio (CAT)")
        } footer: {
            Text("Lets other programs on this Mac send CAT commands to APRSERJi as if it were a radio. In WSJT-X, a logger or a satellite tracker choose Rig “Hamlib NET rigctl” with server [::1]:\(String(port)) (or localhost:\(String(port))), or a Kenwood TS-480 on the serial device. APRSERJi answers Kenwood (FA; MD; IF; TX; …) and Hamlib rigctld (f, F, m, M, t, T …) commands, keeps the frequency, mode, VFO and PTT they set, and can begin its beacon comment with the frequency (e.g. 146.520MHz). Nothing is transmitted because of a CAT command.")
        }
        .onAppear { typed = String(format: "%.6f", Double(rig.shown.frequency) / 1_000_000) }
        .onChange(of: rig.shown.frequency) { _, f in typed = String(format: "%.6f", Double(f) / 1_000_000) }
    }
}
#endif
