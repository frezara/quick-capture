# Highlighter: theme spec

Handover spec for the "Highlighter" direction (B) chosen on 2026-10-17.
Mockups: https://claude.ai/artifact/UXY1n9PSTqAjarCRuHWqFz (theme board and
"B, round 2" row). This file is the source of truth for `DesignSystem.swift`;
the mockups illustrate it.

Status: **approved 2026-10-17** (theme, dark palette, calendar teal, frosted capture panel). Replaces Clear & Charcoal, so ADR-0005 (colour
semantics) and ADR-0006 (three-level ink ramp) need superseding ADRs and
`design-system-overview.md` needs rewriting once this is approved.

## Rules

1. **Carbon is interaction.** Buttons, selection, focus, the current page,
   links. Nothing else is carbon.
2. **Highlighter is "now".** Today's date, the now-line, the current time.
   Never decoration, never in the capture box, never behind more than a few
   words. Text on highlighter is always `ink` (light) / `inkOnHighlight` (dark).
3. **Section hues are identity.** A section's hue marks its name wherever the
   section appears (tag dropdown dot, tag field tint, section labels, events).
   Allocation is unchanged (`TagHueAssignment`); only the palette values change.
4. **Three ink levels.** `ink` for content, `ink2` for every readable label,
   `ink3` for placeholders and disabled only (it is below 4.5:1 on purpose).
5. **Status colour always comes with a symbol or a word.**

## Colour

All text pairs below were checked for WCAG contrast against `surface`,
`rail` and `field`; every text token clears 4.5:1 in both modes except `ink3`
(3.1–3.8:1, placeholder only).

### Grounds

| Token | Light | Dark | Use |
|---|---|---|---|
| `surface` | `#F8F9FB` | `#1B2132` | windows, capture panel, the main page |
| `rail` | `#EDEFF4` | `#151A28` | side rail, toolbars |
| `sunken` | `#F2F4F8` | `#171C2D` | secondary panes (agenda, project list) |
| `field` | `#EEF0F5` | `#242B40` | input wells, preview wells |
| `keycap` | `#E2E5EE` | `#2C3450` | key notation, segmented-control track |
| `border` | `#D6DAE5` | `#343D58` | window and pane edges, card outlines |
| `hairline` | `#E2E5EE` | `#283049` | row and grid separators |

### Ink

| Token | Light | Dark | Use |
|---|---|---|---|
| `ink` | `#1C2233` | `#E9ECF5` | primary text, icons that act |
| `ink2` | `#545C72` | `#A9B0C6` | labels, meta, hints, times |
| `ink3` | `#80879C` | `#7C849C` | placeholders, disabled, other-month dates |

### Interaction and "now"

| Token | Light | Dark | Use |
|---|---|---|---|
| `accent` (carbon) | `#2B3FA0` | `#9AAAFF` | primary buttons, current page, links, selection text |
| `onAccent` | `#FFFFFF` | `#10162A` | text on a solid `accent` fill |
| `accentSoft` | `accent` @ 8% | `accent` @ 14% | selected row / current rail item fill |
| `accentRing` | `accent` @ 28% | `accent` @ 40% | 3pt focus halo |
| `highlight` | `#FFE45C` | `#F0D44A` | today, now-line, current time |
| `inkOnHighlight` | `#1C2233` | `#1C2233` | text on `highlight`, both modes |

### Section hues (identity)

Seven slots, in `TagPalette` order. Assignments persist as slot indices, so
each slot kept its old family (coral→rust, magenta→plum, blue→slate,
amber→ochre, indigo→violet) and existing sections keep a recognisable colour.
`tint` is the hue at 12% (light) / 18% (dark), for the tag field fill and
event blocks.

| Slot | Was | Light | Dark |
|---|---|---|---|
| 0 rust | coral | `#A1452B` | `#F2A88B` |
| 1 teal | teal | `#1F6F74` | `#8AD2D5` |
| 2 plum | magenta | `#8A3B5C` | `#E7A3C1` |
| 3 green | green | `#3B7337` | `#A1CF95` |
| 4 slate | blue | `#3F5F86` | `#A9C1E0` |
| 5 ochre | amber | `#94561C` | `#E6B37E` |
| 6 violet | indigo | `#6650A0` | `#C6B8F0` |

**Calendar teal.** The `cal` command has no section, so it borrows slot 1's
teal (`TagPalette.calendar`) everywhere the calendar shows: the tag field, the
dropdown glyph and the event card. Accent stays interaction-only.

### Status

| Token | Light | Dark | Fill (light / dark) |
|---|---|---|---|
| `error` | `#B03A2A` | `#F4A393` | `#FBE9E5` / `#3A2226` |
| `warning` | `#8A5F12` | `#EBC77A` | `#FDF3D7` / `#3A321C` |
| `success` | `#2F6B3E` | `#A2D6AC` | `#E6F2E8` / `#1F3328` |

Priority marks reuse status: `!!!` error, `!!` warning, `!` ink2.

## Type

One family: **Recursive** (SIL OFL 1.1), bundled as the variable font
`Recursive_VF.ttf`, so the axes in the mockups are reproduced exactly. SwiftUI
can't set custom axes directly; `Typeface` builds a `CTFontDescriptor` with
`kCTFontVariationAttribute` (`wght`, `CASL`, `MONO`) and wraps it in `Font`.
Fallback if the variable font misbehaves: the static instances (Sans Linear,
Mono Linear).

Axes used: `CASL` 0 (linear) for everything, headings included. The casual
style was tried for display and titles and rejected (2026-10-17): it read as
playful. `MONO` 1 for times, paths, key notation and `#tags` as typed.

