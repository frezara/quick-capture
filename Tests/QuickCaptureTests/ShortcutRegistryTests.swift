import AppKit
import XCTest
@testable import QuickCapture

final class ShortcutRegistryTests: XCTestCase {

    // MARK: - Window interception

    func testCommandFTogglesEditorInBothModes() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "f", modifiers: .command, editorOpen: false),
            .toggleEditor
        )
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "f", modifiers: .command, editorOpen: true),
            .toggleEditor
        )
    }

    func testCommandWDismissesInBothModes() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "w", modifiers: .command, editorOpen: false),
            .dismissPanel
        )
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "w", modifiers: .command, editorOpen: true),
            .dismissPanel
        )
    }

    func testCommandRRefilesOnlyInEditorMode() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "r", modifiers: .command, editorOpen: true),
            .refile
        )
        XCTAssertNil(
            ShortcutRegistry.interceptedAction(key: "r", modifiers: .command, editorOpen: false)
        )
    }

    func testCommandShiftSAttachesOnlyInCaptureMode() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "s", modifiers: [.command, .shift], editorOpen: false),
            .attachScreenshot
        )
        XCTAssertNil(
            ShortcutRegistry.interceptedAction(key: "s", modifiers: [.command, .shift], editorOpen: true)
        )
    }

    func testUnboundChordsPassThrough() {
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: "x", modifiers: .command, editorOpen: true))
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: "f", modifiers: [.command, .shift], editorOpen: true))
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: "f", modifiers: [], editorOpen: true))
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: nil, modifiers: .command, editorOpen: true))
    }

    func testEditorLocalActionsAreNeverIntercepted() {
        for action in ShortcutAction.allCases where !action.isWindowIntercepted {
            for editorOpen in [false, true] {
                let matched = ShortcutRegistry.interceptedAction(
                    key: action.chord.key,
                    modifiers: action.chord.modifiers,
                    editorOpen: editorOpen
                )
                XCTAssertNotEqual(matched, action,
                                  "\(action) is editor-local and must not be window-intercepted")
            }
        }
    }

    // MARK: - Editor keymap push

    func testEditorKeymapContainsExactlyTheEditorLocalActions() {
        XCTAssertEqual(ShortcutRegistry.editorKeymap, [
            "readMode": "Mod-e",
            "toggleTask": "Mod-l",
            "save": "Mod-s",
            "reorg": "Mod-'",
        ])
    }

    func testEditorKeymapJSONRoundTrips() throws {
        let json = try XCTUnwrap(ShortcutRegistry.editorKeymapJSON)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, ShortcutRegistry.editorKeymap)
    }

    // MARK: - CodeMirror spec rendering

    func testCodeMirrorSpecRendering() {
        XCTAssertEqual(KeyChord(key: "e", modifiers: .command).codeMirrorSpec, "Mod-e")
        XCTAssertEqual(KeyChord(key: "'", modifiers: .command).codeMirrorSpec, "Mod-'")
        XCTAssertEqual(KeyChord(key: "s", modifiers: [.command, .shift]).codeMirrorSpec, "Shift-Mod-s")
        XCTAssertEqual(KeyChord(key: "e", modifiers: [.command, .control]).codeMirrorSpec, "Ctrl-Mod-e")
    }

    // MARK: - Registry hygiene

    /// Two actions live in the same mode must never share a chord — the first
    /// CaseIterable match would silently shadow the second.
    func testNoDuplicateChordsWithinAnyActiveMode() {
        for editorOpen in [false, true] {
            let active = ShortcutAction.allCases.filter { $0.scope.isActive(editorOpen: editorOpen) }
            var seen: [KeyChord] = []
            for action in active {
                XCTAssertFalse(seen.contains(action.chord),
                               "duplicate chord \(action.chord) in editorOpen=\(editorOpen)")
                seen.append(action.chord)
            }
        }
    }

    func testMenuActionsAllHaveTitles() {
        for action in ShortcutRegistry.menuActions {
            XCTAssertNotNil(action.menuTitle)
            XCTAssertFalse(action.menuTitle!.isEmpty)
        }
    }
}
