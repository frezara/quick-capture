import SwiftUI

@main
struct QuickCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings UI is shown via SettingsWindowController (more reliable for
        // LSUIElement apps). This scene exists only to satisfy App.body.
        Settings { EmptyView() }
    }
}
