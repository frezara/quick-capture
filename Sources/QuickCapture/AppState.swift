import Foundation
import SwiftUI

extension Notification.Name {
    static let hotKeyDidChange      = Notification.Name("QuickCapture.hotKeyDidChange")
    static let capturePanelDidHide  = Notification.Name("QuickCapture.capturePanelDidHide")
    static let vimModeDidChange     = Notification.Name("QuickCapture.vimModeDidChange")
}

/// Font design applied to the capture panel's todo input. Maps directly onto
/// SwiftUI's `Font.Design` cases — kept as a typed enum so it can round-trip
/// through UserDefaults and drive a Picker in Settings.
enum CaptureFontDesign: String, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:     return "System"
        case .rounded:    return "Rounded"
        case .serif:      return "Serif (New York)"
        case .monospaced: return "Monospaced (SF Mono)"
        }
    }

    var design: Font.Design {
        switch self {
        case .system:     return .default
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }
}

final class AppState: ObservableObject {
    private enum Keys {
        static let captureFilePath        = "captureFilePath"
        static let hotKey                 = "hotKey"
        static let includeTimestamp       = "includeTimestamp"
        static let captureFontDesign      = "captureFontDesign"
        static let vimEnabled             = "vimEnabled"
        static let screenshotAttachWindow = "screenshotAttachWindow"
    }

    /// Sentinel for "Any" in the auto-attach window picker — the most recent
    /// screenshot attaches regardless of age.
    static let attachWindowAny: Double = -1

    @Published var captureFilePath: String {
        didSet {
            UserDefaults.standard.set(captureFilePath, forKey: Keys.captureFilePath)
        }
    }

    @Published var hotKey: HotKeyConfig {
        didSet {
            guard hotKey != oldValue else { return }
            if let data = try? JSONEncoder().encode(hotKey) {
                UserDefaults.standard.set(data, forKey: Keys.hotKey)
            }
            NotificationCenter.default.post(name: .hotKeyDidChange, object: nil)
        }
    }

    @Published var includeTimestamp: Bool {
        didSet {
            UserDefaults.standard.set(includeTimestamp, forKey: Keys.includeTimestamp)
        }
    }

    @Published var captureFontDesign: CaptureFontDesign {
        didSet {
            UserDefaults.standard.set(captureFontDesign.rawValue, forKey: Keys.captureFontDesign)
        }
    }

    /// Vim keybindings in the editor. On by default. The editor reads this via
    /// the JS bridge (`MainPanel` pushes it); a change is broadcast so a live
    /// editor can toggle without a reload.
    @Published var vimEnabled: Bool {
        didSet {
            guard vimEnabled != oldValue else { return }
            UserDefaults.standard.set(vimEnabled, forKey: Keys.vimEnabled)
            NotificationCenter.default.post(name: .vimModeDidChange, object: nil)
        }
    }

    /// How recent (seconds) a screenshot must be to pre-attach when the capture
    /// panel is summoned. `attachWindowAny` (-1) disables the age check.
    @Published var screenshotAttachWindow: Double {
        didSet {
            UserDefaults.standard.set(screenshotAttachWindow, forKey: Keys.screenshotAttachWindow)
        }
    }

    /// Tags discovered in the capture file's `## headings`, excluding the
    /// default `## Quick capture` section. Refreshed via `refreshRecentTags()`.
    @Published var recentTags: [String] = []

    // Capture-session state (not persisted). Lives here rather than in
    // CaptureView @State so MainPanel (detection, ⌘⇧S pull-in) and the view
    // share it; it survives the ⌘F editor round-trip and is cleared on the
    // `.capturePanelDidHide` notification alongside the typed text.

    /// Screenshot currently attached to the capture box as a chip.
    @Published var pendingAttachment: URL?
    /// When non-nil, the ⌘⇧S screenshot picker is open over the capture box,
    /// offering these recent screenshots (newest first). Cleared on attach,
    /// Esc, mode switch, and full dismiss.
    @Published var screenshotPickerItems: [ScreenshotLocator.Screenshot]?
    /// A screenshot exists on disk but is outside the auto-attach window —
    /// drives the "⌘⇧S to attach screenshot" hint.
    @Published var recentScreenshotExists = false
    /// Transient feedback for the pull-in keystroke (e.g. "No screenshots
    /// found"). CaptureView clears it after a beat.
    @Published var attachFeedback: String?

    func refreshRecentTags() {
        let url = captureFileURL
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            recentTags = []
            return
        }

        var counts: [String: Int]        = [:]   // lowercased key → item count
        var canonicalName: [String: String] = [:] // lowercased key → original casing
        var currentTagKey: String?

        let headingPattern = #"^##\s+(.+?)\s*$"#
        let headingRegex = try? NSRegularExpression(pattern: headingPattern)
        let untaggedKey = FileWriter.untaggedSection.lowercased()

        for line in content.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = headingRegex?.firstMatch(in: line, range: range),
               let nameRange = Range(match.range(at: 1), in: line) {
                let name = String(line[nameRange])
                let key = name.lowercased()
                if key == untaggedKey {
                    currentTagKey = nil
                } else {
                    currentTagKey = key
                    if canonicalName[key] == nil { canonicalName[key] = name }
                    if counts[key] == nil { counts[key] = 0 }
                }
            } else if line.hasPrefix("- ["),
                      let tag = currentTagKey {
                counts[tag, default: 0] += 1
            }
        }

        // Sort by item count descending; alphabetical for ties.
        let sorted = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }
        recentTags = sorted.compactMap { canonicalName[$0.key] }
    }

    var captureFileURL: URL {
        let expanded = (captureFilePath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: Keys.captureFilePath), !saved.isEmpty {
            self.captureFilePath = saved
        } else {
            let home = NSHomeDirectory()
            self.captureFilePath = (home as NSString)
                .appendingPathComponent("QuickCapture/inbox.md")
        }

        if let data = UserDefaults.standard.data(forKey: Keys.hotKey),
           let decoded = try? JSONDecoder().decode(HotKeyConfig.self, from: data) {
            self.hotKey = decoded
        } else {
            self.hotKey = .default
        }

        self.includeTimestamp = UserDefaults.standard.bool(forKey: Keys.includeTimestamp)

        if let raw = UserDefaults.standard.string(forKey: Keys.captureFontDesign),
           let decoded = CaptureFontDesign(rawValue: raw) {
            self.captureFontDesign = decoded
        } else {
            self.captureFontDesign = .monospaced
        }

        // Default to on (the prior always-on behavior) when never set.
        if UserDefaults.standard.object(forKey: Keys.vimEnabled) == nil {
            self.vimEnabled = true
        } else {
            self.vimEnabled = UserDefaults.standard.bool(forKey: Keys.vimEnabled)
        }

        // 2 minutes by default — "I just took this" territory.
        if UserDefaults.standard.object(forKey: Keys.screenshotAttachWindow) == nil {
            self.screenshotAttachWindow = 120
        } else {
            self.screenshotAttachWindow = UserDefaults.standard.double(forKey: Keys.screenshotAttachWindow)
        }
    }
}
