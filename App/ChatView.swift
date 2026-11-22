import AprsCore
import SwiftUI

struct ChatView: View {
    let core: AppleAprs
    let account: String
    let revision: Int64
    let transportError: String?
    @Binding var recipient: String
    @State private var draft = ""
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
            }

            List(rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.outgoing ? "You" : row.peer).font(.caption.bold())
                    Text(row.body)
                    if row.outgoing {
                        Text(deliveryLabel(row.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button("Queue", action: enqueue)
                    .disabled(sending || draft.isEmpty)
            }
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

    private func deliveryLabel(_ status: String) -> String {
        switch status {
        case "QUEUED": return "Queued"
        case "SENDING": return "Sending"
        case "WAITING": return "Waiting for acknowledgment"
        case "ACKNOWLEDGED": return "Acknowledged"
        case "REJECTED": return "Rejected"
        case "NO_ACK": return "No acknowledgment"
        default: return status
        }
    }
}

func normalizedCallsign(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}
