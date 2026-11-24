import AprsCore
import CoreLocation
import SwiftUI

/** An object or item this station publishes, as saved in settings. */
struct ObjectSetting: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "OBJECT"
    var item = false
    var latitude = 0.0
    var longitude = 0.0
    var symbol = "/o"
    var comment = ""
    var following = false
    var alive = true
    var enabled = true
    var intervalMinutes = 10
    var toInternet = true
    var toRadio = false
    var group = ""
    var shape: [ShapePoint] = []
    var shapeClosed = false
    var shapeStyle = "j"
    /** Frequency object fields; when a frequency is set it leads the comment in the standard form. */
    var frequency = ""
    var tone = ""
    var offset = ""
    var rangeMiles = ""

    struct ShapePoint: Codable, Equatable { var latitude: Double; var longitude: Double }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ObjectSetting()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        item = try c.decodeIfPresent(Bool.self, forKey: .item) ?? d.item
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? d.latitude
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? d.longitude
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? d.symbol
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? d.comment
        following = try c.decodeIfPresent(Bool.self, forKey: .following) ?? d.following
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive) ?? d.alive
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        toInternet = try c.decodeIfPresent(Bool.self, forKey: .toInternet) ?? d.toInternet
        toRadio = try c.decodeIfPresent(Bool.self, forKey: .toRadio) ?? d.toRadio
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? d.group
        shape = try c.decodeIfPresent([ShapePoint].self, forKey: .shape) ?? d.shape
        shapeClosed = try c.decodeIfPresent(Bool.self, forKey: .shapeClosed) ?? d.shapeClosed
        shapeStyle = try c.decodeIfPresent(String.self, forKey: .shapeStyle) ?? d.shapeStyle
        frequency = try c.decodeIfPresent(String.self, forKey: .frequency) ?? d.frequency
        tone = try c.decodeIfPresent(String.self, forKey: .tone) ?? d.tone
        offset = try c.decodeIfPresent(String.self, forKey: .offset) ?? d.offset
        rangeMiles = try c.decodeIfPresent(String.self, forKey: .rangeMiles) ?? d.rangeMiles
    }

    /** "146.940MHz T107 -060 R25 comment" — the form other APRS software reads. */
    var fullComment: String {
        var parts: [String] = []
        if let mhz = Double(frequency.trimmingCharacters(in: .whitespaces)) {
            parts.append(String(format: "%07.3fMHz", mhz))
            let t = tone.trimmingCharacters(in: .whitespaces)
            if let hz = Double(t) { parts.append(String(format: "T%03d", Int(hz.rounded()))) } else if t.lowercased() == "off" { parts.append("Toff") }
            if let o = Double(offset.trimmingCharacters(in: .whitespaces)) {
                parts.append((o < 0 ? "-" : "+") + String(format: "%03d", Int((abs(o) * 100).rounded())))
            }
            if let r = Int(rangeMiles.trimmingCharacters(in: .whitespaces)), (1...99).contains(r) { parts.append(String(format: "R%02d", r)) }
        }
        if !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " ")
    }

    func entity() -> OwnEntity {
        OwnEntity(id: id, name: name, item: item, latitude: latitude, longitude: longitude,
                  symbolTable: String(symbol.prefix(1)), symbol: String(symbol.dropFirst().prefix(1)), comment: fullComment,
                  following: following, alive: alive, enabled: enabled, intervalSeconds: Int32(intervalMinutes * 60),
                  toInternet: toInternet, toRadio: toRadio, group: group.uppercased(),
                  shape: shape.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ";"),
                  shapeClosed: shapeClosed, shapeStyle: shapeStyle)
    }
}

/** A bulletin sent on a schedule. */
struct BulletinSetting: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var slot = "0"
    var group = ""
    var text = ""
    var intervalMinutes = 30
    var enabled = true
    var toInternet = true
    var toRadio = false

    func scheduled() -> ScheduledBulletin {
        ScheduledBulletin(id: id, slot: slot, group: group, text: text, intervalMinutes: Int32(intervalMinutes),
                          enabled: enabled, toInternet: toInternet, toRadio: toRadio)
    }
}

