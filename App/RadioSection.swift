import AprsCore
import SwiftUI

enum ModemProtocol: String, CaseIterable, Identifiable {
    case kiss = "KISS over TCP", agw = "AGWPE"
    var id: String { rawValue }
    var code: String { self == .kiss ? "KISS" : "AGW" }
    var defaultPort: Int { self == .kiss ? 8001 : 8000 }
}

/**
 * Software modems (Dire Wolf, UZ7HO Sound Modem, AGWPE) and network TNCs reached over TCP. Stations heard on the
 * radio join the map and lists; beacons can also go out on RF, and the IGate can pass RF packets to APRS-IS.
 */
struct RadioSection: View {
    let core: AppleAprs
    @AppStorage("tncEnabled") private var enabled = false
    @AppStorage("tncHost") private var host = "127.0.0.1"
    @AppStorage("tncPort") private var port = 8001
    @AppStorage("tncProtocol") private var proto: ModemProtocol = .kiss
    @AppStorage("tncChannel") private var channel = 0
    @AppStorage("tncIgate") private var igate = false
    @AppStorage("callsign") private var callsign = ""

    var body: some View {
        Section {
            Toggle("Connect to software modem", isOn: $enabled)
                .onChange(of: enabled) { _, _ in TncSync.apply(core: core) }
            Picker("Protocol", selection: $proto) {
                ForEach(ModemProtocol.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: proto) { old, new in
                if port == old.defaultPort { port = new.defaultPort }
            }
            TextField("Host", text: $host)
            TextField("Port", value: $port, format: .number.grouping(.never))
            Stepper("\(proto == .kiss ? "KISS channel" : "AGW port") \(channel)", value: $channel, in: 0...15)
            Toggle("IGate: gate RF packets to APRS-IS", isOn: $igate)
                .onChange(of: igate) { _, on in core.setIgate(enabled: on) }
            if enabled {
                Button("Reconnect with these settings") { TncSync.apply(core: core, restart: true) }
                LabeledContent("Status") {
                    Text(stateText).foregroundStyle(core.tncState == "CONNECTED" ? Color.green : Color.orange)
                }
                LabeledContent("Packets", value: "\(core.tncReceived) heard · \(core.tncTransmitted) sent" +
                               (igate ? " · \(core.igatedPackets) gated" : ""))
            }
        } header: {
            Text("Radio")
        } footer: {
            Text("Dire Wolf listens for KISS on port 8001 and AGWPE on 8000; UZ7HO Sound Modem uses 8100 for KISS and 8000 for AGWPE. Use 127.0.0.1 when the modem runs on this Mac, or the modem computer's address from an iPhone or iPad. Transmitting on RF, and gating, require a licensed operator; RF uses your callsign \(callsign.isEmpty ? "(enter it above)" : callsign).")
        }
    }

    private var stateText: String {
        switch core.tncState {
        case "CONNECTED": return "Connected"
        case "CONNECTING": return "Connecting…"
        case "RECONNECTING": return "Retrying" + (core.tncError.map { " — \($0)" } ?? "")
        default: return "Off"
        }
    }
}

/** Starts, restarts or stops the modem link to match the saved settings. */
enum TncSync {
    private static var applied: String?

    static func apply(core: AppleAprs, restart: Bool = false, defaults d: UserDefaults = .standard) {
        guard d.bool(forKey: "tncEnabled") else {
            if applied != nil { core.stopTnc(); applied = nil }
            return
        }
        let proto = ModemProtocol(rawValue: d.string(forKey: "tncProtocol") ?? "") ?? .kiss
        let host = d.string(forKey: "tncHost") ?? "127.0.0.1"
        let port = d.object(forKey: "tncPort") as? Int ?? proto.defaultPort
        let channel = d.object(forKey: "tncChannel") as? Int ?? 0
        let call = normalizedCallsign(d.string(forKey: "callsign") ?? "")
        let igate = d.bool(forKey: "tncIgate")
        let signature = "\(proto.code)|\(host)|\(port)|\(channel)|\(call)"
        guard restart || applied != signature else { return }
        if core.startTnc(host: host, port: Int32(port), modem: proto.code, channel: Int32(channel),
                         callsign: call, igate: igate) {
            applied = signature
        }
    }
}
