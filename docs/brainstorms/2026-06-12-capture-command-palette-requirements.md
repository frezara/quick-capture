---
title: "Capture command palette"
date: 2026-06-12
issue: 82
status: removed
---

> ⚠️ **Removed (2026-06-12).** The capture command palette (this entire feature —
> ⌥⌘O overlay, search/jump, jump-to-tag, Commands, ⌘K per-item actions, and the
> recency token that fed it) was removed from the app at the user's request. The
> Swift surfaces (`PaletteView`, `PaletteViewModel`, `CaptureItemParser`), the
> `.openPalette` shortcut, and the `FileWriter` recency/per-item helpers are all
> gone; ⌥⌘O is unbound. This document is kept as a historical record of what was
> built and why.

# Capture command palette — requirements

## Summary

A global, in-app **command palette** for Quick Capture: a transient overlay with a
single search field over **captures and commands**. Live-filter your captured items
and press Enter (or click) to jump straight to that item in the editor; plus jump-to-tag,
new-capture, typeable global commands, and a per-item actions menu. It is a "go to / do"
tool that sits alongside — not in place of — the existing `⌥⌘P` capture box.

Origin: issue #82. Mockup: `attachments/screenshot-2026-06-12-123206.png`.

---

## Problem Frame

Today, to revisit or act on a past capture you open the editor (`⌥⌘E` / menu) and hunt
for the item by scrolling or `⌘F`. There is no fast "find this capture and take me to it"
path, and no quick launcher for the app's actions. The palette collapses "find an item or
run a command" into one keystroke and one search field.

The user is the sole user (personal app); the value is their own speed of navigating and
acting on a growing capture file.

---

## Goals

- Find any capture by typing, and jump to it in the editor in one action.
- Reach the app's common actions (open editor, archive, re-organize, refile, settings,
  new capture) without menus.
- Jump to a tag's section quickly.
- Keep the instant `⌥⌘P` capture path unchanged.

## Non-goals (v1)

- The palette is **not** the app's front door — `⌥⌘P` still opens the capture box directly.
- No fuzzy matching in v1 (substring only).
- No command-prefix syntax (e.g. `>` for commands).
- No cross-device sync of recency.

---

## Key Flows

- **F1 — Find & jump.** Summon palette → type → the *Recent captures* list live-filters
  (substring, case-insensitive) → Enter/click a result → editor opens (or comes forward)
  scrolled to that item's line with the cursor on it. Esc closes, changing nothing.
- **F2 — Jump to tag.** A *Jump to tag* section lists each tag and its item count →
  selecting it opens the editor on that `## section` heading.
- **F3 — New capture.** A *New capture* entry (`⌘N`) drops into the standard capture box.
- **F4 — Global command.** Typing matches app commands alongside captures (Open Editor,
  Archive completed, Re-organize, Refile, Settings) → selecting runs it.
- **F5 — Per-item actions.** With an item highlighted, `⌘K` opens an actions menu:
  mark done/undone, delete, refile, copy text. Acting returns to the document state.

---

## Requirements

### Surface & summon
- **R1.** The palette is a **transient floating overlay** summoned over whatever surface
  is showing, dismissed by Esc. It is not a persistent mode — it does not violate ADR-0004's
  capture↔editor mutual exclusion (it behaves like the tag dropdown / screenshot picker:
  a transient surface, not a mode).
- **R2.** Summoned by a dedicated global `⌥⌘` chord (registered in `ShortcutRegistry`).
  `⌥⌘O` is the working candidate; final chord chosen at planning.
- **R3.** `⌥⌘P` and the capture box are unchanged — capture stays one instant keystroke.

### Search & results
- **R4.** A single search field filters **captures and commands** together. Results are
  grouped into labeled sections: *Recent captures*, *Jump to tag*, *Commands*.
- **R5.** Matching is **substring, case-insensitive** over item text and command names.
- **R6.** Each capture row shows: priority dot (matching the editor's priority buckets),
  the item text, and its tag (the `## section` it lives under).
- **R7.** Empty state (no query) shows *Recent captures* newest-first (see Recency), the
  *Jump to tag* list, and available commands.

### Navigation
- **R8.** Selecting a capture brings the editor forward (entering editor mode if needed)
  and scrolls to that item's line with the cursor placed on it (reuses the editor's
  `scrollIntoView`). Selecting a tag jumps to its `## section` (reuses `jumpToSection`).

### Recency
> ⚠️ **Superseded (2026-06-12, #90).** The Recency feature (R9 + R10) was removed: the
> "Recent captures" list and the hidden `<!--qc:…-->` creation token are gone. New captures
> write clean prose; the palette surfaces captures by typing a query (no all-items browse
> list). Legacy tokens on existing lines are still tolerated/hidden for back-compat. R9/R10
> below are kept as historical record.

- **R9.** Every new capture records a **creation time that is never displayed**, stored as
  an inline hidden token on the item line (an HTML comment), hidden by the editor's live
  preview and by Obsidian's reading view. The markdown file remains the single source of
  truth — no sidecar, no drift.
- **R10.** The *Recent captures* list sorts by this token, newest first. Items without a
  token (captured before this feature, or edited in by hand) fall back to file order / sort
  last. The token must survive the operations that move or copy item lines (insert, archive,
  refile, re-organize) and must not break priority-bucket classification — the same
  tolerance the parser already grants the `➕` marker.

### Commands & actions
- **R11.** v1 global commands: Open Editor, Archive completed, Re-organize, Refile,
  Settings, New capture. Each reuses its existing implementation.
- **R12.** v1 per-item actions (`⌘K`): mark done/undone (checkbox toggle), delete (remove
  the item's subtree), refile (the existing `⌥⌘R` pipeline), copy text. Reuse existing
  flows where they exist.

---

## Scope Boundaries

**In scope (v1):** the overlay + summon chord; search over captures + commands; recent
ordering via the hidden token; jump-to-item and jump-to-tag; new-capture; the six global
commands; the five per-item actions; priority dot + tag per row.

### Deferred to follow-up
- Fuzzy / typo-tolerant matching.
- Command-prefix syntax (`>`), and searching tags/section text as query targets (beyond the
  dedicated Jump-to-tag section).
- "Recent" reflecting last-*edited* or last-*jumped-to*, not just created.
- Recency for items captured outside the app / on other devices.

---

## Open Questions (non-blocking; resolve in planning)

- The exact summon chord (candidate `⌥⌘O`) — confirm against the `⌥⌘` namespace and macOS
  reserved combos.
- Exact hidden-token format and how each line-moving operation (insert / archive / refile /
  re-organize) preserves it.
- Whether the palette is summonable globally (system-wide, like `⌥⌘P`) or only when the app
  is already active — default assumption: global, matching `⌥⌘P`.
- How commands rank against captures when both match a query (ordering within the merged
  result set).

---

## Dependencies / Assumptions

- Reuses editor navigation primitives (`scrollIntoView`, `jumpToSection`) and the
  `ShortcutRegistry` summon/keymap pattern.
- Reuses existing action implementations (refile pipeline, archive, re-organize, checkbox
  toggle, settings, capture box).
- `TagDropdownPanel` (a floating borderless child window) is a viable host precedent for the
  overlay; final hosting decided in planning.
- Assumes the capture file stays the single source of truth (ADR-0004); the hidden token
  upholds this by living in the file rather than a sidecar.