/** Codable lists kept in UserDefaults. */
enum SavedList {
    static func load<T: Decodable>(_ key: String, _ d: UserDefaults = .standard) -> [T] {
        guard let data = d.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    static func save<T: Encodable>(_ list: [T], _ key: String, _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: key) }
    }
}

/** Pushes the saved reports, automatic answers and services to the engine. Called once a second. */
enum ReportsSync {
    private static var applied: [String: String] = [:]

    private static func changed(_ key: String, _ signature: String) -> Bool {
        if applied[key] == signature { return false }
        applied[key] = signature
        return true
    }

    private static func csv(_ text: String?, count: Int, fallback: [String]) -> [String] {
        var parts = (text ?? "").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count < count { parts += fallback.dropFirst(parts.count).prefix(count - parts.count) }
        while parts.count < count { parts.append("") }
        return Array(parts.prefix(count))
    }

    static func apply(core: AppleAprs, defaults d: UserDefaults = .standard) {
        let objects: [ObjectSetting] = SavedList.load("ownObjects", d)
        if let data = d.data(forKey: "ownObjects"), changed("objects", data.base64EncodedString()) {
            _ = core.setEntities(list: objects.map { $0.entity() })
        }
        let bulletins: [BulletinSetting] = SavedList.load("scheduledBulletins", d)
        if let data = d.data(forKey: "scheduledBulletins"), changed("bulletins", data.base64EncodedString()) {
            _ = core.setScheduledBulletins(list: bulletins.map { $0.scheduled() })
        }
        let status = StatusBeaconSettings(enabled: d.bool(forKey: "statusEnabled"), text: d.string(forKey: "statusText") ?? "",
                                          intervalMinutes: Int32(d.object(forKey: "statusMinutes") as? Int ?? 30),
                                          grid: d.bool(forKey: "statusGrid"),
                                          toInternet: d.object(forKey: "statusIS") as? Bool ?? true, toRadio: d.bool(forKey: "statusRF"))
        if changed("status", "\(status)") { _ = core.configureStatus(settings: status) }

        let sources = csv(d.string(forKey: "telemetrySources"), count: 5, fallback: ["rf", "is", "digi", "gated", "msgs"])
        let telemetry = TelemetrySettings(
            enabled: d.bool(forKey: "telemetryEnabled"), intervalMinutes: Int32(d.object(forKey: "telemetryMinutes") as? Int ?? 10),
            sources: sources,
            names: csv(d.string(forKey: "telemetryNames"), count: 5, fallback: ["RF", "IS", "Digi", "Gated", "Msgs"]),
            units: csv(d.string(forKey: "telemetryUnits"), count: 5, fallback: ["pkt", "pkt", "pkt", "pkt", "msg"]),
            equations: (d.string(forKey: "telemetryEquations") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
            bitNames: csv(d.string(forKey: "telemetryBits"), count: 2, fallback: ["APRS-IS", "Radio"]),
            title: d.string(forKey: "telemetryTitle") ?? "APRSERJi",
            toInternet: d.object(forKey: "telemetryIS") as? Bool ?? true, toRadio: d.bool(forKey: "telemetryRF"))
        if changed("telemetry", "\(telemetry)") {
            _ = core.configureTelemetry(settings: telemetry, sequence: Int32(d.integer(forKey: "telemetrySequence")))
        }
        d.set(Int(core.telemetrySequence), forKey: "telemetrySequence")

        let weather = WeatherBeaconSettings(
            enabled: d.bool(forKey: "wxBeaconEnabled"), intervalMinutes: Int32(d.object(forKey: "wxBeaconMinutes") as? Int ?? 10),
            objectName: d.string(forKey: "wxObjectName") ?? "", toInternet: d.object(forKey: "wxIS") as? Bool ?? true,
            toRadio: d.bool(forKey: "wxRF"), cwop: d.bool(forKey: "cwopEnabled"), cwopCallsign: d.string(forKey: "cwopCallsign") ?? "",
            cwopServer: d.string(forKey: "cwopServer") ?? "cwop.aprs.net:14580", cwopPasscode: d.string(forKey: "cwopPasscode") ?? "-1")
        if changed("weather", "\(weather)") { core.configureWeatherBeacon(settings: weather) }

        let responder = ResponderSettings(
            queries: d.object(forKey: "respQueries") as? Bool ?? true, autoReply: d.bool(forKey: "autoReplyEnabled"),
            autoReplyText: d.string(forKey: "autoReplyText") ?? "Away from the radio; I'll reply later.",
            autoReplyMinutes: Int32(d.object(forKey: "autoReplyMinutes") as? Int ?? 30),
            qru: d.bool(forKey: "qruEnabled"), qruDefaultKm: Int32(d.object(forKey: "qruRadiusKm") as? Int ?? 50),
            qruMaximum: Int32(d.object(forKey: "qruMax") as? Int ?? 5),
            kiosk: d.bool(forKey: "kioskEnabled"), kioskText: d.string(forKey: "kioskText") ?? "")
        if changed("responder", "\(responder)") { core.configureResponder(settings: responder) }

        let server = "\(d.bool(forKey: "isServerEnabled"))|\(d.object(forKey: "isServerPort") as? Int ?? 14580)|\(d.object(forKey: "isServerLocalOnly") as? Bool ?? true)|\(d.bool(forKey: "isServerToIS"))|\(d.bool(forKey: "isServerToRF"))"
        if changed("server", server) {
            core.configureServer(enabled: d.bool(forKey: "isServerEnabled"), port: Int32(d.object(forKey: "isServerPort") as? Int ?? 14580),
                                 localOnly: d.object(forKey: "isServerLocalOnly") as? Bool ?? true,
                                 toInternet: d.bool(forKey: "isServerToIS"), toRadio: d.bool(forKey: "isServerToRF"))
        }
        let udp = "\(d.bool(forKey: "udpEnabled"))|\(d.object(forKey: "udpPort") as? Int ?? 2025)|\(d.string(forKey: "udpAllowed") ?? "")"
        if changed("udp", udp) {
            core.configureUdpInput(enabled: d.bool(forKey: "udpEnabled"), port: Int32(d.object(forKey: "udpPort") as? Int ?? 2025),
                                   allowedSources: d.string(forKey: "udpAllowed") ?? "")
        }
        let syslog = "\(d.bool(forKey: "syslogEnabled"))|\(d.string(forKey: "syslogHost") ?? "")|\(d.object(forKey: "syslogPort") as? Int ?? 514)"
        if changed("syslog", syslog) {
            core.configureSyslog(enabled: d.bool(forKey: "syslogEnabled"), host: d.string(forKey: "syslogHost") ?? "",
                                 port: Int32(d.object(forKey: "syslogPort") as? Int ?? 514))
        }
        let days = d.object(forKey: "archiveDays") as? Int ?? 30
        if changed("archive", "\(days)") { core.setArchiveRetention(days: Int32(days)) }
    }
}

/** Setup ▸ Status and telemetry reports. */
struct StatusTelemetrySections: View {
    let core: AppleAprs
    @AppStorage("statusEnabled") private var statusEnabled = false
    @AppStorage("statusText") private var statusText = ""
    @AppStorage("statusMinutes") private var statusMinutes = 30
    @AppStorage("statusGrid") private var statusGrid = false
    @AppStorage("statusIS") private var statusIS = true
    @AppStorage("statusRF") private var statusRF = false
    @AppStorage("telemetryEnabled") private var telemetryEnabled = false
    @AppStorage("telemetryMinutes") private var telemetryMinutes = 10
    @AppStorage("telemetrySources") private var sources = "rf,is,digi,gated,msgs"
    @AppStorage("telemetryNames") private var names = "RF,IS,Digi,Gated,Msgs"
    @AppStorage("telemetryUnits") private var units = "pkt,pkt,pkt,pkt,msg"
    @AppStorage("telemetryEquations") private var equations = ""
    @AppStorage("telemetryTitle") private var title = "APRSERJi"
    @AppStorage("telemetryIS") private var telemetryIS = true
    @AppStorage("telemetryRF") private var telemetryRF = false

