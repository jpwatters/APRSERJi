import AprsCore
import CoreLocation
import SwiftUI

/** Setup tab: beacon, radio, map layers, offline maps, callsign lookup, display and alerts. */
struct SetupView: View {
    let core: AppleAprs
    let mapCenter: CLLocationCoordinate2D
    @ObservedObject var gps: GPSTracker
    @AppStorage("useMetric") private var metric = false
    @AppStorage("notifyMessages") private var notify = true
    @AppStorage("layerTracks") private var tracks = true
    @AppStorage("layerCoverage") private var coverage = false
    @AppStorage("layerDeadReckoning") private var deadReckoning = true
    @AppStorage("layerRings") private var rings = false
    @AppStorage("ringSpacingMiles") private var ringSpacing = 10.0
    @AppStorage("ringCount") private var ringCount = 4
    @AppStorage("nwsEnabled") private var nws = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                BeaconSections(core: core, mapCenter: mapCenter, now: context.date, gps: gps)
                RadioSection(core: core)
                Section {
                    Toggle("Paths of travel", isOn: $tracks)
                    Toggle("Dead reckoning for moving stations", isOn: $deadReckoning)
                    Toggle("PHG coverage circles", isOn: $coverage)
                    Toggle("NWS warning areas", isOn: $nws)
                    Toggle("Range rings", isOn: $rings)
                    if rings {
                        Picker("Ring spacing", selection: $ringSpacing) {
                            ForEach([1.0, 2.0, 5.0, 10.0, 25.0, 50.0, 100.0], id: \.self) {
                                Text(Units.distance($0 * 1609.344, metric: metric)).tag($0)
                            }
                        }
                        Stepper("\(ringCount) rings", value: $ringCount, in: 1...10)
                    }
                } header: {
                    Text("Map layers")
                } footer: {
                    Text("Dead reckoning draws a dashed line to where a moving station should be now, from its last course and speed (up to 10 minutes). Range rings are centered on your GPS fix, or the map center when GPS is off.")
                }
                OfflineMapsSection()
                FCCDatabaseSection()
                Section("Display & alerts") {
                    Toggle("Metric units", isOn: $metric)
                    Toggle("Notify me of new messages", isOn: $notify)
                        .onChange(of: notify) { _, on in if on { MessageNotifier.shared.requestAuthorization() } }
                }
            }
            .formStyle(.grouped)
        }
    }
}
