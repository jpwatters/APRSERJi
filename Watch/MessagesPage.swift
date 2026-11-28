import SwiftUI

struct MessagesPage: View {
    @EnvironmentObject var store: WatchStore
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let snapshot = store.snapshot {
                    List {
                        if snapshot.conversations.isEmpty {
                            Text("No messages yet").foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.conversations) { conversation in
                            NavigationLink(value: conversation.peer) {
                                ConversationRow(conversation: conversation)
                            }
                        }
                        NavigationLink(value: "") {
                            Label("New message", systemImage: "square.and.pencil")
                        }
                        .disabled(!snapshot.canSend)
                    }
                    .navigationDestination(for: String.self) { peer in
                        if peer.isEmpty { NewMessageView() } else { ConversationView(peer: peer) }
                    }
                } else {
                    WaitingForPhone()
                }
            }
            .navigationTitle("Messages")
        }
        .onReceive(WatchTourDirector.shared.$step) { step in
            if let step { path = step.messagesPath }
        }
    }
}

private struct ConversationRow: View {
    let conversation: WatchSnapshot.Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(conversation.peer).font(.headline)
                if conversation.unread > 0 {
                    Text("\(conversation.unread)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .background(.blue, in: Capsule())
                }
            }
            if let last = conversation.messages.last {
                Text((last.outgoing ? "You: " : "") + last.body)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Text(ageText(last.time)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject var store: WatchStore
    let peer: String
    @State private var replying = false

    private var conversation: WatchSnapshot.Conversation? {
        store.snapshot?.conversations.first { $0.peer == peer }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(conversation?.messages ?? []) { message in
                    VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
                        Text(message.body)
                        Text(message.outgoing
                             ? "\(WatchSnapshot.deliveryText(message.status)) · \(ageText(message.time))"
                             : ageText(message.time))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
                    .listRowBackground(message.outgoing ? Color.blue.opacity(0.25) : Color.gray.opacity(0.2))
                    .id(message.id)
                }
                Button {
                    replying = true
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .disabled(!(store.snapshot?.canSend ?? false))
                .id("reply")
            }
            .onAppear {
                proxy.scrollTo("reply", anchor: .bottom)
                if (conversation?.unread ?? 0) > 0 { store.send(.markRead(peer: peer)) }
            }
        }
        .navigationTitle(peer)
        .sheet(isPresented: $replying) { ReplyView(peer: peer) }
        .onReceive(WatchTourDirector.shared.$step) { step in
            if let step { replying = step.reply }
        }
    }
}

/** Canned replies, or dictate / scribble / type a reply. */
struct ReplyView: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss
    let peer: String
    @State private var text = ""

    static let canned = ["OK", "Yes", "No", "QSL, thanks", "On my way", "Running late", "Call me",
                         "Can't talk now", "Where are you?", "73"]

    var body: some View {
        List {
            Section {
                TextField("Dictate or type", text: $text)
                    .onSubmit { send(text) }
                if !text.isEmpty {
                    Button("Send") { send(text) }
                    if text.count > 67 { Text("\(text.count) characters, sent in parts").font(.caption2) }
                }
            }
            Section("Quick replies") {
                ForEach(Self.canned, id: \.self) { reply in
                    Button(reply) { send(reply) }
                }
            }
        }
        .navigationTitle("To \(peer)")
    }

    private func send(_ body: String) {
        let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "~", with: "-")
        guard !message.isEmpty else { return }
        store.send(.send(to: peer, text: String(message.prefix(300))), note: "Sent to \(peer)")
        dismiss()
    }
}

/** Start a conversation: pick a callsign from nearby stations or dictate one. */
struct NewMessageView: View {
    @EnvironmentObject var store: WatchStore
    @State private var callsign = ""
    @State private var chosen: String?

    var body: some View {
        List {
            Section {
                TextField("Callsign", text: $callsign)
                    .textInputAutocapitalization(.characters)
                    .onSubmit { pick(callsign) }
            }
            Section("Nearby") {
                ForEach((store.snapshot?.stations ?? []).filter(\.canMessage)) { station in
                    Button {
                        pick(station.callsign)
                    } label: {
                        HStack {
                            Text(station.callsign)
                            Spacer()
                            Text(station.distanceText).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("New message")
        .sheet(item: Binding(get: { chosen.map(Peer.init) }, set: { chosen = $0?.id })) { peer in
            ReplyView(peer: peer.id)
        }
    }

    private func pick(_ value: String) {
        let call = value.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "")
        if !call.isEmpty { chosen = call }
    }

    private struct Peer: Identifiable { let id: String }
}
