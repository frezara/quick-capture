import XCTest
@testable import QuickCapture

final class FileWriterTests: XCTestCase {

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

    // MARK: - singleInsertionDelta (split-mode targeted insert)

    func testSingleInsertionDeltaReproducesInsertOutput() {
        // For each scenario, the delta applied to the old buffer must reproduce
        // exactly what FileWriter.insert returns — that's what lets the editor
        // apply a targeted transaction instead of a full setContent.
        let scenarios: [(content: String, item: String, heading: String)] = [
            ("", "- [ ] first", "home"),
            ("# Inbox\n\n## work\n- [ ] task A !!\n- [ ] task B\n", "- [ ] urgent !!!", "work"),
            ("# Inbox\n\n## work\n- [ ] task A !!\n- [ ] plain\n", "- [ ] mid !", "work"),
            ("# Inbox\n\n## home\n- [ ] x\n", "- [ ] standup", "work"),   // new section
        ]
        for s in scenarios {
            let new = FileWriter.insert(item: s.item, underHeading: s.heading, in: s.content)
            guard let (from, inserted) = MainPanel.singleInsertionDelta(from: s.content, to: new) else {
                XCTFail("expected a single contiguous insertion for item \(s.item)")
                continue
            }
            // The only guarantee that matters: applying the delta reproduces
            // FileWriter.insert's output exactly. The inserted *run* is the
            // minimal diff (common prefix AND suffix stripped), so it needn't
            // equal `s.item` verbatim — when the new item shares its `- [ ] `
            // prefix with the adjacent task, that prefix is absorbed into the
            // shared region and the run is a correct rotation.
            XCTAssertEqual(applyUTF16Insertion(to: s.content, at: from, inserting: inserted), new,
                           "delta must reproduce FileWriter.insert output for item \(s.item)")
        }
    }

    func testSingleInsertionDeltaNilWhenNotAPureInsertion() {
        XCTAssertNil(MainPanel.singleInsertionDelta(from: "abc", to: "abc"), "no change → nil")
        XCTAssertNil(MainPanel.singleInsertionDelta(from: "abc", to: "axc"), "replacement → nil")
        XCTAssertNil(MainPanel.singleInsertionDelta(from: "abc", to: "ab"),  "deletion → nil")
    }

    // MARK: - Helpers

    /// Mirrors the CodeMirror transaction `insertCapture` performs: insert
    /// `inserting` at UTF-16 offset `at`.
    private func applyUTF16Insertion(to old: String, at: Int, inserting: String) -> String {
        var units = Array(old.utf16)
        units.insert(contentsOf: Array(inserting.utf16), at: at)
        return String(utf16CodeUnits: units, count: units.count)
    }

    private func makeTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-test-\(UUID().uuidString).md")
    }
}
