# ADR-0006: The ink ramp has three levels

Status: Accepted

## Context

Fixing the frosted panel's hint text (#106) added a fourth ink level,
`inkHint`, so that always-on labels could clear AA without dragging
placeholders up with them. That left the light-mode ramp non-monotonic —
`inkHint` at 0.73 above `inkSecondary` at 0.62 — and left every secondary
label still short of AA (3.33–3.52:1).

The obvious repair was to raise `inkSecondary` too. But light mode needs
0.75 to clear AA, and `inkHint` was 0.73: at the bar, the two levels are the
same colour. The ramp had one level too many.

Three shapes were rendered on the real surfaces
(`design/ink-ramp/`, issue #111).

## Decision

Three levels, in both appearances:

| token | light | dark | carries |
|-------|-------|------|---------|
| `ink` | 0.88 | 0.92 | primary text |
| `inkSecondary` | **0.75** | 0.60 | every readable label |
| `inkTertiary` | 0.36 | 0.32 | placeholders only |

`inkHint` is removed; everything on it moves to `inkSecondary`.

The reason is not that this is the option that clears AA — the four-level
alternative does too, for labels. It is that **the hint/secondary split never
described a real tier.** `⌥⌘I` sat on `inkSecondary` while the word "Editor"
beside it sat on `inkHint`: one element, a keycap and its label, split across
two ink levels — with the operative half the fainter of the two. That split
was an artefact of fixing #106 one token at a time, not a hierarchy anyone
designed. Collapsing it removes a distinction that mapped to nothing.

Where a genuine sub-hierarchy exists — the picker's day line beneath its time,
the status counts beside the filename — it is already carried by size, weight
and position (11px semibold against 12px regular). It does not need an opacity
level as well.

**0.75, not 0.74.** The binding surface is the keycap *chip*, not the frosted
panel: the chip's own fill darkens what sits behind the glyph. 0.74 clears the
panel at 4.83:1 and fails the chip at 4.48:1.

**Dark is unchanged.** It already cleared AA everywhere (4.73–5.76:1) and its
ramp was already monotonic. The inversion was light-only, so the fix is too.

## Considered and rejected

- **Four levels, re-ordered** (`inkSecondary` 0.75, `inkHint` below it). Keeps
  a weight distinction between a label and a hint, and pays for it by pushing
  hints back to 3.52:1 — reverting #106 days after it shipped. It trades a
  correctness property for an aesthetic one, and the aesthetic one is the split
  above, which isn't real.
- **Leave `inkSecondary` at 0.62.** The status quo: secondary text fails AA on
  every surface it lands on, and the ramp reads out of order.

## Consequences

- Keycap glyphs, picker times and dropdown rows get visibly darker in light
  mode, and the hint bar has been always-on since #93 — so the capture box
  gains some weight at rest, which is the opposite of what a quick-capture box
  wants. If that reads as heavy, the fix is a lighter keycap chip or smaller
  glyphs, **not** a fourth ink level.
- `palette.soft` in the editor rises with it, which also darkens blockquotes
  and strikethrough. Both are text meant to be read, so this is an improvement
  rather than a cost; markdown syntax marks stay on `muted` and keep receding.
- `ThemeContrastTests` now asserts the floor on all three backgrounds and pins
  the ramp's ordering, so a future contrast pass can't reintroduce an inversion.
- Contrast on the frosted panel still depends on what is behind the window
  (#112). This decision does not address that and is not blocked by it.
