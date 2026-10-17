import XCTest
import AppKit
@testable import QuickCapture

@MainActor
final class WorkspaceTransitionTests: XCTestCase {
    func testEscapeReturnsDirectlyToCentredCapture() async throws {
        let state = AppState()
        let panel = MainPanel(appState: state, onSubmit: { _, _, _ in true }, onDismiss: {})
        defer { panel.orderOut(nil) }
        for destination in [WorkspaceDestination.calendar, .projects] {
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

/// Today's schedule keys only apply while the schedule has focus, so typing in
/// the editor beside it never moves the day (the bug calendar keys had inside
/// the web view). Real key events through `sendEvent`.
@MainActor
final class TodayKeyRoutingTests: XCTestCase {
    private func press(_ panel: NSWindow, _ chars: String, _ code: UInt16,
                       _ modifiers: NSEvent.ModifierFlags = []) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            // AppKit offers modified keys to the window as key equivalents
            // before dispatching them; sendEvent alone skips that step.
            if modifiers.isEmpty || type == .keyUp || !panel.performKeyEquivalent(with: event) { panel.sendEvent(event) }
        }
    }

    func testFocusChordSwitchesPanesAndScheduleKeysStayOutOfTheEditor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TodayKeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let panel = MainPanel(appState: AppState(), onSubmit: { _, _, _ in true }, onDismiss: {})
        panel.dailyFolderOverride = folder
        defer { panel.orderOut(nil) }
        panel.openWorkspace(.today)
        let note = DailyNote.url(for: Date(), in: folder)
        for _ in 0..<80 where !(panel.editorIsInToday && panel.editorHasKeyFocus
                                && FileManager.default.fileExists(atPath: note.path)) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let model = panel.workspaceModel
        XCTAssertTrue(panel.editorIsInToday, "the editor moves into Today's right panel")
        XCTAssertTrue(panel.editorHasKeyFocus, "Today opens on the editor")
        XCTAssertFalse(model.scheduleFocused)
        let start = model.selectedDay

        try press(panel, "]", 30)
        XCTAssertEqual(model.selectedDay, start, "] typed in the editor must not change the day")

        try press(panel, ";", 41, [.command, .option])
        XCTAssertTrue(model.scheduleFocused)
        XCTAssertFalse(panel.editorHasKeyFocus)
        try press(panel, "]", 30)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: model.selectedDay).day, 1)
        try press(panel, "[", 33)
        try press(panel, "[", 33)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: model.selectedDay).day, -1)
        try press(panel, "t", 17)
        XCTAssertEqual(model.selectedDay, start)

        try press(panel, "\u{1B}", 53)             // Esc goes back to the note, not out of Today
        XCTAssertFalse(model.scheduleFocused)
        XCTAssertTrue(panel.workspaceOpen)
        for _ in 0..<20 where !panel.editorHasKeyFocus { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(panel.editorHasKeyFocus)

        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path), "opening Today creates today's note")
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

/// Todos' keys through real key events over a temp inbox.
@MainActor
final class TodosKeyRoutingTests: XCTestCase {
    private func press(_ panel: NSWindow, _ chars: String, _ code: UInt16,
                       _ modifiers: NSEvent.ModifierFlags = []) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            panel.sendEvent(event)
        }
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        for _ in 0..<40 where try !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testSectionsTickPlanAndFilter() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TodosKeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inbox = folder.appendingPathComponent("inbox.md")
        try "# Inbox\n\n## Home\n- [ ] boiler\n- [ ] hinge !!!\n\n## Garden\n- [ ] bulbs\n".write(to: inbox, atomically: true, encoding: .utf8)
        let read = { try String(contentsOf: inbox, encoding: .utf8) }

        let panel = MainPanel(appState: AppState(), onSubmit: { _, _, _ in true }, onDismiss: {})
        panel.dailyFolderOverride = folder.appendingPathComponent("daily")
        defer { panel.orderOut(nil) }
        panel.openWorkspace(.todos)
        let model = panel.workspaceModel
        model.useFixedItems(WorkspaceItem.parse(try read(), file: inbox, metadata: [:]), sources: [])
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(model.projection.groups.map(\.name), ["Home", "Garden"])
        XCTAssertEqual(model.selectedItem?.title, "hinge !!!", "priority first within a section")
        try press(panel, "\u{F701}", 125, .option)              // ⌥↓ to the next section
        XCTAssertEqual(model.selectedItem?.title, "bulbs")
        try press(panel, "\u{F700}", 126)                        // ↑
        XCTAssertEqual(model.selectedItem?.title, "boiler")

        try press(panel, "x", 7)
        try await waitFor { try read().contains("- [x] boiler") }
        XCTAssertTrue(try read().contains("- [x] boiler"), "X ticks in the file")
        XCTAssertTrue(model.visible.contains { $0.title == "boiler" }, "a ticked todo stays until you leave")

        model.useFixedItems(WorkspaceItem.parse(try read(), file: inbox, metadata: [:]), sources: [])
        model.selectedID = model.visible.first { $0.title == "bulbs" }?.id
        try press(panel, "p", 35)
        let note = DailyNote.url(for: Date(), in: folder.appendingPathComponent("daily"))
        try await waitFor { try FileManager.default.fileExists(atPath: note.path) && !read().contains("bulbs") }
        XCTAssertFalse(try read().contains("bulbs"), "P moves the todo out of the inbox")
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("- [ ] bulbs"), "into today's note")

        try press(panel, "/", 44)
        XCTAssertTrue(model.filterFocused)
        model.libraryFilter = "hinge"
        XCTAssertEqual(model.visible.map(\.title), ["hinge !!!"])
    }
}
