import XCTest
import AppKit
import SwiftUI
@testable import QuickCapture

/// Locks the contrast floor for persistent informational text (#106).
///
/// The capture box and picker are frosted, so what sits behind the text is the
/// panel wash composited over whatever is on screen — modelled here with
/// `Theme.bg`, the behind-window haze the design system already defines. The
/// editor's status bar is opaque: its rail wash over the window surface.
final class ThemeContrastTests: XCTestCase {

    // MARK: - WCAG 2.1

    private func srgb(_ color: Color) -> NSColor {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            XCTFail("colour is not representable in sRGB")
            return .black
        }
        return converted
    }

    /// `fg` (which may be translucent) painted over an opaque `bg`.
    private func composite(_ fg: Color, over bg: NSColor) -> NSColor {
        let f = srgb(fg)
        let a = f.alphaComponent
        return NSColor(srgbRed: f.redComponent * a + bg.redComponent * (1 - a),
                       green: f.greenComponent * a + bg.greenComponent * (1 - a),
                       blue: f.blueComponent * a + bg.blueComponent * (1 - a),
                       alpha: 1)
    }

    private func luminance(_ c: NSColor) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let s = Double(v)
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
             + 0.7152 * channel(c.greenComponent)
             + 0.0722 * channel(c.blueComponent)
    }

    private func contrast(_ fg: Color, on bg: NSColor) -> Double {
        let a = luminance(composite(fg, over: bg))
        let b = luminance(bg)
        let (hi, lo) = a > b ? (a, b) : (b, a)
        return (hi + 0.05) / (lo + 0.05)
    }

    // MARK: - Surfaces

    /// The frosted capture panel resolved against the behind-window haze.
    private func frostedPanel(_ theme: Theme) -> NSColor {
        composite(theme.panel, over: srgb(theme.bg))
    }

    /// The editor's status bar: an opaque window with the rail wash on top.
    private func statusRail(_ theme: Theme) -> NSColor {
        composite(theme.surfaceRail, over: srgb(theme.surface))
    }

    // MARK: - The floor

    func testHintInkMeetsAAOnTheFrostedPanel() {
        for (name, theme) in [("light", Theme.light), ("dark", Theme.dark)] {
            let ratio = contrast(theme.inkHint, on: frostedPanel(theme))
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(name): hint-bar labels are \(String(format: "%.2f", ratio)):1 on the frosted panel"
            )
        }
    }

    func testHintInkMeetsAAOnTheEditorStatusBar() {
        for (name, theme) in [("light", Theme.light), ("dark", Theme.dark)] {
            let ratio = contrast(theme.inkHint, on: statusRail(theme))
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(name): status bar is \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    func testBodyInkIsUnaffected() {
        // The change is confined to the hint ink; primary text was never the
        // problem and must not have moved.
        XCTAssertGreaterThanOrEqual(contrast(Theme.light.ink, on: srgb(Theme.light.surface)), 12)
        XCTAssertGreaterThanOrEqual(contrast(Theme.dark.ink, on: srgb(Theme.dark.surface)), 12)
    }

    func testPlaceholderInkStaysFaintOnPurpose() {
        // `inkTertiary` is placeholder-only and deliberately below AA — a
        // prompt you are about to type over, not text to read. Pinned so a
        // future contrast pass raises `inkHint` (or adds a token) rather than
        // "fixing" this one and flattening the hierarchy.
        for theme in [Theme.light, Theme.dark] {
            XCTAssertLessThan(contrast(theme.inkTertiary, on: frostedPanel(theme)),
                              contrast(theme.inkHint, on: frostedPanel(theme)))
        }
    }
}
