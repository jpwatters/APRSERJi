import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Memory channels for the virtual radio: tuned with the CAT command MC=nnnn (MC=X+1 / MC=X-1 to step,
// MC=-1 for the channel used before), typed in Setup or imported from a CHIRP .csv export.

/** One memory channel. */
struct Channel: Codable, Identifiable, Equatable {
    var number: Int
    var name: String
    var rxHz: Int
    var txHz: Int
    /** Transmit CTCSS tone in Hz; 0 = none. */
    var toneHz: Double
    var modeName: String

    var id: Int { number }
    var mode: RigMode { RigMode(rawValue: modeName) ?? .fm }

    /** "146.940 −0.600 T107.2 FM" */
    var summary: String {
        var s = VirtualRig.mhz(rxHz)
        if txHz != rxHz {
            let offset = Double(txHz - rxHz) / 1_000_000
            s += abs(offset) < 10 ? String(format: " %@%.3f", offset < 0 ? "−" : "+", abs(offset)) : " TX " + VirtualRig.mhz(txHz)
        }
        if toneHz > 0 { s += String(format: " T%.1f", toneHz) }
        return s + " " + modeName
    }
}

/** The channel list, kept in UserDefaults; readable from any thread. */
final class ChannelStore: ObservableObject {
    static let shared = ChannelStore()

    @Published private(set) var channels: [Channel] = []
    private let lock = NSLock()
    private var copy: [Channel] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: "catChannels"),
           let list = try? JSONDecoder().decode([Channel].self, from: data) {
            set(list, save: false)
        }
    }

    /** The channels in number order, safe from any thread. */
    func snapshot() -> [Channel] {
        lock.lock(); defer { lock.unlock() }
        return copy
    }

    /** Adds channels, replacing any with the same numbers. */
    func add(_ new: [Channel]) {
        let numbers = Set(new.map(\.number))
        set(channels.filter { !numbers.contains($0.number) } + new)
    }

    func remove(_ number: Int) { set(channels.filter { $0.number != number }) }

    func removeAll() { set([]) }

    private func set(_ list: [Channel], save: Bool = true) {
        let sorted = list.sorted { $0.number < $1.number }
        lock.lock(); copy = sorted; lock.unlock()
        channels = sorted
        if save, let data = try? JSONEncoder().encode(sorted) { UserDefaults.standard.set(data, forKey: "catChannels") }
    }
}

/** Reads a CHIRP .csv export (Location, Name, Frequency, Duplex, Offset, Tone, rToneFreq, cToneFreq, Mode …). */
enum ChirpImport {
    enum Failure: LocalizedError {
        case notChirp
        var errorDescription: String? { "That isn't a CHIRP .csv export (it needs Location and Frequency columns)." }
    }

    static func channels(from text: String) throws -> [Channel] {
        let rows = parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let location = header.firstIndex(of: "location"), let frequency = header.firstIndex(of: "frequency") else {
            throw Failure.notChirp
        }
        func column(_ name: String) -> Int? { header.firstIndex(of: name.lowercased()) }
        let name = column("Name"), duplex = column("Duplex"), offset = column("Offset"), tone = column("Tone")
        let rTone = column("rToneFreq"), cTone = column("cToneFreq"), crossMode = column("CrossMode"), mode = column("Mode")
        var out: [Channel] = []
        for row in rows.dropFirst() {
            func value(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }
            guard let number = Int(value(location)), let rxMHz = Double(value(frequency)), rxMHz > 0 else { continue }
            let rx = Int((rxMHz * 1_000_000).rounded())
            let shift = Int(((Double(value(offset)) ?? 0) * 1_000_000).rounded())
            var tx = rx
            switch value(duplex).lowercased() {
            case "+": tx = rx + shift
            case "-": tx = rx - shift
            case "split": tx = shift > 0 ? shift : rx
            default: break // simplex, or "off" (receive only)
            }
            var toneHz = 0.0
            switch value(tone) {
            case "Tone": toneHz = Double(value(rTone)) ?? 0
            case "TSQL": toneHz = Double(value(cTone)) ?? 0
            case "Cross" where value(crossMode).hasPrefix("Tone"): toneHz = Double(value(rTone)) ?? 0
            default: break
            }
            let modeName: String
            switch value(mode).uppercased() {
            case "USB": modeName = "USB"
            case "LSB": modeName = "LSB"
            case "CW": modeName = "CW"
            case "AM": modeName = "AM"
            case "RTTY": modeName = "RTTY"
            default: modeName = "FM" // FM, NFM, WFM, DV, DN …
            }
            out.append(Channel(number: number, name: value(name), rxHz: rx, txHz: tx, toneHz: toneHz, modeName: modeName))
        }
        return out
    }

    /** CSV with quoted fields. */
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        while let ch = chars.next() {
            if quoted {
                if ch == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == "," { row.append(field); field = "" }
                            else if next == "\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/** Setup: the channel list MC tunes. */
struct ChannelsSection: View {
    @ObservedObject private var store = ChannelStore.shared
    @ObservedObject private var rig = VirtualRig.shared
    @State private var number = ""
    @State private var name = ""
    @State private var rx = ""
    @State private var tx = ""
    @State private var tone = ""
    @State private var mode: RigMode = .fm
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Section {
            ForEach(store.channels) { ch in
                HStack {
                    Text(String(format: "%04ld", ch.number)).font(.body.monospacedDigit())
                        .foregroundStyle(ch.number == rig.shown.channel ? Color.accentColor : .secondary)
                    VStack(alignment: .leading) {
                        Text(ch.name.isEmpty ? "Channel \(ch.number)" : ch.name)
                        Text(ch.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Tune") { rig.tune(ch) }.buttonStyle(.borderless)
                    Button { store.remove(ch.number) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove channel \(ch.number)")
                }
            }
            DisclosureGroup("Add a channel") {
                TextField("Number", text: $number)
                TextField("Name", text: $name)
                TextField("Receive MHz", text: $rx)
                TextField("Transmit MHz (blank = same)", text: $tx)
                TextField("Tone Hz (blank = none)", text: $tone)
                Picker("Mode", selection: $mode) { ForEach(RigMode.allCases) { Text($0.rawValue).tag($0) } }
                Button("Add channel") { add() }
                    .disabled(Int(number) == nil || VirtualRig.parseHz(rx) == nil)
            }
            HStack {
                Button("Import CHIRP .csv…") { importing = true }
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
                        guard case let .success(url) = result else { return }
                        importChirp(url)
                    }
                Spacer()
                if !store.channels.isEmpty {
                    Button("Remove all", role: .destructive) { store.removeAll() }.buttonStyle(.borderless)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Channels")
        } footer: {
            Text("CAT programs tune these with MC=0012 (channel 12), MC=X+1 / MC=X-1 (next / previous in the list) and MC=-1 (the channel used before). In CHIRP, use File ▸ Export to save your radio's memories as a .csv, then import it here; channels with the same number are replaced.")
        }
    }

    private func add() {
        guard let n = Int(number), let rxHz = VirtualRig.parseHz(rx) else { return }
        let txHz = VirtualRig.parseHz(tx) ?? rxHz
        store.add([Channel(number: n, name: name, rxHz: rxHz, txHz: txHz, toneHz: Double(tone) ?? 0, modeName: mode.rawValue)])
        number = ""; name = ""; rx = ""; tx = ""; tone = ""
    }

    private func importChirp(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let list = try ChirpImport.channels(from: text)
            store.add(list)
            message = "Imported \(list.count) channel\(list.count == 1 ? "" : "s") from \(url.lastPathComponent)."
        } catch {
            message = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
