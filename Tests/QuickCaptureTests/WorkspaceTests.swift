import XCTest
@testable import QuickCapture

final class WorkspaceTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/workspace-inbox.md")

    func testLegacyAndSyncedItemsReadWithoutChangingSource() {
        let id = UUID().uuidString.lowercased()
        var event = OrganiserItem(body_markdown: "Meeting", kind: "event")
        event.starts_at = "2026-10-15T12:00:00Z"
        let text = "# Inbox\n## Personal\n- [ ] Old task !!\n- [ ] Meeting <!--qc-source:\(id)-->\n## Notes\n- [ ] A note\n  Second line\n"
        let items = WorkspaceItem.parse(text, file: file, metadata: [id: event])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].priority, 1)
        XCTAssertEqual(items[1].kind, "event")
        XCTAssertNotNil(items[1].starts)
        XCTAssertFalse(items[1].text.contains("qc-source"))
        XCTAssertEqual(items[2].kind, "note")
        XCTAssertTrue(items[2].text.contains("Second line"))
    }

    func testTagsAreExplicitAndCodeFencesAreNotTasks() {
        let text = "# Inbox\n## Home\n- [ ] Plan #project/Garden #note\n- [x] Finished\n```\n- [ ] Example only\n```\n- [ ] Read https://example.com/a#note\n"
        let items = WorkspaceItem.parse(text, file: file, metadata: [:])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].projects, ["garden"])
        XCTAssertEqual(items[0].kind, "note")
        XCTAssertTrue(items[1].completed)
        XCTAssertEqual(items[2].kind, "capture")
        XCTAssertEqual(items[2].url?.host, "example.com")
    }

    func testCalendarMidnightAndZeroDurationBoundaries() {
        let id = UUID().uuidString.lowercased()
        var event = OrganiserItem(body_markdown: "Event", kind: "event")
        event.starts_at = "2026-10-15T23:00:00Z"
        event.ends_at = "2026-10-16T00:00:00Z"
        let text = "- [ ] Event <!--qc-source:\(id)-->"
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nextDay = WorkspaceItem.date("2026-10-16T12:00:00Z")!
        let item = WorkspaceItem.parse(text, file: file, metadata: [id: event])[0]
        XCTAssertFalse(item.occurs(on: nextDay, calendar: calendar))
        XCTAssertTrue(item.occurs(on: item.starts!, calendar: calendar))
        event.starts_at = event.ends_at
        let point = WorkspaceItem.parse(text, file: file, metadata: [id: event])[0]
        XCTAssertTrue(point.occurs(on: nextDay, calendar: calendar))
    }

    func testNativeDestinationsHaveDistinctWindowShortcuts() {
        let actions = WorkspaceDestination.allCases.map(\.action)
        XCTAssertEqual(Set(actions.map { $0.chord.codeMirrorSpec }).count, actions.count)
        for action in actions {
            for editor in [true, false] {
                XCTAssertEqual(ShortcutRegistry.interceptedAction(key: action.chord.key,
                    modifiers: action.chord.modifiers, editorOpen: editor), action)
            }
        }
    }
}