| Style | Size / line | Weight | Axes | Tracking | Use |
|---|---|---|---|---|---|
| `display` | 40 / 44 | 750 | — | −0.6 | Today's date heading |
| `title` | 30 / 36 | 750 | — | −0.5 | page titles |
| `heading` | 20 / 26 | 700 | — | 0 | pane headings (agenda day) |
| `input` | 18 / 26 | 400 | — | 0 | capture input, settings sentences |
| `bodyLarge` | 14.5 / 20 | 400 | — | 0 | list rows (todos, project items) |
| `body` | 13 / 18 | 400 | — | 0 | general UI text |
| `label` | 13 / 18 | 700 | — | 0 | group labels ("Do first", "Schedule") |
| `meta` | 12 / 16 | 400 | — | 0 | meta, hints, footers |
| `caption` | 10.5 / 13 | 500 | — | 0 | rail labels |
| `mono` | 12.5 / 16 | 400 | MONO 1 | 0 | times, paths |
| `key` | 11 / 14 | 500 | MONO 1 | 0 | key notation |

Sentence case everywhere. No all-caps labels, no letter-spaced captions.
Line heights are targets; SwiftUI applies them as `lineSpacing` = line − the
font's natural height, so expect ±1pt.

## Space, shape, depth

- **Spacing scale:** 4, 8, 12, 16, 24, 32, 40. Window content insets are 40
  horizontal, 30 top.
- **Radii:** key 4, row 8, control 8, well 10, panel 16, window 12.
- **Depth:** one shadow, only for floating surfaces (capture panel, tag
  dropdown): `0 20 48` at 25% of `#141A30` (light) / 50% of `#000000` (dark).
  Everything else is flat, separated by `border` or `hairline`.
- **Hairlines** are 1px at the display scale (`1 / displayScale`), never a
  fractional point.

## Components

- **Primary button:** `accent` fill, `onAccent` text, `body` 600, radius 8,
  padding 7×14. One per surface.
- **Secondary button:** `surface` fill, `border` 1px, `ink` text, same metrics.
- **Field well:** `field` fill, radius 8, padding 13×15; focused: `accentRing`
  halo. A field routed to a section takes that section's `tint` fill and hue text.
- **Key notation:** `key` style, `keycap` fill, `ink` text, radius 4, padding 1×5.
- **Checkbox:** 16pt circle, 1.5pt `ink3` stroke; first-priority items use an
  `accent` stroke; done = filled with the section hue and a check.
- **Selected row:** `accentSoft` fill, radius 8. No left bars.

## Capture box (implemented)

- Frosted panel: behind-window blur under `surface` at 80% (light) / 74%
  (dark), radius 16, `border` hairline.
- Input: plain text on the panel, no well, `input` 18. An empty submit shakes
  it and flashes the placeholder in `error`.
- Tag field: 180 wide well. Focused and unrouted: `accentRing` halo, `#` in
  accent. Routed to a section or `cal`: that hue's tint, text and hairline.
- Tag dropdown: unchanged behaviour; `cal` glyph in calendar teal, highlighted
  row semibold `accent` on `accentSoft`, unknown tags a `border` dot.
- `#cal` card: `field` well, radius 10, padding 12×14; calendar glyph and
  "Event" in teal; parsed title `body` 14 semibold; "Saturday 17 October,
  14:00 to 14:30" in `ink2`. No edit button.
- Footer: Enter and where it files the capture (calendar / section in its
  hue / new section / Quick capture) on the left; registry hints on the right.
- Capture font setting: "Recursive" (sans) and "Recursive Mono" replace System
  and SF Mono; Rounded and Serif stay on the system designs.

## Workspace rail (implemented)

64pt icon-only rail on `rail`, no window buttons. Capture (accent) at the
top, a hairline, then Calendar, Projects, Todos, Notes, Saved links; Editor at
the bottom. Each icon's tooltip and VoiceOver label give its name and
shortcut. Current page: `accentSoft` well, `accent` icon.

## Calendar (implemented)

- Toolbar: title (`title` 30; the year in `ink3`), week range or a `Today`
  tag; Day / Week / Month switcher showing D W M (selected: `accent`
  semibold on `surface`); ‹ Today ›; **New event** (primary). Wraps to two
  rows rather than truncating when the day view's side panel squeezes it.
- Highlight = now: today's date number, the 2pt now-line (`nowLine`,
  `#E8C21E` light, deeper than `now` so it reads on white) and its time pill in
  the hour gutter; today's week column carries `now` at 7% (4% dark).
- Accent = selection: the selected day (2pt inset ring in month, underline in
  week), the selected event (ring), the current view, New event.
- Events wear their section's hue (`TagHueAssignment`), falling back to the
  calendar teal: timed = hue dot (month) or tinted block (week/day); all-day
  = tinted bar with hue text.
- Side panel (`sunken`): month lists the selected day; day shows the selected
  event (section, title, when, note, Open in editor, Done); week has none.

### Keyboard

| Key | Month | Week | Day |
|---|---|---|---|
| D W M | switch view | switch view | switch view |
| ← → | day | day | day |
| ↑ ↓ | week | previous/next event | previous/next event |
| Enter | open the day | open the day | open the event in the editor |
| T, ⌘T | today | today | today |
| N | new event (capture opens on `cal`) | same | same |
| Esc | let go of the event, then close | same | same |
| ⌘← ⌘→ | page | page | page |

The table is `CalendarLayout.command`; `MainPanel` routes keys to it unless a
text field is being edited.

## States still to design

Per view, as each one comes up: hover, pressed, focus, disabled; empty and
error states; long-content truncation; motion.
