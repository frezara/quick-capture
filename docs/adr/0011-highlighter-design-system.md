# Adopt the Highlighter design system

Status: Accepted (17 October 2026). Amends ADR-0005 and ADR-0006; replaces the
Clear & Charcoal system in `design-system-overview.md` for Quick Capture.

Quick Capture's look is now direction B, "Highlighter", chosen from two fresh
directions mocked across every screen. The spec and the source of truth for
`DesignSystem.swift` and the editor palette is `design/highlighter/THEME.md`;
the mockups are on the design canvas linked from it.

## Decision

- **Colour keeps ADR-0005's jobs and adds one.** Section hue is identity,
  the accent is interaction and neutral is the ground, exactly as before. The
  accent is now carbon indigo (`#2B3FA0` / `#9AAAFF`) instead of system blue.
  The new fourth job is the **highlighter** (`#FFE45C` / `#F0D44A`), which
  means "now": today's date, the now-line, the current time, and in the editor
  the line you are on and vim's INSERT mode. It is never decoration and never
  carries text other than `ink`.
- **The ink ramp keeps ADR-0006's three levels** (`ink`, `ink2` for every
  readable label, `ink3` for placeholders and disabled only), now as solid
  colours rather than opacities of one ink.
- **One typeface, bundled:** Recursive (SIL OFL), linear only. Its MONO axis
  gives the mono setting for note text and key notation, so the app no longer
  mixes SF Pro and SF Mono. The casual axis was tried and rejected as not
  serious enough.
- **The editor follows the app.** It reads the same tokens and the same
  bundled font rather than keeping its own palette.

## Consequences

- Highlighter yellow must stay rare to keep meaning "now". The editor's cursor
  band is a faint wash for that reason; anything more than a few words on full
  yellow breaks the rule.
- `design-system-overview.md` was shared with Hyper Active. It stays as the
  record of Clear & Charcoal, marked superseded for Quick Capture; whether
  Hyper Active follows is a separate decision.
- Views still on the old layout (Todos, Projects, Notes, Saved links, Settings)
  already use the new tokens and font; their layouts are redesigned one at a
  time against `THEME.md`.
