# Clear & Charcoal — unified Mac app design system

Design System artifact (tokens, brand book, component previews): https://claude.ai/artifact/7aQj8AcwbqPawmJD1kgwNp

## Where it came from

- **Hyper Active** — approved direction *B (Keyboard) / Ivory & Iris*: `DESIGN_SYSTEM_HA.md`, `Sources/DesignSystem.swift`, `prototypes/settings/`.
- **Quick Capture** — approved direction *D Unified / "Your mix"* (Clear / Charcoal palette): `design/screen-prototype.html`, `design/SCREEN_PROTOTYPE.md`; production tokens in `Sources/QuickCapture/DesignSystem.swift`; colour rules in `docs/adr/0005-colour-semantics.md` and `0006-three-level-ink-ramp.md`.
- Decision (10 Oct 2026): build the shared system on **Your mix**. Ivory & Iris retired because QC's ADR-0005 rejects warm surfaces; Hyper Active moves from iris to the blue accent.

## Palette (Clear / Charcoal)

| Token | Light | Dark | Use |
|---|---|---|---|
| bg | #F0F3F1 | #1E2522 | toolbars, rails, haze |
| surface | #FAFCFB | #242C2A | opaque windows |
| surface-field | #E8EEEB | #303B37 | wells, keycaps |
| panel | #FAFCFB @66% | #242C2A @58% | frosted floating panels |
| border | #D5DEDB | #46534D | all hairlines |
| ink | #202D29 | #F1F4F2 | primary text |
| ink-secondary | #596B64 | #B6C5BD | every readable label |
| ink-tertiary | #596B64 @60% | #B6C5BD @55% | placeholders only |
| accent | #1672DF | #69A8FF | interaction |
| accent-ink | #165EB8 | #91BFFF | accent text on soft fill |
| accent-soft | accent @7% | accent @9% | selection |
| accent-ring | accent @14% | accent @20% | focus halo |
| on-accent | #FFFFFF | #122335 | text on solid accent |
| identity-coral / teal / magenta | #AF553D / #247B69 / #9D4286 | #EDAC95 / #83CDB5 / #E4A0CB | QC section identity |
| status-error / warning / success | #BA503C / #956018 / #3D6C4B | #F09C86 / #E5B95B / #A4D2B0 | status, priority orbs |
| warning-fill | #FCF2DF | #373025 | conflict banners |

Rules: accent = interaction; identity hues = section (QC only); neutral = ground. Three ink levels, no more. Status colours always paired with a label or SF Symbol.

## Type, spacing, radius

- System fonts only: SF Pro for chrome, SF Mono for content and key notation. IBM Plex bundled in both repos is retired — remove from targets.
- Scale: title 22/600 (-0.3), heading 16/600, body 13, label 12/500, caption 11, caption-upper 11/600 +0.8 (QC sections only), status 11/600 +0.5, input-lg 16, input-md 14, mono-body 13, mono-code 12, key 11/500.
- Spacing: 6 / 10 / 16 / 22 (unchanged in both apps).
- Radius: panel 16, window 12, field 8, chip 6 (HA changes: window 14→12, field 6→8, chip 5→6).

## What changes in each app

- **Hyper Active:** swap `Theme.light/.dark` to the palette above (accent iris → blue; warm ivory → cool Clear neutrals); `h1` 21→22; radii per above. Everything else (layout, structure, keyboard reference) stays.
- **Quick Capture:** `Theme` moves from system-blue-on-grey to Clear/Charcoal (accent #007AFF → #1672DF, surfaces take the faint green cast); `TagPalette` first three entries become the identity hues, the other four (green, blue, amber, indigo) need re-tuning to the same muted saturation; priority orbs move from system red/orange/green to status-error / priority-medium / status-success.

## Open items

- Re-tune the remaining four TagPalette hues.
- `borderStrong` (HA keycap edges) has no unified value yet — use `border` for now.
- Verify the Clear accent (#1672DF, 4.5:1 on surface) in a real build; it is at the AA floor.

## Quick Capture implementation (10 October 2026)

The selected designs are implemented on `codex/unified-design`. The primary mockup source remains on `prototype/screen-directions` at `a517bac`; throwaway mockups are not bundled into the app.

Capture keeps its existing geometry and uses the specified frosted wash without the extra top-edge gradient. Screenshot selection keeps its list/preview layout and now has explicit Cancel/Attach actions. Settings uses the shared opaque surface and grouped rows. The inbox has section navigation, the live markdown editor, and a cursor-driven item inspector; section navigation scrolls to headings without hiding or rewriting document content.

The remaining identity hues are now muted green `#527346 / #B0CEA0`, blue `#486D91 / #A1BFDF`, amber `#90651F / #DEC187`, and indigo `#69608E / #BEB2DE`. Persisted hue assignments remain unchanged. Warning is used for medium priority. Legacy IBM Plex resources and runtime registration are removed from the target.

Native contrast checks pass for secondary text, accent-button text, and accent text on selection. The specified dark placeholder reaches 3.56:1 on the modelled panel, so the prior below-3:1 test now checks that placeholders remain below normal-text AA (4.5:1). Manual material/appearance review is still pending because the UI connection was unavailable.

Validation: 198 native tests (including WebKit navigation, inspector, native action, and non-overlapping column checks), 9 editor persistence tests, TypeScript checking, and the bundled editor build passed.
