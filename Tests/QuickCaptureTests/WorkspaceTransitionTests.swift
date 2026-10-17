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
