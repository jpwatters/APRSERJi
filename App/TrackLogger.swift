import AprsCore
import CoreLocation
import Foundation
import SwiftUI

/**
 * Daily GPX and CSV logs per station (and your own GPS fixes), in Documents/APRSERJi Logs. Each GPX file stays a
 * valid document after every point; old files are removed after the retention period.
 */
@MainActor
final class TrackLogger {
    static let shared = TrackLogger()
    private var logged: [String: Int64] = [:]
    private var lastOwn: Date?
    private var cleaned = Date.distantPast
    private let footer = "</trkseg></trk></gpx>\n"

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("APRSERJi Logs", isDirectory: true)
    }

    func tick(tracks: [String: [TrackPoint]], own: CLLocation?, ownCall: String, defaults d: UserDefaults = .standard) {
        guard d.bool(forKey: "trackLogEnabled") else { return }
        let patterns = WatchList.parse(d.string(forKey: "trackLogCalls") ?? "")
        let all = d.bool(forKey: "trackLogAll")
        for (call, points) in tracks where all || WatchList.matches(call, patterns) {
            let since = logged[call] ?? 0
            let fresh = points.filter { $0.timeMillis > since }
            guard !fresh.isEmpty else { continue }
            for p in fresh { append(call, latitude: p.latitude, longitude: p.longitude, time: Date(timeIntervalSince1970: Double(p.timeMillis) / 1000), extra: nil) }
            logged[call] = fresh.last!.timeMillis
        }
        if d.object(forKey: "trackLogOwn") as? Bool ?? true, let fix = own, fix.timestamp != lastOwn {
            if lastOwn == nil || fix.timestamp.timeIntervalSince(lastOwn!) >= 5 {
                append(ownCall.isEmpty ? "MY-POSITION" : ownCall, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                       time: fix.timestamp, extra: fix.verticalAccuracy >= 0 ? fix.altitude : nil)
                lastOwn = fix.timestamp
            }
        }
        if Date().timeIntervalSince(cleaned) > 3600 {
            cleaned = Date()
            removeOld(days: d.object(forKey: "trackLogDays") as? Int ?? 30)
        }
    }

    private func safe(_ call: String) -> String {
        String(call.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    private func append(_ call: String, latitude: Double, longitude: Double, time: Date, extra altitude: Double?) {
        let day = ISO8601DateFormatter.string(from: time, timeZone: .current, formatOptions: [.withFullDate])
        let base = Self.folder.appendingPathComponent(day, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: time)
        // CSV
        let csv = base.appendingPathComponent(safe(call) + ".csv")
        let row = String(format: "%@,%.6f,%.6f,%@\n", stamp, latitude, longitude, altitude.map { String(format: "%.1f", $0) } ?? "")
        appendText(csv, row, header: "time,latitude,longitude,altitude_m\n")
        // GPX: write the point before the closing tags so the file is always complete.
        let gpx = base.appendingPathComponent(safe(call) + ".gpx")
        let point = String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\">%@<time>%@</time></trkpt>\n", latitude, longitude,
                           altitude.map { String(format: "<ele>%.1f</ele>", $0) } ?? "", stamp)
        if !FileManager.default.fileExists(atPath: gpx.path) {
            let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"APRSERJi\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(call)</name><trkseg>\n"
            try? (header + point + footer).write(to: gpx, atomically: true, encoding: .utf8)
        } else if let handle = try? FileHandle(forUpdating: gpx) {
            let end = (try? handle.seekToEnd()) ?? 0
            let back = UInt64(footer.utf8.count)
            try? handle.seek(toOffset: end >= back ? end - back : end)
            try? handle.write(contentsOf: Data((point + footer).utf8))
            try? handle.close()
        }
    }

    private func appendText(_ url: URL, _ text: String, header: String) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? (header + text).write(to: url, atomically: true, encoding: .utf8)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        }
    }

    private func removeOld(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if date < cutoff { try? FileManager.default.removeItem(at: folder) }
        }
    }
}

/** Setup ▸ Track logs. */
struct TrackLogSection: View {
    @AppStorage("trackLogEnabled") private var enabled = false
    @AppStorage("trackLogOwn") private var own = true
    @AppStorage("trackLogAll") private var all = false
    @AppStorage("trackLogCalls") private var calls = ""
    @AppStorage("trackLogDays") private var days = 30

