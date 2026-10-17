import XCTest
@testable import QuickCapture

final class TickCascadeTests: XCTestCase {
    private let doc = [
        "## Tasks",             // 0
        "- [ ] Ship release",   // 1
        "  - [ ] write notes",  // 2
        "    - [x] draft",      // 3
        "    - [ ] proofread",  // 4
        "  - plain bullet",     // 5
        "  - [ ] tag build",    // 6
        "- [ ] Next item",      // 7
        "  - [ ] its child",    // 8
    ]
    private func t(_ line: Int, _ checked: Bool) -> TickCascade.Tick { .init(line: line, checked: checked) }

    func testTickingAParentTicksItsDescendantsNotSiblings() {
        XCTAssertEqual(TickCascade.changes(doc, [t(1, true)]), [t(1, true), t(2, true), t(4, true), t(6, true)])
    }

    func testUntickingAChildUnticksEveryTickedAncestor() {
        let ticked = doc.map { $0.replacingOccurrences(of: "[ ]", with: "[x]") }
        XCTAssertEqual(TickCascade.changes(ticked, [t(4, false)]), [t(1, false), t(2, false), t(4, false)])
    }

    func testUntickingAParentLeavesItsChildren() {
        let ticked = doc.map { $0.replacingOccurrences(of: "[ ]", with: "[x]") }
        XCTAssertEqual(TickCascade.changes(ticked, [t(1, false)]), [t(1, false)])
    }

    func testTickingTheLastChildLeavesTheParent() {
        XCTAssertEqual(TickCascade.changes(["- [ ] parent", "  - [x] a", "  - [ ] b"], [t(2, true)]), [t(2, true)])
    }

    func testBlankLinesEndTheGroup() {
        XCTAssertEqual(TickCascade.changes(["- [ ] parent", "", "  - [ ] not a child"], [t(0, true)]), [t(0, true)])
    }

    func testApplyRewritesOnlyCheckboxes() {
        XCTAssertEqual(TickCascade.apply(to: "- [ ] a !!\n  * [ ] b\n- [ ] c", line: 0, checked: true),
                       "- [x] a !!\n  * [x] b\n- [ ] c")
        XCTAssertNil(TickCascade.apply(to: "- plain", line: 0, checked: true))
    }
}

