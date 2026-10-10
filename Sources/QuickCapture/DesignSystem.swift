import SwiftUI

// Clear & Charcoal — shared tokens from design-system-overview.md.
// Accent means interaction; section hues mean identity; tertiary ink is placeholder-only.

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
    let ink, inkSecondary, inkTertiary: Color
    let accent, accentInk, accentSoft, accentRing, onAccent: Color
    let panel, control, chip, chipHover, rowHover, group: Color
    let priHigh, priMed, priLow, warningFill: Color    // priority orbs
}

extension Theme {
    static let light = Theme(
        bg: Color(0xF0F3F1),
        bgHaze: Color(0xF0F3F1),
        surface: Color(0xFAFCFB),
        surfaceField: Color(0xE8EEEB),
        surfaceRail: Color(0xF0F3F1),
        border: Color(0xD5DEDB),
        borderStrong: Color(0xD5DEDB),
        highlight: Color(0xFAFCFB),
        ink: Color(0x202D29),
        inkSecondary: Color(0x596B64),
        inkTertiary: Color(0x596B64, alpha: 0.60),
        accent: Color(0x1672DF),
        accentInk: Color(0x165EB8),
        accentSoft: Color(0x1672DF, alpha: 0.07),
        accentRing: Color(0x1672DF, alpha: 0.14),
        onAccent: Color(0xFFFFFF),
        panel: Color(0xFAFCFB, alpha: 0.66),
        control: Color(0xFAFCFB),
        chip: Color(0xE8EEEB),
        chipHover: Color(0xD5DEDB),
        rowHover: Color(0xE8EEEB),
        group: Color(0xFAFCFB),
        priHigh: Color(0xBA503C),
        priMed: Color(0x956018),
        priLow: Color(0x3D6C4B),
        warningFill: Color(0xFCF2DF)
    )
    static let dark = Theme(
        bg: Color(0x1E2522),
        bgHaze: Color(0x1E2522),
        surface: Color(0x242C2A),
        surfaceField: Color(0x303B37),
        surfaceRail: Color(0x1E2522),
        border: Color(0x46534D),
        borderStrong: Color(0x46534D),
        highlight: Color(0x242C2A),
        ink: Color(0xF1F4F2),
        inkSecondary: Color(0xB6C5BD),
        inkTertiary: Color(0xB6C5BD, alpha: 0.55),
        accent: Color(0x69A8FF),
        accentInk: Color(0x91BFFF),
        accentSoft: Color(0x69A8FF, alpha: 0.09),
        accentRing: Color(0x69A8FF, alpha: 0.20),
        onAccent: Color(0x122335),
        panel: Color(0x242C2A, alpha: 0.58),
        control: Color(0x242C2A),
        chip: Color(0x303B37),
        chipHover: Color(0x46534D),
        rowHover: Color(0x303B37),
        group: Color(0x242C2A),
        priHigh: Color(0xF09C86),
        priMed: Color(0xE5B95B),
        priLow: Color(0xA4D2B0),
        warningFill: Color(0x373025)
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
