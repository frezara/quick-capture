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

    // MARK: - Helpers

    private func makeTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-test-\(UUID().uuidString).md")
    }
}
