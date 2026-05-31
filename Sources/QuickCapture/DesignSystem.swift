import SwiftUI

// "Misted Steel" design system — see design/HANDOFF.md. Cool monochrome with a
// single steel-blue accent; warm colour is allowed ONLY for the priority orbs.
// Everything visual (colour, spacing, radii, fonts, tracking) is read from the
// tokens below — no hard-coded values in the views.

extension Color {
    /// Color(0xRRGGBB). Positional/`alpha:` form from the handoff — distinct from
    /// the labelled `Color(hex:opacity:)` in TagColor.swift, so both coexist.
    init(_ hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha)
    }
}

/// Theme-independent metrics (shared across light/dark).
enum Metrics {
    static let radiusWindow: CGFloat = 14
    static let radiusField:  CGFloat = 10
    static let radiusChip:   CGFloat = 7
    static let s1: CGFloat = 6    // tight
    static let s2: CGFloat = 10
    static let s3: CGFloat = 16   // panel padding
    static let s4: CGFloat = 22   // section spacing
}

/// All colour tokens for one appearance.
struct Theme {
    let bg, bgHaze, surface, surfaceField, surfaceRail: Color
    let border, borderStrong, highlight: Color
    let ink, inkSecondary, inkTertiary: Color
    let accent, accentInk, accentSoft, onAccent: Color
    let priHigh, priMed, priLow: Color    // priority orbs — the ONLY warm colour
}

extension Theme {
    static let light = Theme(
        bg:           Color(0xE4EAF0),  // desktop / behind-window haze
        bgHaze:       Color(0xD4DDE7),
        surface:      Color(0xF7F9FB),  // panels & windows
        surfaceField: Color(0xE8EEF3),  // recessed input wells
        surfaceRail:  Color(0xEEF2F6),  // status bar / floating cluster card
        border:       Color(0xC2CCD7),
        borderStrong: Color(0xA7B4C2),
        highlight:    Color(0xFFFFFF),  // brushed top-edge light
        ink:          Color(0x1B222B),  // primary entered text
        inkSecondary: Color(0x54616E),  // labels, glyphs
        inkTertiary:  Color(0x8B97A4),  // placeholder
        accent:       Color(0x2F6FA3),  // THE single accent (steel blue)
        accentInk:    Color(0x245A86),  // accent text on soft fill
        accentSoft:   Color(0xD4E3F1),  // accent low-opacity fill
        onAccent:     Color(0xFFFFFF),  // text/icon on a solid accent fill
        priHigh:      Color(0xDB5560),  // high  priority
        priMed:       Color(0xD99A3C),  // med   priority
        priLow:       Color(0x4E9E84)   // low   priority
    )

    static let dark = Theme(
        bg:           Color(0x161B21),
        bgHaze:       Color(0x0D1115),
        surface:      Color(0x242C35),
        surfaceField: Color(0x1A212A),
        surfaceRail:  Color(0x1E252E),
        border:       Color(0x38424E),
        borderStrong: Color(0x4A5663),
        highlight:    Color(0x404B57),
        ink:          Color(0xEDF1F5),
        inkSecondary: Color(0xA2AEBB),
        inkTertiary:  Color(0x6B7682),
        accent:       Color(0x5AA2E0),
        accentInk:    Color(0x8FC2EE),
        accentSoft:   Color(0x23364A),
        onAccent:     Color(0x161B21),
        priHigh:      Color(0xF0727C),
        priMed:       Color(0xE7B05A),
        priLow:       Color(0x6FBBA0)
    )
}

// MARK: - Wiring to system appearance

private struct ThemeKey: EnvironmentKey { static let defaultValue: Theme = .light }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Resolves the active `Theme` from the system colour scheme and injects it into
/// the environment. A future Settings picker swaps the chosen `Theme` here;
/// everything downstream already reads `@Environment(\.theme)`.
struct ThemedRoot<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().environment(\.theme, scheme == .dark ? .dark : .light)
    }
}

// MARK: - Typography

enum Typeface {
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        switch w {
        case .bold, .heavy, .black:
            return .custom("IBMPlexMono-Bold", size: s)
        case .semibold, .medium:
            return .custom("IBMPlexMono-SemiBold", size: s)
        default:
            return .custom("IBMPlexMono-Regular", size: s)
        }
    }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        switch w {
        case .bold, .heavy, .black, .semibold, .medium:
            return .custom("IBMPlexSans-SemiBold", size: s)
        default:
            return .custom("IBMPlexSans-Regular", size: s)
        }
    }
}

/// Exact per-element scale taken from the mockups.
enum TypeScale {
    static let h1        = Typeface.mono(28, .bold)       // heading title
    static let h1Glyph   = Typeface.mono(26, .bold)       // accent "#" glyph
    static let h2        = Typeface.mono(17, .semibold)   // section heading
    static let body      = Typeface.mono(14)              // list items (line spacing ≈ 1.5)
    static let code      = Typeface.mono(13)              // inline code
    static let captureLg = Typeface.mono(17)              // standalone capture input
    static let captureMd = Typeface.mono(15)              // capture input inside editor
    static let tag       = Typeface.mono(15)              // tag field (14 inside editor)
    static let chip      = Typeface.mono(13)              // suggestion chip
    static let status    = Typeface.mono(11, .semibold)   // status bar + mode pill
    static let caption   = Typeface.ui(11, .semibold)     // UPPERCASE section captions
}

/// .tracking(...) values in points.
enum Tracking {
    static let h1: CGFloat      = -0.4   // tighten the title
    static let status: CGFloat  =  1.1   // mode pill / status bar
    static let caption: CGFloat =  1.5   // uppercased UI captions
}
