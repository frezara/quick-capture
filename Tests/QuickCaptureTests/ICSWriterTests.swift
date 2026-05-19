import XCTest
@testable import QuickCapture

final class ICSWriterTests: XCTestCase {

    func testMakeICSContainsRequiredVCalendarStructure() {
        let event = CalendarEvent(
            title: "Standup",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1800
        )

        let ics = ICSWriter.makeICS(for: event, uid: "test-uid", now: event.start)

        XCTAssertTrue(ics.contains("BEGIN:VCALENDAR"))
        XCTAssertTrue(ics.contains("END:VCALENDAR"))
        XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
        XCTAssertTrue(ics.contains("END:VEVENT"))
        XCTAssertTrue(ics.contains("VERSION:2.0"))
        XCTAssertTrue(ics.contains("METHOD:REQUEST"))
        XCTAssertTrue(ics.contains("UID:test-uid"))
        XCTAssertTrue(ics.contains("SUMMARY:Standup"))
    }

    func testMakeICSFormatsDatesAsUTCBasicForm() {
        // 1_700_000_000 = 2023-11-14 22:13:20 UTC
        let event = CalendarEvent(
            title: "x",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 3600
        )

        let ics = ICSWriter.makeICS(for: event, uid: "u", now: event.start)

        XCTAssertTrue(ics.contains("DTSTART:20231114T221320Z"),
                      "DTSTART should be YYYYMMDDTHHMMSSZ; got:\n\(ics)")
        XCTAssertTrue(ics.contains("DTEND:20231114T231320Z"),
                      "DTEND should be DTSTART + duration in UTC; got:\n\(ics)")
    }

    func testMakeICSEscapesSpecialCharactersInSummary() {
        let event = CalendarEvent(
            title: "Call: Seb, re: launch; tomorrow",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1800
        )

        let ics = ICSWriter.makeICS(for: event, uid: "u", now: event.start)

        // Commas and semicolons must be backslash-escaped per RFC 5545.
        XCTAssertTrue(ics.contains(#"SUMMARY:Call: Seb\, re: launch\; tomorrow"#),
                      "commas and semicolons should be backslash-escaped; got:\n\(ics)")
    }

    func testMakeICSUsesCRLFLineEndings() {
        let event = CalendarEvent(
            title: "x",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1800
        )

        let ics = ICSWriter.makeICS(for: event, uid: "u", now: event.start)

        XCTAssertTrue(ics.contains("\r\n"), "iCalendar requires CRLF line endings")
        XCTAssertFalse(ics.contains("\n\n"),
                       "lone \\n indicates a non-CRLF separator slipped in")
    }

    func testWriteTempFileProducesReadableICS() throws {
        let event = CalendarEvent(
            title: "Standup",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1800
        )

        let url = try ICSWriter.writeTempFile(for: event)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "ics")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("SUMMARY:Standup"))
    }
}
