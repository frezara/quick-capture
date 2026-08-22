import SwiftUI

// "Pure System + Color" (native v2) design system — see design/native-v2/HANDOFF.md.
// First-party-Apple feel: system typography, frosted materials, 0.5px hairlines,
// system blue as THE accent. Everything visual is read from the tokens below —
// no hard-coded values in the views.
//
// Color has three jobs and no others (the "Sectioned" direction, #101):
//   - tag hue (TagColor.swift) = SECTION IDENTITY. A section's hue carries its
//     dot, caption, rule, indent guides and the checkboxes inside it, plus the
//     capture tag field — the same tag. Nothing else borrows a tag hue.
//   - system blue = INTERACTION. Focus, selection, links, checked state outside
//     a section, the vim mode pill.
//   - neutral = the ground. Surfaces stay near-monochrome; warmer surfaces were
//     explored and rejected.
// Priority orbs and the settings row icons are the standing exceptions — they
// are functional color that predates the direction.
//
// The `Theme` tokens below are deliberately unchanged by that direction: the
// hue is per-section state (TagColor.swift), not a theme colour, and warmer
// surfaces were explored and rejected. Landed as #102 (hue assignment),
// #103 (editor), #104 (capture tag field); see design/color-directions/.

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
    static let radiusPanel:  CGFloat = 16   // frosted floating panels (capture, picker)
    static let radiusWindow: CGFloat = 12   // opaque windows (editor, settings)
    static let radiusField:  CGFloat = 8
    static let radiusChip:   CGFloat = 6
    static let s1: CGFloat = 6    // tight
    static let s2: CGFloat = 10
    static let s3: CGFloat = 16   // panel padding
    static let s4: CGFloat = 22   // section spacing
}

/// All colour tokens for one appearance.
struct Theme {
    let bg, bgHaze, surface, surfaceField, surfaceRail: Color
    let border, borderStrong, highlight: Color
    let ink, inkSecondary, inkTertiary, inkHint: Color
    let accent, accentInk, accentSoft, accentRing, onAccent: Color
    let panel, control, chip, chipHover, rowHover, group: Color
    let priHigh, priMed, priLow: Color    // priority orbs
}

extension Theme {
    static let light = Theme(
        bg:           Color(0xECEDF0),               // behind-window haze
        bgHaze:       Color(0xDDE0E5),
        surface:      Color(0xF6F6F8),               // opaque windows (editor, settings)
        surfaceField: Color(0x787880, alpha: 0.10),  // recessed input wells
        surfaceRail:  Color(0x000000, alpha: 0.025), // status-bar wash
        border:       Color(0x000000, alpha: 0.14),  // hairline separators (0.5px)
        borderStrong: Color(0x000000, alpha: 0.18),  // 0.5px outer panel ring
        highlight:    Color(0xFFFFFF, alpha: 0.55),  // inset top-edge light
        ink:          Color(0x000000, alpha: 0.88),
        inkSecondary: Color(0x3C3C43, alpha: 0.62),
        inkTertiary:  Color(0x3C3C43, alpha: 0.36),  // placeholders ONLY — deliberately faint
        // Persistent informational text on a frosted panel: hint-bar labels,
        // picker keyboard hints and day lines (#106). `inkTertiary` reads at
        // 1.93:1 there, which is placeholder territory — fine for a prompt you
        // are about to type over, not for text meant to be read. 0.72 clears
        // 4.5:1 over a light desktop; a dark wallpaper darkens the frost and
        // still falls short, which would take a near-black hint to fix and
        // isn't worth what that costs visually. 0.73 rather than 0.72 so the
        // same value also clears the bar on the editor's opaque status rail.
        inkHint:      Color(0x3C3C43, alpha: 0.73),
        accent:       Color(0x007AFF),               // THE accent (system blue)
        accentInk:    Color(0x0066D6),               // accent text on soft fill
        accentSoft:   Color(0x007AFF, alpha: 0.12),  // soft accent fill
        accentRing:   Color(0x007AFF, alpha: 0.35),  // 3px focus halo
        onAccent:     Color(0xFFFFFF),
        panel:        Color(0xFCFCFE, alpha: 0.66),  // frosted wash over blur material
        control:      Color(0xFFFFFF, alpha: 0.95),  // push buttons / pop-ups
        chip:         Color(0x787880, alpha: 0.12),
        chipHover:    Color(0x787880, alpha: 0.20),
        rowHover:     Color(0x787880, alpha: 0.07),
        group:        Color(0xFFFFFF, alpha: 0.62),  // settings group card
        priHigh:      Color(0xFF3B30),
        priMed:       Color(0xFF9500),
        priLow:       Color(0x34C759)
    )

