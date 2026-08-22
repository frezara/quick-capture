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

    /// A keycap on the frosted panel. The binding case, and easy to miss: the
    /// chip's own fill darkens what sits behind the glyph, so a value that
    /// clears the bare panel can still fail here (0.74 → 4.83:1 on the panel,
    /// 4.48:1 on the chip).
    private func keycapChip(_ theme: Theme) -> NSColor {
        composite(theme.chip, over: frostedPanel(theme))
    }

    // MARK: - The floor

    /// One readable level (ADR-0006), so one assertion covering every surface
    /// it lands on.
    func testSecondaryInkMeetsAAOnEverySurfaceItLandsOn() {
        for (name, theme) in [("light", Theme.light), ("dark", Theme.dark)] {
            for (surface, bg) in [("frosted panel", frostedPanel(theme)),
                                  ("keycap chip", keycapChip(theme)),
                                  ("status rail", statusRail(theme))] {
                let ratio = contrast(theme.inkSecondary, on: bg)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name) \(surface): secondary text is \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    /// The ramp has exactly three levels and reads in order. Pinned because the
    /// bug ADR-0006 fixes was a fourth level that ended up *above* the one it
    /// was meant to sit below.
    func testRampIsMonotonic() {
        for (name, theme) in [("light", Theme.light), ("dark", Theme.dark)] {
            let panel = frostedPanel(theme)
            let primary = contrast(theme.ink, on: panel)
            let secondary = contrast(theme.inkSecondary, on: panel)
            let placeholder = contrast(theme.inkTertiary, on: panel)
            XCTAssertGreaterThan(primary, secondary, "\(name): primary must outrank secondary")
            XCTAssertGreaterThan(secondary, placeholder, "\(name): secondary must outrank the placeholder")
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
        // future contrast pass raises the readable level rather than "fixing"
        // this one and flattening the ramp into two.
        for theme in [Theme.light, Theme.dark] {
            XCTAssertLessThan(contrast(theme.inkTertiary, on: frostedPanel(theme)), 3.0)
        }
    }
}
