import Foundation

/// The disk pipeline behind the ⌥⌘U refile gesture (issue #32). Operates over
/// injected source/target URLs so it can be driven against temp dirs in tests,
/// leaving only alert/toast/bridge wiring in `MainPanel`.
///
/// Write the target before removing the source. A failure after target append
/// is uncertain and must not be blindly retried: independent Markdown files
/// have no receipt protocol or cross-file transaction.
enum RefileService {

    /// Refile the subtree at `range` out of `sourceURL` into `targetFolder`'s
    /// `inbox.md` (created if absent). Throws `FileWriter.RefileError.contentDrifted`
    /// if the on-disk lines no longer match `subtree`, or any filesystem error
    /// from the copy/write. After target append, failures are explicitly uncertain.
    static func refile(subtree: String, range: Range<Int>, from sourceURL: URL, toFolder targetFolder: URL) throws {
        let fm = FileManager.default
        let sourceContent = try FileWriter.read(sourceURL)

        // 1. Verify the range still matches the editor's snapshot and compute
        //    the source-without-subtree. Throws before anything touches disk.
        let newSource = try FileWriter.verifyAndRemove(subtree: subtree, at: range, in: sourceContent)

        let targetInbox = targetFolder.appendingPathComponent("inbox.md")

        // Last line of defence for R17. The dropdown already filters the capture
        // file's own folder out, but that filter compares paths — so a target
        // reaching the same file by another route (a symlinked folder, a
        // hand-edited defaults entry) would get here. Steps 4 and 5 both write:
        // the subtree would be appended and then overwritten away, deleting the
        // item outright. Refuse while the source is still untouched.
        let sameFile = targetInbox.resolvingSymlinksInPath().standardizedFileURL.path
            == sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard !sameFile else { throw FileWriter.RefileError.targetIsSource }

        // 2. Copy attachments into the target first (record only true renames).
        //    Copy-first means a copy failure aborts with the source intact.
        let paths = FileWriter.attachmentPaths(in: subtree)
        var renames: [String: String] = [:]
        for path in paths {
            if let final = try AttachmentStore.copyForRefile(path, from: sourceURL, to: targetInbox), final != path {
                renames[path] = final
            }
        }

        // 3. Rewrite links for renamed attachments, then promote to top level.
        var moved = subtree
        for (original, final) in renames {
            moved = moved.replacingOccurrences(of: "](\(original))", with: "](\(final))")
        }
        moved = FileWriter.dedent(moved)

        // 4. Append without replacing existing bytes: scaffold # Inbox if new, append
        //    the subtree at end-of-file.
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        try RefileAppend.append(moved, to: targetInbox)

        // 5. Only now write the source without the subtree. Up to here the
        //    source on disk is byte-for-byte its original self.
        do {
            try FileWriter.write(Data(newSource.utf8), to: sourceURL, ifStillMatching: sourceContent)
        } catch {
            // The destination has already accepted bytes. Repeating could duplicate.
            throw RefileAppend.AppendError.uncertain
        }

        // 6. Only now delete the moved originals — keeping any the post-removal
        //    source still references (shared-path safety).
        for path in paths {
            AttachmentStore.removeRefiledOriginal(path, besideFile: sourceURL, ifNotReferencedIn: newSource)
        }
    }
}
