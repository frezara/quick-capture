import XCTest
@testable import QuickCapture

final class FileWriterTests: XCTestCase {

    // MARK: - scaffoldContent

    func testScaffoldContentStartsWithDocumentHeading() {
        XCTAssertTrue(FileWriter.scaffoldContent.hasPrefix("# Inbox"))
    }

    func testScaffoldContentContainsWelcomeTodo() {
        XCTAssertTrue(
            FileWriter.scaffoldContent.contains("- [ ]"),
            "scaffold must include at least one todo so the editor has content on first run"
        )
    }

    func testScaffoldContentContainsMentionOfHotkey() {
        XCTAssertTrue(
            FileWriter.scaffoldContent.contains("⌥T") || FileWriter.scaffoldContent.contains("⌘F"),
            "scaffold welcome entry should mention the core gestures"
        )
    }

    // MARK: - insert(item:underHeading:in:)

    func testInsertCreatesHeadingAndItemWhenContentIsEmpty() {
        let result = FileWriter.insert(item: "- [ ] buy milk", underHeading: "home", in: "")
        XCTAssertEqual(result, "## home\n- [ ] buy milk\n")
    }

    func testInsertPrependsAboveExistingItemsUnderHeading() {
        let content = """
        # Inbox

        ## home
        - [ ] mow lawn
        """
        let result = FileWriter.insert(item: "- [ ] buy milk", underHeading: "home", in: content)
        XCTAssertTrue(result.contains("- [ ] buy milk\n- [ ] mow lawn"),
                      "new item should be inserted above existing items under the heading; got:\n\(result)")
    }

    func testInsertMatchesHeadingCaseInsensitively() {
        let content = """
        # Inbox

        ## Home
        - [ ] mow lawn
        """
        let result = FileWriter.insert(item: "- [ ] buy milk", underHeading: "home", in: content)
        XCTAssertTrue(result.contains("## Home"),  "original heading casing preserved")
        XCTAssertTrue(result.contains("- [ ] buy milk\n- [ ] mow lawn"),
                      "new item should land at the top of the existing ## Home section")
    }

    func testInsertAppendsNewSectionWhenHeadingMissing() {
        let content = "# Inbox\n\n## home\n- [ ] mow lawn\n"
        let result = FileWriter.insert(item: "- [ ] standup", underHeading: "work", in: content)
        XCTAssertTrue(result.contains("## work\n- [ ] standup"),
                      "new heading + item should be appended at end; got:\n\(result)")
    }

    func testInsertStopsAtNextHeading() {
        let content = """
        # Inbox

        ## home
        - [ ] mow lawn

        ## work
        - [ ] standup
        """
        let result = FileWriter.insert(item: "- [ ] buy milk", underHeading: "home", in: content)
        // The new item should land inside the home section, before the ## work heading.
        let homeIndex = result.range(of: "## home")!.lowerBound
        let workIndex = result.range(of: "## work")!.lowerBound
        let milkIndex = result.range(of: "- [ ] buy milk")!.lowerBound
        XCTAssertTrue(homeIndex < milkIndex && milkIndex < workIndex,
                      "new item must land between ## home and ## work")
    }

    // MARK: - insert priority-aware ordering

    func testInsertHighPriorityGoesAboveAllLower() {
        let content = """
        # Inbox

        ## work
        - [ ] task A !!
        - [ ] task B !
        - [ ] task C
        """
        let result = FileWriter.insert(item: "- [ ] urgent !!!", underHeading: "work", in: content)
        // New !!! should land directly under the heading, above everything.
        XCTAssertTrue(result.contains("## work\n- [ ] urgent !!!\n- [ ] task A !!"),
                      "!!! item should be at the top of the section; got:\n\(result)")
    }

    func testInsertMediumPriorityLandsAfterAllHigh() {
        let content = """
        # Inbox

        ## work
        - [ ] hot !!!
        - [ ] other !!
        - [ ] task C
        """
        let result = FileWriter.insert(item: "- [ ] new med !!", underHeading: "work", in: content)
        // New !! sits after the !!! block but ABOVE the existing !! (newer-first
        // within a bucket).
        XCTAssertTrue(result.contains("- [ ] hot !!!\n- [ ] new med !!\n- [ ] other !!"),
                      "!! item should land after !!! and above existing !!; got:\n\(result)")
    }

