import XCTest
@testable import QuickCapture

final class DailyNoteTests: XCTestCase {
    private var folder: URL!
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyNoteTests-\(UUID().uuidString)/daily", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private func day(_ d: Int, _ m: Int = 10, _ y: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }

    private func write(_ text: String, on date: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: DailyNote.url(for: date, in: folder, calendar: calendar), atomically: true, encoding: .utf8)
    }

    private func read(_ date: Date) throws -> String {
        try String(contentsOf: DailyNote.url(for: date, in: folder, calendar: calendar), encoding: .utf8)
    }

    func testFolderSitsBesideTheCaptureFile() {
        let capture = URL(fileURLWithPath: "/Users/me/notes/inbox.md")
        XCTAssertEqual(DailyNote.folder(forCaptureFile: capture).path, "/Users/me/notes/daily")
    }

    func testFilenameAndHeading() {
        XCTAssertEqual(DailyNote.url(for: day(7, 3), in: folder, calendar: calendar).lastPathComponent, "2026-03-07.md")
        XCTAssertEqual(DailyNote.heading(for: day(17), calendar: calendar), "# Saturday 17 October 2026")
    }

    func testFirstNoteIsTheBareScaffold() throws {
        try DailyNote.ensureNote(for: day(17), today: day(17), in: folder, calendar: calendar)
        XCTAssertEqual(try read(day(17)), "# Saturday 17 October 2026\n\n## Tasks\n\n## Log\n")
    }

    func testUnfinishedSubtreesFollowTheRolloverRules() {
        let note = """
        # Friday 16 October 2026

        ## Tasks

        - [ ] Ship release
          - [x] write notes
          ![shot](attachments/a.png)
        - [x] Book dentist
          - [ ] call first
        - plain bullet
          - [ ] under a bullet

        ## Log

        Talked to Sam.
        - [ ] reply to Sam <!--qc-source:0f0e0d0c-0b0a-0908-0706-050403020100-->
        """
        XCTAssertEqual(DailyNote.unfinishedSubtrees(in: note), [
            "- [ ] Ship release\n  - [x] write notes\n  ![shot](attachments/a.png)",
            "- [ ] reply to Sam",
        ])
    }

    func testTodayCopiesFromTheMostRecentEarlierNoteAndLeavesItUntouched() throws {
        let friday = "# Friday 16 October 2026\n\n## Tasks\n\n- [ ] carry me\n- [x] done\n\n## Log\n"
        try write("# Wednesday\n\n## Tasks\n\n- [ ] stale\n", on: day(14))
        try write(friday, on: day(16))

        try DailyNote.ensureNote(for: day(19), today: day(19), in: folder, calendar: calendar)

        XCTAssertEqual(try read(day(19)), "# Monday 19 October 2026\n\n## Tasks\n\n- [ ] carry me\n\n## Log\n")
        XCTAssertEqual(try read(day(16)), friday, "earlier notes are never written")
    }

    func testRolloverRunsOnlyWhenTheNoteIsCreated() throws {
        try write("## Tasks\n- [ ] carry me\n", on: day(16))
        try write("# Mine\n\nedited by hand\n", on: day(17))
        try DailyNote.ensureNote(for: day(17), today: day(17), in: folder, calendar: calendar)
        XCTAssertEqual(try read(day(17)), "# Mine\n\nedited by hand\n")
    }

    func testPastAndFutureNotesStartEmpty() throws {
        try write("## Tasks\n- [ ] carry me\n", on: day(10))
        try DailyNote.ensureNote(for: day(12), today: day(17), in: folder, calendar: calendar)
        try DailyNote.ensureNote(for: day(20), today: day(17), in: folder, calendar: calendar)
        XCTAssertFalse(try read(day(12)).contains("carry me"))
        XCTAssertFalse(try read(day(20)).contains("carry me"))
    }

    func testMostRecentNoteIgnoresOtherFiles() throws {
        try write("x", on: day(15))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["2026-10-16.md.tmp", "notes.md", "2026-10-18.md"] {
            try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(DailyNote.mostRecentNote(before: day(17), in: folder, calendar: calendar)?.lastPathComponent,
                       "2026-10-15.md")
    }

    // MARK: - Plan for today

    func testInsertUnderTasksAppendsAfterTheLastItem() {
        let note = "# Day\n\n## Tasks\n\n- [ ] one\n  - child\n\n## Log\n\nwords\n"
        XCTAssertEqual(DailyNote.insertUnderTasks("- [ ] two", in: note),
                       "# Day\n\n## Tasks\n\n- [ ] one\n  - child\n- [ ] two\n\n## Log\n\nwords\n")
    }

    func testInsertUnderAnEmptyTasksSection() {
        XCTAssertEqual(DailyNote.insertUnderTasks("- [ ] two", in: "# Day\n\n## Tasks\n\n## Log\n"),
                       "# Day\n\n## Tasks\n\n- [ ] two\n\n## Log\n")
        XCTAssertEqual(DailyNote.insertUnderTasks("- [ ] two", in: "# Day\n\n## Tasks\n"),
                       "# Day\n\n## Tasks\n\n- [ ] two\n")
    }

    func testInsertRecreatesADeletedTasksSectionUnderTheDate() {
        XCTAssertEqual(DailyNote.insertUnderTasks("- [ ] two", in: "# Day\n## Log\n\nwords\n"),
                       "# Day\n\n## Tasks\n\n- [ ] two\n\n## Log\n\nwords\n")
    }

    func testPlanForTodayMovesTheSubtreeAndItsImageIntoTodaysNote() throws {
        let root = folder.deletingLastPathComponent()
        let inbox = root.appendingPathComponent("inbox.md")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try "img".write(to: root.appendingPathComponent("attachments/a.png"), atomically: true, encoding: .utf8)
        try """
        # Inbox

        ## Home
        - [ ] keep
        - [ ] fix the hinge <!--qc-source:0f0e0d0c-0b0a-0908-0706-050403020100-->
          ![shot](attachments/a.png)
        """.write(to: inbox, atomically: true, encoding: .utf8)
        try write("# Friday\n\n## Tasks\n\n- [ ] carried\n", on: day(16))

        let subtree = "- [ ] fix the hinge <!--qc-source:0f0e0d0c-0b0a-0908-0706-050403020100-->\n  ![shot](attachments/a.png)"
        let note = try PlanForToday.move(subtree: subtree, range: 4..<6, from: inbox, dailyFolder: folder,
                                         today: day(17), calendar: calendar)

        XCTAssertEqual(try read(day(17)),
                       "# Saturday 17 October 2026\n\n## Tasks\n\n- [ ] carried\n- [ ] fix the hinge\n  ![shot](attachments/a.png)\n\n## Log\n",
                       "today's note is created with rollover, then gains the item without its marker")
        XCTAssertEqual(try String(contentsOf: inbox, encoding: .utf8), "# Inbox\n\n## Home\n- [ ] keep")
        XCTAssertEqual(try String(contentsOf: note.deletingLastPathComponent().appendingPathComponent("attachments/a.png"),
                                  encoding: .utf8), "img")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/a.png").path))
    }

    func testPlanForTodayLeavesTheInboxAloneWhenItDrifted() throws {
        let root = folder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inbox = root.appendingPathComponent("inbox.md")
        let original = "# Inbox\n\n## Home\n- [ ] changed elsewhere\n"
        try original.write(to: inbox, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PlanForToday.move(subtree: "- [ ] fix the hinge", range: 3..<4, from: inbox,
                                                   dailyFolder: folder, today: day(17), calendar: calendar))
        XCTAssertEqual(try String(contentsOf: inbox, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DailyNote.url(for: day(17), in: folder, calendar: calendar).path))
    }
}
