import SwiftUI

struct StationsPage: View {
    @EnvironmentObject var store: WatchStore
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let snapshot = store.snapshot {
                    if snapshot.latitude == nil {
                        Text("No position on the iPhone yet").foregroundStyle(.secondary)
                    } else if snapshot.stations.isEmpty {
                        Text("No stations heard nearby").foregroundStyle(.secondary)
                    } else {
                        List(snapshot.stations) { station in
                            NavigationLink(value: station.callsign) { StationRow(station: station) }
                        }
                        .navigationDestination(for: String.self) { call in
                            if let station = snapshot.stations.first(where: { $0.callsign == call }) {
                                StationDetailPage(station: station)
                            }
                        }
                    }
                } else {
                    WaitingForPhone()
                }
            }
            .navigationTitle("Nearby")
        }
        .onReceive(WatchTourDirector.shared.$step) { step in
            if let step { path = step.stationsPath }
        }
    }
}

private struct StationRow: View {
    let station: WatchSnapshot.Station

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.north.fill")
                .rotationEffect(.degrees(station.bearing))
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: kindIcon(station.kind)).font(.caption2)
                    Text(station.callsign).font(.headline).lineLimit(1)
                }
                Text("\(station.distanceText) \(compassText(station.bearing)) · \(ageText(station.heard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct StationDetailPage: View {
    @EnvironmentObject var store: WatchStore
    let station: WatchSnapshot.Station
    @State private var messaging = false

    var body: some View {
        List {
            HStack {
                Image(systemName: "location.north.fill")
                    .font(.title)
                    .rotationEffect(.degrees(station.bearing))
                    .foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(station.distanceText).font(.title3)
                    Text("\(compassText(station.bearing)) \(Int(station.bearing.rounded()))°")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let speed = station.speedText { LabeledContent("Speed", value: speed) }
            LabeledContent("Heard", value: ageText(station.heard))
            if !station.comment.isEmpty { Text(station.comment).font(.footnote) }
            if station.canMessage {
                Button {
                    messaging = true
                } label: {
                    Label("Message", systemImage: "message")
                }
                .disabled(!(store.snapshot?.canSend ?? false))
            }
        }
        .navigationTitle(station.callsign)
        .sheet(isPresented: $messaging) { ReplyView(peer: station.callsign) }
    }
}
