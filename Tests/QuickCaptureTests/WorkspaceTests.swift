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

    func testTodosGroupBySectionInFileOrderAndKeepTicksMadeThisVisit() {
        func todo(_ id: String, _ section: String, line: Int, priority: Int = 3, done: Bool = false, depth: Int = 0) -> WorkspaceItem {
            WorkspaceItem(id: id, text: id, section: section, file: URL(fileURLWithPath: "/tmp/test"), completed: done,
                          priority: priority, tags: [], kind: "capture", starts: nil, ends: nil, url: nil, line: line, depth: depth)
        }
        let items = [todo("boiler", "Home", line: 3), todo("hinge", "Home", line: 4, priority: 0),
                     todo("child", "Home", line: 5, depth: 2), todo("drill", "Home", line: 6, done: true),
                     todo("bulbs", "Garden", line: 9)]
        let p = WorkspaceProjection(items: items, destination: .todos, project: nil, date: at("2026-10-15T12:00:00Z"),
                                    mode: .month, kept: ["drill"], calendar: calendar)
        XCTAssertEqual(p.groups.map(\.name), ["Home", "Garden"])
        XCTAssertEqual(p.groups[0].items.map(\.id), ["hinge", "boiler", "drill"])
        let filtered = WorkspaceProjection(items: items, destination: .todos, project: nil, date: at("2026-10-15T12:00:00Z"),
                                           mode: .month, filter: "BULB", calendar: calendar)
        XCTAssertEqual(filtered.visible.map(\.id), ["bulbs"])
    }

    func testCapturedStampIsRead() {
        XCTAssertNotNil(WorkspaceItem.capturedDate("- [ ] milk ➕ 2026-10-14 09:12"))
        XCTAssertNil(WorkspaceItem.capturedDate("- [ ] milk"))
    }

    func testTodayProjectsJustTheSelectedDayWhateverTheCalendarMode() {
        let p = projection([item("a", start: "2026-10-15T09:00:00Z", end: "2026-10-15T10:00:00Z"),
                            item("b", start: "2026-10-16T09:00:00Z")], destination: .today, mode: .month)
        XCTAssertEqual(p.days, [at("2026-10-15T00:00:00Z")])
        XCTAssertEqual(p.eventsByDay[at("2026-10-15T00:00:00Z")]?.map(\.id), ["a"])
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

final class CalendarKeyboardTests: XCTestCase {
    private func command(_ key: String = "", code: UInt16 = 0, mode: WorkspaceCalendarMode = .month,
                         selected: Bool = false, modifiers: Bool = false, editing: Bool = false) -> CalendarLayout.Command? {
        CalendarLayout.command(key: key, keyCode: code, hasModifiers: modifiers, editingText: editing,
                               mode: mode, hasSelectedEvent: selected)
    }

    func testLettersSwitchViewAndAct() {
        XCTAssertEqual(command("d"), .mode(.day))
        XCTAssertEqual(command("W"), .mode(.week))
        XCTAssertEqual(command("m"), .mode(.month))
        XCTAssertEqual(command("t"), .today)
        XCTAssertEqual(command("n"), .newEvent)
    }

    func testSidewaysArrowsMoveADayInEveryView() {
        for mode in WorkspaceCalendarMode.allCases {
            XCTAssertEqual(command(code: 123, mode: mode), .moveDays(-1))
            XCTAssertEqual(command(code: 124, mode: mode), .moveDays(1))
        }
    }

    func testVerticalArrowsMoveAWeekInMonthAndStepEventsElsewhere() {
        XCTAssertEqual(command(code: 126, mode: .month), .moveDays(-7))
        XCTAssertEqual(command(code: 125, mode: .month), .moveDays(7))
        XCTAssertEqual(command(code: 126, mode: .week), .stepEvent(-1))
        XCTAssertEqual(command(code: 125, mode: .day), .stepEvent(1))
    }

    func testEnterOpensAndEscOnlyClaimedWhileAnEventIsSelected() {
        XCTAssertEqual(command(code: 36), .open)
        XCTAssertEqual(command(code: 76), .open)
        XCTAssertEqual(command(code: 53, selected: true), .deselect)
        XCTAssertNil(command(code: 53, selected: false), "Esc falls through to closing the workspace")
    }

    func testTypingAndChordsAreLeftAlone() {
        XCTAssertNil(command("t", editing: true))
        XCTAssertNil(command(code: 124, editing: true))
        XCTAssertNil(command("n", modifiers: true))
    }

    func testWeekRangeNamesTheMonthOnceOrTwice() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let day = { (m: Int, d: Int) in cal.date(from: DateComponents(year: 2026, month: m, day: d))! }
        XCTAssertTrue(NativeCalendarView.rangeText(day(10, 12), day(10, 18), calendar: cal).hasPrefix("12 to "))
        XCTAssertFalse(NativeCalendarView.rangeText(day(9, 28), day(10, 4), calendar: cal).hasPrefix("28 to "))
    }

    func testTimelineOpensTwoHoursBeforeNowOnlyWhenTodayIsShown() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 7, minute: 40))!
        let today = cal.startOfDay(for: now)
        let lastWeek = cal.date(byAdding: .day, value: -7, to: today)!
        XCTAssertEqual(NativeCalendarView.firstVisibleHour(days: [today], now: now, calendar: cal), 5)
        XCTAssertEqual(NativeCalendarView.firstVisibleHour(days: [lastWeek], now: now, calendar: cal), 8)
    }
}

@MainActor
final class CalendarSelectionTests: XCTestCase {
    func testStepEventEntersAtTheEndsAndStopsThere() {
        let model = WorkspaceModel.preview(destination: .calendar, calendarMode: .day)
        model.date = Date()
        let ids = model.eventsOnSelectedDay.map(\.id)
        XCTAssertGreaterThanOrEqual(ids.count, 2)
        model.stepEvent(1)
        XCTAssertEqual(model.selectedEventID, ids.first)
        model.stepEvent(-1)
        XCTAssertEqual(model.selectedEventID, ids.first, "↑ on the first event stays put")
        model.selectedEventID = nil
        model.stepEvent(-1)
        XCTAssertEqual(model.selectedEventID, ids.last)
    }

    func testMovingOffTheEventsDayLetsGoOfIt() {
        let model = WorkspaceModel.preview(destination: .calendar, calendarMode: .day)
        model.date = Date()
        model.stepEvent(1)
        XCTAssertNotNil(model.selectedEventID)
        model.moveDays(5)
        XCTAssertNil(model.selectedEventID)
    }
}

@MainActor
final class TodayMidnightTests: XCTestCase {
    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    }

    func testTodayFollowsTheDateAcrossMidnight() {
        let model = WorkspaceModel.preview(destination: .today)
        model.date = Date()
        XCTAssertTrue(model.rollToTodayIfNeeded(now: day(1)))
        XCTAssertTrue(Calendar.current.isDate(model.date, inSameDayAs: day(1)))
    }

    func testASteppedToDayStaysPut() {
        let model = WorkspaceModel.preview(destination: .today)
        model.date = day(-3)
        XCTAssertFalse(model.rollToTodayIfNeeded(now: day(1)))
        XCTAssertTrue(Calendar.current.isDate(model.date, inSameDayAs: day(-3)))
    }

    func testNoChangeWithinTheSameDay() {
        let model = WorkspaceModel.preview(destination: .today)
        model.date = Date()
        XCTAssertFalse(model.rollToTodayIfNeeded(now: Date()))
    }
}
