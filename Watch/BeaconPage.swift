import SwiftUI

struct BeaconPage: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        if let snapshot = store.snapshot {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                List {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.callsign.isEmpty ? "No callsign" : snapshot.callsign).font(.headline)
                        Label(snapshot.connection, systemImage: "circle.fill")
                            .font(.footnote)
                            .foregroundStyle(snapshot.connection == "Verified" || snapshot.connection == "Receiving" ? .green : .orange)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WatchSnapshot.beaconText(snapshot.beaconState))
                        if let last = snapshot.lastBeacon {
                            Text("Last: \(ageText(last, now: context.date))").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let next = snapshot.nextBeacon, next > context.date {
                            Text("Next: \(next.formatted(date: .omitted, time: .shortened))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        store.send(.beaconNow, note: "Beacon requested")
                    } label: {
                        Label("Beacon now", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(snapshot.beaconState == "NOT_CONNECTED" || snapshot.beaconState == "NOT_VERIFIED")
                    if let note = store.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Updated \(ageText(snapshot.sent, now: context.date))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Beacon")
        } else {
            WaitingForPhone()
        }
    }
}
