#if os(macOS)
import AppKit
import SwiftUI

/**
 * Keeps the Mac window's size and position across restarts, and remembers the size the window first opened at
 * so Reset Window Size can return to it.
 *
 * SwiftUI sizes and places a new window itself, and its window restoration can put back an old frame after the
 * window appears, so the app keeps the frame in its own setting ("mainWindowFrame"), turns restoration off for
 * this window, and reapplies the saved frame twice while the window settles. Nothing is saved until then, so the
 * small opening frame never replaces the saved one.
 */
enum MainWindow {
    static let frameKey = "mainWindowFrame"
    private static let defaultSizeKey = "defaultWindowSize"
    private static weak var window: NSWindow?
    private static var settled = false
    private static var observers: [NSObjectProtocol] = []

    static func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        settled = false
        window.isRestorable = false
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        observers = [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.willCloseNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { _ in save() }
        }
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let defaults = UserDefaults.standard
                // The first time this runs, the window is at SwiftUI's normal size: remember it for Reset.
                if defaults.string(forKey: defaultSizeKey) == nil {
                    defaults.set(NSStringFromSize(window.frame.size), forKey: defaultSizeKey)
                }
                if let saved = savedFrame(on: window), saved != window.frame {
                    window.setFrame(saved, display: true)
                }
                if delay >= 1.0 { settled = true }
            }
        }
    }

    /** The saved frame, kept on a screen that still exists. */
    private static func savedFrame(on window: NSWindow) -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let frame = NSRectFromString(text)
        guard frame.width >= 300, frame.height >= 300 else { return nil }
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let screen = screens.first(where: { $0.intersects(frame) }) ?? window.screen?.visibleFrame else { return frame }
        var fitted = frame
        fitted.size.width = min(frame.width, screen.width)
        fitted.size.height = min(frame.height, screen.height)
        fitted.origin.x = min(max(frame.minX, screen.minX), screen.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, screen.minY), screen.maxY - fitted.height)
        return fitted
    }

    static func save() {
        guard settled, let window, window.isVisible, !window.isMiniaturized else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
    }

    /** Back to the normal size, centered on the window's screen. */
    static func resetSize() {
        guard let window else { return }
        let saved = NSSizeFromString(UserDefaults.standard.string(forKey: defaultSizeKey) ?? "")
        let size = saved.width >= 300 && saved.height >= 300 ? saved : NSSize(width: 900, height: 700)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                           width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey)
    }
}

/** Reports the hosting NSWindow as soon as the view is placed in it. */
struct WindowAccessor: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.attach(window) }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

/** Saves the window frame when the app quits with ⌘Q, before windows are torn down. */
final class AppQuitSaver: NSObject {
    static let shared = AppQuitSaver()
    private var observer: NSObjectProtocol?

    func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { _ in MainWindow.save() }
    }
}
#endif
