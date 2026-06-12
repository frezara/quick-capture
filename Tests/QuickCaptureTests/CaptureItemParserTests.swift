import XCTest
@testable import QuickCapture

final class CaptureItemParserTests: XCTestCase {

    // MARK: - Tagging by section

    func testItemsTaggedByEnclosingSection() {
        let content = """
        # Inbox

        ## home
        - [ ] mow lawn

        ## work
        - [ ] standup
        - [ ] ship it
        """
        let items = CaptureItemParser.parse(content)
        XCTAssertEqual(items.map(\.tag), ["home", "work", "work"])
        XCTAssertEqual(items.map(\.displayText), ["mow lawn", "standup", "ship it"])
    }

    func testCatchAllItemsTagAsQuickCapture() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] random thought
        """
        let items = CaptureItemParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].tag, "Quick capture")
        XCTAssertEqual(items[0].tag, FileWriter.untaggedSection)
    }

    // MARK: - Priority bucket parity with FileWriter

    func testPriorityBucketMatchesFileWriter() {
        let token = FileWriter.creationToken(for: Date(timeIntervalSince1970: 1_700_000_000))
        let content = """
        # Inbox

        ## work
        - [ ] urgent !!! \(token)
        - [ ] high !!
        - [ ] low !
        - [ ] plain
        - [x] done
        """
        let items = CaptureItemParser.parse(content)
        XCTAssertEqual(items.map(\.priorityBucket), [0, 1, 2, 3, 4])
        // Each item's bucket equals FileWriter's verdict on its raw line.
        let rawLines = content.components(separatedBy: "\n").filter {
            $0.range(of: #"^[-*+]\s+\["#, options: .regularExpression) != nil
        }
        for (item, raw) in zip(items, rawLines) {
            XCTAssertEqual(item.priorityBucket, FileWriter.priorityBucket(for: raw))
        }
    }

    // MARK: - Display text stripping (R6)

    func testDisplayTextStripsTokenTimestampAndPriorityMarkers() {
        let token = FileWriter.creationToken(for: Date(timeIntervalSince1970: 1_700_000_000))
        let content = """
        # Inbox

        ## work
        - [ ] buy milk !!! ➕ 2023-11-14 22:13 \(token)
        - [x] shipped ! \(token)
        - [ ] plain text \(token)
        """
        let items = CaptureItemParser.parse(content)
        XCTAssertEqual(items[0].displayText, "buy milk",
                       "token, ➕ suffix, and trailing !!! must all be stripped")
        XCTAssertEqual(items[1].displayText, "shipped")
        XCTAssertEqual(items[2].displayText, "plain text")
    }

    func testDisplayTextOnTokenlessHandAuthoredLine() {
        let content = """
        # Inbox

        ## work
        - [ ] hand authored !!
        """
        let items = CaptureItemParser.parse(content)
        XCTAssertEqual(items[0].displayText, "hand authored")
        XCTAssertEqual(items[0].priorityBucket, 1)
        XCTAssertNil(items[0].createdAt)
    }

    // MARK: - Recency (R10)

    func testRecencySortNewestFirstTokenlessLast() {
        let older = FileWriter.creationToken(for: Date(timeIntervalSince1970: 1_600_000_000))
        let newer = FileWriter.creationToken(for: Date(timeIntervalSince1970: 1_700_000_000))
        let content = """
        # Inbox

        ## work
        - [ ] tokenless one
        - [ ] older item \(older)
        - [ ] tokenless two
        - [ ] newer item \(newer)
        """
        let sorted = CaptureItemParser.recencySorted(CaptureItemParser.parse(content))
        XCTAssertEqual(
            sorted.map(\.displayText),
            ["newer item", "older item", "tokenless one", "tokenless two"],
            "timestamped items sort newest-first; tokenless items follow in original file order"
        )
    }

    func testRecencySortIsStableForEqualTimestamps() {
        let same = FileWriter.creationToken(for: Date(timeIntervalSince1970: 1_700_000_000))
        let content = """
        # Inbox

        ## work
        - [ ] first \(same)
        - [ ] second \(same)
        """
        let sorted = CaptureItemParser.recencySorted(CaptureItemParser.parse(content))
        XCTAssertEqual(sorted.map(\.displayText), ["first", "second"],
                       "ties preserve original file order")
    }

    // MARK: - Tag summary (R7)

    func testTagSummaryReportsPerTagCounts() {
        let content = """
        # Inbox

        ## home
        - [ ] mow lawn
        - [ ] water plants

        ## work
        - [ ] standup
        """
        let summary = CaptureItemParser.tagSummary(content)
        XCTAssertEqual(summary, [
            CaptureTagSummary(tag: "home", count: 2),
            CaptureTagSummary(tag: "work", count: 1),
        ])
    }

    func testTagSummaryIncludesEmptySectionsWithZeroCount() {
        let content = """
        # Inbox

        ## home
        - [ ] mow lawn

        ## someday

        ## work
        - [ ] standup
        """
        let summary = CaptureItemParser.tagSummary(content)
        XCTAssertEqual(summary, [
            CaptureTagSummary(tag: "home", count: 1),
            CaptureTagSummary(tag: "someday", count: 0),
            CaptureTagSummary(tag: "work", count: 1),
        ], "every ## section is reported; an empty one has count 0")
    }

    // MARK: - Line numbers and nested-line handling

    func testLineNumbersPointAtItemLineAndSkipNestedChildren() {
        let content = """
        # Inbox

        ## work
        - [ ] parent task
          ![screenshot](attachments/shot.png)
          - [ ] nested child
        - [ ] sibling task
        """
        let lines = content.components(separatedBy: "\n")
        let items = CaptureItemParser.parse(content)

        // Only the two top-level tasks surface; the attachment and nested child
        // are not separate items.
        XCTAssertEqual(items.map(\.displayText), ["parent task", "sibling task"])
        XCTAssertEqual(lines[items[0].line], "- [ ] parent task")
        XCTAssertEqual(lines[items[1].line], "- [ ] sibling task")
        // The nested child's text must not appear as its own item.
        XCTAssertFalse(items.contains { $0.displayText == "nested child" })
    }

    func testNestedChildrenDoNotShiftParentReportedLine() {
        let content = """
        # Inbox

        ## work
        - [ ] alpha
          ![screenshot](attachments/a.png)
        - [ ] beta
        """
        let lines = content.components(separatedBy: "\n")
        let items = CaptureItemParser.parse(content)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(lines[items[0].line], "- [ ] alpha")
        XCTAssertEqual(lines[items[1].line], "- [ ] beta")
    }

    // MARK: - Empty / edge cases

    func testEmptyFileYieldsNoItems() {
        XCTAssertTrue(CaptureItemParser.parse("").isEmpty)
        XCTAssertTrue(CaptureItemParser.tagSummary("").isEmpty)
    }

    func testInboxHeadingOnlyYieldsNoItems() {
        let content = "# Inbox\n"
        XCTAssertTrue(CaptureItemParser.parse(content).isEmpty)
        XCTAssertTrue(CaptureItemParser.tagSummary(content).isEmpty)
    }

    func testSectionWithNoItemsCountsZero() {
        let content = """
        # Inbox

        ## empty section
        """
        XCTAssertTrue(CaptureItemParser.parse(content).isEmpty)
        XCTAssertEqual(CaptureItemParser.tagSummary(content),
                       [CaptureTagSummary(tag: "empty section", count: 0)])
    }

    func testH3HeadingIsNotTreatedAsSection() {
        // An H3 must not register as a Jump-to-tag section; the item beneath it
        // keeps the enclosing ## section's tag.
        let content = """
        # Inbox

        ## work
        ### a sub heading
        - [ ] under work
        """
        let items = CaptureItemParser.parse(content)
        XCTAssertEqual(items.map(\.tag), ["work"])
        XCTAssertEqual(CaptureItemParser.tagSummary(content),
                       [CaptureTagSummary(tag: "work", count: 1)])
    }
}
