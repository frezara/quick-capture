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
