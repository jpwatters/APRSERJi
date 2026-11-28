import CoreLocation
import Foundation

/**
 Screenshot tour mode for the Watch app (launch argument `-TourMode YES`, used by tour.sh on a Watch
 simulator): made-up stations and messages around Goose Lake Prairie instead of data from the iPhone, and a
 walk through every page, writing each scene's name to Documents/scene.txt and waiting for tour.sh's ack.txt.
 */
enum WatchTour {
    static let enabled = UserDefaults.standard.bool(forKey: "TourMode")
    static let here = CLLocationCoordinate2D(latitude: 41.36750, longitude: -88.29722)

    struct Step: Equatable {
        let name: String
        let title: String
        var page = 0
        var messagesPath: [String] = []
        var reply = false
        var stationsPath: [String] = []
    }

    static let steps: [Step] = [
        Step(name: "watch-messages", title: "Messages: recent conversations with unread counts", page: 0),
        Step(name: "watch-conversation", title: "A conversation, with acknowledgment status", page: 0, messagesPath: ["N0DEMO-9"]),
        Step(name: "watch-reply", title: "Reply by dictation, Scribble or a quick reply", page: 0, messagesPath: ["N0DEMO-9"], reply: true),
        Step(name: "watch-nearby", title: "Nearby stations with distance and an arrow pointing to each", page: 1),
        Step(name: "watch-station", title: "Station details, with a button to message it", page: 1, stationsPath: ["N0DEMO-9"]),
        Step(name: "watch-map", title: "The map around you; swipe the right edge to change pages", page: 2),
        Step(name: "watch-beacon", title: "Beacon status and Beacon now", page: 3),
    ]

    static var demo: WatchSnapshot {
        let now = Date()
        func station(_ call: String, _ lat: Double, _ lon: Double, _ kind: String, _ comment: String,
                     ago: Double, speed: String? = nil, canMessage: Bool = true) -> WatchSnapshot.Station {
            let there = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let meters = CLLocation(latitude: here.latitude, longitude: here.longitude)
                .distance(from: CLLocation(latitude: lat, longitude: lon))
            let miles = meters / 1609.344
            return WatchSnapshot.Station(callsign: call, latitude: lat, longitude: lon, kind: kind, comment: comment,
                                         heard: now.addingTimeInterval(-ago),
                                         distanceText: String(format: "%.1f mi", miles), distanceMeters: meters,
                                         bearing: bearing(here, there), speedText: speed, canMessage: canMessage)
        }
        var s = WatchSnapshot()
        s.callsign = "KC9KKO"
        s.connection = "Verified"
        s.canSend = true
        s.latitude = here.latitude
        s.longitude = here.longitude
        s.stations = [
            station("N0TOUR-7", 41.3712, -88.2905, "station", "Hiking the prairie trail", ago: 40, speed: "3 mph"),
            station("CABIN", 41.3655, -88.3030, "object", "Cragg Cabin open house 10-2", ago: 300, canMessage: false),
            station("N0DEMO-9", 41.3810, -88.2560, "station", "Mobile, monitoring 146.52", ago: 25, speed: "38 mph"),
            station("N0WXST", 41.4050, -88.2480, "weather", "Weather station, Channahon", ago: 180),
            station("N0HOME", 41.3300, -88.2200, "station", "Home station", ago: 600),
            station("N0DIGI-10", 41.3570, -88.4210, "station", "Digipeater, Morris", ago: 120, canMessage: false),
            station("N0IGAT-10", 41.4330, -88.1950, "station", "IGate", ago: 240, canMessage: false),
        ].sorted { $0.distanceMeters < $1.distanceMeters }
        func message(_ id: Int64, _ outgoing: Bool, _ body: String, _ time: Date, _ status: String) -> WatchSnapshot.Message {
            WatchSnapshot.Message(id: id, outgoing: outgoing, body: body, time: time, status: status)
        }
        s.conversations = [
            WatchSnapshot.Conversation(peer: "N0DEMO-9", unread: 1, messages: [
                message(1, false, "Heading to Goose Lake Prairie, ETA 20 minutes", now.addingTimeInterval(-900), ""),
                message(2, true, "Sounds good. See you at the visitor center, 73", now.addingTimeInterval(-840), "ACKNOWLEDGED"),
                message(3, false, "Parking now, by the cabin", now.addingTimeInterval(-60), ""),
            ]),
            WatchSnapshot.Conversation(peer: "N0TOUR-7", unread: 0, messages: [
                message(4, false, "QSL, on the tallgrass trail", now.addingTimeInterval(-3600), ""),
                message(5, true, "Thanks, I'll meet you at the overlook", now.addingTimeInterval(-3500), "ACKNOWLEDGED"),
            ]),
            WatchSnapshot.Conversation(peer: "N0HOME", unread: 0, messages: [
                message(6, true, "Leaving the park at 4", now.addingTimeInterval(-7200), "WAITING"),
            ]),
        ]
        s.beaconState = "SCHEDULED"
        s.lastBeacon = now.addingTimeInterval(-240)
        s.nextBeacon = now.addingTimeInterval(360)
        s.sent = now
        return s
    }

    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2), x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
}

/** Walks through [WatchTour.steps], waiting for tour.sh to screenshot each one. */
@MainActor
final class WatchTourDirector: ObservableObject {
    static let shared = WatchTourDirector()
    @Published private(set) var step: WatchTour.Step?
    private var started = false

    func start() {
        guard WatchTour.enabled, !started else { return }
        started = true
        let folder = WatchTour.folder
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("ack.txt"))
        let catalog = WatchTour.steps.map { "\($0.name)\t\($0.title)" }.joined(separator: "\n") + "\n"
        try? catalog.write(to: folder.appendingPathComponent("scenes.tsv"), atomically: true, encoding: .utf8)
        Task {
            write("-1\tloading")
            try? await Task.sleep(for: .seconds(6))
            for (index, next) in WatchTour.steps.enumerated() {
                step = next
                try? await Task.sleep(for: .seconds(2.5))
                write("\(index)\t\(next.name)")
                await waitForAck(index)
            }
            write("\(WatchTour.steps.count)\tdone")
        }
    }

    private func write(_ line: String) {
        try? (line + "\n").write(to: WatchTour.folder.appendingPathComponent("scene.txt"), atomically: true, encoding: .utf8)
    }

    private func waitForAck(_ index: Int) async {
        let url = WatchTour.folder.appendingPathComponent("ack.txt")
        for _ in 0..<150 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let done = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), done >= index { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
