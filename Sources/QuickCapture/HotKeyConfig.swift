import AppKit
import HotKey

struct HotKeyConfig: Equatable, Codable {
    var keyCode: UInt32       // Carbon key code (NSEvent.keyCode)
    var modifiers: UInt       // NSEvent.ModifierFlags.rawValue, masked to ⌃⌥⇧⌘
    var displayName: String   // e.g. "T", "Space", "F1"

    static let `default` = HotKeyConfig(
        keyCode: 45,          // kVK_ANSI_N
        modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue,
        displayName: "N"
    )

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var key: Key? {
        Key(carbonKeyCode: keyCode)
    }

    var displayString: String {
        var s = ""
        let m = modifierFlags
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += displayName
        return s
    }
}
