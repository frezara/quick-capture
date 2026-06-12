import AppKit
import XCTest
@testable import QuickCapture

final class ShortcutRegistryTests: XCTestCase {

    // MARK: - Window interception

    func testOptionCommandETogglesEditorInBothModes() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "e", modifiers: [.command, .option], editorOpen: false),
            .toggleEditor
        )
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "e", modifiers: [.command, .option], editorOpen: true),
            .toggleEditor
        )
    }

    /// The first namespace pick (#55) was ⌃⌘ — retired by #69 because the
    /// chord is hard to press. It must stay unbound, not silently aliased.
    func testRetiredControlCommandChordsPassThrough() {
        for editorOpen in [false, true] {
            XCTAssertNil(ShortcutRegistry.interceptedAction(key: "e", modifiers: [.command, .control], editorOpen: editorOpen))
            XCTAssertNil(ShortcutRegistry.interceptedAction(key: "r", modifiers: [.command, .control], editorOpen: editorOpen))
        }
    }

    /// ⌘F is native find (CodeMirror's search panel) — the window must let it
    /// through to the web view in editor mode, and bind nothing in capture mode.
    func testCommandFIsNeverIntercepted() {
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: "f", modifiers: .command, editorOpen: false))
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: "f", modifiers: .command, editorOpen: true))
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

    func testOptionCommandRRefilesOnlyInEditorMode() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "r", modifiers: [.command, .option], editorOpen: true),
            .refile
        )
        XCTAssertNil(
            ShortcutRegistry.interceptedAction(key: "r", modifiers: [.command, .option], editorOpen: false)
        )
    }

    /// ⌘R must be swallowed in editor mode (WebKit would reload the warm
    /// editor) and pass through untouched in capture mode.
    func testCommandRIsSwallowedOnlyInEditorMode() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "r", modifiers: .command, editorOpen: true),
            .swallowReload
        )
        XCTAssertNil(
            ShortcutRegistry.interceptedAction(key: "r", modifiers: .command, editorOpen: false)
        )
    }

    /// ⌥⌘O opens the command palette in either mode (anyMode, app-active
    /// summon, epic #82) — window-intercepted so it fires before WebKit can
    /// claim the key in editor mode.
    func testOptionCommandOOpensPaletteInBothModes() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "o", modifiers: [.command, .option], editorOpen: false),
            .openPalette
        )
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "o", modifiers: [.command, .option], editorOpen: true),
            .openPalette
        )
    }

    func testOptionCommandSAttachesOnlyInCaptureMode() {
        XCTAssertEqual(
            ShortcutRegistry.interceptedAction(key: "s", modifiers: [.command, .option], editorOpen: false),
            .attachScreenshot
        )
        XCTAssertNil(
            ShortcutRegistry.interceptedAction(key: "s", modifiers: [.command, .option], editorOpen: true)
        )
    }

    /// ⌘⇧S was retired in favor of ⌥⌘S (the ⌥⌘ toggle family) — it must bind
    /// nothing now, not silently keep attaching screenshots.
    func testRetiredCommandShiftSPassesThrough() {
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: "s", modifiers: [.command, .shift], editorOpen: false))
        XCTAssertNil(ShortcutRegistry.interceptedAction(key: "s", modifiers: [.command, .shift], editorOpen: true))
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
            "nextSection": "Alt-Mod-ArrowDown",
            "prevSection": "Alt-Mod-ArrowUp",
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
        XCTAssertEqual(KeyChord(key: "r", modifiers: [.command, .option]).codeMirrorSpec, "Alt-Mod-r")
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

    // MARK: - Global summon default (U1)

    /// The shipped global hotkey default is ⌥⌘P — code, docs, and a fresh
    /// install must agree. Custom rebinds in UserDefaults are untouched.
    func testGlobalHotkeyDefaultIsOptionCommandP() {
        XCTAssertEqual(HotKeyConfig.default.displayString, "⌥⌘P")
    }
}

/// Capture mode runs as `.accessory` with no menu bar, so the standard editing
/// chords (⌘V/⌘C/⌘X/⌘A) have no Edit-menu key-equivalent to dispatch them —
/// `MainPanel` routes them to the first responder itself (#78). This covers the
/// pure key→selector mapping that decides which ones get routed.
final class CaptureEditingChordTests: XCTestCase {

    func testStandardEditingChordsMapToTheirSelectors() {
        XCTAssertEqual(CaptureEditingChord.selector(key: "v", modifiers: .command), #selector(NSText.paste(_:)))
        XCTAssertEqual(CaptureEditingChord.selector(key: "c", modifiers: .command), #selector(NSText.copy(_:)))
        XCTAssertEqual(CaptureEditingChord.selector(key: "x", modifiers: .command), #selector(NSText.cut(_:)))
        XCTAssertEqual(CaptureEditingChord.selector(key: "a", modifiers: .command), #selector(NSText.selectAll(_:)))
    }

    func testNonEditingCommandChordsAreNotRouted() {
        // ⌘F/⌘S/⌘E etc. keep their native/registry meaning — not our concern.
        XCTAssertNil(CaptureEditingChord.selector(key: "f", modifiers: .command))
        XCTAssertNil(CaptureEditingChord.selector(key: "s", modifiers: .command))
        XCTAssertNil(CaptureEditingChord.selector(key: nil, modifiers: .command))
    }

    func testEditingKeysRequireExactlyCommand() {
        // Plain key, or ⌘ plus another modifier, must not route — only bare ⌘V etc.
        XCTAssertNil(CaptureEditingChord.selector(key: "v", modifiers: []))
        XCTAssertNil(CaptureEditingChord.selector(key: "v", modifiers: [.command, .shift]))
        XCTAssertNil(CaptureEditingChord.selector(key: "v", modifiers: [.command, .option]))
    }
}
