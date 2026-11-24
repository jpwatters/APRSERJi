import AprsCore
import SwiftUI

/** How a radio port's bytes travel. Serial and Bluetooth are Mac-only. */
enum PortTransport: String, Codable, CaseIterable, Identifiable {
    case tcp = "Network (TCP)"
    case serial = "Serial / USB"
    case spp = "Bluetooth Classic (SPP)"
    case ble = "Bluetooth LE"
    var id: String { rawValue }

    static var available: [PortTransport] {
        #if os(macOS)
        return allCases
        #else
        return [.tcp]
        #endif
    }
}

/** TNC profiles: how bytes are framed, and commands that put the TNC in that mode. */
enum TncProfile: String, Codable, CaseIterable, Identifiable {
    case kiss = "KISS"
    case simplyKiss = "Simply KISS (already in KISS)"
    case kenwood = "Kenwood (switch to KISS)"
    case agw = "AGWPE"
    case tnc2 = "TEXT / TNC2 monitor"
    var id: String { rawValue }
    var framing: String {
        switch self {
        case .agw: return "AGW"
        case .tnc2: return "TNC2"
        default: return "KISS"
        }
    }
    /** Commands sent when a serial or Bluetooth link opens ("\r" separates lines). */
    var initCommands: String {
        switch self {
        case .kenwood: return "\r\rKISS ON\rRESTART\r"
        case .tnc2: return "\r\rECHO OFF\rMONITOR ON\rHEADERLN OFF\r"
        default: return ""
        }
    }
}

/** One radio port as saved in settings. */
struct PortSetting: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "Radio"
    var transport: PortTransport = .tcp
    var enabled = true
    var host = "127.0.0.1"
    var port = 8001
    /** Serial device path, Bluetooth address, or Bluetooth LE peripheral identifier. */
    var device = ""
    var baud = 9600
    var profile: TncProfile = .kiss
    var channel = 0
    var transmit = true
    var beacons = true
    var digipeat = false
    var transforms = "WIDE1-1="
    var igateToInternet = false
    var igateToRadio = false
    var path = "WIDE1-1,WIDE2-1"
    var crossPorts = ""
    var initCommands = ""

    var isExternal: Bool { transport != .tcp }

    init() {}

    /** Missing keys keep their defaults, so ports saved by earlier versions still load. */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PortSetting()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        transport = try c.decodeIfPresent(PortTransport.self, forKey: .transport) ?? d.transport
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? d.device
        baud = try c.decodeIfPresent(Int.self, forKey: .baud) ?? d.baud
        profile = try c.decodeIfPresent(TncProfile.self, forKey: .profile) ?? d.profile
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? d.channel
        transmit = try c.decodeIfPresent(Bool.self, forKey: .transmit) ?? d.transmit
        beacons = try c.decodeIfPresent(Bool.self, forKey: .beacons) ?? d.beacons
        digipeat = try c.decodeIfPresent(Bool.self, forKey: .digipeat) ?? d.digipeat
        transforms = try c.decodeIfPresent(String.self, forKey: .transforms) ?? d.transforms
        igateToInternet = try c.decodeIfPresent(Bool.self, forKey: .igateToInternet) ?? d.igateToInternet
        igateToRadio = try c.decodeIfPresent(Bool.self, forKey: .igateToRadio) ?? d.igateToRadio
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? d.path
        crossPorts = try c.decodeIfPresent(String.self, forKey: .crossPorts) ?? d.crossPorts
        initCommands = try c.decodeIfPresent(String.self, forKey: .initCommands) ?? d.initCommands
    }

    func config() -> PortConfig {
        PortConfig(id: id, name: name, kind: isExternal ? "EXTERNAL" : "TCP", host: host, port: Int32(port),
                   framing: profile.framing, channel: Int32(channel), transmit: transmit, beacons: beacons,
                   digipeat: digipeat, igateToInternet: igateToInternet, igateToRadio: igateToRadio, path: path,
                   transforms: transforms, crossPorts: crossPorts)
    }

    /** The ISS / ARISS preset: digipeated through the space station, no local digipeating or gating to RF. */
    static func issPreset() -> PortSetting {
        var p = PortSetting()
        p.name = "ISS (437.825 MHz)"
        p.path = "ARISS"
        p.digipeat = false
        p.igateToRadio = false
        p.beacons = false
        return p
    }
}

