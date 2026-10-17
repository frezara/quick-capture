import XCTest
import AppKit
@testable import QuickCapture

@MainActor
final class WorkspaceTransitionTests: XCTestCase {
    func testEscapeReturnsDirectlyToCentredCapture() async throws {
        let state = AppState()
        let panel = MainPanel(appState: state, onSubmit: { _, _, _ in true }, onDismiss: {})
        defer { panel.orderOut(nil) }
        for destination in [WorkspaceDestination.calendar, .agenda] {
            panel.openWorkspace(destination)
            try await Task.sleep(nanoseconds: 400_000_000)
            let screen = try XCTUnwrap(panel.screen).visibleFrame
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertTrue(panel.performKeyEquivalent(with: escape))
            XCTAssertFalse(panel.workspaceOpen)
            let immediate = panel.frame
            XCTAssertEqual(immediate.midX, screen.midX, accuracy: 1)
            XCTAssertEqual(immediate.midY, screen.midY, accuracy: 1)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(panel.frame.minX, immediate.minX, accuracy: 1, "Capture must not slide sideways after Escape")
            XCTAssertEqual(panel.frame.width, immediate.width, accuracy: 1)
            XCTAssertTrue(panel.isVisible)
        }
    }
}

/// Calendar keys sent through the window's real event dispatch (`sendEvent`),
/// so a SwiftUI view swallowing an arrow or Return would fail here even though
/// the key table itself is right.
@MainActor
final class CalendarKeyRoutingTests: XCTestCase {
    private func press(_ panel: NSWindow, _ chars: String, _ code: UInt16) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            panel.sendEvent(event)
        }
    }

    func testArrowsLettersAndReturnReachTheCalendar() async throws {
        let panel = MainPanel(appState: AppState(), onSubmit: { _, _, _ in true }, onDismiss: {})
        defer { panel.orderOut(nil) }
        panel.openWorkspace(.calendar)
        try await Task.sleep(nanoseconds: 400_000_000)
        let model = panel.workspaceModel
        model.date = Date()
        model.calendarMode = .month
        let start = model.selectedDay

        try press(panel, "\u{F703}", 124)            // →
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: model.selectedDay).day, 1)
        try press(panel, "\u{F701}", 125)            // ↓ in month moves a week
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: model.selectedDay).day, 8)
        try press(panel, "t", 17)
        XCTAssertEqual(model.selectedDay, start)
        try press(panel, "w", 13)
        XCTAssertEqual(model.calendarMode, .week)
        try press(panel, "m", 46)
        XCTAssertEqual(model.calendarMode, .month)
        try press(panel, "\r", 36)                   // Enter opens the selected day
        XCTAssertEqual(model.calendarMode, .day)
        XCTAssertTrue(panel.workspaceOpen)
    }
}

/// Agenda's keys through real key events, over fixed items in temp files so
/// nothing touches the real inboxes.
@MainActor
final class AgendaKeyRoutingTests: XCTestCase {
    private func press(_ panel: NSWindow, _ chars: String, _ code: UInt16,
                       _ modifiers: NSEvent.ModifierFlags = []) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            panel.sendEvent(event)
        }
    }

    func testArrowsWeeksTickAndOpen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgendaKeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inbox = folder.appendingPathComponent("project/inbox.md")
        try FileManager.default.createDirectory(at: inbox.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Inbox\n\n## Home\n- [ ] parent\n  - [ ] child\n- [ ] second\n".write(to: inbox, atomically: true, encoding: .utf8)

        let panel = MainPanel(appState: AppState(), onSubmit: { _, _, _ in true }, onDismiss: {})
        panel.dailyFolderOverride = folder.appendingPathComponent("daily")
        defer { panel.orderOut(nil) }
        panel.openWorkspace(.agenda)
        let model = panel.workspaceModel
        let items = WorkspaceItem.parse(try String(contentsOf: inbox, encoding: .utf8), file: inbox, metadata: [:])
        model.useFixedItems(items, sources: [AgendaSource(name: "Project", file: inbox)])
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: DailyNote.url(for: Date(), in: folder.appendingPathComponent("daily")).path),
                      "opening Agenda creates today's note")
        XCTAssertEqual(model.agenda.groups.map(\.name), ["Project"])
        XCTAssertEqual(model.agendaSelectedRow?.item.title, "parent", "nothing is scheduled, so the first todo is selected")
        try press(panel, "\u{F701}", 125)                      // ↓
        XCTAssertEqual(model.agendaSelectedRow?.item.title, "second")
        try press(panel, "\u{F700}", 126, .option)             // ⌥↑ to the group's top
        XCTAssertEqual(model.agendaSelectedRow?.item.title, "parent")

        let start = Calendar.current.startOfDay(for: model.agendaStart)
        try press(panel, "]", 30)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: Calendar.current.startOfDay(for: model.agendaStart)).day, 7)
        try press(panel, "t", 17)
        XCTAssertEqual(Calendar.current.startOfDay(for: model.agendaStart), Calendar.current.startOfDay(for: Date()))

        try press(panel, "x", 7)
        for _ in 0..<40 {
            if try String(contentsOf: inbox, encoding: .utf8).contains("- [x] parent") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try String(contentsOf: inbox, encoding: .utf8),
                       "# Inbox\n\n## Home\n- [x] parent\n  - [x] child\n- [ ] second\n", "X ticks the item and its children")

        try press(panel, "\r", 36)
        XCTAssertTrue(panel.editorOpen, "Enter opens the item in the editor")
    }
}