    private let sourceChoices: [(String, String)] = [
        ("rf", "Packets heard on RF"), ("is", "Packets heard on APRS-IS"), ("digi", "Packets digipeated"),
        ("gated", "Packets gated to APRS-IS"), ("torf", "Packets gated to RF"), ("msgs", "Messages received"),
        ("stations", "Stations tracked"), ("uptime", "Minutes running"), ("const:0", "Constant 0"),
        ("input:sensor1", "App input: sensor1"), ("input:sensor2", "App input: sensor2"),
    ]

    var body: some View {
        Section {
            Toggle("Send a status report", isOn: $statusEnabled)
            TextField("Status text", text: $statusText)
            Text("\(statusText.count)/62").font(.caption).foregroundStyle(statusText.count > 62 ? .red : .secondary)
            Picker("Every", selection: $statusMinutes) {
                ForEach([10, 20, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Toggle("Include my grid square", isOn: $statusGrid)
            Toggle("APRS-IS", isOn: $statusIS)
            Toggle("Radio ports", isOn: $statusRF)
            Button("Send status now") { core.sendStatusNow() }
        } header: { Text("Status") } footer: {
            Text("A status report (\">\") shows under your callsign in other stations' lists, e.g. “Monitoring 146.52” or a net name.")
        }

        Section {
            Toggle("Send telemetry", isOn: $telemetryEnabled)
            Picker("Every", selection: $telemetryMinutes) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            ForEach(0..<5, id: \.self) { index in
                Picker("Channel \(index + 1)", selection: binding(for: index, in: $sources)) {
                    ForEach(sourceChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            TextField("Channel names (comma separated)", text: $names)
            TextField("Units (comma separated)", text: $units)
            TextField("Scaling: 15 numbers a,b,c per channel (optional)", text: $equations)
            TextField("Project title", text: $title)
            Toggle("APRS-IS", isOn: $telemetryIS)
            Toggle("Radio ports", isOn: $telemetryRF)
            LabeledContent("Sequence", value: "\(core.telemetrySequence)")
        } header: { Text("Telemetry") } footer: {
            Text("Raw values are 0–255 (counters wrap). Bits report APRS-IS verified and radio connected. Channel names, units and scaling go out as PARM/UNIT/EQNS/BITS messages first and every tenth report.")
        }
    }

    private func binding(for index: Int, in text: Binding<String>) -> Binding<String> {
        Binding(get: {
            let parts = text.wrappedValue.split(separator: ",").map(String.init)
            return index < parts.count ? parts[index] : "rf"
        }, set: { value in
            var parts = text.wrappedValue.split(separator: ",").map(String.init)
            while parts.count < 5 { parts.append("rf") }
            parts[index] = value
            text.wrappedValue = parts.prefix(5).joined(separator: ",")
        })
    }
}

/** Tools ▸ Objects & items: everything this station publishes, with kill and revive. */
struct ObjectsView: View {
    let core: AppleAprs
    let mapCenter: CLLocationCoordinate2D
    let myPosition: CLLocationCoordinate2D?
    @State private var objects: [ObjectSetting] = SavedList.load("ownObjects")
    @State private var editing: ObjectSetting?

    var body: some View {
        Form {
            Section {
                if objects.isEmpty { Text("No objects yet.").foregroundStyle(.secondary) }
                ForEach(objects) { object in
                    let status = core.entityStatuses.first { $0.id == object.id }
                    HStack {
                        Image(systemName: AprsSymbol.info(table: String(object.symbol.prefix(1)), symbol: String(object.symbol.dropFirst().prefix(1))).image)
                        VStack(alignment: .leading) {
                            Text(object.name).font(.headline.monospaced())
                                .strikethrough(!object.alive)
                            Text((object.item ? "Item" : "Object") + (object.following ? " · follows me" : "") +
                                 (object.group.isEmpty ? "" : " · QRU \(object.group)") +
                                 (status.map { $0.lastSentMillis > 0 ? " · sent \(Date(timeIntervalSince1970: Double($0.lastSentMillis) / 1000).formatted(date: .omitted, time: .shortened))" : "" } ?? "") +
                                 (status?.error.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(object.alive ? "Kill" : "Revive") { update(object.id) { $0.alive.toggle() } }
                        Button("Send now") { core.sendEntityNow(id: object.id) }.disabled(!object.enabled)
                        Button("Edit") { editing = object }
                    }
                }
                Button("New object") {
                    var o = ObjectSetting()
                    o.latitude = mapCenter.latitude
                    o.longitude = mapCenter.longitude
                    editing = o
                }
                Button("New frequency object") {
                    var o = ObjectSetting()
                    o.name = "146.520"
                    o.symbol = "/r"
                    o.frequency = "146.520"
                    o.latitude = mapCenter.latitude
                    o.longitude = mapCenter.longitude
                    o.enabled = false
                    editing = o
                }
            } footer: {
                Text("Objects mark something that isn't a station: a net control, an aid station, an event, a repeater's frequency. Killing one tells every station to remove it (sent three times). New frequency objects start disabled so you can choose where they go first.")
            }
            ScheduledBulletinsSection(core: core)
            QruQuerySection(core: core)
        }
        .formStyle(.grouped)
        .navigationTitle("Objects & bulletins")
        .sheet(item: $editing) { object in
            ObjectEditor(object: object, mapCenter: mapCenter, myPosition: myPosition, onSave: { saved in
                if let i = objects.firstIndex(where: { $0.id == saved.id }) { objects[i] = saved } else { objects.append(saved) }
                SavedList.save(objects, "ownObjects")
                editing = nil
            }, onDelete: {
                objects.removeAll { $0.id == object.id }
                SavedList.save(objects, "ownObjects")
                editing = nil
            }, onCancel: { editing = nil })
        }
    }

    private func update(_ id: String, _ change: (inout ObjectSetting) -> Void) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        change(&objects[i])
        SavedList.save(objects, "ownObjects")
    }
}

private struct ObjectEditor: View {
    @State var object: ObjectSetting
    let mapCenter: CLLocationCoordinate2D
    let myPosition: CLLocationCoordinate2D?
    let onSave: (ObjectSetting) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    @State private var showSymbols = false

    private var valid: Bool { core().map { _ in true } ?? false }
    private func core() -> Bool? {
        let n = object.name.trimmingCharacters(in: .whitespaces)
        return (3...9).contains(n.count) && n.allSatisfy { $0.isASCII && $0 != "!" && $0 != "_" } ? true : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Object") {
                    TextField("Name (3–9 characters)", text: $object.name)
                    Picker("Kind", selection: $object.item) {
                        Text("Object (time-stamped)").tag(false)
                        Text("Item").tag(true)
                    }
                    Button { showSymbols = true } label: {
                        LabeledContent("Symbol", value: AprsSymbol.info(table: String(object.symbol.prefix(1)), symbol: String(object.symbol.dropFirst().prefix(1))).name)
                    }
                    .buttonStyle(.plain)
                    TextField("Comment", text: $object.comment)
                }
                Section("Position") {
                    Toggle("Follow my position", isOn: $object.following)
                    if !object.following {
                        TextField("Latitude", value: $object.latitude, format: .number.precision(.fractionLength(5)))
                        TextField("Longitude", value: $object.longitude, format: .number.precision(.fractionLength(5)))
                        HStack {
                            Button("Use map center") { object.latitude = mapCenter.latitude; object.longitude = mapCenter.longitude }
                            if let me = myPosition { Button("Use my position") { object.latitude = me.latitude; object.longitude = me.longitude } }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Section {
                    TextField("Frequency MHz, e.g. 146.940", text: $object.frequency)
                    TextField("Tone Hz, e.g. 107.2 or off", text: $object.tone)
                    TextField("Offset MHz, e.g. -0.6", text: $object.offset)
                    TextField("Range miles", text: $object.rangeMiles)
                    if !object.frequency.isEmpty { Text(object.fullComment).font(.caption.monospaced()) }
                } header: { Text("Frequency (optional)") }
                Section {
                    ForEach(Array(object.shape.enumerated()), id: \.offset) { index, point in
                        Text(String(format: "%d. %.5f, %.5f", index + 1, point.latitude, point.longitude)).font(.caption.monospaced())
                    }
                    HStack {
                        Button("Add map center as a point") {
                            object.shape.append(.init(latitude: mapCenter.latitude, longitude: mapCenter.longitude))
                        }
                        .disabled(object.shape.count >= 23)
                        if !object.shape.isEmpty { Button("Remove last") { object.shape.removeLast() } }
                    }
                    .buttonStyle(.bordered)
                    Toggle("Closed (polygon)", isOn: $object.shapeClosed)
                    Picker("Style", selection: $object.shapeStyle) {
                        ForEach(Array("abcdefghijkl").map(String.init), id: \.self) { s in
                            let index = Int(s.unicodeScalars.first!.value - 97)
                            Text(["Red", "Yellow", "Blue", "Green"][index / 3] + " " + ["solid", "dashed", "dotted"][index % 3]).tag(s)
                        }
                    }
                } header: { Text("Line or area (optional)") } footer: {
                    Text("Move the map to each corner and add it (up to 23 points). Sent as an AE5PL multiline that APRSIS32, Xastir and APRSERJi draw.")
                }
                Section {
                    Toggle("Enabled", isOn: $object.enabled)
                    Picker("Every", selection: $object.intervalMinutes) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Toggle("APRS-IS", isOn: $object.toInternet)
                    Toggle("Radio ports", isOn: $object.toRadio)
                    TextField("QRU group (optional), e.g. REPEATR", text: $object.group)
                } header: { Text("Sending") } footer: {
                    Text("With a QRU group, this station answers QRU queries for that group with this object (Services ▸ QRU server).")
                }
                Section { Button("Delete object", role: .destructive, action: onDelete) }
            }
            .formStyle(.grouped)
            .navigationTitle(object.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(object) }.disabled(!valid) }
            }
            .sheet(isPresented: $showSymbols) { SymbolPicker(selection: $object.symbol) }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
    }
}

/** Bulletins sent on a schedule (BLN0–BLN9, BLNA–Z, with an optional group). */
struct ScheduledBulletinsSection: View {
    let core: AppleAprs
    @State private var bulletins: [BulletinSetting] = SavedList.load("scheduledBulletins")

    var body: some View {
        Section {
            ForEach($bulletins) { $b in
                VStack(alignment: .leading) {
                    HStack {
                        Picker("Slot", selection: $b.slot) {
                            ForEach(Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init), id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 120)
                        TextField("Group (≤5)", text: $b.group).frame(maxWidth: 100)
                        Toggle("On", isOn: $b.enabled)
                    }
                    TextField("Bulletin text (≤67)", text: $b.text)
                    HStack {
                        Picker("Every", selection: $b.intervalMinutes) {
                            ForEach([10, 20, 30, 60, 120, 240], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        Toggle("APRS-IS", isOn: $b.toInternet)
                        Toggle("RF", isOn: $b.toRadio)
                        Button("Send now") { core.sendBulletinNow(id: b.id) }
                        Button(role: .destructive) { bulletins.removeAll { $0.id == b.id } } label: { Image(systemName: "trash") }
                    }
                }
            }
            Button("New bulletin") { bulletins.append(BulletinSetting()) }
        } header: { Text("Scheduled bulletins") } footer: {
            Text("Bulletins appear on every station's bulletin board in range: BLN0 to BLN9 for general news, a group (BLN1CLUB) for a club or event.")
        }
        .onChange(of: bulletins) { _, list in SavedList.save(list, "scheduledBulletins") }
    }
}

/** Ask QRU servers nearby for objects in a group (repeaters, hamfests, net locations…). */
struct QruQuerySection: View {
    let core: AppleAprs
    @AppStorage("callsign") private var callsign = ""
    @State private var group = "INFO"
    @State private var radius = 50
    @State private var result: String?

    var body: some View {
        Section {
            TextField("Group (e.g. INFO, REPEATR, HAMFEST)", text: $group)
            Stepper("Within \(radius) km", value: $radius, in: 5...500, step: 5)
            Button("Send query") {
                let g = group.trimmingCharacters(in: .whitespaces).uppercased()
                Task {
                    let account = normalizedCallsign(callsign)
                    do {
                        try await core.enqueue(account: account, peer: "QRU", body: "\(g) \(radius)")
                        result = "Query sent; answers appear on the map as items."
                    } catch {
                        result = "Enter your callsign first."
                    }
                }
            }
            .disabled(group.isEmpty)
            if let result { Text(result).font(.caption) }
        } header: { Text("QRU query") } footer: {
            Text("QRU servers answer with the nearest objects in that group, sent to you as items. Your position must be on the air first so they know where \"nearest\" is.")
        }
    }
}
