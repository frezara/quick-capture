# Quick Capture — Build Handoff (Native v2: "Pure System + Color")

Visual target: `variant-a2-color.html` with the **blue** signature accent
(the default; the teal/indigo/amber picker variants are NOT being built).
**Do not port the HTML literally** — build the idiomatic SwiftUI/AppKit/CSS
equivalent that *matches* it visually. Supersedes `design/HANDOFF.md`
(Misted Steel); that doc's workflow notes still apply.

Direction in one line: first-party Apple utility — frosted materials, system
typography, 0.5px hairlines, system blue — with *functional* color: Finder-style
tag hues and System-Settings-style row icons.

---

## 1. Design tokens

All values below are the blue-accent light/dark pair from the mockup's
`:root` / `html.dark`. In Swift these live in `DesignSystem.swift` (`Theme`);
in the editor they're mirrored in `editor-web/src/editor.ts` palettes
(keep the two in sync by hand — there is no generator).

| token        | light                     | dark                      | use |
|--------------|---------------------------|---------------------------|-----|
| accent       | #007AFF                   | #0A84FF                   | THE accent: focus, selection, checked boxes, links, NORMAL pill, toggles — but see #101 below: a checkbox inside a section takes that section's tag hue |
| accentTint   | accent @ 12%              | accent @ 16%              | soft fills (pill bg, matched chip, selection bg) |
| accentTint2  | accent @ 20%              | accent @ 28%              | stronger fill (hover on tinted things) |
| accentRing   | accent @ 35%              | accent @ 40%              | 3px focus ring outside a focused field |
| onAccent     | #FFFFFF                   | #FFFFFF                   | glyphs on solid accent |
| text1        | black @ 88%               | white @ 92%               | primary text |
| text2        | (60,60,67) @ 62%          | (235,235,245) @ 60%       | secondary: labels, hints |
| text3        | (60,60,67) @ 36%          | (235,235,245) @ 32%       | placeholder, disabled |
| hairline     | black @ 14%               | white @ 13%               | separators (0.5px) |
| ring         | black @ 18%               | white @ 14%               | 0.5px outer border of panels/windows |
| edgeLight    | white @ 55%               | white @ 10%               | inset 1px top-edge light |
| panel        | (252,252,254) @ 66%       | (38,38,42) @ 58%          | FROSTED surfaces: capture box, picker (sits on blur material) |
| window       | (246,246,248) @ 96%       | (33,33,37) @ 96%          | opaque windows: editor, settings |
| bar          | black @ 2.5%              | white @ 3%                | status-bar wash |
| well         | (120,120,128) @ 10%       | (120,120,128) @ 20%       | recessed input wells |
| chip         | (120,120,128) @ 12%       | (120,120,128) @ 24%       | neutral chips/keycaps |
| chipHover    | (120,120,128) @ 20%       | (120,120,128) @ 34%       | chip hover |
| control      | white @ 95%               | white @ 14%               | push buttons / pop-ups |
| group        | white @ 62%               | white @ 5%                | settings group card |
| rowHover     | (120,120,128) @ 7%        | white @ 5%                | list/settings row hover |
| cbBorder     | black @ 28%               | white @ 35%               | unchecked checkbox border |
| prioRed      | #FF3B30                   | #FF453A                   | priority orb (high) |
| prioGreen    | #34C759                   | #30D158                   | priority orb (low) |

Priority medium (amber `!!`): use system amber #FF9500 / #FF9F0A — the mockup
only showed red/green; keep the three-level scheme from the current app.

### Tag hues (Finder-tag style)

| hue     | light    | dark     |
|---------|----------|----------|
| coral   | #E8643F  | #F4795A  |
| teal    | #2A9D8F  | #3DBDAD  |
| magenta | #C2479B  | #DA62B4  |
| green   | #4F9E4F  | #5FBF60  |