/** Saved radio ports, and pushing them to the engine. */
enum PortStore {
    static let key = "radioPorts"

    static func load(_ d: UserDefaults = .standard) -> [PortSetting] {
        if let data = d.data(forKey: key), let ports = try? JSONDecoder().decode([PortSetting].self, from: data) { return ports }
        // First run with ports: carry over the single software-modem setting from earlier versions.
        guard d.object(forKey: "tncHost") != nil || d.bool(forKey: "tncEnabled") else { return [] }
        var p = PortSetting()
        p.name = "Software modem"
        p.enabled = d.bool(forKey: "tncEnabled")
        p.host = d.string(forKey: "tncHost") ?? "127.0.0.1"
        p.port = d.object(forKey: "tncPort") as? Int ?? 8001
        p.profile = d.string(forKey: "tncProtocol") == "AGWPE" ? .agw : .kiss
        p.channel = d.object(forKey: "tncChannel") as? Int ?? 0
        p.igateToInternet = d.bool(forKey: "tncIgate")
        p.beacons = d.bool(forKey: "beaconViaRadio")
        p.path = d.string(forKey: "beaconRadioPath") ?? "WIDE1-1,WIDE2-1"
        save([p], d)
        return [p]
    }

    static func save(_ ports: [PortSetting], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(ports) { d.set(data, forKey: key) }
        applied = nil
    }

    private static var applied: String?
    private static var igateApplied: String?

    /** Starts, restarts or stops ports to match the saved settings. Called once a second. */
    @MainActor static func apply(core: AppleAprs, defaults d: UserDefaults = .standard) {
        let ports = load(d).filter { $0.enabled && PortTransport.available.contains($0.transport) }
        let signature = (try? String(data: JSONEncoder().encode(ports), encoding: .utf8)) ?? ""
        if signature != applied {
            _ = core.configurePorts(ports: ports.map { $0.config() })
            applied = signature
            #if os(macOS)
            ExternalPorts.shared.update(ports.filter(\.isExternal), core: core)
            #endif
        }
        let igate = [d.string(forKey: "igatePassCalls") ?? "", d.string(forKey: "igatePassObjects") ?? "",
                     d.string(forKey: "igateFilter") ?? ""]
        let igateSignature = igate.joined(separator: "|")
        if igateSignature != igateApplied {
            if core.configureIgate(passCallsigns: igate[0], passObjectNames: igate[1], filter: igate[2]) {
                igateApplied = igateSignature
            }
        }
    }
}

/**
 * Setup ▸ Radio. On iPhone and iPad: one network software modem or TNC (Dire Wolf, UZ7HO, AGWPE, a KISS TNC on the
 * network). On the Mac: a workspace of named ports — network, serial/USB, Bluetooth Classic and Bluetooth LE.
 */
struct PortsSection: View {
    let core: AppleAprs
    @State private var ports: [PortSetting] = PortStore.load()
    @State private var editing: PortSetting?
    @AppStorage("igatePassCalls") private var passCalls = ""
    @AppStorage("igatePassObjects") private var passObjects = ""
    @AppStorage("igateFilter") private var gateFilter = ""
    @AppStorage("callsign") private var callsign = ""
    @StateObject private var discovery = TncDiscovery()

