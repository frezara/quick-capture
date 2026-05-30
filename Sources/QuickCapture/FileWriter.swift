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

        let heading = sectionName(for: tag)
        let item = todoLine(trimmedText, includeTimestamp: includeTimestamp, now: now)
        try appendUnderHeading(heading, item: item, to: url)
    }

    /// The `## H2` a capture routes to: the trimmed tag, or `## Quick capture`
    /// when untagged. Shared so the file-append path and the editor-buffer
    /// insert path (split mode) route identically.
    static func sectionName(for tag: String?) -> String {
        let trimmedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTag.isEmpty ? untaggedSection : trimmedTag
    }

    /// Build the `- [ ] …` line for a capture. The single source of truth for
    /// item formatting so the two write paths (disk append vs. editor-buffer
    /// insert) can never drift — including the optional `➕ DATE TIME` suffix.
    static func todoLine(_ text: String, includeTimestamp: Bool, now: Date = Date()) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeTimestamp {
            line += " \(createdMarker) \(timestampString(for: now))"
        }
        return "- [ ] \(line)"
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
    ///
    /// Insertion is priority-aware: `!!!` items go to the very top of the
    /// section, `!!` after all `!!!`s, `!` after those, and no-priority items
    /// after those. Within a bucket the new item lands at the TOP (newer first).
    /// Checked items (bucket 4) stay below everything.
    static func insert(item: String, underHeading heading: String, in content: String) -> String {
        let headingLine = "## \(heading)"
        var lines = content.components(separatedBy: "\n")

        let headingIndex = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.caseInsensitiveCompare(headingLine) == .orderedSame
        }

        if let h = headingIndex {
            let newBucket = priorityBucket(for: item)

            // Skip blank lines right after the heading so the item attaches
            // cleanly to the existing block.
            var sectionStart = h + 1
            while sectionStart < lines.count,
                  lines[sectionStart].trimmingCharacters(in: .whitespaces).isEmpty {
                sectionStart += 1
            }

            // Walk through the section, skipping past any task whose bucket is
            // strictly less than the new item's (higher priority). Stop at the
            // first task with bucket >= newBucket, or at the next heading, or
            // at the end of the document. Indented continuation lines move
            // with their parent task.
            var i = sectionStart
            var landedBeforeTask = false
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { break }
                if isTopLevelTaskLine(lines[i]) {
                    let bucket = priorityBucket(for: lines[i])
                    if bucket >= newBucket {
                        landedBeforeTask = true
                        break
                    }
                    i += 1
                    while i < lines.count,
                          lines[i].range(of: #"^\s+\S"#, options: .regularExpression) != nil {
                        i += 1
                    }
                    continue
                }
                i += 1
            }

            // When landing at the section boundary (next heading or EOF),
            // trim back over any trailing blank lines so we don't widen the gap.
            var insertIndex = i
            if !landedBeforeTask {
                while insertIndex > sectionStart,
                      lines[insertIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    insertIndex -= 1
                }
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

    /// 0 = unchecked `!!!`, 1 = `!!`, 2 = `!`, 3 = no priority, 4 = checked.
    /// Tolerant of a trailing `➕ DATE TIME` timestamp suffix so `appendTodo`'s
    /// timestamped output still classifies correctly.
    static func priorityBucket(for line: String) -> Int {
        if line.range(of: #"^\s*[-*+]\s+\[[xX]\]"#, options: .regularExpression) != nil {
            return 4
        }
        let pattern = #"\s(!{1,3})(?:\s+➕\s+\S+\s+\S+)?\s*$"#
        if let range = line.range(of: pattern, options: .regularExpression) {
            let count = line[range].filter { $0 == "!" }.count
            if count == 3 { return 0 }
            if count == 2 { return 1 }
            if count == 1 { return 2 }
        }
        return 3
    }

    private static func isTopLevelTaskLine(_ line: String) -> Bool {
        return line.range(of: #"^[-*+]\s+\["#, options: .regularExpression) != nil
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