The mockup pinned hues to specific tags; the app assigns them
deterministically per tag name via `TagPalette` (DJB2 hash → palette entry).
Replace `TagPalette.entries` with a curated 8-hue native set (the 4 above
plus blue #3B82F6-family, amber #D99A3C-family, indigo, slate) with light/dark
pairs. `cal` is a command, not a tag — its chip stays neutral, no dot.

Where tag hues appear (ONLY here):
1. 7px dot on capture suggestion chips.
2. Matched chip while typing: tint bg with hue @ ~10-12%, label in the hue.
3. 7px dot before each `##` section heading in the editor.

#### Revised by #101 — the "Sectioned" direction

The list above (and the 8-hue set) is superseded. The resolved stance is that
a tag hue is **section identity**, system blue is **interaction**, and neutral
is the ground — so the hue reaches further than a dot, and nothing outside a
section borrows one. Mockups and the generator that produced them live in
`design/color-directions/`; the decision is recorded on #101.

- **Palette**: 7 hues. **Slate is retired** — a grey gives a section no
  identity. Blue stays: at the heading mix below it renders as a dark navy,
  clearly not the system accent.
- **Assignment**: not a hash. A section takes the next unused hue the first
  time it is seen and that map is persisted, so the hue survives reordering,
  renames above it, and relaunches; past 7 sections, reuse the
  least-recently-assigned. Swift owns the map and pushes it into the editor on
  boot and on change (mirroring `setRefileTargets`) — `tagHue()` in editor.ts
  becomes a lookup and its DJB2 reimplementation goes away.
- **Where the hue now appears**: the `##` caption, mixed
  toward the PRIMARY ink (70% light / 76% dark) rather than `text2`; the
  heading's tinted band (hue @ 8% light / 12% dark) and rule (hue @ 32%); the
  indent guides under that section (hue @ 45% over the hairline); the
  checkboxes inside it; and the capture tag field when the typed tag matches a
  known one (fill hue @ 11% / 16%, border hue @ 38%, text and `#` in the hue).
  **No dot before the heading** — removed once the caption carried the hue
  itself; a bullet in front of a heading also read as a list item. The 7px dot
  on capture suggestion chips stays: there, it is the only hue present.
- **Unmatched tags and `cal`** keep the accent treatment — a tag that does not
  exist yet has no hue, and `cal` is a command, not a tag.
- **Contrast**: the caption mix is an improvement, not a cost — every hue
  lands between 5.05:1 and 8.52:1, against today's 3.49:1 light / 5.74:1 dark.

### Metrics

- Radii: capture panel 16, windows 12, fields 8, chips/keycaps 6, settings icon squares 6.
- Hairlines are 0.5px (SwiftUI: 0.5 stroke; CSS: `box-shadow: 0 0 0 0.5px`).
- Panel borders: 0.5px `ring` outside + inset 1px `edgeLight` top.
- Focus: accent border + 3px `accentRing` halo.
- Priority orbs: 8px, halo `0 0 0 3px hue@22%`.

### Typography

- **UI chrome: system font** (SF Pro) — `.system(size:weight:)` in SwiftUI,
  `-apple-system` in CSS. IBM Plex is retired from chrome (Fonts/ can stay
  bundled for now; `Typeface` maps to system).
- **Editor content + file paths: monospace** — `ui-monospace` (SF Mono) 13px,
  line-height ~1.6 in the editor; 12px for paths in settings/status bar.
- Scale: page H1 (editor "Inbox") 22px semibold sans, tracking -0.3;
  section captions 11px semibold UPPERCASE tracked +0.8 in `text2`;
  body UI 13px; status bar 11px; capture input 16px regular;
  tag field 13px mono-ish is NOT used — tag field is 13px sans.

---

## 2. Surface specs

### Capture window (frosted)
- The panel itself is the material: `NSVisualEffectView` (`.hudWindow`/
  `.popover` material, behind-window blending) under SwiftUI content, `panel`
  wash on top, radius 16, `ring` + `edgeLight` border treatment, real shadow.
- Row 1: main input in a `well` (radius 8, 16px text, placeholder `text3`),
  focused → accent border + 3px `accentRing`. Trailing narrower tag well
  (placeholder "# tag"); when it has a value → `accentTint` fill, accent text.
- Hairline divider; suggestions row: neutral `chip` chips, each tag chip gets
  its 7px hue dot; matched chip = own-hue tint + hue label. `cal` chip keeps
  its calendar glyph, no dot. Right-aligned hint "⌘⇧S to attach screenshot"
  in `text3`.
- Keep CaptureView's window-sizing contract (`onContentSizeChange`) intact —
  retheme in place, do not restructure the measurement hierarchy.

### Editor window (opaque)
- Window/container: `window` bg, radius 12 (chrome handled Swift-side in
  `MainPanel.setupContainer`), no title bar (unchanged).
- H1 line: 26px rounded-square (radius 7) accent-gradient app-mark with white
  "#" + "Inbox" in 22px semibold sans. (Replaces the old mono H1 + HashGlyph.)
- `##` headings render as 11px semibold UPPERCASE tracked `text2` captions
  with a 7px tag-hue dot (hue from the shared TagPalette logic — heading text
  == tag name) and a hairline rule. Cursor-on-line still reveals raw `## x`.
- Items: mono 13px `text1`; checkbox 15px rounded-square (r4), `cbBorder`
  0.5px, checked = accent fill + white ✓; done label struck `text3`.
  Links accent. Inline code in `well` bg. Attachment chips: `chip` bg, mono
  11px, image glyph.
- Priority orbs: 8px prioRed/amber/prioGreen + halo, right-aligned (unchanged
  behavior).
- Floating action cluster: frosted-look `control` card, radius 8, icon buttons
  with `rowHover` hover; bottom-right (unchanged behavior).
- Status bar: `bar` wash, hairline top; left = NORMAL pill (`accentTint` bg,
  accent text, 11px semibold, radius 5) + filename in mono 11px `text2`;
  right = "27 items · 2 done" + "UTF-8" in 11px `text2`/`text3`. Sans for
  everything except filename.

### Screenshot picker (frosted)
- Same material recipe as the capture panel, radius 12.
- Header: "Recent screenshots" 15px semibold; right keyboard hints in `text3`
  with keycap chips (`chip` bg, radius 6, mono 11px) for ↑↓ / ↵ / esc.
- Left list rows: thumbnail + "1:19 PM / Today" (13px `text1` + 11px `text2`),
  radius 8; selected = `accentTint` bg + accent 0.5px ring; hover `rowHover`.
- Right: preview in a recessed `well` (radius 8) with checkerboard backing.

### Settings window
- `window` bg. Grouped System-Settings-style: group title 11px semibold
  uppercase `text2`, then a `group` card (radius 10, `ring` border) of rows
  separated by hairlines (inset past the icon column). Row height ~38px.
- Every row: leading 24px rounded-square (r6) colored icon, subtle vertical
  gradient (lighter top), white SF Symbol ~13px:
  capture file = blue `doc.text`; timestamp = grey `clock`; font = grey "Aa";
  vim = green `terminal`; auto-attach = teal `camera`; launch-at-login =
  orange `power`; hotkey = indigo `command`; refile targets = amber `folder`.
- Controls: native SwiftUI `Toggle` (`.switch`), `Picker` (`.menu`), plain
  bordered buttons. Drop the custom `SettingsGhostButton` styling in favor of
  the `control` recipe or native bordered style.
- Refile target rows: amber folder square, name 13px, path mono 11px `text2`,
  trailing ▲▼✕ ghost buttons. "Add Folder…" button below the card.
- Hotkey row shows current binding as keycaps + "Record…" button
  (KeyRecorderView restyled to keycap look).

---

## 3. Implementation order & gotchas

1. `DesignSystem.swift` — new `Theme` (table above), `Typeface` → system
   fonts, new `TypeScale`/`Tracking`, curated `TagPalette`. Keep the
   `Theme`/`Metrics`/`TypeScale` API shape so views keep compiling.
2. Capture window (`CaptureView` + `MainPanel` material/corner config).
3. Editor (`editor-web/src/editor.ts`): update both palettes + theme CSS.
   **`npm run build` required after.** Swift-side container colors in
   `MainPanel.setupContainer` must match `window`.
4. Screenshot picker view.
5. `SettingsView` (+ `KeyRecorderView` keycaps).
- Warm color only in priority orbs, tag hues, and settings icon squares.
- Atomic writes / NSLog / LSUIElement conventions unchanged.
- Tests: quit the running app first (single-instance guard kills the test
  host). Existing FileWriter/refile tests are visual-independent.
