import AprsCore
import CoreLocation
import SwiftUI
#if os(macOS)
import AppKit
import ImageIO
#endif

/**
 Screenshot tour mode, started by tour.sh with the launch argument `-TourMode YES`. The app connects to the
 demo APRS-IS server that tour.sh runs on this Mac (made-up stations around Goose Lake Prairie State Natural
 Area), sits at a fixed position there instead of using GPS, keeps its chats in a separate database, and walks
 itself through every tab, panel, tool and Setup section. For each one it writes the scene's name to
 scene.txt and waits until tour.sh has taken the screenshot and written its number to ack.txt.
 */
enum Tour {
    static let enabled = UserDefaults.standard.bool(forKey: "TourMode")
    /** Goose Lake Prairie State Natural Area, Grundy County, Illinois. */
    static let coordinate = CLLocationCoordinate2D(latitude: 41.36750, longitude: -88.29722)
    static let server = "127.0.0.1"
    static let port: Int32 = 14590

    /** Where scene.txt, scenes.tsv and ack.txt live: /tmp/aprserji-tour on the Mac, Documents on iPhone/iPad. */
    static var folder: URL {
        #if os(macOS)
        let url = URL(fileURLWithPath: "/tmp/aprserji-tour", isDirectory: true)
        #else
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /** The standard APRS-IS passcode for [callsign] (without SSID), so the demo login is "verified". */
    static func passcode(_ callsign: String) -> String {
        let base = Array(callsign.uppercased().split(separator: "-").first.map(String.init) ?? "").map { Int($0.asciiValue ?? 0) }
        var hash = 0x73E2
        var i = 0
        while i < base.count {
            hash ^= base[i] << 8
            if i + 1 < base.count { hash ^= base[i + 1] }
            i += 2
        }
        return String(hash & 0x7FFF)
    }

    static let scenes: [TourScene] = {
        var list: [TourScene] = [
            TourScene("map", "The map: stations around you with callsign labels, tracks and a range of tile styles", tab: 0),
            TourScene("map-settings", "Map settings: connection, tiles, layers, receive ranges and the station filter", tab: 0, mapControls: true),
            TourScene("stations", "Stations: everything heard, sorted by distance, with filters", tab: 2),
            TourScene("station-weather", "Station details: a weather station's readings", tab: 2, station: "N0WXST"),
            TourScene("station-mobile", "Station details: a moving station with course, speed and path", tab: 2, station: "N0DEMO-9"),
            TourScene("messages", "Messages: two-way APRS messaging with delivery and acknowledgment status", tab: 1, recipient: "N0DEMO-9"),
            TourScene("bulletins", "Bulletins and announcements, with NWS warnings for your area", tab: 4),
        ]
        var setup: [(String, String)] = [
            ("beacon", "Setup: beaconing your position (fixed interval, GeniusBeaconing, SmartBeaconing)"),
            ("status", "Setup: status text and telemetry"),
            ("ports", "Setup: radio ports — network, serial and Bluetooth TNCs, IGate and digipeater"),
        ]
        #if os(macOS)
        setup.append(("gps", "Setup: GPS source (Core Location, serial or network NMEA, gpsd)"))
        #endif
        setup += [
            ("cat", "Setup: virtual radio (CAT control) for logging and radio programs"),
            ("weather", "Setup: your weather station, Tempest and CWOP"),
            ("services", "Setup: local services — APRS server for other programs, UDP input, syslog"),
            ("layers", "Setup: map layers"),
            ("reference", "Setup: state and county boundaries and roads"),
            ("offline", "Setup: offline maps"),
            ("tracklog", "Setup: track logging"),
            ("watchalerts", "Setup: watch list alerts"),
            ("fcc", "Setup: FCC callsign database"),
            ("display", "Setup: display and alerts"),
        ]
        list += setup.map { TourScene("setup-" + $0.0, $0.1, tab: 3, setup: $0.0) }
        list.append(TourScene("tools", "Tools", tab: 5))
        list += ToolPage.allCases.map { TourScene("tools-" + $0.rawValue, "Tools: " + $0.title, tab: 5, tool: $0) }
        list.append(TourScene("multitrack", "MultiTrack: follow up to 8 stations at once", tab: 0, multiTrack: true))
        return list
    }()
}

struct TourScene: Equatable {
    let name: String
    let title: String
    var tab = 0
    var mapControls = false
    var station: String?
    var recipient: String?
    var setup: String?
    var tool: ToolPage?
    var multiTrack = false