    var body: some View {
        Section {
            Toggle("Write daily GPX and CSV track logs", isOn: $enabled)
            if enabled {
                Toggle("My own position", isOn: $own)
                Toggle("Every station that moves", isOn: $all)
                if !all { TextField("These stations (e.g. KJ4DXK*, KC9KKO-9)", text: $calls) }
                Picker("Keep logs for", selection: $days) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
                }
                #if os(macOS)
                Button("Show logs in Finder") {
                    try? FileManager.default.createDirectory(at: TrackLogger.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(TrackLogger.folder)
                }
                #else
                Text("Find them in the Files app under On My iPhone ▸ APRSERJi ▸ APRSERJi Logs.").font(.caption).foregroundStyle(.secondary)
                #endif
            }
        } header: { Text("Track logs") }
    }
}

/** Alerts when a watched station comes near you or goes quiet. */
@MainActor
final class WatchAlerts {
    static let shared = WatchAlerts()
    private var near: Set<String> = []
    private var lastHeard: [String: Date] = [:]
    private var lostAlerted: Set<String> = []

    func tick(stations: [StationDetail], origin: CLLocationCoordinate2D, defaults d: UserDefaults = .standard) {
        let patterns = WatchList.parse(d.string(forKey: "viewWatchList") ?? "")
        guard !patterns.isEmpty else { return }
        let proximity = d.object(forKey: "alertProximityMiles") as? Int ?? 0
        let lostMinutes = d.object(forKey: "alertLostMinutes") as? Int ?? 0
        let sound = d.string(forKey: "alertSound") ?? "Glass"
        let now = Date()
        for s in stations where WatchList.matches(s.callsign, patterns) {
            lastHeard[s.callsign] = s.heardAt
            if lostAlerted.remove(s.callsign) != nil, now.timeIntervalSince(s.heardAt) < 120 {
                MessageNotifier.shared.postAlert(title: "\(s.callsign) is back", body: "Heard again", sound: sound)
            }
            guard proximity > 0 else { continue }
            let inside = Geo.distance(origin, s.coordinate) <= Double(proximity) * 1609.344
            if inside && !near.contains(s.callsign) {
                near.insert(s.callsign)
                MessageNotifier.shared.postAlert(title: "\(s.callsign) is nearby",
                                                 body: "Within \(proximity) mi — \(Units.distance(Geo.distance(origin, s.coordinate), metric: false)) \(Units.compass(Geo.bearing(from: origin, to: s.coordinate)))",
                                                 sound: sound)
            } else if !inside && Geo.distance(origin, s.coordinate) > Double(proximity) * 1609.344 * 1.2 {
                near.remove(s.callsign)
            }
        }
        guard lostMinutes > 0 else { return }
        for (call, heard) in lastHeard where now.timeIntervalSince(heard) > Double(lostMinutes) * 60 && !lostAlerted.contains(call) {
            lostAlerted.insert(call)
            MessageNotifier.shared.postAlert(title: "\(call) has gone quiet", body: "Not heard for \(lostMinutes) minutes", sound: sound)
        }
    }
}

/** Setup ▸ Watched-station alerts. */
struct WatchAlertSection: View {
    @AppStorage("alertProximityMiles") private var proximity = 0
    @AppStorage("alertLostMinutes") private var lost = 0
    @AppStorage("alertSound") private var sound = "Glass"

    var body: some View {
        Section {
            Picker("When a watched station comes within", selection: $proximity) {
                Text("Off").tag(0)
                ForEach([1, 2, 5, 10, 25], id: \.self) { Text("\($0) mi").tag($0) }
            }
            Picker("When a watched station goes quiet for", selection: $lost) {
                Text("Off").tag(0)
                ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Picker("Sound", selection: $sound) {
                ForEach(["Glass", "Ping", "Submarine", "Hero", "Sosumi", "Funk", "Default"], id: \.self) { Text($0).tag($0) }
            }
            Button("Test alert") { MessageNotifier.shared.postAlert(title: "APRSERJi", body: "This is how alerts sound.", sound: sound) }
        } header: { Text("Watched-station alerts") } footer: {
            Text("Applies to the Always show list on the Map page.")
        }
    }
}
