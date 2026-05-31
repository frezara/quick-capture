# ADR-0003: Persistent capture input, editor opens beneath it

Status: Superseded by ADR-0004

> **Superseded (ADR-0004):** the persistent input strip + editor-beneath
> ("split") model below was reverted. The capture box and editor are again
> **mutually-exclusive modes**, and the single-writer / in-memory-buffer model
> (Decision §2–§3) is gone — the file on disk is canonical. Kept for the record
> and for the concurrency analysis, which is why ADR-0004 doesn't need to
> re-derive it.

## Context

ADR-0001 made capture and editor two **mutually-exclusive modes** of one panel
that crossfade: only one is ever visible. We want the opposite — to keep
capturing *while* the editor is open, so the capture **input strip** stays
pinned to the top and the **editor opens beneath it** (a "split"). The input
is always present; `⌘F` toggles the editor open/closed under it.

This breaks ADR-0001's load-bearing invariant: because the two modes never ran
at once, there was only ever **one writer** to the capture file. With both
surfaces live, a capture write and the editor's 400ms debounced autosave race
on the same file — either the capture is lost (editor's pending save overwrites
it) or the in-flight edit is clobbered (the capture's atomic write trips the
file watcher and reloads the editor). In model A this is the main flow, not an
edge case.

## Decision

1. **Layout.** The input strip is a persistent top bar; the editor opens
   beneath it. Two states: **input-only** (collapsed, `600` wide, capture-grade
   behavior) and **split** (`900` wide, input strip on top + editor below,
   editor-grade behavior). The crossfade is gone.

2. **Single writer.** While the editor is open, **its in-memory buffer is the
   canonical copy** of the capture file. A capture submitted from the input is
   *not* written to disk directly — it runs the existing pure
   `FileWriter.insert` (tag routing + priority insert) over the editor's current
   buffer and the result is applied to the editor, which persists it via its
   normal autosave. When the editor is **closed** (input-only), capture writes
   to the file directly, exactly as before. There is one writer at all times.

3. **Non-destructive insert.** The capture-insert is applied as a **targeted
   CodeMirror transaction** (compute text + offset, dispatch an insert at that
   position), not a full `setContent` replace — so cursor, scroll, and undo
   history survive, and the insert is a single undoable step.

4. **Behavior keyed to editor-open.** "Editor open" is the switch that was
   formerly "editor mode": survives blur, `.regular` activation policy,
   `canBecomeMain`. Input-only is capture-grade: self-dismiss on blur,
   `.accessory`, non-activating. `⌘J` jumps focus to the input; submit or `Esc`
   returns it to the editor. `⌘F` collapses the editor (preserving unsaved
   capture text); `✕` or `Esc`-from-input-only fully dismisses (clearing it).

## Considered alternatives

- **Serialize through the file** (flush editor save → `FileWriter` appends to
  disk → reload editor). Keeps the file canonical but needs a flush→append→reload
  handshake across the JS bridge and still races if the user keeps typing during
  the round-trip. Rejected for the cleaner single-buffer-canonical model.
- **Read-only editor while the input has focus.** Sidesteps concurrency by
  forbidding simultaneous edits — but that defeats the entire purpose of keeping
  capture available while editing. Rejected.

## Consequences

- `FileWriter.insert` must be reachable from the capture-while-editing path and
  must agree, line-for-line, with what `appendTodo` produces on disk — otherwise
  input-only and split captures would format items differently. Keep them in
  sync; cover both paths in `FileWriterTests`.
- A new Swift→editor bridge call is needed: "insert this item at this offset"
  (not just "set content").
- ADR-0001's crossfade and its mutual-exclusion premise no longer hold; its
  consequences (the `⌘F` window intercept, mode-aware dismiss, activation-policy
  swap) carry forward but are now keyed to *editor-open* rather than *mode*.