    func testInsertNoPriorityLandsAfterAllPriorityItems() {
        let content = """
        # Inbox

        ## work
        - [ ] hot !!!
        - [ ] med !!
        - [ ] low !
        - [ ] existing plain
        """
        let result = FileWriter.insert(item: "- [ ] plain", underHeading: "work", in: content)
        XCTAssertTrue(result.contains("- [ ] low !\n- [ ] plain\n- [ ] existing plain"),
                      "no-priority item should sit after all priorities; got:\n\(result)")
    }

    func testInsertPriorityItemSkipsOverIndentedChildren() {
        let content = """
        # Inbox

        ## work
        - [ ] parent !!
          - sub of parent
        - [ ] other
        """
        let result = FileWriter.insert(item: "- [ ] new !", underHeading: "work", in: content)
        // New ! item belongs after the !! parent + its indented child, before
        // the plain "other".
        XCTAssertTrue(result.contains("- [ ] parent !!\n  - sub of parent\n- [ ] new !\n- [ ] other"),
                      "priority insertion must step over indented children of higher-priority parents; got:\n\(result)")
    }

    // MARK: - ensureDocumentHeading(in:)

    func testEnsureDocumentHeadingOnEmpty() {
        XCTAssertEqual(FileWriter.ensureDocumentHeading(in: ""), "# Inbox\n")
    }

    func testEnsureDocumentHeadingPrependsWhenMissing() {
        let result = FileWriter.ensureDocumentHeading(in: "## home\n- [ ] x")
        XCTAssertTrue(result.hasPrefix("# Inbox\n\n## home"))
    }

    func testEnsureDocumentHeadingPreservesWhenPresent() {
        let content = "# Inbox\n\n## home\n"
        XCTAssertEqual(FileWriter.ensureDocumentHeading(in: content), content)
    }

    func testEnsureDocumentHeadingCaseInsensitive() {
        let content = "# inbox\n\n## home\n"
        // Already-present heading is preserved as-is (case-insensitive match).
        XCTAssertEqual(FileWriter.ensureDocumentHeading(in: content), content)
    }

    // MARK: - appendTodo (integration)

    func testAppendTodoCreatesFileWithInboxAndQuickCaptureSection() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileWriter.appendTodo("buy milk", to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Inbox"), "file should start with # Inbox")
        XCTAssertTrue(content.contains("## Quick capture"), "untagged items go under ## Quick capture")
        XCTAssertTrue(content.contains("- [ ] buy milk"))
    }

