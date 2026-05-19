import AppKit
import HotKey
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
            button.image = NSImage(
                systemSymbolName: "checkmark.square",
                accessibilityDescription: "Quick Capture"
            )
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

    // MARK: - Settings

    @objc func showSettings() {
        settingsController.show()
    }
}