final class AgendaProjectionTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }
    private let inbox = URL(fileURLWithPath: "/tmp/agenda/inbox.md")
    private let garden = URL(fileURLWithPath: "/tmp/agenda/garden/inbox.md")
    private func at(_ value: String) -> Date { WorkspaceItem.date(value)! }
    private func item(_ id: String, file: URL? = nil, start: String? = nil, end: String? = nil, reminder: String? = nil,
                      completed: Bool = false, priority: Int = 3, line: Int = 0, depth: Int = 0) -> WorkspaceItem {
        WorkspaceItem(id: id, text: id, section: "Home", file: file ?? inbox, completed: completed, priority: priority,
                      tags: [], kind: "capture", starts: start.map(at), ends: end.map(at), url: nil,
                      line: line, depth: depth, reminder: reminder.map(at))
    }
    private var sources: [AgendaSource] {
        [AgendaSource(name: "Inbox", file: inbox), AgendaSource(name: "Garden", file: garden)]
    }
    private func project(_ items: [WorkspaceItem], start: String = "2026-10-17T09:00:00Z",
                         now: String = "2026-10-17T13:20:00Z", kept: Set<String> = []) -> AgendaProjection {
        AgendaProjection(items: items, sources: sources, start: at(start), now: at(now), kept: kept, calendar: calendar)
    }

    func testSevenDaysFromTheStartDay() {
        let days = project([]).days.map(\.date)
        XCTAssertEqual(days.first, at("2026-10-17T00:00:00Z"))
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last, at("2026-10-23T00:00:00Z"))
    }

    func testADayListsOverdueThenAllDayThenTimedInOrder() {
        let p = project([
            item("cake", reminder: "2026-10-17T18:00:00Z"),
            item("garden", start: "2026-10-17T14:00:00Z", end: "2026-10-17T15:00:00Z"),
            item("birthday", start: "2026-10-17T00:00:00Z", end: "2026-10-18T00:00:00Z"),
            item("council", reminder: "2026-10-15T14:00:00Z"),
        ])
        let today = p.days[0].rows
        XCTAssertEqual(today.map(\.item.id), ["council", "birthday", "garden", "cake"])
        XCTAssertEqual(today[0].kind, .reminder(overdueDays: 2))
        XCTAssertEqual(today[1].kind, .event(allDay: true, part: 1, of: 1))
    }

    func testOverdueRemindersOnlyShowWhenTheSpanHasToday() {
        let council = item("council", reminder: "2026-10-15T14:00:00Z")
        let nextWeek = project([council], start: "2026-10-24T09:00:00Z")
        XCTAssertTrue(nextWeek.rows.filter { $0.day != nil }.isEmpty)
        let lastWeek = project([council], start: "2026-10-10T09:00:00Z")
        XCTAssertTrue(lastWeek.rows.contains { $0.kind == .reminder(overdueDays: nil) && $0.day == self.at("2026-10-15T00:00:00Z") })
    }

    func testAMultiDayEventRepeatsWithItsPart() {
        let trip = item("trip", start: "2026-10-21T00:00:00Z", end: "2026-10-24T00:00:00Z")
        let rows = project([trip]).rows.filter { $0.item.id == "trip" }
        XCTAssertEqual(rows.map(\.kind), [1, 2, 3].map { AgendaRow.Kind.event(allDay: true, part: $0, of: 3) })
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "each day's row has its own identity")
    }

    func testOpenTodosGroupByFileInSourceOrderAndSortByPriority() {
        let p = project([
            item("seeds", file: garden, line: 4),
            item("plain", line: 2),
            item("passport", priority: 0, line: 9),
            item("child", line: 3, depth: 2),
            item("done", completed: true, line: 5),
            item("meeting", start: "2026-10-18T10:00:00Z", line: 6),
        ])
        XCTAssertEqual(p.groups.map(\.name), ["Inbox", "Garden"])
        XCTAssertEqual(p.groups[0].rows.map(\.item.id), ["passport", "plain"])
        XCTAssertEqual(p.groups[1].rows.map(\.item.id), ["seeds"])
    }

    func testAnItemTickedThisVisitStaysOnScreen() {
        let done = item("passport", completed: true)
        XCTAssertTrue(project([done]).groups.isEmpty)
        XCTAssertEqual(project([done], kept: ["passport"]).groups.first?.rows.map(\.item.id), ["passport"])
    }

    func testSourcesListEachFileOnceInOrder() {
        let capture = URL(fileURLWithPath: "/tmp/agenda/inbox.md")
        let list = AgendaSource.list(dailyNote: URL(fileURLWithPath: "/tmp/agenda/daily/2026-10-17.md"), captureFile: capture,
                                     projects: [(name: "garden", file: garden)],
                                     targets: [(name: "Garden folder", file: garden), (name: "Work", file: URL(fileURLWithPath: "/tmp/work/inbox.md"))])
        XCTAssertEqual(list.map(\.name), ["Today", "Inbox", "garden", "Work"])
    }

    func testParseRecordsLineDepthAndChildCounts() {
        let items = WorkspaceItem.parse("# Inbox\n\n## Home\n- [ ] parent\n  - [x] a\n  - [ ] b\n- [ ] next",
                                        file: inbox, metadata: [:])
        let parent = items.first { $0.title == "parent" }
        XCTAssertEqual(parent?.line, 3)
        XCTAssertEqual(parent?.depth, 0)
        XCTAssertEqual(parent.map { [$0.childTasksDone, $0.childTasks] }, [1, 2])
        XCTAssertEqual(items.first { $0.title == "a" }?.depth, 2)
    }
}
