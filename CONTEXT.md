# Context

Domain vocabulary and the project's language for Quick Capture. Engineering
skills read this before exploring; output that names a domain concept should
use the term **as defined here** rather than drifting to a synonym.

For the architecture tour and build instructions, see `CLAUDE.md`. For the
decisions behind the non-obvious bits, see `docs/adr/`.

## What the app is

Quick Capture is a personal macOS menu bar app (`LSUIElement`, no permanent
dock icon). A single floating `NSPanel` shows one of two mutually-exclusive
surfaces — a small **capture box** or a full markdown **editor** — and ⌥⌘I
crossfades between them.

## Glossary

- **Capture file** — the single user-chosen markdown file every capture is
  appended to. There is always exactly one, and the editor always opens it — it
  is **the active inbox**. Its first line is always `# Inbox`. Refile writes to
  *other* inboxes (see **Target inbox**) but never changes which file is the
  capture file.

- **Inbox** — an `# Inbox`-headed markdown file that items live under. **No
  longer unique**: the capture file is the active inbox the editor opens; refile
  targets each hold their own inbox the app writes to but never opens. The H1 is
  mandatory and `FileWriter.appendTodo` enforces it.

- **Section** — an `## H2` heading under which items live. Tag values become
  section names verbatim.

- **Quick capture** — the `## Quick capture` section: the catch-all where
  untagged items land. Use this exact phrase for the catch-all; don't call it
  "default section" or "uncategorized".

- **Tag routing** — typing `#tag` in capture routes the entry under the
  matching `## tag` section (created if absent). See `[[tag_routing_decisions]]`
  in agent memory for the resolved rules.

- **Item / todo** — a single `- [ ] <text>` (or `- [x]`) line. "Item" and
  "todo" are interchangeable; prefer **item**.

- **Capture box** — the small, content-sized, centered quick-capture surface
  summoned by the global hotkey (default `⌥⌘P`). Self-dismisses on click-away.
  Laid out in three bands: the inputs row, the **preview band**, and the
  **hint bar**.

- **Hint bar** — the persistent bottom bar in capture mode. Always visible (it
  does not collapse on focus changes), it shows shortcut-hint **chips** whose
  labels are sourced from `ShortcutRegistry` so they track rebinds — currently
  Editor (`⌥⌘I`) and Screenshots (`⌥⌘O`). The capture-mode counterpart to the
  editor's bottom status bar. Do not call it the "footer".

- **Preview band** — the middle band between the inputs row and the hint bar.
  Shows attached screenshots as a larger, scannable, horizontally-scrolling
  strip, or — in `#cal` mode — the calendar preview. Absent when there is
  nothing to show (no screenshots, not in `#cal` mode).

- **Capture mode** — the state showing the capture box and nothing else. One of
  two mutually-exclusive modes (see **editor mode**).

- **Editor mode** — the state showing the full-screen editor and nothing else.
  Reached via `⌥⌘I`; `⌥⌘I` returns to capture mode (`⌘F` is native find inside
  the editor — see epic #53). Survives loss of
  focus. Capturing and editing are mutually exclusive — only one surface is
  ever on screen (see ADR-0004).

- **Editor** — the markdown editing surface (CodeMirror 6 in a `WKWebView`,
  Obsidian-style live preview), shown full-screen in editor mode. The capture
  file on disk is always canonical: the editor reads it on entry and autosaves
  back to it (see ADR-0004).

- **MainPanel** — the one `NSPanel` that hosts both surfaces (kept warm) and
  drives the capture↔editor mode switch (a crossfade). There is never more than
  one.

- **Live preview** — the editor's rendering of markdown in place: checkbox
  widgets, hidden syntax marks when the cursor is off the line, indent guides,
  priority dots. Modeled on Obsidian.

- **Priority bucket** — the sort/insert class of an item, 0–4. Trailing
  markers set it; see `[[#priority-markers]]` below and ADR-0002. Lower number
  = higher priority.

- **Priority marker** — trailing `!` / `!!` / `!!!` on an item's text →
  buckets 2 / 1 / 0. No marker → bucket 3. A checked `[x]` item → bucket 4.

- **Child item** — an item indented under another by **2+ spaces or a tab**.
  Single-space indent is NOT a child. (`/^( {2,}|\t)\S/`.)

- **Archive** — moving every `- [x]` line to a sibling `<name>_archive.<ext>`
  file, preserving the source's sections. Indented checked items are
  flattened to top level in the archive.

- **Re-org / sweep** (`⌘'`) — moves checked items to the bottom of their
  section, sorts unchecked items by priority bucket, and strips priority
  markers off checked items. "Re-org" and "sweep" are the same gesture.

- **Refile** — a gesture (editor mode) that moves the item under the cursor —
  its whole **subtree** (the item, its attachment lines, and any nested
  sub-items) — out of the current file into a chosen **refile target**, removing
  it from the source. Modeled on Emacs org-mode refile. Distinct from archive
  (which moves only checked items, and only within a sibling `_archive` file).

- **Refile target** — a user-configured destination **folder** (set in
  Settings). The capture file's own folder is never offered as a target.

- **Target inbox** — the `inbox.md` inside a refile target (filename is always
  literally `inbox.md`). A plain `# Inbox` file with **no fixed sections**:
  refiled subtrees are appended at **top level**, in arrival order, directly
  under the `# Inbox` H1 (their content — nested items, image lines — travels
  with them). Created with a bare `# Inbox` scaffold if missing. The app writes
  to it on refile but never opens it.

- **`#cal`** — a capture prefix that re-interprets the input as a
  natural-language calendar event and opens a generated `.ics`.

## Language to avoid

- Don't say "window" for the panel — it's the **MainPanel** / **the panel**.
- Don't say "note" for an item — it's an **item** / **todo**.
- Don't say "tab" or "view" for the two surfaces — they are **capture mode**
  and **editor mode**, two mutually-exclusive modes of the one panel.
- Don't say "input strip" / "input-only" / "split" — that was the superseded
  ADR-0003 model (persistent input with the editor beneath). The current model
  is mutually-exclusive modes (ADR-0004).
- Don't say "footer" for the capture-mode bottom bar — it's the **hint bar**
  (always-on, not the old collapse-on-blur footer).
