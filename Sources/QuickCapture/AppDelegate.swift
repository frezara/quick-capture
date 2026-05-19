import AppKit
import HotKey
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem!
    private var capturePanel: CapturePanel?
    private var hotKey: HotKey?
    private lazy var settingsController = SettingsWindowController(appState: appState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true   // honors the asset's template intent on all paths
            image?.accessibilityDescription = "Quick Capture"
            button.image = image
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()

        let captureItem = NSMenuItem(title: "Capture…",
                                     action: #selector(showCapture),
                                     keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let launchItem = NSMenuItem(title: "Launch at Login",
                                    action: #selector(toggleLaunchAtLogin),
                                    keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Quick Capture",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Hotkey

    private func setupHotKey() {
        rebindHotKey()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebindHotKey),
            name: .hotKeyDidChange,
            object: nil
        )
    }

    @objc private func rebindHotKey() {
        hotKey = nil
        guard let key = appState.hotKey.key else { return }
        let combo = HotKey(key: key, modifiers: appState.hotKey.modifierFlags)
        combo.keyDownHandler = { [weak self] in self?.toggleCapture() }
        hotKey = combo
    }

    // MARK: - Capture panel

    @objc func toggleCapture() {
        if capturePanel?.isVisible == true {
            hideCapture()
        } else {
            showCapture()
        }
    }

    @objc func showCapture() {
        appState.refreshRecentTags()
        if capturePanel == nil {
            capturePanel = CapturePanel(
                appState: appState,
                onSubmit: { [weak self] text, tag in self?.handleCapture(text, tag: tag) },
                onDismiss: { [weak self] in self?.hideCapture() }
            )
        }
        capturePanel?.show()
    }

    func hideCapture() {
        capturePanel?.orderOut(nil)
        // Tells CaptureView to clear its input state — fresh slate next time.
        NotificationCenter.default.post(name: .capturePanelDidHide, object: nil)
    }

    private func handleCapture(_ text: String, tag: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if tag?.lowercased() == "cal" {
            handleCalendarCapture(trimmed)
            return
        }

        do {
            try FileWriter.appendTodo(
                trimmed,
                tag: tag,
                to: appState.captureFileURL,
                includeTimestamp: appState.includeTimestamp
            )
            hideCapture()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// `#cal` branch: parse the text as a calendar event, hand the resulting
    /// `.ics` to the default handler (Calendar.app shows its own confirmation
    /// sheet). The markdown todo file is NOT touched for these captures.
    private func handleCalendarCapture(_ text: String) {
        switch EventParser.parse(text) {
        case .success(let event):
            do {
                let url = try ICSWriter.writeTempFile(for: event)
                NSWorkspace.shared.open(url)
                hideCapture()
            } catch {
                showCalendarError(message: "Couldn't create calendar event",
                                  detail: error.localizedDescription)
            }
        case .failure(let error):
            showCalendarError(message: "Couldn't create calendar event",
                              detail: error.localizedDescription)
        }
    }

    private func showCalendarError(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Settings

    @objc func showSettings() {
        settingsController.show()
    }

    // MARK: - Launch at login

    /// Toggles whether the app auto-starts on user login. Uses SMAppService
    /// (modern replacement for the legacy LSSharedFileList API). The app must
    /// live in /Applications for the system to honor this registration.
    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update launch-at-login setting"
            alert.informativeText = """
            \(error.localizedDescription)

            You can also toggle this in System Settings → General → Login Items.
            """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Called by AppKit before the status menu is shown — used here to refresh
    /// the "Launch at Login" checkmark to reflect the current SMAppService state.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin) {
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        return true
    }
}
