import AppKit
import CoreText
import HotKey
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem!
    private var mainPanel: MainPanel?
    private var hotKey: HotKey?
    private lazy var settingsController = SettingsWindowController(appState: appState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard. Macs can end up with a stale Quick Capture
        // alongside a freshly-launched one (login-item restore racing with a
        // user double-click, dev builds opened while the installed copy is
        // running, etc.). If another instance is already up, hand off to it
        // and quit ourselves so the menu bar never grows two icons.
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.quickcapture.app"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
            .filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
            return
        }

        registerBundledFonts()
        scaffoldDefaultCaptureFile()
        setupStatusItem()
        setupMainMenu()
        setupHotKey()
    }

    // MARK: - Main menu
    //
    // LSUIElement apps don't get a standard application menu by default, so
    // shortcuts like ⌘H / ⌘Q / ⌘W and the standard Edit-menu actions don't
    // work in the editor windows. Building the minimal main menu here wires
    // those up — AppKit handles the actions automatically via selectors
    // sent through the responder chain.

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appName = "Quick Capture"

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(title: "About \(appName)",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(title: "Hide \(appName)",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))

        // Edit menu — Cut / Copy / Paste / Select All / Undo / Redo land on
        // the focused text view via the responder chain.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo",
                                    action: Selector(("undo:")),
                                    keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",
                                    action: #selector(NSText.cut(_:)),
                                    keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",
                                    action: #selector(NSText.copy(_:)),
                                    keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",
                                    action: #selector(NSText.paste(_:)),
                                    keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All",
                                    action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Close",
                                      action: #selector(NSWindow.performClose(_:)),
                                      keyEquivalent: "w"))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
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
        if mainPanel?.isVisible == true {
            hideCapture()
        } else {
            showCapture()
        }
    }

    /// Lazily builds the single shared panel that hosts both the capture box
    /// and the editor.
    @discardableResult
    private func ensurePanel() -> MainPanel {
        if let panel = mainPanel { return panel }
        let panel = MainPanel(
            appState: appState,
            onSubmit: { [weak self] text, tag in self?.handleCapture(text, tag: tag) },
            onDismiss: { [weak self] in self?.hideCapture() }
        )
        mainPanel = panel
        return panel
    }

    @objc func showCapture() {
        appState.refreshRecentTags()
        ensurePanel().show()
    }

    func hideCapture() {
        mainPanel?.orderOut(nil)
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

    // MARK: - Font registration

    /// Registers the IBM Plex Mono / Sans OTFs bundled in Resources/Fonts/
    /// for the process lifetime. CTFontManager makes them available to SwiftUI
    /// (.custom(…)) and AppKit (NSFont(name:size:)) without a system install.
    private func registerBundledFonts() {
        guard let fontsURL = Bundle.main.url(forResource: "Fonts", withExtension: nil) else {
            NSLog("QuickCapture: Fonts/ folder not found in bundle")
            return
        }
        let otfs = (try? FileManager.default.contentsOfDirectory(
            at: fontsURL, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "otf" } ?? []

        for url in otfs {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // MARK: - Default capture file scaffolding

    /// Creates ~/QuickCapture/inbox.md on every launch if it doesn't exist yet,
    /// but only when the user has never set a custom capture path. Idempotent.
    private func scaffoldDefaultCaptureFile() {
        let saved = UserDefaults.standard.string(forKey: "captureFilePath") ?? ""
        guard saved.isEmpty else { return }

        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: (home as NSString).appendingPathComponent("QuickCapture"))
        let file = dir.appendingPathComponent("inbox.md")
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) {
                try FileWriter.scaffoldContent
                    .write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("QuickCapture: failed to scaffold default capture file: %@", error.localizedDescription)
        }
    }

}
