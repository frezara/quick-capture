import Foundation

/// A daily note is `daily/YYYY-MM-DD.md` beside the capture file (CONTEXT.md,
/// ADR-0010). It is created on demand; creating today's note rolls over the
/// unfinished items of the most recent earlier note by copying them, so earlier
/// notes are never written.
enum DailyNote {
    static let folderName = "daily"
    static let tasksSection = "Tasks"
    static let logSection = "Log"

    enum CreateError: LocalizedError {
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .writeFailed(let reason): return "Couldn't create the daily note: \(reason)"
            }
        }
    }

    static func folder(forCaptureFile captureFile: URL) -> URL {
        captureFile.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    static func fileStem(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func url(for date: Date, in folder: URL, calendar: Calendar = .current) -> URL {
        folder.appendingPathComponent(fileStem(for: date, calendar: calendar) + ".md")
    }

    /// `# Saturday 17 October 2026`. The ISO date is already the filename, so
    /// the heading is for reading.
    static func heading(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return "# " + formatter.string(from: date)
    }

    static func scaffold(for date: Date, carrying carried: [String], calendar: Calendar = .current) -> String {
        var text = heading(for: date, calendar: calendar) + "\n\n## \(tasksSection)\n\n"
        if !carried.isEmpty { text += carried.joined(separator: "\n") + "\n\n" }
        return text + "## \(logSection)\n"
    }

    /// Every unticked top-level item with everything nested under it, in
    /// document order and from any section. A ticked item closes its whole
    /// subtree; plain bullets and prose never roll over. Source markers are
    /// dropped because daily notes stay local (ADR-0010).
    static func unfinishedSubtrees(in content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        var subtrees: [String] = []
        var i = 0
        while i < lines.count {
            guard lines[i].range(of: #"^[-*+]\s+\[ \]"#, options: .regularExpression) != nil,
                  let range = FileWriter.subtreeRange(in: content, atLine: i) else {
                i += 1
                continue
            }
            subtrees.append(lines[range].map(stripSourceMarkers).joined(separator: "\n"))
            i = range.upperBound
        }
        return subtrees
    }

    /// The newest `YYYY-MM-DD.md` in `folder` dated before `date`, if any.
    static func mostRecentNote(before date: Date, in folder: URL, calendar: Calendar = .current) -> URL? {
        let stem = fileStem(for: date, calendar: calendar)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil }
            .map { String($0.dropLast(3)) }
            .filter { $0 < stem }
            .max()
            .map { folder.appendingPathComponent($0 + ".md") }
    }

    /// Returns the note for `date`, creating it if it doesn't exist. Only
    /// today's note rolls over: a past or future note starts empty.
    @discardableResult
    static func ensureNote(for date: Date, today: Date = Date(), in folder: URL,
                           calendar: Calendar = .current) throws -> URL {
        let target = url(for: date, in: folder, calendar: calendar)
        if FileManager.default.fileExists(atPath: target.path) { return target }

        var carried: [String] = []
        if calendar.isDate(date, inSameDayAs: today),
           let previous = mostRecentNote(before: date, in: folder, calendar: calendar) {
            carried = unfinishedSubtrees(in: try FileWriter.read(previous))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try createExclusively(scaffold(for: date, carrying: carried, calendar: calendar), at: target)
        return target
    }

    /// Appends `subtree` to the end of `## Tasks`, recreating the section
    /// under the date heading if it was deleted.
    static func insertUnderTasks(_ subtree: String, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let heading = "## \(tasksSection)"
        guard let h = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(heading) == .orderedSame
        }) else {
            let at = lines.firstIndex { $0.hasPrefix("# ") }.map { $0 + 1 } ?? 0
            var block = [heading, "", subtree]
            if at > 0 { block.insert("", at: 0) }
            if at < lines.count, !lines[at].trimmingCharacters(in: .whitespaces).isEmpty { block.append("") }
            lines.insert(contentsOf: block, at: at)
            return lines.joined(separator: "\n")
        }
        var end = h + 1
        while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
        var last = end - 1
        while last > h, lines[last].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
        if last == h {
            // An empty section: one blank line either side of the new item.
            lines.replaceSubrange((h + 1)..<end, with: ["", subtree, ""])
        } else {
            lines.insert(subtree, at: last + 1)
        }
        return lines.joined(separator: "\n")
    }

    static func stripSourceMarkers(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s*<!--(?:qc:|qc-source:)[^>]*-->"#, with: "", options: .regularExpression)
    }

    /// Atomic and never overwrites: if another writer (Obsidian, a second open
    /// of Today) created the note first, theirs wins and rollover doesn't run
    /// twice. `Data.write` can't combine `.atomic` with `.withoutOverwriting`,
    /// so this writes a temp file and renames it with RENAME_EXCL.
    private static func createExclusively(_ text: String, at target: URL) throws {
        guard let data = text.data(using: .utf8) else { throw FileWriter.WriteError.encodingFailed }
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        if renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST { return }
            throw CreateError.writeFailed(String(cString: strerror(errno)))
        }
        try LocalFileDurability.sync(target)
    }
}
