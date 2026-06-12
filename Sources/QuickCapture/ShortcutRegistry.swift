import AppKit

/// Single source of truth for every app-level keyboard shortcut (epic #53).
///
/// Shortcuts used to live in three disconnected places: a hardcoded switch in
/// `MainPanel.performKeyEquivalent`, the CodeMirror keymap array in
/// `editor-web/src/editor.ts`, and the Carbon global hotkey. Adding one meant
/// knowing which layer owns it and whether WebKit reserves the key. Now:
/// adding a shortcut = one `ShortcutAction` case here, plus either a dispatch
/// arm in `MainPanel.perform(shortcut:)` (window actions) or an entry in the
/// `appCommands` map in editor.ts (editor-local actions).
///
/// The global summon hotkey stays separate (`HotKeyConfig` / `AppDelegate.
/// rebindHotKey`) — it's a Carbon registration that must work while the app
/// has no key window, which is a different mechanism entirely.

/// A key + modifier combination. Matched against `performKeyEquivalent`
/// events on the Swift side; rendered as a CodeMirror key spec for
/// editor-local bindings.
struct KeyChord: Equatable {
    /// Lowercased `charactersIgnoringModifiers` of the key, or a CodeMirror
    /// key name ("ArrowDown") for non-character keys — those are editor-local
    /// only, so they never go through `matches`.
    let key: String
    let modifiers: NSEvent.ModifierFlags

    func matches(key: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        key == self.key && modifiers == self.modifiers
    }

    /// CodeMirror key spec for this chord ("Mod-e", "Mod-'"). ⌘ maps to "Mod"
    /// so the same spec resolves to Ctrl in the browser harness.
    var codeMirrorSpec: String {
        var s = ""
        if modifiers.contains(.control) { s += "Ctrl-" }
        if modifiers.contains(.option)  { s += "Alt-" }
        if modifiers.contains(.shift)   { s += "Shift-" }
        if modifiers.contains(.command) { s += "Mod-" }
        return s + key
    }

    /// What an `NSMenuItem` wants in `keyEquivalent` — function-key characters
    /// for the named keys, the raw character otherwise.
    var menuKeyEquivalent: String {
        switch key {
        case "ArrowUp":   return String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        case "ArrowDown": return String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        default:          return key
        }
    }
}

/// When a shortcut is live, keyed off the panel's surface (the takeovers are
/// mutually exclusive, ADR-0004).
enum ShortcutScope {
    case captureMode
    case editorMode
    case anyMode

    func isActive(editorOpen: Bool) -> Bool {
        switch self {
        case .captureMode: return !editorOpen
        case .editorMode:  return editorOpen
        case .anyMode:     return true
        }
    }
}

enum ShortcutAction: String, CaseIterable {
    // Window-intercepted: matched in `MainPanel.performKeyEquivalent` before
    // WebKit/CodeMirror can claim the key.
    //
    // Binding scheme (epic #53, namespace revised by #69): plain ⌘ keys keep
    // their native/Obsidian editor meaning (⌘F find, ⌘S save, ⌘E read mode…);
    // ⌥⌘ is the app's reserved namespace for panel-level actions — ⌥ is the
    // Mac's Meta, and the adjacent keys roll under one thumb (⌃⌘, the first
    // pick, proved a pinky claw in practice). Avoid the system-claimed
    // combos: ⌥⌘Esc (force quit), ⌥⌘H (Hide Others — it's in our own app
    // menu), ⌥⌘D (Dock), ⌥⌘Space (Finder search).
    case toggleEditor
    case dismissPanel
    case attachScreenshot
    case refile
    /// ⌘R must stay swallowed in editor mode even though refile moved to ⌥⌘R:
    /// WebKit reserves the key for "reload", which would blow away the warm
    /// editor (and its undo history / cursor) the moment it got through.
    case swallowReload

    // Editor-local: bound inside CodeMirror via the keymap Swift pushes on
    // boot (`qcEditor.setKeymap`). The window must NOT intercept these — they
    // are text-editing bindings that should only fire while the editor view
    // itself has focus (not, say, the refile dropdown's key capture). ⌘F is
    // deliberately absent: CodeMirror's own searchKeymap owns find.
    case readMode
    case toggleTask
    case save
    case reorg
    case nextSection
    case prevSection