final class CalendarLayoutTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }
    private func item(_ id: String, start: String, end: String) -> WorkspaceItem {
        WorkspaceItem(id: id, text: id, section: "Events", file: URL(fileURLWithPath: "/tmp/test"),
            completed: false, priority: 3, tags: [], kind: "event",
            starts: WorkspaceItem.date(start), ends: WorkspaceItem.date(end), url: nil)
    }
    func testOverlappingEventsUseSeparateColumnsAndReuseFreeSpace() {
        let a = item("a", start: "2026-10-15T09:00:00Z", end: "2026-10-15T11:00:00Z")
        let b = item("b", start: "2026-10-15T09:30:00Z", end: "2026-10-15T10:00:00Z")
        let c = item("c", start: "2026-10-15T10:00:00Z", end: "2026-10-15T10:30:00Z")
        let d = item("d", start: "2026-10-15T11:00:00Z", end: "2026-10-15T12:00:00Z")
        let segments = CalendarLayout.segments(items: [d, c, b, a], day: a.starts!, calendar: calendar)
        XCTAssertEqual(segments.map(\.column), [0, 1, 1, 0])
        XCTAssertEqual(segments.map(\.columnCount), [2, 2, 2, 1])
        XCTAssertEqual(segments[0].startMinute, 540)
        XCTAssertEqual(segments[0].endMinute, 660)
    }
    func testMidnightClippingAndFullDayEvents() {
        let overnight = item("night", start: "2026-10-15T23:00:00Z", end: "2026-10-16T01:00:00Z")
        let day = item("day", start: "2026-10-16T00:00:00Z", end: "2026-10-17T00:00:00Z")
        XCTAssertTrue(CalendarLayout.isAllDay(day, calendar: calendar))
        let previous = CalendarLayout.segments(items: [overnight], day: overnight.starts!, calendar: calendar)
        XCTAssertEqual(previous.first?.endMinute, 1440)
        let next = CalendarLayout.segments(items: [overnight, day], day: day.starts!, calendar: calendar)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.startMinute, 0)
        XCTAssertEqual(next.first?.endMinute, 60)
    }
    func testBareViewKeysLeaveTextAndCommandShortcutsAlone() {
        XCTAssertEqual(CalendarLayout.mode(for: "m", hasModifiers: false, editingText: false), .month)
        XCTAssertEqual(CalendarLayout.mode(for: "D", hasModifiers: false, editingText: false), .day)
        XCTAssertEqual(CalendarLayout.mode(for: "w", hasModifiers: false, editingText: false), .week)
        XCTAssertNil(CalendarLayout.mode(for: "m", hasModifiers: true, editingText: false))
        XCTAssertNil(CalendarLayout.mode(for: "w", hasModifiers: false, editingText: true))
    }
}

final class WorkspaceProjectionTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }
    private func at(_ value: String) -> Date { WorkspaceItem.date(value)! }
    private func item(_ id: String, start: String? = nil, end: String? = nil, completed: Bool = false, kind: String = "event") -> WorkspaceItem {
        WorkspaceItem(id: id, text: id, section: "Events", file: URL(fileURLWithPath: "/tmp/test"),
            completed: completed, priority: 3, tags: [], kind: kind,
            starts: start.map(at), ends: end.map(at), url: nil)
    }
    private func projection(_ items: [WorkspaceItem], destination: WorkspaceDestination = .calendar,
                            date: String = "2026-10-15T12:00:00Z", mode: WorkspaceCalendarMode = .month) -> WorkspaceProjection {
        WorkspaceProjection(items: items, destination: destination, project: nil, date: at(date), mode: mode, calendar: calendar)
    }

    func testMonthGridStartsOnTheMondayBeforeTheFirstAndCoversWholeWeeks() {
        let days = projection([]).days
        XCTAssertEqual(days.first, at("2026-09-28T00:00:00Z"))
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.last, at("2026-11-01T00:00:00Z"))
    }

    func testWeekAndDayRanges() {
        let week = projection([], mode: .week).days
        XCTAssertEqual(week.first, at("2026-10-12T00:00:00Z"))
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(projection([], mode: .day).days, [at("2026-10-15T00:00:00Z")])
    }

    func testEventsAreGroupedOntoEveryDayTheyTouchInStartOrder() {
        let overnight = item("overnight", start: "2026-10-15T22:00:00Z", end: "2026-10-17T02:00:00Z")
        let morning = item("morning", start: "2026-10-16T09:00:00Z", end: "2026-10-16T10:00:00Z")
        let allDay = item("allday", start: "2026-10-16T00:00:00Z", end: "2026-10-17T00:00:00Z")
        let byDay = projection([morning, overnight, allDay]).eventsByDay
        XCTAssertEqual(byDay[at("2026-10-15T00:00:00Z")]?.map(\.id), ["overnight"])
        XCTAssertEqual(byDay[at("2026-10-16T00:00:00Z")]?.map(\.id), ["overnight", "allday", "morning"])
        XCTAssertEqual(byDay[at("2026-10-17T00:00:00Z")]?.map(\.id), ["overnight"])
        XCTAssertNil(byDay[at("2026-10-18T00:00:00Z")])
    }

    func testCalendarShowsOnlyOpenDatedItemsAndTodosOnlyOpenTasks() {
        let dated = item("dated", start: "2026-10-15T09:00:00Z")
        let done = item("done", start: "2026-10-15T10:00:00Z", completed: true)
        let task = item("task", kind: "capture")
        let finished = item("finished", completed: true, kind: "capture")
        XCTAssertEqual(projection([dated, done, task, finished]).visible.map(\.id), ["dated"])
        XCTAssertEqual(projection([dated, done, task, finished], destination: .todos).visible.map(\.id), ["task"])
    }
}
