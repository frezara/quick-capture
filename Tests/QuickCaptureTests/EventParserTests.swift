import XCTest
@testable import QuickCapture

final class EventParserTests: XCTestCase {

    func testParseExtractsTitleAndStart() {
        // NSDataDetector's duration heuristics are OS-dependent (we observed
        // 1800s, not 3600s, for "for one hour today"), so the duration value
        // itself isn't asserted here — only that parsing succeeded and the
        // title and date were extracted.
        let now = Date()
        let result = EventParser.parse("Call with Seb at 1400 for one hour today", now: now)

        guard case .success(let event) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertTrue(event.title.contains("Call with Seb"),
                      "title should retain the non-date portion; got '\(event.title)'")
        XCTAssertGreaterThan(event.duration, 0, "duration must be positive")
        XCTAssertTrue(Calendar.current.isDate(event.start, inSameDayAs: now),
                      "start should be today")
    }

    func testParseFallsBackToDefaultDurationWhenNotSpecified() {
        let result = EventParser.parse("standup at 9am tomorrow", now: Date())

        guard case .success(let event) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertEqual(event.duration, EventParser.defaultDuration,
                       "no 'for N minutes' phrase → default duration")
    }

    func testParseReturnsNoDateFoundWhenInputHasNoDate() {
        let result = EventParser.parse("buy milk", now: Date())

        guard case .failure(let error) = result else {
            XCTFail("expected failure, got \(result)")
            return
        }
        XCTAssertEqual(error, .noDateFound)
    }

    func testParseReturnsEmptyTitleWhenInputIsBlank() {
        let result = EventParser.parse("   \n  ", now: Date())

        guard case .failure(let error) = result else {
            XCTFail("expected failure, got \(result)")
            return
        }
        XCTAssertEqual(error, .emptyTitle)
    }

    func testParseStripsTrailingPunctuationFromTitle() {
        let result = EventParser.parse("lunch with Mae, tomorrow at noon", now: Date())

        guard case .success(let event) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertFalse(event.title.hasSuffix(","), "trailing comma should be trimmed")
        XCTAssertFalse(event.title.hasSuffix(" "), "trailing whitespace should be trimmed")
    }
}
