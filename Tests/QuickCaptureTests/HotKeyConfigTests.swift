import AppKit
import HotKey
import XCTest
@testable import QuickCapture

/// Round-trip coverage for the hotkey model that backs the Settings recorder.
/// The recorder persists a `HotKeyConfig` to UserDefaults as JSON and the
/// AppDelegate decodes it on launch to register the global shortcut, so the
/// encode→decode cycle must preserve the key code, modifier mask, and label
/// exactly across every modifier combination (issue #41).
final class HotKeyConfigTests: XCTestCase {

    private func roundTrip(_ config: HotKeyConfig,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> HotKeyConfig {
        let data = try JSONEncoder().encode(config)
        return try JSONDecoder().decode(HotKeyConfig.self, from: data)
    }

    func testDefaultRoundTrips() throws {
        let decoded = try roundTrip(.default)
        XCTAssertEqual(decoded, .default)
    }

    func testRoundTripAcrossModifierCombinations() throws {
        // Every non-empty subset of the four maskable modifiers, on a stable key.
        let mods: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift]
        for size in 1...mods.count {
            for combo in mods.combinations(ofCount: size) {
                let flags = combo.reduce(NSEvent.ModifierFlags()) { $0.union($1) }
                let config = HotKeyConfig(keyCode: 17, modifiers: flags.rawValue, displayName: "T")
                let decoded = try roundTrip(config)
                XCTAssertEqual(decoded, config, "modifiers \(flags.rawValue) did not survive the round trip")
                XCTAssertEqual(decoded.modifierFlags, flags)
            }
        }
    }

    func testRoundTripPreservesKeyCodeAndDisplayName() throws {
        let config = HotKeyConfig(
            keyCode: 49,   // kVK_Space
            modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
            displayName: "Space"
        )
        let decoded = try roundTrip(config)
        XCTAssertEqual(decoded.keyCode, 49)
        XCTAssertEqual(decoded.displayName, "Space")
        XCTAssertEqual(decoded.modifierFlags, [.control, .option])
    }

    func testDecodedConfigResolvesToHotKeyKey() throws {
        // The AppDelegate registration path bails (keeping the prior binding)
        // when `key` is nil, so a persisted standard combo must still resolve.
        let decoded = try roundTrip(.default)
        XCTAssertNotNil(decoded.key, "default hotkey must map to a HotKey.Key so it can register")
        XCTAssertEqual(decoded.key, Key(carbonKeyCode: 17))
    }

    func testDisplayStringOrdersModifiersAndAppendsName() {
        let config = HotKeyConfig(
            keyCode: 17,
            modifiers: NSEvent.ModifierFlags([.command, .option, .shift, .control]).rawValue,
            displayName: "T"
        )
        XCTAssertEqual(config.displayString, "⌃⌥⇧⌘T")
    }
}

// MARK: - Combinations helper

private extension Array {
    /// All combinations of `count` elements, preserving source order. Small,
    /// test-local helper so the modifier matrix above stays declarative without
    /// pulling in swift-algorithms.
    func combinations(ofCount count: Int) -> [[Element]] {
        guard count > 0 else { return [[]] }
        guard count <= self.count else { return [] }
        if count == self.count { return [self] }
        guard let first = self.first else { return [] }
        let rest = Array(self.dropFirst())
        let withFirst = rest.combinations(ofCount: count - 1).map { [first] + $0 }
        let withoutFirst = rest.combinations(ofCount: count)
        return withFirst + withoutFirst
    }
}
