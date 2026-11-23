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
    let onWhoIs: () -> Void
    let onClose: () -> Void

    private var metric: Bool { UserDefaults.standard.bool(forKey: "useMetric") }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StationBadge(station: station).scaleEffect(0.75).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(station.callsign).font(.headline.monospaced()).foregroundStyle(Color.accentColor)
                        Text("\(station.kindLabel) · \(station.symbolInfo.name)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(action: onClose) { Image(systemName: "xmark").font(.caption.bold()) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Close")
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
                if let coverage = station.coverageMeters?.doubleValue {
                    Text("PHG coverage \(Units.distance(coverage, metric: metric))").font(.caption)
                }
                if station.hasTelemetry {
                    Text("Telemetry available in details").font(.caption).foregroundStyle(.secondary)
                }
                if !station.path.isEmpty {
                    Text("[\(station.heardOnRadio ? "RF" : "APRS") via \(station.path)]").font(.caption2).foregroundStyle(.secondary)
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
                    Text("·").foregroundStyle(.secondary)
                    Button("who-is", action: onWhoIs)
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

/** The bubble's shape: a rounded card with a small pointer toward the station. */
struct CalloutBubble<Content: View>: View {
    let pointsDown: Bool
    /** Horizontal offset of the pointer from the bubble's center, so it still aims at the marker near an edge. */
    let pointerOffset: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !pointsDown { pointer.rotationEffect(.degrees(180)) }
            content
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
            if pointsDown { pointer }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private var pointer: some View {
        Triangle().fill(.background).frame(width: 18, height: 9).offset(x: pointerOffset)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
