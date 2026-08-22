import Foundation
import SwiftUI

extension Notification.Name {
    static let hotKeyDidChange       = Notification.Name("QuickCapture.hotKeyDidChange")
    static let capturePanelDidHide   = Notification.Name("QuickCapture.capturePanelDidHide")
    static let vimModeDidChange      = Notification.Name("QuickCapture.vimModeDidChange")
    static let refileTargetsDidChange = Notification.Name("QuickCapture.refileTargetsDidChange")
    static let tagHuesDidChange      = Notification.Name("QuickCapture.tagHuesDidChange")
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
        static let refileTargets          = "refileTargets"
        static let tagHues                = "tagHues"
    }

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

    /// Ordered list of refile destinations (issue #32). The editor can't read
    /// settings directly, so `MainPanel` pushes the effective list into the web
    /// layer on editor entry and whenever this changes — hence the broadcast.
    @Published var refileTargets: [RefileTarget] {
        didSet {
            guard refileTargets != oldValue else { return }
            if let data = try? JSONEncoder().encode(refileTargets) {
                UserDefaults.standard.set(data, forKey: Keys.refileTargets)
            }
            NotificationCenter.default.post(name: .refileTargetsDidChange, object: nil)
        }
    }

    /// Which hue each section owns (#102). Allocated as the capture file is
    /// scanned — first section seen takes the first hue, and keeps it — then
    /// persisted, so hues don't shuffle when the file is reordered or the app
    /// relaunches. The editor can't read settings and no longer derives the hue
    /// itself, so `MainPanel` pushes the resolved map in; hence the broadcast.
    @Published private(set) var tagHues: TagHueAssignment {
        didSet {
            guard tagHues != oldValue else { return }
            if let data = try? JSONEncoder().encode(tagHues) {
                UserDefaults.standard.set(data, forKey: Keys.tagHues)
            }
            NotificationCenter.default.post(name: .tagHuesDidChange, object: nil)
        }
    }

    /// The hue a tag owns, or nil when it has never been seen in the capture
    /// file — an unmatched tag has no identity yet, so callers fall back to the
    /// accent rather than inventing one.
    func hueEntry(for tag: String) -> TagPalette.Entry? { tagHues.entry(for: tag) }

    /// Give a hue to any section in `content` that hasn't got one, in file
    /// order. Runs over the editor's buffer as well as the capture-file scan,
    /// so a `## section` typed straight into the editor gets its hue without
    /// waiting for the next summon. Returns true when anything was allocated.
    @discardableResult
    func assignHues(inContent content: String) -> Bool {
        var updated = tagHues
        guard updated.assign(Self.sectionNames(in: content)) else { return false }
        tagHues = updated
        return true
    }

    /// Section names in the order they appear, excluding the untagged
    /// catch-all — `## Quick capture` is not a tag and takes no hue.
    static func sectionNames(in content: String) -> [String] {
        let untaggedKey = FileWriter.untaggedSection.lowercased()
        var seen: Set<String> = []
        var names: [String] = []
        for line in content.components(separatedBy: "\n") {
            guard line.hasPrefix("##"), !line.hasPrefix("###") else { continue }
            let name = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            guard !name.isEmpty, key != untaggedKey, !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }
        return names
    }

    /// The refile targets actually offered in the editor: the capture file's own
    /// folder and any missing folders filtered out (R17/R18).
    var effectiveRefileTargets: [RefileTarget] {
        RefileTarget.effective(refileTargets, captureFolder: captureFileURL.deletingLastPathComponent())
    }

    /// Tags discovered in the capture file's `## headings`, excluding the
    /// default `## Quick capture` section. Refreshed via `refreshRecentTags()`.
    @Published var recentTags: [String] = []

    // Capture-session state (not persisted). Lives here rather than in
    // CaptureView @State so MainPanel (detection, ⌥⌘O pull-in) and the view
    // share it; it survives the ⌥⌘I editor round-trip and is cleared on the
    // `.capturePanelDidHide` notification alongside the typed text.

    /// Screenshots currently attached to the capture box, in selection order
    /// (oldest-attached first). Each renders as its own chip and writes its own
    /// indented `![…]` child line under the captured todo. Deduped by path so
    /// the same screenshot can't attach twice.
    @Published var pendingAttachments: [URL] = []
    /// When non-nil, the ⌥⌘O screenshot picker is open over the capture box,
    /// offering these recent screenshots (newest first). Cleared on attach,
    /// Esc, mode switch, and full dismiss.
    @Published var screenshotPickerItems: [ScreenshotLocator.Screenshot]?
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

        // Allocation follows the file, not the count-sorted suggestion order —
        // the first section in the file takes the first hue.
        assignHues(inContent: content)
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

        if let data = UserDefaults.standard.data(forKey: Keys.refileTargets),
           let decoded = try? JSONDecoder().decode([RefileTarget].self, from: data) {
            self.refileTargets = decoded
        } else {
            self.refileTargets = []
        }

        if let data = UserDefaults.standard.data(forKey: Keys.tagHues),
           let decoded = try? JSONDecoder().decode(TagHueAssignment.self, from: data) {
            self.tagHues = decoded
        } else {
            self.tagHues = TagHueAssignment()
        }
    }
}
