# ADR-0004: Revert to mutually-exclusive capture and editor modes

Status: Accepted — supersedes ADR-0003, restores ADR-0001's mutual-exclusion premise

## Context

ADR-0003 made the capture **input strip** persistent and opened the editor
*beneath* it (a "split"), so you could capture while editing. In practice this
is confusing: two surfaces compete for attention, and the persistent input bar
pinned above the editor reads as clutter. The capture-while-editing capability
it bought is also largely redundant — in the editor you can just type an item
into the right section directly, because the editor *is* the file.

So we revert to ADR-0001's model: one surface on screen at a time.

## Decision

1. **Mutually-exclusive modes.** Two modes of the one `MainPanel`: **capture
   mode** (the capture box, ≈600 wide, content-height, centered) and **editor
   mode** (the full editor, ≈1000 wide, full height). `⌘F` switches between
   them with a **crossfade + frame animation**; both surfaces stay mounted and
   the web view stays warm. There is no persistent input strip and no split.
   The editor is headerless — its status bar carries the filename, and `⌘W`
   dismisses — so it needs no title bar.

2. **Disk is always canonical.** Reverts ADR-0003's single-writer /
   in-memory-buffer model. Capture mode writes items straight to disk
   (`FileWriter.appendTodo` / `insert`); editor mode reads the file on entry and
   autosaves back to it. The `insertCapture` buffer-splice path and its JS
   bridge call are removed.

3. **Flush on exit.** Leaving editor mode flushes the editor's pending
   (debounced) autosave so disk is current before capture mode can write. With
   mutual exclusion there is no concurrent typing to race against, so a single
   flush-before-switch is sufficient — no handshake.

4. **Dismiss.** `⌘W` dismisses directly from **either** mode (the editor no
   longer requires `⌘F`-then-`Esc`). `Esc` dismisses in capture mode, and in
   editor mode **when vim is off**; when vim is on, `Esc` belongs to vim and
   `⌘W` is the dismiss. Dismissing flushes the editor save and clears any
   preserved capture text.

5. **State preservation (carried forward).** Typed-but-unsaved capture text
   survives a `⌘F` round-trip and is cleared only on full dismiss. The editor
   stays warm (cursor/scroll preserved). `⌥T` always lands in capture mode;
   the menu-bar "Open Editor…" enters editor mode.

## Considered alternatives

- **Keep the split but hide the input strip in editor mode.** Cosmetic only —
  leaves the buffer-canonical concurrency machinery as dead weight and the model
  muddy. Rejected.
- **A transient one-line capture overlay invoked from the editor.** Preserves a
  capture-while-editing affordance, but re-introduces the exact concurrency
  problem ADR-0003 had to solve, for a workflow the editor already covers (type
  directly). Rejected.

## Consequences

- The riskiest code in the app — the in-memory-buffer-canonical model, the
  targeted `insertCapture` transaction, and its Swift→JS insert bridge — is
  deleted. One writer at all times, by exclusion.
- Reopening the editor reloads from disk if the file changed while it was hidden
  (a capture made in capture mode); the cursor resets on such an external
  reload, which is acceptable for mutually-exclusive modes.
- ADR-0001's mutual-exclusion mechanics (the `⌘F` window intercept, mode-aware
  dismiss, `.regular`↔`.accessory` activation swap, `canBecomeMain` only in
  editor mode) are restored, now extended by `⌘W` direct-dismiss and vim-aware
  `Esc`.
- `CLAUDE.md` and the code on `feat/persistent-input-split` (the
  `SplitContainerView`, the fused-panel "join", the persistent-strip layout)
  need rewinding to the mode model. The Misted-Steel redesign, vim toggle,
  focus fix, and dark mode are unaffected.

## Update (2026-06, epic #53)

The switch gesture moved from `⌘F` to `⌃⌘E`, refile from `⌘R` to `⌃⌘R`, and
`⌘F` became native find inside the editor (CodeMirror search panel). `⌘R` is
still window-intercepted in editor mode, now as a deliberate no-op — WebKit
would otherwise reload the warm editor. The mutual-exclusion mechanics this
ADR restores are unchanged; bindings live in `ShortcutRegistry.swift`. Where
this document says `⌘F`, read the registry's `toggleEditor` chord.
