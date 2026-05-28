import SwiftUI

@main
struct QuickCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI binds ⌘, to this scene automatically. The menu bar's
        // "Settings…" item (and our App-menu item in AppDelegate) still go
        // through SettingsWindowController — that's a regular NSWindow which
        // is more reliable than the Settings scene for LSUIElement apps in
        // some edge cases (e.g. when no window is foreground).
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}
