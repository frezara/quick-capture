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
