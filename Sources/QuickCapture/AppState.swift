import Foundation
import SwiftUI

extension Notification.Name {
    static let hotKeyDidChange      = Notification.Name("QuickCapture.hotKeyDidChange")
    static let capturePanelDidHide  = Notification.Name("QuickCapture.capturePanelDidHide")
}

final class AppState: ObservableObject {
    private enum Keys {
        static let captureFilePath  = "captureFilePath"
        static let hotKey           = "hotKey"
        static let includeTimestamp = "includeTimestamp"
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

    /// Tags discovered in the capture file's `## headings`, excluding the
    /// default `## Quick capture` section. Refreshed via `refreshRecentTags()`.
    @Published var recentTags: [String] = []

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
            self.captureFilePath = (home as NSString).appendingPathComponent("QuickCapture.md")
        }

        if let data = UserDefaults.standard.data(forKey: Keys.hotKey),
           let decoded = try? JSONDecoder().decode(HotKeyConfig.self, from: data) {
            self.hotKey = decoded
        } else {
            self.hotKey = .default
        }

        self.includeTimestamp = UserDefaults.standard.bool(forKey: Keys.includeTimestamp)
    }
}
