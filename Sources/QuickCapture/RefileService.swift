import Foundation

/// The disk pipeline behind the ⌥⌘R refile gesture (issue #32). Operates over
/// injected source/target URLs so it can be driven against temp dirs in tests,
/// leaving only alert/toast/bridge wiring in `MainPanel`.
///
/// Pipeline order is crash-safe: the source file — the one place the user's
/// captured thought lives — is written **last** (step 5), so any failure
/// through that point leaves it completely intact and the item never vanishes
/// (the failure contract, mirroring capture R16). A failure between steps 5 and
/// 6 leaves at worst a harmless copied orphan in the target.
enum RefileService {

    /// Refile the subtree at `range` out of `sourceURL` into `targetFolder`'s
    /// `inbox.md` (created if absent). Throws `FileWriter.RefileError.contentDrifted`
    /// if the on-disk lines no longer match `subtree`, or any filesystem error
    /// from the copy/write — in every throwing case the source is untouched.
    static func refile(subtree: String, range: Range<Int>, from sourceURL: URL, toFolder targetFolder: URL) throws {
        let fm = FileManager.default
        let sourceContent = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""

        // 1. Verify the range still matches the editor's snapshot and compute
        //    the source-without-subtree. Throws before anything touches disk.
        let newSource = try FileWriter.verifyAndRemove(subtree: subtree, at: range, in: sourceContent)

        let targetInbox = targetFolder.appendingPathComponent("inbox.md")

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

        // 4. Write the target inbox (atomic): scaffold # Inbox if new, append
        //    the subtree at end-of-file.
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let targetContent = (try? String(contentsOf: targetInbox, encoding: .utf8)) ?? ""
        let newTarget = FileWriter.appendUnderInbox(subtree: moved, to: targetContent)
        try newTarget.write(to: targetInbox, atomically: true, encoding: .utf8)

        // 5. Only now write the source without the subtree. Up to here the
        //    source on disk is byte-for-byte its original self.
        try newSource.write(to: sourceURL, atomically: true, encoding: .utf8)

        // 6. Only now delete the moved originals — keeping any the post-removal
        //    source still references (shared-path safety).
        for path in paths {
            AttachmentStore.removeRefiledOriginal(path, besideFile: sourceURL, ifNotReferencedIn: newSource)
        }
    }
}
