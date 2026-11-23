#if os(macOS)
import AppKit
import SwiftUI

/**
 * Keeps the Mac window's size and position across restarts (AppKit frame autosave), and remembers the size the
 * window first opened at so Reset Window Size can return to it.
 */
enum MainWindow {
    static let autosaveName = "APRSERJiMainWindow"
    private static let defaultSizeKey = "defaultWindowSize"
    private static weak var window: NSWindow?

    static func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        let defaults = UserDefaults.standard
        // The first time the app runs with this feature, the window is at its normal size: remember it.
        if defaults.string(forKey: defaultSizeKey) == nil {
            defaults.set(NSStringFromSize(window.frame.size), forKey: defaultSizeKey)
        }
        window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
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

/** Finds the hosting NSWindow once the view is on screen. */
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { MainWindow.attach(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { MainWindow.attach(window) }
    }
}
#endif
