import Foundation

/**
 What APRSERJi on the iPhone sends to the Apple Watch companion app, and the commands the Watch sends back.
 Shared by the iPhone and Watch targets. Kept small: WatchConnectivity's application context holds about 64 KB.
 */
struct WatchSnapshot: Codable, Equatable {
    struct Station: Codable, Equatable, Identifiable {
        var id: String { callsign }
        let callsign: String
        let latitude: Double
        let longitude: Double
        /** "station", "weather", "object" or "item". */
        let kind: String
        let comment: String
        let heard: Date
        /** Distance from my position, already in the iPhone's units ("2.4 mi"). */
        let distanceText: String
        let distanceMeters: Double
        /** True bearing from my position, 0–360°. */
        let bearing: Double
        let speedText: String?
        let canMessage: Bool
    }

    struct Message: Codable, Equatable, Identifiable {
        let id: Int64
        let outgoing: Bool
        let body: String
        let time: Date
        /** QUEUED, SENDING, WAITING, ACKNOWLEDGED, REJECTED, NO_ACK or SENT; empty for incoming. */
        let status: String
    }

    struct Conversation: Codable, Equatable, Identifiable {
        var id: String { peer }
        let peer: String
        let unread: Int
        /** Oldest first; the last few messages. */
        let messages: [Message]
    }

    var callsign = ""
    /** "Verified", "Receiving", "Connecting", "Reconnecting" or "Disconnected". */
    var connection = "Disconnected"
    var canSend = false
    var latitude: Double?
    var longitude: Double?
    var stations: [Station] = []
    var conversations: [Conversation] = []
    /** OFF, NOT_CONNECTED, NOT_VERIFIED, NO_POSITION, LOW_ACCURACY, SCHEDULED, WATCHING, TOO_SOON, SENT or FAILED. */
    var beaconState = "OFF"
    var lastBeacon: Date?
    var nextBeacon: Date?
    var sent = Date()

    static let contextKey = "snapshot"

    func encoded() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.contextKey: data]
    }

    init() {}

    init?(_ dictionary: [String: Any]) {
        guard let data = dictionary[Self.contextKey] as? Data,
              let value = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return nil }
        self = value
    }

    /** Plain words for [beaconState]. */
    static func beaconText(_ state: String) -> String {
        switch state {
        case "OFF": return "Beaconing is off"
        case "NOT_CONNECTED": return "Not connected"
        case "NOT_VERIFIED": return "Waiting for passcode check"
        case "NO_POSITION": return "No GPS position"
        case "LOW_ACCURACY": return "GPS not accurate enough"
        case "SCHEDULED": return "Scheduled"
        case "WATCHING": return "Watching movement"
        case "TOO_SOON": return "Too soon since last beacon"
        case "SENT": return "Beacon sent"
        case "FAILED": return "Last beacon failed"
        default: return state.capitalized
        }
    }

    static func deliveryText(_ status: String) -> String {
        switch status {
        case "QUEUED": return "Queued"
        case "SENDING": return "Sending"
        case "WAITING": return "Waiting for ack"
        case "ACKNOWLEDGED": return "Acked"
        case "REJECTED": return "Rejected"
        case "NO_ACK": return "No ack"
        case "SENT": return "Sent"
        default: return status.capitalized
        }
    }
}

/** A request from the Watch, carried in a WatchConnectivity message or user-info transfer. */
enum WatchCommand {
    static let key = "command"

    case beaconNow
    case send(to: String, text: String)
    case markRead(peer: String)
    case refresh

    var dictionary: [String: Any] {
        switch self {
        case .beaconNow: return [Self.key: "beacon"]
        case .send(let to, let text): return [Self.key: "send", "to": to, "text": text]
        case .markRead(let peer): return [Self.key: "read", "peer": peer]
        case .refresh: return [Self.key: "refresh"]
        }
    }

    init?(_ dictionary: [String: Any]) {
        switch dictionary[Self.key] as? String {
        case "beacon": self = .beaconNow
        case "send":
            guard let to = dictionary["to"] as? String, let text = dictionary["text"] as? String else { return nil }
            self = .send(to: to, text: text)
        case "read":
            guard let peer = dictionary["peer"] as? String else { return nil }
            self = .markRead(peer: peer)
        case "refresh": self = .refresh
        default: return nil
        }
    }
}
