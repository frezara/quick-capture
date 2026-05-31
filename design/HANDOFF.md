# Quick Capture — Build Handoff (Misted Steel)

Visual targets: `quick_capture_redesign.html` (capture bar) and
`inbox_editor_redesign.html` (editor window). **Do not port the HTML literally** —
build the idiomatic SwiftUI/AppKit equivalent that *matches* these visually.
Target macOS Tahoe (26).

Single light/dark pair for now, driven by system appearance. A theme picker in
Settings can be added later by swapping the `Theme` value — no structural change.

> This is the **sharpened** pass: brighter accent, crisper borders/shadow, tighter
> radii, colour-coded priority orbs, no title bar / window chrome / left rail.

---

## 1. Design tokens → SwiftUI

```swift
import SwiftUI

extension Color {
    /// Color(0xRRGGBB)
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
```

### Wiring to system appearance

```swift
private struct ThemeKey: EnvironmentKey { static let defaultValue: Theme = .light }
extension EnvironmentValues {
    var theme: Theme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } }
}

struct RootView: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ContentView().environment(\.theme, scheme == .dark ? .dark : .light)
    }
}
// Subviews:  @Environment(\.theme) private var theme  →  .background(theme.surface)
```

A future Settings picker just replaces `scheme == .dark ? .dark : .light` with the
user's chosen `Theme`; everything downstream already reads from the environment.

---

## 2. Typography & type scale

The mockups use **IBM Plex Mono** (all user content + markdown body) and
**IBM Plex Sans** (chrome: captions, status bar). Bundle both in the app target,
or fall back to the system equivalents (`.monospaced` design / default).

```swift
enum Typeface {
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .custom("IBMPlexMono", size: s).weight(w)
        // fallback if not bundled:  .system(size: s, weight: w, design: .monospaced)
    }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .custom("IBMPlexSans", size: s).weight(w)
        // fallback:  .system(size: s, weight: w)
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
```

Rule of thumb: **hierarchy comes from size / weight / tracking, never from extra
colours.** Mono carries all content; the UI font is only for tiny uppercased chrome.

---

## 3. Screen specs

### Capture bar (`quick_capture_redesign.html`)
- Single horizontal row in a `surface` panel: `radiusWindow` corners, 1px `border`,
  soft top-edge `highlight` gradient (top ~12%). **No leading icon** — the row
  starts at the input.
- Main input: `surfaceField` well, `TypeScale.captureLg`. Focus → `accent` border
  + a 3px `accentSoft` ring.
- Tag field: same well, narrower, secondary. Becomes `accentSoft` fill +
  `accentInk` text once a tag is entered.
- Trailing: "open inbox.md" glyph (`inkTertiary`) — **standalone HUD only**; omit it
  inside the editor (inbox.md is already open there).
- Suggestions row: one chip treatment for all; the matched tag carries `accentSoft`
  + `accentInk`, the rest stay neutral. No per-tag colours.
- **Behaviour:** input must hold focus on first launch.

### Editor window (`inbox_editor_redesign.html`)
- **No title bar and no window controls** — it's a borderless rounded panel, not a
  chromed window. The filename appears only in the status bar.
- Top = the capture bar (no leading glyph, no "open" icon here).
- Body = scrolling markdown content, **full width** (no left rail).
- Markdown render: H1 = `accent` `#` glyph + bold mono title; H2 sections with
  hairline `border` rules; checklist items in mono; done item = `accent`-filled box
  + strikethrough; inline code uses `accentSoft`.
- **Priority orbs:** a trailing dot per flagged item, colour-coded
  `priHigh` / `priMed` / `priLow`, each with a soft same-colour halo
  (`shadow 0 0 0 3px <colour>@22%`). This is the only place warm colour appears.
  Unflagged items show no orb.
- **Floating action cluster** (bottom-right, over content): a small `surface` card
  with `border` + `shadow`, holding export + archive icon buttons; hover →
  `accentSoft`. Replaces the old left rail.
- **Status bar** (`surfaceRail`, bottom): `NORMAL` mode pill (`accentSoft` /
  `accentInk`), filename, item count, encoding. This is the vim mode indicator's home.

### Deferred (not built yet)
- **Snapshot / date tab strip.** Liked, but needs one-file-per-day first. When that
  lands, reintroduce the strip directly above the content — readable labels
  (`May 30 · 12:37`), active tab marked by an `accent` underline + filled dot. No
  other structural change required.

---

## 4. Prompt for Claude Code

> I'm building a native macOS quick-capture app in SwiftUI (target macOS Tahoe 26).
> Attached: two HTML mockups (capture bar, editor window) and HANDOFF.md with the
> design tokens, type scale, and screen specs.
>
> Don't translate the HTML literally — build the idiomatic SwiftUI version that
> matches the mockups visually. Use the `Theme`, `Metrics`, `Typeface`, `TypeScale`,
> and `Tracking` definitions from HANDOFF.md verbatim and read all colours, spacing,
> radii, fonts, and tracking from them — no hard-coded values anywhere. Drive
> light/dark off the system colour scheme via the environment as shown. Keep warm
> colour confined to the priority orbs.
>
> Start with the capture bar only — visual shell plus the resting / typing /
> suggestion states, no persistence or Drive logic yet. Get the panel, focus ring,
> and tag treatment right first. I'll run it in Xcode preview and send screenshots
> back before we build the editor window.

Then work the loop: preview → screenshot → adjust. Build the editor as a second
slice once the capture bar matches.

---

## 5. Optional: repo `CLAUDE.md`

```md
# Project
Native macOS quick-capture app (SwiftUI, macOS Tahoe 26). Drops timestamped
markdown into an Obsidian inbox via Google Drive.

# Design — "Misted Steel"
Cool monochrome, single steel-blue accent, crisp borders. All colours, spacing,
radii, fonts, and tracking come from DesignSystem.swift (Theme / Metrics /
TypeScale). Never hard-code these. Light/dark follow system appearance.
Warm colour is allowed ONLY for priority orbs (high/med/low).

# Conventions
- User content + markdown body: IBM Plex Mono (fallback: system monospaced).
- Chrome labels: IBM Plex Sans, uppercased, wide tracking.
- No title bar / window chrome; filename lives in the status bar.
- Prefer native AppKit/SwiftUI patterns. Build in small slices, one screen at a time.
```
