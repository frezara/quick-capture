import Foundation

enum FileWriter {
    enum WriteError: LocalizedError {
        case encodingFailed
        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Failed to encode text as UTF-8."
            }
        }
    }

    static let documentHeading = "# Inbox"
    static let untaggedSection = "Quick capture"

    /// Obsidian Tasks plugin's "created date" marker.
    static let createdMarker = "➕"

    /// Append `text` as a `- [ ] …` todo to `url`, routed under a `## tag` H2
    /// section when `tag` is non-empty. Untagged items go under `## Quick capture`.
    /// The file always starts with a `# Inbox` H1.
    /// If `includeTimestamp` is true, appends `➕ YYYY-MM-DD HH:MM`.
    static func appendTodo(
        _ text: String,
        tag: String? = nil,
        to url: URL,
        includeTimestamp: Bool = false,
        now: Date = Date()
    ) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let trimmedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heading = trimmedTag.isEmpty ? untaggedSection : trimmedTag

        var line = trimmedText
        if includeTimestamp {
            line += " \(createdMarker) \(timestampString(for: now))"
        }
        try appendUnderHeading(heading, item: "- [ ] \(line)", to: url)
    }

    /// Format date as `YYYY-MM-DD HH:MM` in the user's local timezone.
    /// Locale is forced to `en_US_POSIX` to keep digit/separator output stable
    /// regardless of system locale (Arabic numerals, hyphens, colons).
    static func timestampString(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static func appendUnderHeading(_ heading: String, item: String, to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let withDocHeading = ensureDocumentHeading(in: existing)
        let updated = insert(item: item, underHeading: heading, in: withDocHeading)

        guard let data = updated.data(using: .utf8) else { throw WriteError.encodingFailed }
        try data.write(to: url, options: .atomic)
    }

    /// Make sure the file starts with `# Inbox`. Prepends it if missing.
    static func ensureDocumentHeading(in content: String) -> String {
        let firstNonBlank = content
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces)

        if firstNonBlank?.caseInsensitiveCompare(documentHeading) == .orderedSame {
            return content
        }

        if content.isEmpty {
            return "\(documentHeading)\n"
        }

        return "\(documentHeading)\n\n" + content
    }

    /// Pure function so it's easy to reason about and unit-test.
    /// Matches headings case-insensitively so `#Home` and `#home` land in the same section.
    static func insert(item: String, underHeading heading: String, in content: String) -> String {
        let headingLine = "## \(heading)"
        var lines = content.components(separatedBy: "\n")

        let headingIndex = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.caseInsensitiveCompare(headingLine) == .orderedSame
        }

        if let h = headingIndex {
            var insertIndex = lines.count
            for i in (h + 1)..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                    insertIndex = i
                    break
                }
            }
            while insertIndex > h + 1,
                  lines[insertIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertIndex -= 1
            }
            lines.insert(item, at: insertIndex)
            return lines.joined(separator: "\n")
        }

        // Heading missing — append a new section at the end.
        var result = content
        if !result.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            result += "\n"
        }
        result += "\(headingLine)\n\(item)\n"
        return result
    }
}
