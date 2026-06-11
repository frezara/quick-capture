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

    /// Content written to inbox.md on first launch. Includes a welcome todo so
    /// the editor has something to show and users discover the core gestures.
    static let scaffoldContent = """
        # Inbox

        ## Quick capture

        - [ ] Welcome to Quick Capture — press ⌥T to capture a thought, ⌘F to open the editor.
        """

    /// Obsidian Tasks plugin's "created date" marker.
    static let createdMarker = "➕"

    /// Append `text` as a `- [ ] …` todo to `url`, routed under a `## tag` H2
    /// section when `tag` is non-empty. Untagged items go under `## Quick capture`.
    /// The file always starts with a `# Inbox` H1.
    /// If `includeTimestamp` is true, appends `➕ YYYY-MM-DD HH:MM`.
    /// Each path in `attachmentLinks` becomes an indented image-link child line
    /// directly under the todo, in order, and the block travels together through
    /// insertion, re-org, and archive. Duplicate paths are collapsed so a
    /// screenshot referenced twice is written once.
    static func appendTodo(
        _ text: String,
        tag: String? = nil,
        to url: URL,
        includeTimestamp: Bool = false,
        now: Date = Date(),
        attachmentLinks: [String] = []
    ) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let heading = sectionName(for: tag)
        let item = todoLine(trimmedText, includeTimestamp: includeTimestamp, now: now)
        var seen = Set<String>()
        let children = attachmentLinks
            .filter { seen.insert($0).inserted }
            .map(attachmentChildLine)
        try appendUnderHeading(heading, item: item, childLines: children, to: url)
    }

    /// The indented image-link child line for an attachment. Single source of
    /// truth for the format so the capture path and the editor's parsing
    /// (`editor.ts` matches indented `![…](…)` lines) can never drift.
    static func attachmentChildLine(_ relativePath: String) -> String {
        return "  ![screenshot](\(relativePath))"
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

    static func appendUnderHeading(_ heading: String, item: String, childLines: [String] = [], to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let withDocHeading = ensureDocumentHeading(in: existing)
        let updated = insert(item: item, childLines: childLines, underHeading: heading, in: withDocHeading)

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
    ///
    /// `childLines` (indented continuation lines, e.g. an attachment image
    /// link) land directly after `item` as one block — they stay separate
    /// array elements so the priority bucket is always computed on the parent
    /// line alone.
    static func insert(item: String, childLines: [String] = [], underHeading heading: String, in content: String) -> String {
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
                    // Same child rule as extractCompletedItems and the editor
                    // so all three sites agree on what travels with a parent task.
                    while i < lines.count,
                          lines[i].range(of: childContinuationPattern, options: .regularExpression) != nil {
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
            lines.insert(contentsOf: [item] + childLines, at: insertIndex)
            return lines.joined(separator: "\n")
        }

        // Heading missing — append a new section at the end.
        var result = content
        if !result.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            result += "\n"
        }
        result += "\(headingLine)\n" + ([item] + childLines).joined(separator: "\n") + "\n"
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

    /// Matches a line that is an indented continuation of its parent task:
    /// 2+ spaces or a tab before a non-space character. The same rule lives in
    /// editor-web/src/editor.ts (child grouping + image-line matching) and must
    /// stay in sync with it.
    private static let childContinuationPattern = #"^( {2,}|\t)\S"#

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
            archiveText = insert(item: item.text, childLines: item.children, underHeading: item.section ?? untaggedSection, in: archiveText)
        }

        guard let archiveData = archiveText.data(using: .utf8),
              let remainingData = remaining.data(using: .utf8) else {
            throw WriteError.encodingFailed
        }
        try archiveData.write(to: archiveURL, options: .atomic)
        try remainingData.write(to: sourceURL, options: .atomic)
    }

    struct ArchivedItem: Equatable {
        let text: String        // the task line, with indentation stripped
        let section: String?    // the `## section` it lived under (nil → untagged)
        let children: [String]  // trailing indented continuation lines, re-indented to 2 spaces

        init(text: String, section: String?, children: [String] = []) {
            self.text = text
            self.section = section
            self.children = children
        }
    }

    /// Splits `content` into the file body with every `- [x]` line removed,
    /// plus a list of those removed items with their containing section name.
    /// A checked task's trailing indented continuation lines that are NOT
    /// themselves task lines (e.g. attachment image links, notes) move with it,
    /// so the archive never strands a child in the source file. Indented task
    /// lines are left for the main loop to handle (checked ones are extracted
    /// individually and flattened; unchecked ones remain in the source).
    static func extractCompletedItems(from content: String) -> (remaining: String, items: [ArchivedItem]) {
        let lines = content.components(separatedBy: "\n")
        var items: [ArchivedItem] = []
        var kept: [String] = []
        var currentSection: String? = nil

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                currentSection = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                kept.append(line)
                i += 1
            } else if line.range(of: #"^\s*[-*+]\s+\[[xX]\]"#, options: .regularExpression) != nil {
                let unindented = line.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
                var children: [String] = []
                var j = i + 1
                // Collect only indented continuation lines (notes, image links).
                // Stop at any indented task line — the main loop handles nested
                // tasks individually (checked ones get extracted and flattened;
                // unchecked ones stay in the source).
                while j < lines.count,
                      lines[j].range(of: childContinuationPattern, options: .regularExpression) != nil,
                      lines[j].range(of: #"^\s*[-*+]\s+\["#, options: .regularExpression) == nil {
                    // The parent flattens to top level, so children normalize
                    // to a 2-space indent under it.
                    let body = lines[j].replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
                    children.append("  " + body)
                    j += 1
                }
                items.append(ArchivedItem(text: unindented, section: currentSection, children: children))
                i = j
            } else {
                kept.append(line)
                i += 1
            }
        }

        return (kept.joined(separator: "\n"), items)
    }

    // MARK: - Refile (issue #32)

    enum RefileError: LocalizedError {
        /// The on-disk lines at the supplied range no longer match the editor's
        /// subtree text — the file changed underneath us, so refusing to move
        /// the wrong item.
        case contentDrifted
        var errorDescription: String? {
            switch self {
            case .contentDrifted:
                return "The file changed since you pressed ⌘R. Refile again."
            }
        }
    }

    /// The leading-whitespace width of a line, tabs counted as 4 columns to
    /// match the editor's `indentUnit.of("    ")`. Used to compare nesting depth
    /// when resolving a subtree span.
    static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 }
            else if ch == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    private static func isItemLine(_ line: String) -> Bool {
        return line.range(of: #"^\s*[-*+]\s"#, options: .regularExpression) != nil
    }

    /// Resolve the line range of the subtree that owns `atLine` — the item
    /// itself plus every more-indented line that belongs to it (attachment
    /// children, notes, nested child items), bounded by the next line at the
    /// item's own indent or a heading or EOF. A cursor on a child/continuation
    /// line resolves *up* to the owning item. Returns nil when the line isn't
    /// on (or under) an item — a blank line or a heading — so the caller can
    /// show the off-item hint. Range is a half-open `start..<end` over the
    /// document's `\n`-split lines.
    static func subtreeRange(in content: String, atLine line: Int) -> Range<Int>? {
        let lines = content.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return nil }

        // Resolve up to the owning item: from the cursor line, walk back over
        // more-indented continuation lines to the nearest item line.
        var root = line
        if !isItemLine(lines[root]) {
            let trimmed = lines[root].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            let childWidth = indentWidth(lines[root])
            var i = root - 1
            root = -1
            while i >= 0 {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { break }
                if isItemLine(lines[i]), indentWidth(lines[i]) < childWidth {
                    root = i
                    break
                }
                i -= 1
            }
            if root < 0 { return nil }
        }

        let rootWidth = indentWidth(lines[root])
        var end = root + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if t.hasPrefix("#") { break }
            if indentWidth(lines[end]) <= rootWidth { break }
            end += 1
        }
        return root..<end
    }

    /// Content-addressed identity guard. Confirm the `range` of lines in
    /// `content` equals `subtree` byte-for-byte, then return `content` with that
    /// range removed. Throws `RefileError.contentDrifted` (removing nothing) if
    /// the file changed underneath the editor's snapshot.
    static func verifyAndRemove(subtree: String, at range: Range<Int>, in content: String) throws -> String {
        var lines = content.components(separatedBy: "\n")
        guard range.lowerBound >= 0, range.upperBound <= lines.count else {
            throw RefileError.contentDrifted
        }
        let actual = lines[range].joined(separator: "\n")
        guard actual == subtree else { throw RefileError.contentDrifted }
        lines.removeSubrange(range)
        return lines.joined(separator: "\n")
    }

    /// Shift a subtree left so its top item sits at column 0, every descendant
    /// shifted by the same delta so relative nesting is preserved. A subtree
    /// already at column 0 is returned unchanged. The delta is measured from the
    /// first line's leading whitespace; each line drops up to that many leading
    /// whitespace characters (lines indented with fewer simply lose what they
    /// have — they cannot exist in a well-formed subtree).
    static func dedent(_ subtree: String) -> String {
        let lines = subtree.components(separatedBy: "\n")
        guard let first = lines.first else { return subtree }
        let rootPrefix = first.prefix { $0 == " " || $0 == "\t" }
        guard !rootPrefix.isEmpty else { return subtree }
        let drop = rootPrefix.count
        let shifted = lines.map { line -> String in
            var i = line.startIndex
            var dropped = 0
            while dropped < drop, i < line.endIndex, line[i] == " " || line[i] == "\t" {
                i = line.index(after: i)
                dropped += 1
            }
            return String(line[i...])
        }
        return shifted.joined(separator: "\n")
    }

    /// The in-folder relative `attachments/…` image paths referenced by a
    /// subtree, in document order, used to plan the attachment move. Only
    /// markdown image links (`![…](…)`) whose target is a relative
    /// `attachments/…` path count — URLs, absolute paths, and non-image
    /// (`[…](…)` without the leading `!`) links are ignored. Duplicates are
    /// collapsed so a path referenced twice is moved once.
    static func attachmentPaths(in subtree: String) -> [String] {
        let pattern = #"!\[[^\]]*\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [String] = []
        for line in subtree.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard let r = Range(match.range(at: 1), in: line) else { continue }
                let path = String(line[r])
                guard path.hasPrefix("\(AttachmentStore.folderName)/") else { continue }
                if !result.contains(path) { result.append(path) }
            }
        }
        return result
    }

    /// Append a (already dedented) subtree at end-of-file under the target's
    /// `# Inbox` H1, scaffolding a bare `# Inbox` when the target is empty/new.
    /// Items land in arrival order (FIFO) — refile targets are flat inboxes with
    /// no fixed sections (issue #32). Reuses `ensureDocumentHeading`.
    static func appendUnderInbox(subtree: String, to content: String) -> String {
        var base = ensureDocumentHeading(in: content)
        while base.hasSuffix("\n") { base.removeLast() }
        // A heading-only target wants a blank line before its first item; an
        // inbox that already has items wants the subtree on the very next line.
        let hasBody = base.components(separatedBy: "\n").dropFirst().contains {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let separator = hasBody ? "\n" : "\n\n"
        return base + separator + subtree + "\n"
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
