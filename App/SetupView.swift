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
    @AppStorage("layerLabels") private var labels: StationLabels = .callsign
    @AppStorage("layerDF") private var df = true
    @AppStorage("layerHorizons") private var horizons = false
    @AppStorage("layerAmbiguity") private var ambiguity = true
    @AppStorage("layerShapes") private var shapes = true
    @AppStorage("radarOpacity") private var radar = 0.0
    @AppStorage("layerPathsRF") private var pathsRF = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                BeaconSections(core: core, mapCenter: mapCenter, now: context.date, gps: gps)
                StatusTelemetrySections(core: core)
                PortsSection(core: core)
                #if os(macOS)
                GpsSourceSection(core: core)
                #endif
                CatRigSection()
                WeatherStationSections(core: core)
                ServicesSections(core: core)
                Section {
                    Toggle("Paths of travel", isOn: $tracks)
                    Toggle("Dead reckoning for moving stations", isOn: $deadReckoning)
                    Toggle("PHG coverage circles", isOn: $coverage)
                    Toggle("NWS warning areas", isOn: $nws)
                    Picker("Station labels", selection: $labels) {
                        ForEach(StationLabels.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Packet paths for stations heard on RF", isOn: $pathsRF)
                    Toggle("Direction finding beams", isOn: $df)
                    Toggle("Radio horizon for aircraft and balloons", isOn: $horizons)
                    Toggle("Ambiguous positions as shaded areas", isOn: $ambiguity)
                    Toggle("Lines and areas from multiline objects", isOn: $shapes)
                    HStack {
                        Text("Weather radar")
                        Slider(value: $radar, in: 0...0.9, step: 0.1)
                        Text(radar == 0 ? "Off" : "\(Int(radar * 100))%").monospacedDigit().frame(width: 44)
                    }
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
                    Text("Dead reckoning draws a dashed line to where a moving station should be now, from its last course and speed (up to 10 minutes). Range rings are centered on your GPS fix, or the map center when GPS is off. Weather radar is the NEXRAD composite from Iowa Environmental Mesonet (USA).")
                }
                ReferenceLayersSection()
                OfflineMapsSection()
                TrackLogSection()
                WatchAlertSection()
                FCCDatabaseSection()
                Section("Display & alerts") {
                    Toggle("Metric units", isOn: $metric)
                    Toggle("Notify me of new messages", isOn: $notify)
                        .onChange(of: notify) { _, on in if on { MessageNotifier.shared.requestAuthorization() } }
                    #if os(macOS)
                    Button("Reset window size") { MainWindow.resetSize() }
                        .help("Return the window to its normal size, centered — or press ⌥⌘0 (Window ▸ Reset Window Size) anytime.")
                    #endif
                }
            }
            .formStyle(.grouped)
        }
    }
}