    static let dark = Theme(
        bg:           Color(0x1E1E22),
        bgHaze:       Color(0x141417),
        surface:      Color(0x212125),
        surfaceField: Color(0x787880, alpha: 0.20),
        surfaceRail:  Color(0xFFFFFF, alpha: 0.03),
        border:       Color(0xFFFFFF, alpha: 0.13),
        borderStrong: Color(0xFFFFFF, alpha: 0.14),
        highlight:    Color(0xFFFFFF, alpha: 0.10),
        ink:          Color(0xFFFFFF, alpha: 0.92),
        inkSecondary: Color(0xEBEBF5, alpha: 0.60),
        inkTertiary:  Color(0xEBEBF5, alpha: 0.32),
        // Not light mode's 0.72: dark ink starts far brighter relative to the
        // panel, so 0.72 would land at 7.72:1 and read as loud as body text.
        // 0.55 meets the same 4.5:1 bar without promoting a hint to a headline.
        inkHint:      Color(0xEBEBF5, alpha: 0.55),
        accent:       Color(0x0A84FF),
        accentInk:    Color(0x409CFF),
        accentSoft:   Color(0x0A84FF, alpha: 0.16),
        accentRing:   Color(0x0A84FF, alpha: 0.40),
        onAccent:     Color(0xFFFFFF),
        panel:        Color(0x26262A, alpha: 0.58),
        control:      Color(0xFFFFFF, alpha: 0.14),
        chip:         Color(0x787880, alpha: 0.24),
        chipHover:    Color(0x787880, alpha: 0.34),
        rowHover:     Color(0xFFFFFF, alpha: 0.05),
        group:        Color(0xFFFFFF, alpha: 0.05),
        priHigh:      Color(0xFF453A),
        priMed:       Color(0xFF9F0A),
        priLow:       Color(0x30D158)
    )
}

// MARK: - Materials

/// Behind-window blur for the frosted floating panels (capture box, picker).
/// `.active` always — a non-activating panel never becomes key, and the frost
/// shouldn't die when focus sits elsewhere.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
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

/// UI chrome is the system font (SF Pro); monospace (SF Mono) is reserved for
/// user content — editor text, file paths, keycaps. IBM Plex is retired.
enum Typeface {
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: s, weight: w, design: .monospaced)
    }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: s, weight: w)
    }
}

/// Per-element scale from the native-v2 mockup.
enum TypeScale {
    static let h1        = Typeface.ui(22, .semibold)    // editor title
    static let h1Glyph   = Typeface.ui(15, .bold)        // "#" inside the app-mark
    static let h2        = Typeface.ui(11, .semibold)    // UPPERCASE section captions
    static let body      = Typeface.mono(13)             // editor list items
    static let code      = Typeface.mono(12)             // inline code, file paths
    static let captureLg = Typeface.ui(16)               // standalone capture input
    static let captureMd = Typeface.ui(14)               // capture input inside editor
    static let tag       = Typeface.ui(13)               // tag field
    static let chip      = Typeface.ui(12)               // suggestion chip
    static let status    = Typeface.ui(11, .semibold)    // status bar + mode pill
    static let caption   = Typeface.ui(11, .semibold)    // UPPERCASE UI captions
}

/// .tracking(...) values in points.
enum Tracking {
    static let h1: CGFloat      = -0.3
    static let status: CGFloat  =  0.5
    static let caption: CGFloat =  0.8
}
