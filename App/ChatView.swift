import AprsCore
import CoreLocation
import SwiftUI

struct ChatView: View {
    let core: AppleAprs
    let account: String
    let revision: Int64
    let transportError: String?
    @Binding var recipient: String
    var myPosition: CLLocationCoordinate2D? = nil
    @State private var draft = ""
    @State private var route = "best"
    @State private var requestAck = true
    @State private var rows: [ChatRow] = []
    @State private var peers: [String] = []
    @State private var problem: String?
    @State private var sending = false

    private struct Conversation: Equatable {
        let account: String
        let peer: String
        let revision: Int64
    }

    private var peer: String { normalizedCallsign(recipient) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Recipient callsign", text: $recipient)
                    .textFieldStyle(.roundedBorder)
                if !peers.isEmpty {
                    Menu("Conversations") {
                        ForEach(peers, id: \.self) { callsign in
                            Button(callsign) { recipient = callsign }
                        }
                    }
                }
                if !peer.isEmpty {
                    Menu {
                        Picker("Send via", selection: $route) {
                            Text("Best route").tag("best")
                            Text("Radio only").tag("rf")
                            Text("APRS-IS only").tag("is")
                        }
                        Toggle("Ask for acknowledgment", isOn: $requestAck)
                    } label: {
                        Label(route == "rf" ? "RF" : route == "is" ? "APRS-IS" : "Best", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .fixedSize()
                    .help("How messages to \(peer) are sent")
                    .onChange(of: route) { _, _ in saveOptions() }
                    .onChange(of: requestAck) { _, _ in saveOptions() }
                }
            }

            List(rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.outgoing ? "You" : row.peer).font(.caption.bold())
                    Text(row.body)
                    if row.outgoing {
                        HStack {
                            Text(deliveryLabel(row.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if row.status == "NO_ACK" || row.status == "REJECTED" {
                                Button("Retry") { Task { try? await core.retry(account: account, row: row.id) } }
                                    .font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            HStack {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button("Queue", action: enqueue)
                    .disabled(sending || draft.isEmpty)
                if let me = myPosition {
                    Button {
                        draft = "My position: " + String(format: "%.4f %.4f", me.latitude, me.longitude) + " " + Geo.grid(me)
                    } label: { Image(systemName: "location.circle") }
                    .help("Share my position")
                }
            }
            Text(draft.count > 67 ? "\(draft.count)/300 · sent in \((draft.count + 60) / 61) numbered parts" : "\(draft.count)/67")
                .font(.caption2).foregroundStyle(draft.count > 300 ? .red : .secondary)
            if let message = problem ?? transportError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .onChange(of: account) { _, _ in
            peers = []
            rows = []
            problem = nil
            draft = ""
        }
        .onChange(of: peer) { _, _ in
            rows = []
            problem = nil
        }
        .task(id: Conversation(account: account, peer: peer, revision: revision)) {
            do {
                let selected = peer
                let conversations = try await core.conversations(account: account)
                let messages = selected.isEmpty ? [] : try await core.messages(account: account, peer: selected)
                guard !Task.isCancelled else { return }
                peers = conversations
                rows = messages
                if !selected.isEmpty, let options = try? await core.conversationOptions(account: account, peer: selected) {
                    if route != options.route { route = options.route }
                    if requestAck != options.requestAck { requestAck = options.requestAck }
                    try? await core.markRead(account: account, peer: selected)
                }
                if selected.isEmpty, let first = conversations.first {
                    recipient = first
                }
            } catch {
                if !Task.isCancelled { problem = "Unable to load chat history." }
            }
        }
    }

    private func enqueue() {
        let destination = peer
        let body = draft
        guard AprsProtocol.shared.validCallsign(value: account),
              AprsProtocol.shared.validCallsign(value: destination),
              account != destination else {
            problem = "Enter your callsign and a different recipient callsign."
            return
        }
        guard AprsMessages.shared.validLongText(text: body) else {
            problem = "Enter up to 300 printable APRS characters. Exclude {, | and ~."
            return
        }
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            do {
                try await core.enqueue(account: account, peer: destination, body: body)
                if draft == body { draft = "" }
            } catch {
                problem = "Unable to save the message."
            }
        }
    }

    private func saveOptions() {
        let destination = peer
        guard AprsProtocol.shared.validCallsign(value: account), !destination.isEmpty else { return }
        Task { _ = try? await core.saveConversationOptions(account: account, peer: destination, route: route, requestAck: requestAck) }
    }

    private func deliveryLabel(_ status: String) -> String {
        switch status {
        case "QUEUED": return "Queued"
        case "SENDING": return "Sending"
        case "WAITING": return "Waiting for acknowledgment"
        case "ACKNOWLEDGED": return "Acknowledged"
        case "REJECTED": return "Rejected"
        case "NO_ACK": return "No acknowledgment"
        case "SENT": return "Sent (no acknowledgment requested)"
        default: return status
        }
    }
}

func normalizedCallsign(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}