    func testAppendTodoRoutesTaggedItemUnderTagSection() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileWriter.appendTodo("mow lawn", tag: "home", to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("## home\n- [ ] mow lawn"))
        XCTAssertFalse(content.contains("## Quick capture"),
                       "tagged items should not create the untagged section")
    }

    func testAppendTodoAppendsTimestampWhenRequested() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
        try FileWriter.appendTodo("buy milk", to: url, includeTimestamp: true, now: fixed)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("\(FileWriter.createdMarker) "),
                      "timestamp marker should be present")
        // YYYY-MM-DD HH:MM pattern check (loose — exact value depends on local TZ).
        let regex = try NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#)
        let nsContent = content as NSString
        XCTAssertGreaterThan(
            regex.numberOfMatches(in: content, range: NSRange(location: 0, length: nsContent.length)),
            0,
            "timestamp should match YYYY-MM-DD HH:MM"
        )
    }

    // MARK: - timestampString

    func testTimestampStringFormat() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let s = FileWriter.timestampString(for: fixed)
        // Just verify the shape — the exact value depends on the runner's timezone.
        XCTAssertEqual(s.count, "yyyy-MM-dd HH:mm".count)
        let regex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#)
        XCTAssertEqual(
            regex.numberOfMatches(in: s, range: NSRange(location: 0, length: s.count)),
            1
        )
    }

    // MARK: - todoLine / sectionName parity (disk path vs. split-buffer path)

    func testTodoLineReproducesAppendTodoLineExactly() throws {
        // Split mode builds its item via FileWriter.todoLine; the disk path
        // builds it inside appendTodo. They must be byte-identical or captures
        // would format differently depending on whether the editor is open.
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)

        try FileWriter.appendTodo("buy milk", tag: "home", to: url, includeTimestamp: true, now: fixed)
        let written = try String(contentsOf: url, encoding: .utf8)
        let line = FileWriter.todoLine("buy milk", includeTimestamp: true, now: fixed)

        XCTAssertTrue(written.contains(line),
                      "todoLine must reproduce the exact line appendTodo writes.\nline: \(line)\nfile:\n\(written)")
    }

    func testTodoLineWithoutTimestampIsPlainTask() {
        XCTAssertEqual(FileWriter.todoLine("buy milk", includeTimestamp: false), "- [ ] buy milk")
    }

    func testSectionNameRoutingMatchesAppendTodo() {
        XCTAssertEqual(FileWriter.sectionName(for: "home"), "home")
        XCTAssertEqual(FileWriter.sectionName(for: "  work  "), "work")
        XCTAssertEqual(FileWriter.sectionName(for: nil), FileWriter.untaggedSection)
        XCTAssertEqual(FileWriter.sectionName(for: "   "), FileWriter.untaggedSection)
    }

    // MARK: - Attachment child lines (insert)

    func testInsertPairLandsTogetherAbovePlainItems() {
        let content = """
        # Inbox

        ## work
        - [ ] existing plain
        """
        let result = FileWriter.insert(
            item: "- [ ] fix layout !!",
            childLines: ["  ![screenshot](attachments/shot.png)"],
            underHeading: "work",
            in: content
        )
        XCTAssertTrue(
            result.contains("- [ ] fix layout !!\n  ![screenshot](attachments/shot.png)\n- [ ] existing plain"),
            "todo + image child must land together, above plain items; got:\n\(result)"
        )
    }

    func testInsertDoesNotSplitExistingAttachmentPair() {
        let content = """
        # Inbox

        ## work
        - [ ] with image !!
          ![screenshot](attachments/shot.png)
        - [ ] plain
        """
        let result = FileWriter.insert(item: "- [ ] urgent !!!", underHeading: "work", in: content)
        XCTAssertTrue(
            result.contains("- [ ] with image !!\n  ![screenshot](attachments/shot.png)"),
            "a later insert must never split an existing todo + image pair; got:\n\(result)"
        )
        XCTAssertTrue(
            result.contains("## work\n- [ ] urgent !!!\n- [ ] with image !!"),
            "!!! item should land above the !! pair; got:\n\(result)"
        )
    }

    func testInsertMediumPriorityStepsOverPairAndLandsBeforeLower() {
        let content = """
        # Inbox

        ## work
        - [ ] hot !!!
          ![screenshot](attachments/hot.png)
        - [ ] low !
        """
        let result = FileWriter.insert(item: "- [ ] med !!", underHeading: "work", in: content)
        XCTAssertTrue(
            result.contains("- [ ] hot !!!\n  ![screenshot](attachments/hot.png)\n- [ ] med !!\n- [ ] low !"),
            "insert must step over the pair as a unit; got:\n\(result)"
        )
    }

    func testInsertPairIntoMissingHeadingCreatesSectionWithBothLines() {
        let result = FileWriter.insert(
            item: "- [ ] buy milk",
            childLines: ["  ![screenshot](attachments/milk.png)"],
            underHeading: "home",
            in: ""
        )
        XCTAssertEqual(result, "## home\n- [ ] buy milk\n  ![screenshot](attachments/milk.png)\n")
    }

    // MARK: - Attachment child lines (appendTodo integration)

    func testAppendTodoWritesAttachmentChildLine() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileWriter.appendTodo("fix layout !!", tag: "work", to: url, attachmentLink: "attachments/shot.png")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            content.contains("- [ ] fix layout !!\n  ![screenshot](attachments/shot.png)"),
            "attachment child line must directly follow the todo, leaving trailing priority markers on the todo line; got:\n\(content)"
        )
    }

    func testAppendTodoUntaggedPairLandsUnderQuickCapture() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileWriter.appendTodo("buy milk", to: url, attachmentLink: "attachments/milk.png")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            content.contains("## Quick capture\n- [ ] buy milk\n  ![screenshot](attachments/milk.png)"),
            "untagged pair routes under ## Quick capture; got:\n\(content)"
        )
    }

    func testAppendTodoTimestampedPairStillClassifiesPriority() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)

        try FileWriter.appendTodo("plain task", tag: "work", to: url)
        try FileWriter.appendTodo(
            "urgent !!!",
            tag: "work",
            to: url,
            includeTimestamp: true,
            now: fixed,
            attachmentLink: "attachments/urgent.png"
        )

        let content = try String(contentsOf: url, encoding: .utf8)
        let urgentIndex = content.range(of: "- [ ] urgent !!!")!.lowerBound
        let childIndex = content.range(of: "![screenshot](attachments/urgent.png)")!.lowerBound
        let plainIndex = content.range(of: "- [ ] plain task")!.lowerBound
        XCTAssertTrue(
            urgentIndex < childIndex && childIndex < plainIndex,
            "timestamped !!! pair must classify on the parent line and land above plain items; got:\n\(content)"
        )
    }

    // MARK: - attachmentChildLine

    func testAttachmentChildLineFormat() {
        XCTAssertEqual(
            FileWriter.attachmentChildLine("attachments/shot.png"),
            "  ![screenshot](attachments/shot.png)"
        )
    }

    // MARK: - Archive carries attachment children

    func testExtractCompletedMovesChildWithCheckedParent() {
        let content = """
        # Inbox

        ## work
        - [x] done task
          ![screenshot](attachments/done.png)
        - [ ] open task
        """
        let (remaining, items) = FileWriter.extractCompletedItems(from: content)
        XCTAssertFalse(remaining.contains("![screenshot]"),
                       "child line must not be stranded in the source; got:\n\(remaining)")
        XCTAssertTrue(remaining.contains("- [ ] open task"))
        XCTAssertEqual(items, [
            FileWriter.ArchivedItem(
                text: "- [x] done task",
                section: "work",
                children: ["  ![screenshot](attachments/done.png)"]
            )
        ])
    }

    func testExtractCompletedLeavesUncheckedParentsChildAlone() {
        let content = """
        # Inbox

        ## work
        - [ ] open task
          ![screenshot](attachments/open.png)
        - [x] done plain
        """
        let (remaining, items) = FileWriter.extractCompletedItems(from: content)
        XCTAssertTrue(remaining.contains("- [ ] open task\n  ![screenshot](attachments/open.png)"),
                      "unchecked parent keeps its child; got:\n\(remaining)")
        XCTAssertEqual(items, [FileWriter.ArchivedItem(text: "- [x] done plain", section: "work")])
    }

    func testExtractCompletedPairAtEndOfFileWithoutTrailingNewline() {
        let content = "# Inbox\n\n## work\n- [x] last\n  ![screenshot](attachments/last.png)"
        let (remaining, items) = FileWriter.extractCompletedItems(from: content)
        XCTAssertTrue(remaining.contains("## work"), "section heading survives; got:\n\(remaining)")
        XCTAssertFalse(remaining.contains("![screenshot]"))
        XCTAssertEqual(items, [
            FileWriter.ArchivedItem(
                text: "- [x] last",
                section: "work",
                children: ["  ![screenshot](attachments/last.png)"]
            )
        ])
    }

    func testExtractCompletedReindentsChildOfIndentedCheckedParent() {
        let content = """
        # Inbox

        ## work
        - [ ] parent
            - [x] nested done
              ![screenshot](attachments/nested.png)
        """
        let (_, items) = FileWriter.extractCompletedItems(from: content)
        XCTAssertEqual(items, [
            FileWriter.ArchivedItem(
                text: "- [x] nested done",
                section: "work",
                children: ["  ![screenshot](attachments/nested.png)"]
            )
        ], "parent flattens, child normalizes to a 2-space indent")
    }

    func testArchiveCompletedWritesPairToArchiveFile() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = FileWriter.archiveURL(for: url)
        defer { try? FileManager.default.removeItem(at: archive) }

        let content = """
        # Inbox

        ## work
        - [x] shipped !!
          ![screenshot](attachments/shipped.png)
        - [ ] still open
        """
        try content.write(to: url, atomically: true, encoding: .utf8)

        try FileWriter.archiveCompleted(at: url)

        let source = try String(contentsOf: url, encoding: .utf8)
        let archived = try String(contentsOf: archive, encoding: .utf8)
        XCTAssertFalse(source.contains("![screenshot]"), "source must not strand the child; got:\n\(source)")
        XCTAssertTrue(source.contains("- [ ] still open"))
        XCTAssertTrue(
            archived.contains("- [x] shipped !!\n  ![screenshot](attachments/shipped.png)"),
            "archive must keep the pair adjacent under the section; got:\n\(archived)"
        )
        XCTAssertTrue(archived.contains("## work"))
    }

    // MARK: - Helpers

    private func makeTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-test-\(UUID().uuidString).md")
    }
}
