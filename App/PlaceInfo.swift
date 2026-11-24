import CoreLocation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// "About this place": right-click the map on a Mac, or press and hold on iPhone and iPad, to see the state,
// county, township, city or town, and nearby roads at that spot — from the Census Bureau online, or from
// imported boundary and road files when offline.

/** A spot on the map the user asked about. */
struct PlaceQuery: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

/** What's known about a spot. */
struct PlaceInfo {
    var state: String?
    var county: String?
    var township: String?
    var place: String?
    var roads: [String] = []
    var source: String
}

enum PlaceLookup {
    /** Census layers in TIGERweb's tigerWMS_Current service. */
    private static let stateLayer = 80, countyLayer = 82, townshipLayer = 22, cityLayer = 28, cdpLayer = 30

    static func lookup(_ c: CLLocationCoordinate2D) async -> PlaceInfo {
        let source = ReferenceSource(rawValue: UserDefaults.standard.string(forKey: "refSource") ?? "") ?? .online
        if source != .imported, let online = await online(c) { return online }
        return ReferenceStore.shared.place(at: c)
    }

    private static func online(_ c: CLLocationCoordinate2D) async -> PlaceInfo? {
        let point = String(format: "%.6f,%.6f", c.longitude, c.latitude)
        let dLat = 150.0 / 111_320, dLon = dLat / max(0.2, cos(c.latitude * .pi / 180))
        let box = String(format: "%.6f,%.6f,%.6f,%.6f", c.longitude - dLon, c.latitude - dLat, c.longitude + dLon, c.latitude + dLat)
        async let state = query("tigerWMS_Current", stateLayer, point, "esriGeometryPoint", "NAME,STUSAB")
        async let county = query("tigerWMS_Current", countyLayer, point, "esriGeometryPoint", "NAME")
        async let township = query("tigerWMS_Current", townshipLayer, point, "esriGeometryPoint", "NAME")
        async let city = query("tigerWMS_Current", cityLayer, point, "esriGeometryPoint", "NAME")
        async let cdp = query("tigerWMS_Current", cdpLayer, point, "esriGeometryPoint", "NAME")
        async let primary = query("Transportation", 2, box, "esriGeometryEnvelope", "NAME,RTTYP")
        async let secondary = query("Transportation", 6, box, "esriGeometryEnvelope", "NAME,RTTYP")
        async let local = query("Transportation", 8, box, "esriGeometryEnvelope", "NAME,RTTYP")
        let results = await (state, county, township, city, cdp, primary, secondary, local)
        guard let states = results.0 else { return nil } // no answer at all: offline
        var info = PlaceInfo(source: "U.S. Census Bureau (TIGERweb)")
        if let s = states.first, let name = s["NAME"] as? String {
            info.state = (s["STUSAB"] as? String).map { "\(name) (\($0))" } ?? name
        }
        info.county = results.1?.first?["NAME"] as? String
        info.township = results.2?.first?["NAME"] as? String
        info.place = (results.3?.first ?? results.4?.first)?["NAME"] as? String
        let roads = (results.5 ?? []) + (results.6 ?? []) + (results.7 ?? [])
        info.roads = rankRoads(roads.compactMap { r in (r["NAME"] as? String).map { ($0, r["RTTYP"] as? String ?? "") } })
        return info
    }

    /** Route roads first (Interstate, US, State, County), then streets; no repeats; at most eight. */
    static func rankRoads(_ roads: [(name: String, type: String)]) -> [String] {
        let order = ["I": 0, "U": 1, "S": 2, "C": 3]
        var seen = Set<String>()
        return roads.filter { !$0.name.isEmpty }
            .sorted { (order[$0.type] ?? 9, $0.name) < (order[$1.type] ?? 9, $1.name) }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .prefix(8).map(\.name)
    }

    private static func query(_ service: String, _ layer: Int, _ geometry: String, _ type: String, _ fields: String) async -> [[String: Any]]? {
        var parts = URLComponents(string: TigerTiles.service + service + "/MapServer/\(layer)/query")!
        parts.queryItems = [
            URLQueryItem(name: "geometry", value: geometry), URLQueryItem(name: "geometryType", value: type),
            URLQueryItem(name: "inSR", value: "4326"), URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: fields), URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json"),
        ]
        var request = URLRequest(url: parts.url!, timeoutInterval: 12)
        request.setValue("APRSERJi (+https://github.com/kj4dxk/APRSERJi)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return nil }
        return features.compactMap { $0["attributes"] as? [String: Any] }
    }

    /** 41°31.500′ N, 88°04.902′ W */
    static func degreesMinutes(_ c: CLLocationCoordinate2D) -> String {
        func part(_ v: Double, _ pos: String, _ neg: String, _ width: Int) -> String {
            let a = abs(v), d = Int(a), m = (a - Double(d)) * 60
            return String(format: "%0\(width)ld°%06.3f′ %@", d, m, v >= 0 ? pos : neg)
        }
        return part(c.latitude, "N", "S", 2) + ", " + part(c.longitude, "E", "W", 3)
    }
}

/** The "About this place" panel. */
struct PlaceInfoView: View {
    let query: PlaceQuery
    @State private var info: PlaceInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("About this place", systemImage: "mappin.and.ellipse").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if let info {
                    row("State", info.state)
                    row("County", info.county)
                    row("Township", info.township)
                    row("City or town", info.place)
                    if !info.roads.isEmpty { row("Roads nearby", info.roads.joined(separator: "\n")) }
                } else {
                    GridRow { ProgressView().controlSize(.small); Text("Looking up…").foregroundStyle(.secondary) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Coordinates", String(format: "%.5f, %.5f", query.coordinate.latitude, query.coordinate.longitude))
                row("", PlaceLookup.degreesMinutes(query.coordinate))
                row("Grid square", Geo.grid(query.coordinate))
            }
            .textSelection(.enabled)
            if let info {
                Text(info.state == nil && info.county == nil && info.roads.isEmpty
                     ? "No boundary or road names found here. When offline, names come from boundary and road files imported in Setup."
                     : "From \(info.source).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy coordinates") {
                    copy(String(format: "%.5f, %.5f", query.coordinate.latitude, query.coordinate.longitude))
                }
                if let info {
                    Button("Copy all") { copy(summary(info)) }
                }
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .task { info = await PlaceLookup.lookup(query.coordinate) }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value)
            }
        }
    }

    private func summary(_ info: PlaceInfo) -> String {
        [("State", info.state), ("County", info.county), ("Township", info.township), ("City or town", info.place),
         ("Roads nearby", info.roads.isEmpty ? nil : info.roads.joined(separator: ", ")),
         ("Coordinates", String(format: "%.5f, %.5f (%@)", query.coordinate.latitude, query.coordinate.longitude,
                                PlaceLookup.degreesMinutes(query.coordinate))),
         ("Grid square", Geo.grid(query.coordinate))]
            .compactMap { label, value in value.map { "\(label): \($0)" } }
            .joined(separator: "\n")
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
