import AppKit

/// Registry of open editor windows, keyed by file URL. Opening the same file
/// twice raises the existing window rather than creating a duplicate.
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()

    private var openWindows: [URL: EditorWindow] = [:]

    /// Opens `url` in the editor. Activates the app and brings the window
    /// forward; if a window for that file is already open, focuses it.
    /// Centers the window on the active screen each time (so opening always
    /// puts it where the user is looking).
    func open(_ url: URL) {
        if let existing = openWindows[url] {
            centerOnActiveScreen(existing)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = EditorWindow(fileURL: url)
        window.delegate = self
        openWindows[url] = window
        centerOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Places `window` in the middle of the screen the mouse is on (or the
    /// main screen as a fallback). Uses the screen's `visibleFrame` so the
    /// window doesn't end up underneath the menu bar or dock.
    private func centerOnActiveScreen(_ window: NSWindow) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - window.frame.width / 2
        let y = visible.midY - window.frame.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Prompt the user for a markdown file to open.
    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text, .plainText]
        panel.allowsOtherFileTypes = true   // .md isn't a registered system UTType by default
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open a markdown file"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? EditorWindow else { return }
        openWindows.removeValue(forKey: window.fileURL)
    }
}
