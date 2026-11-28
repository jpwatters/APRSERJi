#if os(iOS)
import AprsCore
import CoreLocation
import Foundation
import WatchConnectivity

/**
 The iPhone end of the Apple Watch companion app. Once a second the map's loop calls [tick], which sends the
 Watch a small snapshot (nearest stations, recent conversations, beacon status) whenever something changed, and
 carries out what the Watch asked for (beacon now, send a message, mark a conversation read).
 */
@MainActor
final class WatchCompanion: NSObject {
    static let shared = WatchCompanion()

    private var session: WCSession?
    /** Commands from the Watch, run on the next tick where the APRS core is at hand. */
    private var pending: [WatchCommand] = []
    private var conversations: [WatchSnapshot.Conversation] = []
    private var loadedRevision: Int64 = -1
    private var loading = false
    private var lastSent: WatchSnapshot?
    private var lastSentAt = Date.distantPast
    private var forceSend = false

    private static let stationLimit = 25
    private static let conversationLimit = 8
    private static let messagesPerConversation = 12

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    private var watchReady: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isPaired && session.isWatchAppInstalled
    }

    func tick(core: AppleAprs, account: String, canSend: Bool, connection: String,
              stations: [StationDetail], origin: CLLocationCoordinate2D?, revision: Int64) {
        guard session != nil else { return }
        let commands = pending
        pending = []
        for command in commands { run(command, core: core, account: account) }
        guard watchReady else { return }

        if revision != loadedRevision && !loading && AprsProtocol.shared.validCallsign(value: account) {
            loading = true
            Task { [weak self] in
                let loaded = await Self.loadConversations(core: core, account: account)
                guard let self else { return }
                self.loading = false
                if let loaded {
                    self.conversations = loaded
                    self.loadedRevision = revision
                }
            }
        }

        var snapshot = WatchSnapshot()
        snapshot.callsign = account
        snapshot.connection = connection
        snapshot.canSend = canSend
        snapshot.latitude = origin?.latitude
        snapshot.longitude = origin?.longitude
        snapshot.stations = Self.nearest(stations, from: origin, own: account)
        snapshot.conversations = conversations
        snapshot.beaconState = core.beaconState
        snapshot.lastBeacon = core.lastBeaconMillis > 0 ? Date(timeIntervalSince1970: Double(core.lastBeaconMillis) / 1000) : nil
        snapshot.nextBeacon = core.nextBeaconMillis > 0 ? Date(timeIntervalSince1970: Double(core.nextBeaconMillis) / 1000) : nil

        // Send when something changed, at most every 3 seconds (and at least every 2 minutes so ages stay fresh).
        var compare = snapshot
        compare.sent = lastSent?.sent ?? snapshot.sent
        let changed = compare != lastSent
        let elapsed = Date().timeIntervalSince(lastSentAt)
        guard forceSend || (changed && elapsed >= 3) || elapsed >= 120 else { return }
        forceSend = false
        snapshot.sent = Date()
        do {
            try session?.updateApplicationContext(snapshot.encoded())
            lastSent = snapshot
            lastSentAt = Date()
        } catch {
            // The Watch isn't reachable right now; try again on a later tick.
        }
    }

    private func run(_ command: WatchCommand, core: AppleAprs, account: String) {
        switch command {
        case .beaconNow:
            core.beaconNow()
            forceSend = true
        case .send(let to, let text):
            let peer = normalizedCallsign(to)
            guard AprsProtocol.shared.validCallsign(value: account), AprsProtocol.shared.validCallsign(value: peer),
                  peer != account, AprsMessages.shared.validLongText(text: text) else { return }
            Task {
                try? await core.enqueue(account: account, peer: peer, body: text)
                self.loadedRevision = -1
                self.forceSend = true
            }
        case .markRead(let peer):
            Task {
                try? await core.markRead(account: account, peer: normalizedCallsign(peer))
                self.loadedRevision = -1
            }
        case .refresh:
            forceSend = true
        }
    }

    private static func loadConversations(core: AppleAprs, account: String) async -> [WatchSnapshot.Conversation]? {
        guard let peers = try? await core.conversations(account: account) else { return nil }
        var result: [WatchSnapshot.Conversation] = []
        for peer in peers.prefix(conversationLimit) {
            guard let rows = try? await core.messages(account: account, peer: peer) else { continue }
            let recent = rows.suffix(messagesPerConversation).map { row in
                WatchSnapshot.Message(id: row.id, outgoing: row.outgoing, body: row.body,
                                      time: Date(timeIntervalSince1970: Double(row.time) / 1000),
                                      status: row.outgoing ? row.status : "")
            }
            result.append(WatchSnapshot.Conversation(peer: peer, unread: rows.filter { $0.unread && !$0.outgoing }.count,
                                                     messages: Array(recent)))
        }
        return result
    }

    private static func nearest(_ stations: [StationDetail], from origin: CLLocationCoordinate2D?,
                                own: String) -> [WatchSnapshot.Station] {
        guard let origin else { return [] }
        let metric = UserDefaults.standard.bool(forKey: "useMetric")
        return stations
            .filter { $0.callsign != own }
            .map { station -> (StationDetail, CLLocationCoordinate2D, Double) in
                let where_ = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
                return (station, where_, Geo.distance(origin, where_))
            }
            .sorted { $0.2 < $1.2 }
            .prefix(stationLimit)
            .map { station, coordinate, meters in
                let knots = station.speedKnots?.doubleValue ?? 0
                return WatchSnapshot.Station(
                    callsign: station.callsign, latitude: coordinate.latitude, longitude: coordinate.longitude,
                    kind: station.kind, comment: String(station.comment.prefix(60)), heard: station.heardAt,
                    distanceText: Units.distance(meters, metric: metric), distanceMeters: meters,
                    bearing: Geo.bearing(from: origin, to: coordinate),
                    speedText: knots >= 1 ? Units.speed(knots: knots, metric: metric) : nil,
                    canMessage: station.canMessage)
            }
    }

    fileprivate func receive(_ dictionary: [String: Any]) {
        guard let command = WatchCommand(dictionary) else { return }
        pending.append(command)
    }
}

extension WatchCompanion: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.forceSend = true }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different Watch was paired; start a session with it.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.forceSend = true }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.receive(message) }
        replyHandler(["ok": true])
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.receive(userInfo) }
    }
}
#endif
