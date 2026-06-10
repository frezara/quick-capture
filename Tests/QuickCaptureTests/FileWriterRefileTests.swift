import XCTest
@testable import QuickCapture

/// Module 1 — `FileWriter` refile core. Pure string-in/string-out functions
/// behind the ⌘R refile gesture (issue #32), unit-tested without a filesystem
/// or UI, in the style of `insert` / `extractCompletedItems`.
final class FileWriterRefileTests: XCTestCase {

    // MARK: - subtreeRange

    func testSubtreeRangeCoversItemAndAttachmentChild() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] fix the thing
          ![screenshot](attachments/a.png)
        - [ ] another
        """
        // Cursor on the item line (index 3).
        let range = FileWriter.subtreeRange(in: content, atLine: 3)
        XCTAssertEqual(range, 3..<5,
                       "subtree must cover the item line and its indented attachment child, stopping at the sibling item")
    }

    func testSubtreeRangeCursorOnAttachmentChildResolvesUpToOwningItem() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] fix the thing
          ![screenshot](attachments/a.png)
        - [ ] another
        """
        // Cursor on the attachment child line (index 4) resolves up to its item.
        let range = FileWriter.subtreeRange(in: content, atLine: 4)
        XCTAssertEqual(range, 3..<5, "cursor on a child line must resolve up to the owning item's subtree")
    }

    func testSubtreeRangeIncludesNestedChildItems() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] parent
          - [ ] child one
            ![screenshot](attachments/a.png)
          - [x] child two
        - [ ] sibling
        """
        let range = FileWriter.subtreeRange(in: content, atLine: 3)
        XCTAssertEqual(range, 3..<7,
                       "subtree must include nested child items and their attachments, stopping at the sibling")
    }

    func testSubtreeRangeCursorOnNestedChildItemTakesThatChildSubtree() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] parent
          - [ ] child one
            ![screenshot](attachments/a.png)
          - [x] child two
        """
        // Cursor on the nested child item (index 4): refile that child's subtree.
        let range = FileWriter.subtreeRange(in: content, atLine: 4)
        XCTAssertEqual(range, 4..<6,
                       "cursor on a nested child item refiles that child's own subtree (item + its attachment)")
    }

    func testSubtreeRangeStopsAtHeading() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] last in section
          note line
        ## next
        - [ ] elsewhere
        """
        let range = FileWriter.subtreeRange(in: content, atLine: 3)
        XCTAssertEqual(range, 3..<5, "subtree must end before the next heading")
    }

    func testSubtreeRangeAtEndOfFileNoTrailingNewline() {
        let content = "# Inbox\n\n## Quick capture\n- [ ] only\n  ![screenshot](attachments/a.png)"
        let range = FileWriter.subtreeRange(in: content, atLine: 3)
        XCTAssertEqual(range, 3..<5, "subtree must extend to EOF when there is no trailing sibling")
    }

    func testSubtreeRangeOnBlankLineIsNil() {
        let content = "# Inbox\n\n## Quick capture\n- [ ] item\n"
        XCTAssertNil(FileWriter.subtreeRange(in: content, atLine: 1), "a blank line owns no item")
    }

    func testSubtreeRangeOnHeadingIsNil() {
        let content = "# Inbox\n\n## Quick capture\n- [ ] item\n"
        XCTAssertNil(FileWriter.subtreeRange(in: content, atLine: 2), "a heading owns no item")
    }

    // MARK: - verifyAndRemove

    func testVerifyAndRemoveExactMatchRemovesRange() throws {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] keep me
        - [ ] move me
          ![screenshot](attachments/a.png)
        - [ ] keep me too
        """
        let subtree = "- [ ] move me\n  ![screenshot](attachments/a.png)"
        let result = try FileWriter.verifyAndRemove(subtree: subtree, at: 4..<6, in: content)
        XCTAssertEqual(result, """
        # Inbox

        ## Quick capture
        - [ ] keep me
        - [ ] keep me too
        """)
    }

    func testVerifyAndRemoveOneCharDriftThrowsAndRemovesNothing() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] move me
        - [ ] keep
        """
        // Editor thinks the line reads "move ME" but disk says "move me".
        XCTAssertThrowsError(try FileWriter.verifyAndRemove(subtree: "- [ ] move ME", at: 3..<4, in: content)) { error in
            guard case FileWriter.RefileError.contentDrifted = error else {
                return XCTFail("expected contentDrifted, got \(error)")
            }
        }
    }

    // MARK: - dedent

    func testDedentTopLevelSubtreeUnchanged() {
        let subtree = "- [ ] parent\n  ![screenshot](attachments/a.png)"
        XCTAssertEqual(FileWriter.dedent(subtree), subtree, "an already top-level subtree is unchanged")
    }

    func testDedentNestedSubtreePromotesToColumnZeroPreservingRelativeNesting() {
        let subtree = "  - [ ] child\n    ![screenshot](attachments/a.png)\n    - [ ] grandchild"
        XCTAssertEqual(
            FileWriter.dedent(subtree),
            "- [ ] child\n  ![screenshot](attachments/a.png)\n  - [ ] grandchild",
            "the root shifts to column 0 and every descendant shifts left by the same delta"
        )
    }

    // MARK: - attachmentPaths

    func testAttachmentPathsPicksOutInFolderImages() {
        let subtree = """
        - [ ] parent
          ![screenshot](attachments/a.png)
          - [ ] child
            ![screenshot](attachments/b.jpg)
        """
        XCTAssertEqual(FileWriter.attachmentPaths(in: subtree),
                       ["attachments/a.png", "attachments/b.jpg"],
                       "every in-folder attachments/ image path is collected in order")
    }

    func testAttachmentPathsIgnoresUrlsAbsolutePathsAndNonImageLinks() {
        let subtree = """
        - [ ] parent
          ![remote](https://example.com/x.png)
          ![abs](/Users/me/Pictures/y.png)
          [a doc](attachments/notes.pdf)
          see [link](attachments/page.md)
        """
        XCTAssertEqual(FileWriter.attachmentPaths(in: subtree), [],
                       "URLs, absolute paths, and non-image (no `!`) links are ignored")
    }

    // MARK: - appendUnderInbox

    func testAppendUnderInboxLandsAtEndOfExistingInbox() {
        let target = """
        # Inbox

        - [ ] already here
        """
        let result = FileWriter.appendUnderInbox(subtree: "- [ ] refiled\n  ![screenshot](attachments/a.png)", to: target)
        XCTAssertEqual(result, "# Inbox\n\n- [ ] already here\n- [ ] refiled\n  ![screenshot](attachments/a.png)\n",
                       "subtree appends at end-of-file (FIFO arrival order), file ends with a single newline")
    }

    func testAppendUnderInboxScaffoldsInboxWhenTargetEmpty() {
        let result = FileWriter.appendUnderInbox(subtree: "- [ ] first ever", to: "")
        XCTAssertEqual(result, "# Inbox\n\n- [ ] first ever\n",
                       "an empty/new target gets a bare `# Inbox` scaffold, then the subtree")
    }

    func testAppendUnderInboxPreservesItemTextVerbatim() {
        let subtree = "- [x] shipped !!! ➕ 2026-06-01 09:30"
        let result = FileWriter.appendUnderInbox(subtree: subtree, to: "# Inbox\n")
        XCTAssertTrue(result.contains(subtree),
                      "priority markers, checkbox state, and the ➕ timestamp are preserved verbatim; got:\n\(result)")
    }
}
