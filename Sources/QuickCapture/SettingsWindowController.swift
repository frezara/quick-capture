import AppKit
import SwiftUI

final class SettingsWindowController {
    private let appState: AppState
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        if window == nil {
            let view = SettingsView().environmentObject(appState)
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Quick Capture Settings"
            // Resizable, and tall enough to show the content: it was pinned to
            // 360pt with no resize and no scroll, which put everything past the
            // third card out of reach (#116). Width stays fixed — the content
            // is laid out at 520 — so only the height gives.
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            let width: CGFloat = 520
            let ideal = min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
            w.setContentSize(NSSize(width: width, height: ideal))
            w.contentMinSize = NSSize(width: width, height: 320)
            w.contentMaxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