    var body: some View {
        Section {
            #if os(macOS)
            ForEach(ports) { port in portRow(port) }
            Menu("Add port") {
                ForEach(PortTransport.available) { transport in
                    Button(transport.rawValue) {
                        var p = PortSetting()
                        p.transport = transport
                        p.name = transport == .tcp ? "Network TNC" : transport.rawValue
                        if transport != .tcp { p.port = 0 }
                        editing = p
                    }
                }
                Divider()
                Button("ISS / ARISS preset") { editing = PortSetting.issPreset() }
            }
            #else
            if let first = ports.first(where: { $0.transport == .tcp }) {
                portRow(first)
            } else {
                Button("Set up a software modem or network TNC") {
                    var p = PortSetting()
                    p.name = "Software modem"
                    editing = p
                }
            }
            #endif
            if !discovery.found.isEmpty {
                ForEach(discovery.found, id: \.self) { service in
                    Button("Add \(service.name) (found on the network)") {
                        var p = PortSetting()
                        p.name = service.name
                        p.host = service.host
                        p.port = service.port
                        editing = p
                    }
                }
            }
            Button(discovery.searching ? "Searching the network…" : "Find network KISS TNCs") { discovery.search() }
                .disabled(discovery.searching)
        } header: {
            Text("Radio ports")
        } footer: {
            Text("Dire Wolf listens for KISS on port 8001 and AGWPE on 8000; UZ7HO Sound Modem uses 8100 for KISS and 8000 for AGWPE. Transmitting on RF, digipeating and gating require a licensed operator; RF uses your callsign \(callsign.isEmpty ? "(enter it on the Map page)" : callsign).")
        }
        .sheet(item: $editing) { port in
            PortEditor(port: port, otherPorts: ports.filter { $0.id != port.id }, onSave: { saved in
                if let index = ports.firstIndex(where: { $0.id == saved.id }) { ports[index] = saved } else { ports.append(saved) }
                PortStore.save(ports)
                PortStore.apply(core: core)
                editing = nil
            }, onDelete: {
                ports.removeAll { $0.id == port.id }
                PortStore.save(ports)
                PortStore.apply(core: core)
                editing = nil
            }, onCancel: { editing = nil })
        }

        Section {
            TextField("Always gate these callsigns to RF (comma separated)", text: $passCalls)
            TextField("Always gate these objects to RF", text: $passObjects)
            TextField("Gate filter, e.g. r/41.5/-88.1/50 -t/w", text: $gateFilter)
            if !gateFilter.isEmpty && !core.configureIgate(passCallsigns: passCalls, passObjectNames: passObjects, filter: gateFilter) {
                Text("The gate filter isn't a valid javAPRSFilter expression.").font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("IGate")
        } footer: {
            Text("With “Gate APRS-IS to RF” on a port, messages for stations heard on that port are always gated. These lists and the filter (r/ a/ b/ p/ o/ d/ e/ g/ u/ t/ s/ q/ m/ f/ terms, - to exclude, + to require) add more. PASSALL, NOGATE, RFONLY and duplicate rules always apply.")
        }
    }

    private func portRow(_ port: PortSetting) -> some View {
        let status = core.portStatuses.first { $0.id == port.id }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(port.name).font(.headline)
                    Text(port.transport.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Text(port.transport == .tcp ? "\(port.host):\(port.port) · \(port.profile.rawValue)" : "\(port.device.isEmpty ? "No device chosen" : port.device) · \(port.profile.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                if let status {
                    Text(Self.stateText(status) + " · \(status.received) heard · \(status.transmitted) sent" +
                         (port.digipeat ? " · \(status.digipeated) digipeated" : "") +
                         (port.igateToInternet ? " · \(status.gated) gated" : ""))
                        .font(.caption).foregroundStyle(status.state == "CONNECTED" ? Color.green : Color.orange)
                    if let diag = status.diagnostics.last { Text(diag).font(.caption2).foregroundStyle(.secondary) }
                } else {
                    Text(port.enabled ? "Starting…" : "Off").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("On", isOn: Binding(get: { port.enabled }, set: { on in
                if let index = ports.firstIndex(where: { $0.id == port.id }) {
                    ports[index].enabled = on
                    PortStore.save(ports)
                    PortStore.apply(core: core)
                }
            })).labelsHidden()
            Button("Edit") { editing = port }
        }
    }

    static func stateText(_ s: PortStatus) -> String {
        switch s.state {
        case "CONNECTED": return "Connected"
        case "CONNECTING": return "Connecting…"
        case "RECONNECTING": return "Retrying" + (s.error.map { " — \($0)" } ?? "")
        default: return "Off"
        }
    }
}

/** Edits one port. */
private struct PortEditor: View {
    @State var port: PortSetting
    let otherPorts: [PortSetting]
    let onSave: (PortSetting) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Port") {
                    TextField("Name", text: $port.name)
                    Picker("Connection", selection: $port.transport) {
                        ForEach(PortTransport.available) { Text($0.rawValue).tag($0) }
                    }
                    Picker("TNC", selection: $port.profile) {
                        ForEach(TncProfile.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: port.profile) { old, new in
                        if port.initCommands == old.initCommands { port.initCommands = new.initCommands }
                        if port.transport == .tcp && (port.port == 8001 || port.port == 8000) {
                            port.port = new == .agw ? 8000 : 8001
                        }
                    }
                    switch port.transport {
                    case .tcp:
                        TextField("Host", text: $port.host)
                        TextField("TCP port", value: $port.port, format: .number.grouping(.never))
                    case .serial:
                        #if os(macOS)
                        Picker("Device", selection: $port.device) {
                            Text("Choose…").tag("")
                            ForEach(SerialPort.devices(), id: \.self) { Text($0).tag($0) }
                        }
                        #endif
                        Picker("Speed", selection: $port.baud) {
                            ForEach([1200, 4800, 9600, 19200, 38400, 57600, 115200], id: \.self) { Text("\($0) baud").tag($0) }
                        }
                    case .spp:
                        #if os(macOS)
                        Picker("Paired device", selection: $port.device) {
                            Text("Choose…").tag("")
                            ForEach(SppLink.pairedDevices(), id: \.address) { Text("\($0.name) (\($0.address))").tag($0.address) }
                        }
                        #endif
                    case .ble:
                        #if os(macOS)
                        BlePicker(selection: $port.device)
                        #endif
                    }
                    if port.profile != .tnc2 {
                        Stepper("\(port.profile == .agw ? "AGW port" : "KISS channel") \(port.channel)", value: $port.channel, in: 0...15)
                    }
                    if port.isExternal {
                        TextField("Commands sent on connect (\\r between lines)", text: Binding(
                            get: { port.initCommands.replacingOccurrences(of: "\r", with: "\\r") },
                            set: { port.initCommands = $0.replacingOccurrences(of: "\\r", with: "\r") }))
                    }
                }
                Section {
                    Toggle("Transmit on this port", isOn: $port.transmit)
                    Toggle("Send my beacons, objects and bulletins here", isOn: $port.beacons).disabled(!port.transmit)
                    TextField("Path for my packets", text: $port.path)
                } header: {
                    Text("Transmit")
                } footer: {
                    Text("Turn Transmit off for a receive-only port (a scanner, or listening to a busy channel). Typical paths: WIDE1-1,WIDE2-1 mobile, WIDE2-1 fixed, ARISS for the space station.")
                }
                Section {
                    Toggle("Digipeat", isOn: $port.digipeat).disabled(!port.transmit)
                    if port.digipeat {
                        TextField("Transforms", text: $port.transforms)
                        if !otherPorts.isEmpty {
                            ForEach(otherPorts) { other in
                                Toggle("Also repeat onto \(other.name)", isOn: Binding(
                                    get: { port.crossPorts.split(separator: ",").map(String.init).contains(other.id) },
                                    set: { on in
                                        var ids = port.crossPorts.split(separator: ",").map(String.init).filter { $0 != other.id }
                                        if on { ids.append(other.id) }
                                        port.crossPorts = ids.joined(separator: ",")
                                    }))
                            }
                        }
                    }
                } header: {
                    Text("Digipeater")
                } footer: {
                    Text("Transforms are ALIAS=REPLACEMENT. WIDE1-1= is a fill-in digipeater; add WIDE2-2=WIDE2-1,WIDE2-1= for a wide-area digipeater. Your own callsign is always repeated.")
                }
                Section {
                    Toggle("Gate RF to APRS-IS", isOn: $port.igateToInternet)
                    Toggle("Gate APRS-IS to RF (messages and filtered packets)", isOn: $port.igateToRadio).disabled(!port.transmit)
                } header: {
                    Text("IGate")
                } footer: {
                    Text("Gating to APRS-IS needs a verified login (Enable sending + passcode).")
                }
                if otherPorts.count + 1 > 0 {
                    Section {
                        Button("Delete port", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(port.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(port) }.disabled(port.name.isEmpty) }
            }
            .confirmationDialog("Delete \(port.name)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}
