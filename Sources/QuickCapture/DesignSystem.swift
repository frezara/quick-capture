import AppKit
import CoreText
import SwiftUI

// Highlighter — tokens from design/highlighter/THEME.md.
// Carbon (accent) means interaction; highlight means "now"; section hues mean
// identity; tertiary ink is placeholder-only.

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
    static let radiusWell:   CGFloat = 10   // preview wells (the #cal event card)
    static let radiusField:  CGFloat = 8
    static let radiusChip:   CGFloat = 6
    static let radiusKey:    CGFloat = 4
    static let s1: CGFloat = 6    // tight
    static let s2: CGFloat = 10
    static let s3: CGFloat = 16   // panel padding
    static let s4: CGFloat = 22   // section spacing
}

/// All colour tokens for one appearance.
struct Theme {
    let bg, bgHaze, surface, surfaceField, surfaceRail, sunken: Color
    let border, borderStrong, hairline, highlight: Color
    let ink, inkSecondary, inkTertiary: Color
    let accent, accentInk, accentSoft, accentRing, onAccent: Color
    let panel, control, chip, chipHover, rowHover, group, keycap: Color
    let now, nowLine, inkOnNow: Color                   // the highlighter; nowLine is deeper so 2pt reads on white
    let priHigh, priMed, priLow, warningFill: Color    // status / priority orbs
}

extension Theme {
    static let light = Theme(
        bg: Color(0xEDEFF4),
        bgHaze: Color(0xEDEFF4),
        surface: Color(0xF8F9FB),
        surfaceField: Color(0xEEF0F5),
        surfaceRail: Color(0xEDEFF4),
        sunken: Color(0xF2F4F8),
        border: Color(0xD6DAE5),
        borderStrong: Color(0xD6DAE5),
        hairline: Color(0xE2E5EE),
        highlight: Color(0xF8F9FB),
        ink: Color(0x1C2233),
        inkSecondary: Color(0x545C72),
        inkTertiary: Color(0x80879C),
        accent: Color(0x2B3FA0),
        accentInk: Color(0x2B3FA0),
        accentSoft: Color(0x2B3FA0, alpha: 0.08),
        accentRing: Color(0x2B3FA0, alpha: 0.28),
        onAccent: Color(0xFFFFFF),
        panel: Color(0xF8F9FB, alpha: 0.80),
        control: Color(0xF8F9FB),
        chip: Color(0xE2E5EE),
        chipHover: Color(0xD6DAE5),
        rowHover: Color(0xEEF0F5),
        group: Color(0xF8F9FB),
        keycap: Color(0xE2E5EE),
        now: Color(0xFFE45C),
        nowLine: Color(0xE8C21E),
        inkOnNow: Color(0x1C2233),
        priHigh: Color(0xB03A2A),
        priMed: Color(0x8A5F12),
        priLow: Color(0x2F6B3E),
        warningFill: Color(0xFDF3D7)
    )
    static let dark = Theme(
        bg: Color(0x151A28),
        bgHaze: Color(0x151A28),
        surface: Color(0x1B2132),
        surfaceField: Color(0x242B40),
        surfaceRail: Color(0x151A28),
        sunken: Color(0x171C2D),
        border: Color(0x343D58),
        borderStrong: Color(0x343D58),
        hairline: Color(0x283049),
        highlight: Color(0x1B2132),
        ink: Color(0xE9ECF5),
        inkSecondary: Color(0xA9B0C6),
        inkTertiary: Color(0x7C849C),
        accent: Color(0x9AAAFF),
        accentInk: Color(0x9AAAFF),
        accentSoft: Color(0x9AAAFF, alpha: 0.14),
        accentRing: Color(0x9AAAFF, alpha: 0.40),
        onAccent: Color(0x10162A),
        panel: Color(0x1B2132, alpha: 0.74),
        control: Color(0x1B2132),
        chip: Color(0x2C3450),
        chipHover: Color(0x343D58),
        rowHover: Color(0x242B40),
        group: Color(0x1B2132),
        keycap: Color(0x2C3450),
        now: Color(0xF0D44A),
        nowLine: Color(0xF0D44A),
        inkOnNow: Color(0x1C2233),
        priHigh: Color(0xF4A393),
        priMed: Color(0xEBC77A),
        priLow: Color(0xA2D6AC),
        warningFill: Color(0x3A321C)
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

/// One family, Recursive (bundled variable font, SIL OFL), in its linear style
/// throughout. `mono` sets its MONO axis for times, paths, key notation and the
/// monospaced capture option.
enum Typeface {
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        Font(Recursive.nsFont(size: s, weight: Recursive.axisWeight(w), mono: true) as CTFont)
    }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        Font(Recursive.nsFont(size: s, weight: Recursive.axisWeight(w), mono: false) as CTFont)
    }
}

