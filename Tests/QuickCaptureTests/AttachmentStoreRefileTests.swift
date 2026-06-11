import XCTest
@testable import QuickCapture

/// Module 2 — attachment relocation for the ⌃⌘R refile gesture (issue #32).
/// Copy-first into the target folder (collision-safe, name-preserving) and a
/// shared-path-safe delete of the source original.
final class AttachmentStoreRefileTests: XCTestCase {

    func testCopyForRefilePreservesNameWhenNoCollision() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceFile = source.appendingPathComponent("inbox.md")
        let targetFile = target.appendingPathComponent("inbox.md")
        try writeAttachment(in: source, named: "shot.png", contents: "img")

        let final = try AttachmentStore.copyForRefile("attachments/shot.png", from: sourceFile, to: targetFile)

        XCTAssertEqual(final, "attachments/shot.png", "basename is preserved when the target has no collision")
        let copied = target.appendingPathComponent("attachments/shot.png")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "img")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("attachments/shot.png").path),
                      "copy-first leaves the source original in place")
    }

    func testCopyForRefileCollisionGetsDashTwoSuffixAndReportsRename() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceFile = source.appendingPathComponent("inbox.md")
        let targetFile = target.appendingPathComponent("inbox.md")
        try writeAttachment(in: source, named: "shot.png", contents: "incoming")
        try writeAttachment(in: target, named: "shot.png", contents: "already there")

        let final = try AttachmentStore.copyForRefile("attachments/shot.png", from: sourceFile, to: targetFile)

        XCTAssertEqual(final, "attachments/shot-2.png", "a name collision in the target forces a -2 rename")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("attachments/shot.png"), encoding: .utf8),
                       "already there", "the pre-existing target file must never be overwritten")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("attachments/shot-2.png"), encoding: .utf8),
                       "incoming")
    }

    func testCopyForRefileMissingSourceReturnsNil() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceFile = source.appendingPathComponent("inbox.md")
        let targetFile = target.appendingPathComponent("inbox.md")

        let final = try AttachmentStore.copyForRefile("attachments/gone.png", from: sourceFile, to: targetFile)

        XCTAssertNil(final, "a missing source is best-effort: nothing to copy, no throw, link carried verbatim")
    }

    func testRemoveRefiledOriginalDeletesWhenUnreferenced() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let sourceFile = source.appendingPathComponent("inbox.md")
        try writeAttachment(in: source, named: "shot.png", contents: "img")

        AttachmentStore.removeRefiledOriginal("attachments/shot.png", besideFile: sourceFile,
                                              ifNotReferencedIn: "# Inbox\n\n- [ ] something else\n")

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("attachments/shot.png").path),
                       "an unreferenced original is removed so the source folder doesn't accumulate orphans")
    }

    func testRemoveRefiledOriginalKeepsWhenStillReferenced() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let sourceFile = source.appendingPathComponent("inbox.md")
        try writeAttachment(in: source, named: "shot.png", contents: "img")

        let remaining = "# Inbox\n\n- [ ] kept item\n  ![screenshot](attachments/shot.png)\n"
        AttachmentStore.removeRefiledOriginal("attachments/shot.png", besideFile: sourceFile,
                                              ifNotReferencedIn: remaining)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("attachments/shot.png").path),
                      "a still-referenced original must be kept so a remaining item's link doesn't break")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-refile-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeAttachment(in dir: URL, named name: String, contents: String) throws -> URL {
        let attachments = dir.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let url = attachments.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
