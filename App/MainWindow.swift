#if os(macOS)
import AppKit
import SwiftUI

/**
 * Keeps the Mac window's size and position across restarts (AppKit frame autosave), and remembers the size the
 * window first opened at so Reset Window Size can return to it.
 *
 * SwiftUI sizes and places a new window itself just after creating it, so the saved frame is applied a moment
 * later, once SwiftUI has finished, and the autosave name is set only then — SwiftUI's initial small frame is
 * never written over the saved one.
 */
enum MainWindow {
    static let autosaveName = "APRSERJiMainWindow"
    private static let defaultSizeKey = "defaultWindowSize"
    private static weak var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let defaults = UserDefaults.standard
            // The first time this runs, the window is at SwiftUI's normal size: remember it for Reset.
            if defaults.string(forKey: defaultSizeKey) == nil {
                defaults.set(NSStringFromSize(window.frame.size), forKey: defaultSizeKey)
            }
            window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
        }
        // Belt and braces: save once more as the window closes or the app quits.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { _ in
            window.saveFrame(usingName: autosaveName)
        }
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
        window.saveFrame(usingName: autosaveName)
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
                                                          queue: .main) { _ in
            for window in NSApp.windows where window.frameAutosaveName == MainWindow.autosaveName {
                window.saveFrame(usingName: MainWindow.autosaveName)
            }
        }
    }
}
#endif