/// The bundled Recursive variable font. SwiftUI can't set custom variation
/// axes, so fonts are built in CoreText with explicit `wght`/`CASL`/`MONO`
/// values and wrapped. Registration is lazy and process-scoped: the app
/// delegate stays inert under XCTest, and snapshot tests still need the font.
enum Recursive {
    private static let base: NSFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "Recursive-VF", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontURLs([url] as CFArray, .process, true, nil)
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        return descriptors?.first.map { $0 as NSFontDescriptor }
    }()

    private static func tag(_ s: String) -> NSNumber {
        NSNumber(value: s.unicodeScalars.reduce(UInt32(0)) { ($0 << 8) | $1.value })
    }

    private struct Key: Hashable { let size: CGFloat, weight: CGFloat, mono: Bool }
    /// Views ask for the same few faces on every render (the calendar alone,
    /// hundreds of times), and building a variable-font instance isn't free.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: NSFont] = [:]

    static func nsFont(size: CGFloat, weight: CGFloat, mono: Bool) -> NSFont {
        let key = Key(size: size, weight: weight, mono: mono)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let font = cache[key] { return font }
        let font = makeFont(size: size, weight: weight, mono: mono)
        cache[key] = font
        return font
    }

    /// Falls back to the system font if the bundled file is missing, so a
    /// broken resource degrades the look rather than the app.
    private static func makeFont(size: CGFloat, weight: CGFloat, mono: Bool) -> NSFont {
        guard let base else {
            return mono ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        }
        let variation: [NSNumber: CGFloat] = [tag("wght"): weight, tag("CASL"): 0, tag("MONO"): mono ? 1 : 0]
        let descriptor = base.addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }

    static func axisWeight(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .ultraLight: return 300
        case .thin:       return 300
        case .light:      return 300
        case .medium:     return 500
        case .semibold:   return 600
        case .bold:       return 700
        case .heavy:      return 800
        case .black:      return 900
        default:          return 400
        }
    }
}

/// The Highlighter scale (THEME.md), plus the older per-element names that the
/// views not yet redesigned still use.
enum TypeScale {
    static let display   = Font(Recursive.nsFont(size: 40, weight: 750, mono: false) as CTFont)
    static let title     = Font(Recursive.nsFont(size: 30, weight: 750, mono: false) as CTFont)
    static let heading   = Typeface.ui(20, .bold)
    static let input     = Typeface.ui(18)
    static let bodyLarge = Typeface.ui(14.5)
    static let uiBody    = Typeface.ui(13)
    static let label     = Typeface.ui(13, .bold)
    static let meta      = Typeface.ui(12)
    static let railLabel = Typeface.ui(10.5, .medium)
    static let monoMeta  = Typeface.mono(12.5)
    static let key       = Typeface.mono(11, .medium)

    static let h1        = Typeface.ui(22, .semibold)    // editor title
    static let h1Glyph   = Typeface.ui(15, .bold)        // "#" inside the app-mark
    static let h2        = Typeface.ui(11, .semibold)    // section captions
    static let body      = Typeface.mono(13)             // editor list items
    static let code      = Typeface.mono(12)             // inline code, file paths
    static let captureLg = Typeface.ui(18)               // standalone capture input
    static let captureMd = Typeface.ui(14)               // capture input inside editor
    static let tag       = Typeface.ui(13)               // tag field
    static let chip      = Typeface.ui(12.5)             // suggestion row, hint labels
    static let status    = Typeface.ui(11, .semibold)    // status bar + mode pill
    static let caption   = Typeface.ui(11, .semibold)    // UI captions
}

/// .tracking(...) values in points.
enum Tracking {
    static let display: CGFloat = -0.6
    static let title: CGFloat   = -0.5
    static let h1: CGFloat      = -0.3
    static let status: CGFloat  =  0.5
    static let caption: CGFloat =  0.8
}

// MARK: - Shared components

extension View {
    /// The grouped card: opaque group fill, field radius, hairline border.
    func groupedSurface(_ t: Theme) -> some View {
        background(t.group)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                    .strokeBorder(t.borderStrong, lineWidth: 0.5)
            )
    }
}

/// Secondary action: neutral control fill, hairline border.
struct GhostButtonStyle: ButtonStyle {
    let t: Theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(12))
            .foregroundStyle(t.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(configuration.isPressed ? t.chipHover : t.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .strokeBorder(t.borderStrong, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
    }
}

/// The one primary action on a surface: solid accent.
struct AccentButtonStyle: ButtonStyle {
    let t: Theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(12, .medium))
            .foregroundStyle(t.onAccent)
            .padding(.horizontal, Metrics.s2)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(t.accent.opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}

/// Key notation chip (Recursive mono, per the typography rule).
struct Keycap: View {
    let text: String
    let t: Theme
    var body: some View {
        Text(text)
            .font(TypeScale.key)
            .foregroundStyle(t.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusKey, style: .continuous).fill(t.keycap))
            .fixedSize()
    }
}

/// A status message that needs attention. Status colour is always paired with
/// a symbol (design-system-overview.md).
struct WarningBanner: View {
    let text: String
    let t: Theme
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(Typeface.ui(12))
            .foregroundStyle(t.priMed)
            .padding(.horizontal, Metrics.s2)
            .padding(.vertical, Metrics.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.warningFill, in: RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous))
    }
}

/// A text input in a field well — the capture field's recipe, so it reads as
/// something you can type into.
struct ThemedField: View {
    let placeholder: String
    @Binding var text: String
    let t: Theme
    var lines: ClosedRange<Int>? = nil
    var body: some View {
        Group {
            if let lines {
                TextField("", text: $text, prompt: prompt, axis: .vertical).lineLimit(lines)
            } else {
                TextField("", text: $text, prompt: prompt)
            }
        }
        .textFieldStyle(.plain)
        .font(Typeface.ui(13))
        .foregroundStyle(t.ink)
        .padding(.horizontal, Metrics.s2)
        .padding(.vertical, 7)
        .background(t.surfaceField, in: RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous))
    }
    private var prompt: Text { Text(placeholder).foregroundStyle(t.inkTertiary) }
}
