import XCTest
@testable import QuickCapture

/// Module 3 — `RefileService` integration (issue #32). Drives the full disk
/// pipeline over temp dirs: verify → copy → rewrite/dedent → write target →
/// write source → delete originals. The central guarantee under test is that
/// any failure leaves the source completely intact — the item never vanishes.
final class RefileServiceTests: XCTestCase {

    func testHappyPathMovesSubtreeAndAttachment() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceInbox = source.appendingPathComponent("inbox.md")
        try """
        # Inbox

        ## Quick capture
        - [ ] keep this
        - [ ] move me !!
          ![screenshot](attachments/a.png)
        - [ ] keep this too
        """.write(to: sourceInbox, atomically: true, encoding: .utf8)
        try writeAttachment(in: source, named: "a.png", contents: "img-bytes")

        let subtree = "- [ ] move me !!\n  ![screenshot](attachments/a.png)"
        try RefileService.refile(subtree: subtree, range: 4..<6, from: sourceInbox, toFolder: target)

        let newSource = try String(contentsOf: sourceInbox, encoding: .utf8)
        XCTAssertFalse(newSource.contains("move me"), "source must lose the refiled subtree")
        XCTAssertTrue(newSource.contains("- [ ] keep this\n- [ ] keep this too"), "surrounding items stay put")

        let targetInbox = try String(contentsOf: target.appendingPathComponent("inbox.md"), encoding: .utf8)
        XCTAssertTrue(targetInbox.hasPrefix("# Inbox"), "target inbox is scaffolded with # Inbox")
        XCTAssertTrue(targetInbox.contains("- [ ] move me !!\n  ![screenshot](attachments/a.png)"),
                      "target gains the subtree with its link intact; got:\n\(targetInbox)")

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("attachments/a.png"), encoding: .utf8),
                       "img-bytes", "the image travels into the target's attachments/")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("attachments/a.png").path),
                       "the now-unreferenced source original is removed")
    }

    func testNestedSubtreeIsPromotedToTopLevelInTarget() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceInbox = source.appendingPathComponent("inbox.md")
        try """
        # Inbox

        ## Quick capture
        - [ ] parent
          - [ ] move this child
            sub note
        """.write(to: sourceInbox, atomically: true, encoding: .utf8)

        let subtree = "  - [ ] move this child\n    sub note"
        try RefileService.refile(subtree: subtree, range: 4..<6, from: sourceInbox, toFolder: target)

        let targetInbox = try String(contentsOf: target.appendingPathComponent("inbox.md"), encoding: .utf8)
        XCTAssertTrue(targetInbox.contains("- [ ] move this child\n  sub note"),
                      "a nested subtree lands at column 0 with descendants shifted to match; got:\n\(targetInbox)")
    }

    func testCollisionRewritesLinkOnlyOnRename() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceInbox = source.appendingPathComponent("inbox.md")
        try """
        # Inbox

        ## Quick capture
        - [ ] move me
          ![screenshot](attachments/a.png)
        """.write(to: sourceInbox, atomically: true, encoding: .utf8)
        try writeAttachment(in: source, named: "a.png", contents: "incoming")
        try writeAttachment(in: target, named: "a.png", contents: "already there")

        let subtree = "- [ ] move me\n  ![screenshot](attachments/a.png)"
        try RefileService.refile(subtree: subtree, range: 3..<5, from: sourceInbox, toFolder: target)

        let targetInbox = try String(contentsOf: target.appendingPathComponent("inbox.md"), encoding: .utf8)
        XCTAssertTrue(targetInbox.contains("![screenshot](attachments/a-2.png)"),
                      "the moved item's link is rewritten to the de-collided name; got:\n\(targetInbox)")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("attachments/a.png"), encoding: .utf8),
                       "already there", "the pre-existing target attachment is untouched")
    }

    func testDriftedContentAbortsAndChangesNothing() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceInbox = source.appendingPathComponent("inbox.md")
        let original = """
        # Inbox

        ## Quick capture
        - [ ] on disk
        """
        try original.write(to: sourceInbox, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try RefileService.refile(subtree: "- [ ] editor thought this", range: 3..<4, from: sourceInbox, toFolder: target)
        ) { error in
            guard case FileWriter.RefileError.contentDrifted = error else {
                return XCTFail("expected contentDrifted, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: sourceInbox, encoding: .utf8), original, "source must be byte-for-byte unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("inbox.md").path),
                       "no target inbox is created when the refile aborts")
    }

    func testUnwritableTargetLeavesSourceIntact() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir()
        let sourceInbox = source.appendingPathComponent("inbox.md")
        let original = """
        # Inbox

        ## Quick capture
        - [ ] move me
        - [ ] keep me
        """
        try original.write(to: sourceInbox, atomically: true, encoding: .utf8)

        // Make the target folder read-only so writing inbox.md fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try? FileManager.default.removeItem(at: target)
        }

        XCTAssertThrowsError(
            try RefileService.refile(subtree: "- [ ] move me", range: 3..<4, from: sourceInbox, toFolder: target),
            "an unwritable target must surface as a thrown error"
        )
        XCTAssertEqual(try String(contentsOf: sourceInbox, encoding: .utf8), original,
                       "the source is left completely intact — the item never vanishes (the central safety guarantee)")
    }

    func testRefilePreservesHiddenTokenOnEachLine() throws {
        let source = try makeTempDir(); defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTempDir(); defer { try? FileManager.default.removeItem(at: target) }
        let sourceInbox = source.appendingPathComponent("inbox.md")
        let token = "<!--qc:2023-11-14T22:13:20Z-->"
        let childToken = "<!--qc:2020-09-13T12:26:40Z-->"
        try """
        # Inbox

        ## Quick capture
        - [ ] keep this \(childToken)
        - [ ] move me !! \(token)
          - [ ] nested \(childToken)
        - [ ] keep this too
        """.write(to: sourceInbox, atomically: true, encoding: .utf8)

        let subtree = "- [ ] move me !! \(token)\n  - [ ] nested \(childToken)"
        try RefileService.refile(subtree: subtree, range: 4..<6, from: sourceInbox, toFolder: target)

        let targetInbox = try String(contentsOf: target.appendingPathComponent("inbox.md"), encoding: .utf8)
        XCTAssertTrue(targetInbox.contains("- [ ] move me !! \(token)\n  - [ ] nested \(childToken)"),
                      "the refiled subtree keeps the hidden token on every line; got:\n\(targetInbox)")

        let newSource = try String(contentsOf: sourceInbox, encoding: .utf8)
        XCTAssertTrue(newSource.contains("- [ ] keep this \(childToken)"),
                      "the untouched neighbor keeps its token; got:\n\(newSource)")
        XCTAssertFalse(newSource.contains("move me"), "source loses the refiled subtree")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-refile-service-\(UUID().uuidString)", isDirectory: true)
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
