import AprsCore
import CoreLocation
import SwiftUI

/** The contents of the bubble shown when a station is clicked on the map. */
struct StationCallout: View {
    let station: StationDetail
    let origin: CLLocationCoordinate2D
    let originLabel: String
    let onZoom: () -> Void
    let onDetails: () -> Void
    let onMessage: () -> Void

    private var metric: Bool { UserDefaults.standard.bool(forKey: "useMetric") }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StationBadge(station: station).scaleEffect(0.75).frame(width: 24, height: 24)
                    Text("\(station.kindLabel) · \(station.symbolInfo.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Rectangle().fill(station.tint.opacity(0.6)).frame(height: 2)
                Text("\(station.heardAt.formatted(date: .numeric, time: .standard)) (\(Units.age(station.heardAt, now: context.date)))")
                    .font(.callout)
                if !station.comment.isEmpty {
                    Text(station.comment).font(.callout.italic()).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(detailLines, id: \.self) { line in
                    Text(line).font(.caption)
                }
                if let owner = station.owner {
                    Text("Owner \(owner)").font(.caption)
                }
                if !station.path.isEmpty {
                    Text("[APRS via \(station.path)]").font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(Units.distance(Geo.distance(origin, station.coordinate), metric: metric)) \(Units.compass(Geo.bearing(from: origin, to: station.coordinate))) of \(originLabel) · \(Geo.grid(station.coordinate))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Button("zoom", action: onZoom)
                    Text("·").foregroundStyle(.secondary)
                    Button("details", action: onDetails)
                    if station.canMessage {
                        Text("·").foregroundStyle(.secondary)
                        Button("message", action: onMessage)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.callout)
                .padding(.top, 2)
            }
            .frame(width: 250, alignment: .leading)
        }
    }

    private var detailLines: [String] {
        var lines: [String] = []
        if station.hasWeather {
            var parts: [String] = []
            if let t = station.temperatureC?.doubleValue { parts.append(Units.temperature(t, metric: metric)) }
            if let h = station.humidity?.intValue { parts.append("\(h)% RH") }
            if let p = station.pressureHpa?.doubleValue { parts.append(Units.pressure(p, metric: metric)) }
            if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
            if let wind = station.windKph?.doubleValue {
                let from = station.windDegrees.map { " from \(Units.compass(Double($0.intValue)))" } ?? ""
                let gust = (station.gustKph?.doubleValue).map { ", gusts \(Units.speed(kph: $0, metric: metric))" } ?? ""
                lines.append("Wind \(Units.speed(kph: wind, metric: metric))\(from)\(gust)")
            }
            if let rain = station.rainDayMm?.doubleValue ?? station.rainMidnightMm?.doubleValue {
                lines.append("Rain \(Units.rain(rain, metric: metric)) today")
            }
        }
        var motion: [String] = []
        if let knots = station.speedKnots?.doubleValue, knots >= 1 { motion.append(Units.speed(knots: knots, metric: metric)) }
        if let course = station.courseDegrees?.doubleValue, (station.speedKnots?.doubleValue ?? 0) >= 1 {
            motion.append("heading \(Units.compass(course))")
        }
        if let altitude = station.altitudeMeters?.doubleValue { motion.append("alt \(Units.altitude(altitude, metric: metric))") }
        if !motion.isEmpty { lines.append(motion.joined(separator: " · ")) }
        return lines
    }
}

/** Hosts the SwiftUI bubble inside MapKit's native callout and lets it be refreshed in place. */
#if os(macOS)
import AppKit

final class CalloutHost {
    private let host: NSHostingView<StationCallout>
    init(_ content: StationCallout) { host = NSHostingView(rootView: content) }
    var view: NSView { host }
    func update(_ content: StationCallout) { host.rootView = content }
}
#else
import UIKit

final class CalloutHost {
    private let controller: UIHostingController<StationCallout>
    init(_ content: StationCallout) {
        controller = UIHostingController(rootView: content)
        controller.sizingOptions = .intrinsicContentSize
        controller.view.backgroundColor = .clear
    }
    var view: UIView { controller.view }
    func update(_ content: StationCallout) {
        controller.rootView = content
        controller.view.invalidateIntrinsicContentSize()
    }
}
#endif