    var chord: KeyChord {
        switch self {
        case .toggleEditor:     return KeyChord(key: "e", modifiers: [.command, .option])
        case .dismissPanel:     return KeyChord(key: "w", modifiers: .command)
        case .attachScreenshot: return KeyChord(key: "s", modifiers: [.command, .option])
        case .refile:           return KeyChord(key: "r", modifiers: [.command, .option])
        case .swallowReload:    return KeyChord(key: "r", modifiers: .command)
        case .readMode:         return KeyChord(key: "e", modifiers: .command)
        case .toggleTask:       return KeyChord(key: "l", modifiers: .command)
        case .save:             return KeyChord(key: "s", modifiers: .command)
        case .reorg:            return KeyChord(key: "'", modifiers: .command)
        case .nextSection:      return KeyChord(key: "ArrowDown", modifiers: [.command, .option])
        case .prevSection:      return KeyChord(key: "ArrowUp", modifiers: [.command, .option])
        }
    }

    var scope: ShortcutScope {
        switch self {
        case .toggleEditor, .dismissPanel:
            return .anyMode
        case .attachScreenshot:
            return .captureMode
        case .refile, .swallowReload, .readMode, .toggleTask, .save, .reorg,
             .nextSection, .prevSection:
            return .editorMode
        }
    }

    var isWindowIntercepted: Bool {
        switch self {
        case .toggleEditor, .dismissPanel, .attachScreenshot, .refile, .swallowReload:
            return true
        case .readMode, .toggleTask, .save, .reorg, .nextSection, .prevSection:
            return false
        }
    }

    /// Title for the Editor menu in the menu bar (visible while editor mode
    /// holds `.regular`). nil = no menu item: ⌘W is already the Window menu's
    /// Close, and capture-only actions have no menu bar to live in
    /// (`.accessory`).
    var menuTitle: String? {
        switch self {
        case .toggleEditor:     return "Toggle Editor"
        case .dismissPanel:     return nil
        case .attachScreenshot: return nil
        case .refile:           return "Refile…"
        case .swallowReload:    return nil
        case .readMode:         return "Toggle Read Mode"
        case .toggleTask:       return "Toggle Checkbox"
        case .save:             return "Save Now"
        case .reorg:            return "Re-organize"
        case .nextSection:      return "Next Section"
        case .prevSection:      return "Previous Section"
        }
    }
}

enum ShortcutRegistry {
    /// The action a window-level key event should trigger, or nil to pass the
    /// event through to WebKit / the menu bar.
    static func interceptedAction(key: String?,
                                  modifiers: NSEvent.ModifierFlags,
                                  editorOpen: Bool) -> ShortcutAction? {
        ShortcutAction.allCases.first { action in
            action.isWindowIntercepted
                && action.scope.isActive(editorOpen: editorOpen)
                && action.chord.matches(key: key, modifiers: modifiers)
        }
    }

    static func interceptedAction(for event: NSEvent,
                                  editorOpen: Bool) -> ShortcutAction? {
        interceptedAction(
            key: event.charactersIgnoringModifiers?.lowercased(),
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            editorOpen: editorOpen
        )
    }

    /// Editor-local bindings as `{actionId: CodeMirror key spec}`, pushed into
    /// the web layer on editor boot — same pattern as `setRefileTargets`. The
    /// editor keeps its own copy of these defaults so the browser harness
    /// works without the bridge; this push is what makes Swift authoritative
    /// in the app.
    static var editorKeymap: [String: String] {
        Dictionary(uniqueKeysWithValues:
            ShortcutAction.allCases
                .filter { !$0.isWindowIntercepted }
                .map { ($0.rawValue, $0.chord.codeMirrorSpec) }
        )
    }

    static var editorKeymapJSON: String? {
        guard let data = try? JSONEncoder().encode(editorKeymap) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Actions that get an Editor-menu item, in declaration order.
    static var menuActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.menuTitle != nil }
    }
}
