import XCTest
import AppKit
@testable import QuickCapture

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testSettingsReplacesCaptureAndCaptureHidesSettings() async throws {
        let delegate = AppDelegate()
        delegate.showCapture()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? MainPanel }.first { $0.isVisible })
        let attachment = URL(fileURLWithPath: "/tmp/settings-draft-attachment.png")
        delegate.appState.pendingAttachments = [attachment]
        let comma = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
        XCTAssertTrue(panel.performKeyEquivalent(with: comma))
        try await Task.sleep(nanoseconds: 300_000_000)
        let settings = try XCTUnwrap(NSApp.windows.first { $0.title == "Quick Capture Settings" && $0.isVisible })
        XCTAssertFalse(panel.isVisible, "Settings must replace capture, not leave it behind")
        delegate.showSettings()
        XCTAssertEqual(NSApp.windows.filter { $0.title == "Quick Capture Settings" && $0.isVisible }.count, 1)
        delegate.showCapture()
        XCTAssertFalse(settings.isVisible, "Summoning capture must hide Settings")
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(delegate.appState.pendingAttachments, [attachment])
        XCTAssertFalse(settings.isRestorable)
        panel.orderOut(nil)
        settings.orderOut(nil)
    }
}