    init(_ name: String, _ title: String, tab: Int, mapControls: Bool = false, station: String? = nil,
         recipient: String? = nil, setup: String? = nil, tool: ToolPage? = nil, multiTrack: Bool = false) {
        self.name = name; self.title = title; self.tab = tab; self.mapControls = mapControls; self.station = station
        self.recipient = recipient; self.setup = setup; self.tool = tool; self.multiTrack = multiTrack
    }
}

/** Steps through [Tour.scenes], waiting for tour.sh to screenshot each one. */
@MainActor
final class TourDirector: ObservableObject {
    static let shared = TourDirector()
    @Published private(set) var scene: TourScene?
    private var started = false

    func start() {
        guard Tour.enabled, !started else { return }
        started = true
        let folder = Tour.folder
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("ack.txt"))
        let catalog = Tour.scenes.map { "\($0.name)\t\($0.title)" }.joined(separator: "\n") + "\n"
        try? catalog.write(to: folder.appendingPathComponent("scenes.tsv"), atomically: true, encoding: .utf8)
        Task {
            // Time for the demo stations to arrive and the map tiles to load.
            write(status: "-1\tloading")
            try? await Task.sleep(for: .seconds(20))
            for (index, next) in Tour.scenes.enumerated() {
                scene = next
                try? await Task.sleep(for: .seconds(2.5))
                #if os(macOS)
                captureOwnWindow()
                #endif
                write(status: "\(index)\t\(next.name)")
                await waitForAck(index)
            }
            scene = TourScene("done", "", tab: 0)
            write(status: "\(Tour.scenes.count)\tdone")
        }
    }

    private func write(status: String) {
        var line = status
        #if os(macOS)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            line += "\t\(window.windowNumber)"
        }
        #endif
        try? (line + "\n").write(to: Tour.folder.appendingPathComponent("scene.txt"), atomically: true, encoding: .utf8)
    }

    #if os(macOS)
    /**
     Saves this app's own window to current.png, which tour.sh uses when Terminal isn't allowed to record the
     screen. An app may picture its own windows without that permission. CGWindowListCreateImage is looked up
     at run time because newer SDKs no longer declare it.
     */
    private func captureOwnWindow() {
        let url = Tour.folder.appendingPathComponent("current.png")
        try? FileManager.default.removeItem(at: url)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var image: CGImage?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            // Only this window (includingWindow = 8), without its shadow (boundsIgnoreFraming = 1), at full resolution (8).
            image = create(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
        }
        if image == nil, let view = window.contentView?.superview {
            // Fallback: draw the window's views (maps may come out blank this way).
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                image = rep.cgImage
            }
        }
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    #endif

    /** Waits up to 30 seconds for tour.sh to write [index] to ack.txt. */
    private func waitForAck(_ index: Int) async {
        let url = Tour.folder.appendingPathComponent("ack.txt")
        for _ in 0..<150 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let done = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), done >= index { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

extension GPSTracker {
    /** Tour mode: stand at Goose Lake Prairie instead of using the real GPS. */
    func tourFix() {
        let fix = ExternalFix(latitude: Tour.coordinate.latitude, longitude: Tour.coordinate.longitude,
                              altitudeMeters: nil, speedKnots: nil, courseDegrees: nil, accuracyMeters: 5,
                              timeMillis: Int64(Date().timeIntervalSince1970 * 1000))
        ingest(fix)
    }
}
