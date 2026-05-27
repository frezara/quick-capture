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
            // Insert at the top of the section — newest first. Skip any blank
            // lines immediately after the heading so the item attaches cleanly
            // to the existing block rather than landing in the gap.
            var insertIndex = h + 1
            while insertIndex < lines.count,
                  lines[insertIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                insertIndex += 1
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

    // MARK: - Archive

    /// Moves every `- [x]` line from `sourceURL` into a sibling `_archive`
    /// file, inserting each item under the same `## section` heading it had
    /// in the source. The archive file mirrors the source's `# Inbox` + H2
    /// structure; missing sections are created. Indented checked tasks are
    /// unindented so the archive reads as a flat list of completed items.
    static func archiveCompleted(at sourceURL: URL) throws {
        let sourceText = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        let (remaining, archived) = extractCompletedItems(from: sourceText)
        guard !archived.isEmpty else { return }

        let archiveURL = archiveURL(for: sourceURL)
        let archiveExisting = (try? String(contentsOf: archiveURL, encoding: .utf8)) ?? ""
        var archiveText = ensureDocumentHeading(in: archiveExisting)
        for item in archived {
            archiveText = insert(item: item.text, underHeading: item.section ?? untaggedSection, in: archiveText)
        }

        guard let archiveData = archiveText.data(using: .utf8),
              let remainingData = remaining.data(using: .utf8) else {
            throw WriteError.encodingFailed
        }
        try archiveData.write(to: archiveURL, options: .atomic)
        try remainingData.write(to: sourceURL, options: .atomic)
    }

    struct ArchivedItem: Equatable {
        let text: String      // the task line, with indentation stripped
        let section: String?  // the `## section` it lived under (nil → untagged)
    }

    /// Splits `content` into the file body with every `- [x]` line removed,
    /// plus a list of those removed items with their containing section name.
    static func extractCompletedItems(from content: String) -> (remaining: String, items: [ArchivedItem]) {
        var lines = content.components(separatedBy: "\n")
        var items: [ArchivedItem] = []
        var keepIndices: [Int] = []
        var currentSection: String? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                currentSection = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                keepIndices.append(i)
            } else if line.range(of: #"^\s*[-*+]\s+\[[xX]\]"#, options: .regularExpression) != nil {
                let unindented = line.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
                items.append(ArchivedItem(text: unindented, section: currentSection))
            } else {
                keepIndices.append(i)
            }
        }

        lines = keepIndices.map { lines[$0] }
        return (lines.joined(separator: "\n"), items)
    }

    /// Sibling URL with `_archive` inserted before the extension.
    /// e.g. `inbox.md` → `inbox_archive.md`, `notes` → `notes_archive`.
    static func archiveURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let name = ext.isEmpty ? "\(base)_archive" : "\(base)_archive.\(ext)"
        return dir.appendingPathComponent(name)
    }
}
