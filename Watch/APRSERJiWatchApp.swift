import SwiftUI

@main
struct APRSERJiWatchApp: App {
    @StateObject private var store = WatchStore()
    /** 0 Messages, 1 Nearby, 2 Map, 3 Beacon. -1 and 4 are copies of Beacon and Messages at the ends, so the
        pages go round in a circle: past Beacon comes Messages, and before Messages comes Beacon. */
    @State private var page = 0
    private static let count = 4

    var body: some Scene {
        WindowGroup {
            TabView(selection: $page) {
                BeaconPage().tag(-1)
                MessagesPage().tag(0)
                StationsPage().tag(1)
                MapPage(visible: page == 2).tag(2)
                BeaconPage().tag(3)
                MessagesPage().tag(Self.count)
            }
            .tabViewStyle(.verticalPage)
            .overlay(alignment: .trailing) { PageEdge(turn: turn) }
            .onChange(of: page) { _, new in wrapAround(new) }
            .environmentObject(store)
            .onAppear { WatchTourDirector.shared.start() }
            .onReceive(WatchTourDirector.shared.$step) { step in
                if let step { page = step.page }
            }
        }
    }

    /** Next (+1) or previous (−1) page from the right-edge strip, going round at the ends. */
    private func turn(_ step: Int) {
        guard (0..<Self.count).contains(page) else { return }
        withAnimation { page += step }
    }

    /** Landing on an end copy jumps, without animation, to the real page it shows. */
    private func wrapAround(_ new: Int) {
        guard new < 0 || new >= Self.count else { return }
        let target = new < 0 ? Self.count - 1 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard page == new else { return }
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { page = target }
        }
    }
}

/**
 A strip along the right edge of every page: swipe up on it for the next page and down for the previous one,
 wherever a list is scrolled to and even on the map.
 */
struct PageEdge: View {
    let turn: (Int) -> Void

    var body: some View {
        Color.clear
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Capsule().fill(.white.opacity(0.45)).frame(width: 4, height: 44).padding(.trailing, 3)
            }
            .gesture(
                DragGesture(minimumDistance: 8).onEnded { drag in
                    if drag.translation.height < -20 { turn(1) } else if drag.translation.height > 20 { turn(-1) }
                }
            )
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("Change page")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: turn(1)
                case .decrement: turn(-1)
                @unknown default: break
                }
            }
    }
}

/** Shown until the first snapshot arrives from the iPhone. */
struct WaitingForPhone: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right").font(.title2)
            Text("Open APRSERJi on your iPhone").multilineTextAlignment(.center)
            Text(store.phoneReachable ? "Waiting for data…" : "iPhone not in reach")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/** "5m ago" style age. */
func ageText(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86_400)d ago"
}

func compassText(_ degrees: Double) -> String {
    let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return points[Int((degrees.truncatingRemainder(dividingBy: 360) + 360 + 11.25) / 22.5) % 16]
}

func kindIcon(_ kind: String) -> String {
    switch kind {
    case "weather": return "cloud.sun"
    case "object", "item": return "mappin"
    default: return "antenna.radiowaves.left.and.right"
    }
}
