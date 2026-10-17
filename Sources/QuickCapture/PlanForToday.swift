import Foundation

/// "Plan for today": moves an inbox item's subtree into today's daily note,
/// under `## Tasks`. The first entry in the ⌥⌘U refile picker. Same order as
/// `RefileService` — verify, copy attachments, write the note, write the
/// source last — so a failure before the last step leaves the inbox intact.
/// The item's source marker is dropped: daily notes stay local (ADR-0010).
enum PlanForToday {
    /// The id the refile picker posts back. Real targets are folder paths, so
    /// this can't collide with one.
    static let targetID = "today"

    @discardableResult
    static func move(subtree: String, range: Range<Int>, from sourceURL: URL,
                     dailyFolder: URL, today: Date = Date(), calendar: Calendar = .current) throws -> URL {
        let sourceContent = try FileWriter.read(sourceURL)
        let newSource = try FileWriter.verifyAndRemove(subtree: subtree, at: range, in: sourceContent)

        let note = try DailyNote.ensureNote(for: today, today: today, in: dailyFolder, calendar: calendar)
        guard note.resolvingSymlinksInPath().standardizedFileURL.path
                != sourceURL.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw FileWriter.RefileError.targetIsSource
        }

        let paths = FileWriter.attachmentPaths(in: subtree)
        var moved = subtree
        for path in paths {
            if let final = try AttachmentStore.copyForRefile(path, from: sourceURL, to: note), final != path {
                moved = moved.replacingOccurrences(of: "](\(path))", with: "](\(final))")
            }
        }
        moved = FileWriter.dedent(moved).components(separatedBy: "\n")
            .map(DailyNote.stripSourceMarkers).joined(separator: "\n")

        let noteContent = try FileWriter.read(note)
        try FileWriter.write(Data(DailyNote.insertUnderTasks(moved, in: noteContent).utf8),
                             to: note, ifStillMatching: noteContent)
        do {
            try FileWriter.write(Data(newSource.utf8), to: sourceURL, ifStillMatching: sourceContent)
        } catch {
            // The note already holds the item; repeating could duplicate it.
            throw RefileAppend.AppendError.uncertain
        }
        for path in paths {
            AttachmentStore.removeRefiledOriginal(path, besideFile: sourceURL, ifNotReferencedIn: newSource)
        }
        return note
    }
}
