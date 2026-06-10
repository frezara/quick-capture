---
date: 2026-06-07
topic: screenshot-attach
---

# Screenshot Attach for Quick Capture

## Summary

Summon quick capture shortly after taking a screenshot and the image arrives pre-attached as a thumbnail chip; outside that window, a keystroke pulls in the most recent screenshot on demand. On save, the image is copied into an `attachments/` folder beside the capture file and linked with a relative path on an indented line under the todo. The editor renders the link folded, expandable to an inline preview.

---

## Problem Frame

On a laptop screen there isn't room for a terminal and a Finder window side by side. Take a screenshot to share with Claude, miss the drag-and-drop, and the file is stranded somewhere on the Desktop — relocating it later means hunting by timestamp. The note about the screenshot and the screenshot itself end up in two disconnected places.

The existing capture flow already solves half of this: screenshot, then hotkey, then type the thought. What's missing is the image coming along. With it, the capture entry becomes the index that keeps note and image together — droppable into a project `todo.md` in one sweep, and findable again when it's time to hand the image to Claude.

---

## Key Decisions

- **Copy, don't move or link in place.** The screenshot is copied into `attachments/` beside the capture file. Links survive Desktop cleanup, the markdown stays portable (Obsidian, Claude, anywhere), and the original stays where macOS put it. Cost: one duplicate file.
- **Passive detection, on summon only.** The app never reacts to a screenshot being taken — no popup, no badge, no persistent watcher. When capture is summoned, a one-shot lookup finds any screenshot created within the auto-attach window. Zero always-running footprint.
- **Auto-attach window plus manual fallback.** Within a short window (default ~2 minutes) the screenshot pre-attaches; older screenshots are reachable via a deliberate keystroke. Fresh screenshots cost zero keystrokes, stale ones cost one, and the app never guesses wrong.
- **Most recent screenshot only.** One chip, no list management. Several screenshots means several captures.
- **Indented child line in the markdown.** The image link lives on its own indented line under the todo, matching the existing nested-item convention. Trailing priority markers (`!`/`!!`/`!!!`) stay intact on the todo line, and the editor gets a clean whole-line target to fold.
- **Screenshots only in v1.** Screen recordings are deferred — file sizes make the copy rule expensive, and the detection plumbing will carry over when video earns its slot.

---

## Requirements

**Detection and attach**

- R1. When capture is summoned and a screenshot was saved to disk within the auto-attach window, it appears pre-attached as a thumbnail chip in the capture box.
- R2. Only the most recent screenshot attaches, even when several fall inside the window.
- R3. A single action detaches the chip; the entry then saves as a plain todo with no copy made.
- R4. Outside the window, a keystroke in the capture box attaches the most recent screenshot regardless of age; the affordance is discoverable via a subtle hint.
- R5. Detection finds screenshots wherever macOS is configured to save them, not just the Desktop.
- R6. The app performs no continuous monitoring; detection runs only when capture is summoned or the pull-in keystroke fires.

**File handling and markdown**

- R7. On save with an attachment, the image is copied into an `attachments/` folder beside the capture file; the original file is untouched.
- R8. The entry gains an indented child line directly under the todo carrying a relative-path image link.
- R9. Tag routing is unchanged — the todo and its image line land together under the entry's `## tag` heading (or `## Quick capture`).
- R10. Trailing priority markers and the optional timestamp suffix on the todo line are unaffected by the image line.

**Integrity across file operations**

- R11. Priority-aware insertion treats the todo and its image line as one unit.
- R12. Re-org (⌘') moves the image line together with its parent todo.
- R13. Archiving a checked todo moves its image line to the archive file with it; because the archive is a sibling of the capture file, the relative link still resolves.

**Editor**

- R14. The editor renders the image link folded by default — a compact placeholder, not the raw markdown or an open image.
- R15. Expanding the placeholder shows the image inline; it can be collapsed again.

---

## Key Flows

- F1. Fresh screenshot, one sweep
  - **Trigger:** User presses ⌘⇧4, then the capture hotkey within the window.
  - **Steps:** Capture box opens with the screenshot chip pre-attached; user types the thought (and optional tag); Enter saves.
  - **Outcome:** Image copied to `attachments/`, todo plus indented image link written under the right heading. **Covers R1, R7–R10.**
- F2. Late summon
  - **Trigger:** User summons capture more than the window's length after the screenshot.
  - **Steps:** Box opens with no chip; user presses the pull-in keystroke; the most recent screenshot attaches; user saves.
  - **Outcome:** Same as F1. **Covers R4.**
- F3. Unrelated note
  - **Trigger:** A recent screenshot exists, but the thought has nothing to do with it.
  - **Steps:** Chip is pre-attached; user detaches with one action; saves.
  - **Outcome:** Plain todo, no file copied. **Covers R3.**

---

## Acceptance Examples

- AE1. **Covers R1, R2.** Given two screenshots taken 60s and 20s ago, when capture is summoned, then only the 20s-old one appears as the chip.
- AE2. **Covers R4.** Given the last screenshot is 5 minutes old, when capture is summoned, then no chip appears — and the pull-in keystroke attaches that screenshot.
- AE3. **Covers R4.** Given no screenshot exists on disk, when the pull-in keystroke fires, then nothing attaches and the capture flow is undisturbed.
- AE4. **Covers R10.** Given a capture "fix layout !!" with a screenshot, when saved, then the todo line ends with `!!` and the image link sits on the indented line below — priority classification unchanged.
- AE5. **Covers R13.** Given a checked todo with an image line, when archive runs, then both lines move to the archive file and the image still renders from there.
- AE6. **Covers R6.** Given a screenshot taken with ⌘⇧⌃4 (clipboard only, no file), when capture is summoned, then nothing attaches — clipboard captures are outside this feature.

---

## Scope Boundaries

- Screen recordings / video — deferred until the screenshot flow proves itself.
- Multiple attachments per entry — deferred; one chip, one image.
- Pasting clipboard images into the capture box — deferred; would cover ⌘⇧⌃4 captures later.
- Proactive reactions to screenshots (auto-open, menu-bar badge, notification) — out; the passive model is the design.
- Orphan cleanup (attachment files whose todo was deleted) — out of v1.

---

## Dependencies / Assumptions

- The app is unsandboxed (`QuickCapture.entitlements` is empty), so reading the screenshot save location and copying files needs no new entitlements. Verified.
- The archive file is a sibling of the capture file (`<name>_archive.<ext>`), so relative `attachments/` links resolve from both. Verified against current archive behavior.
- macOS tags screenshots with Spotlight metadata (`kMDItemIsScreenCapture`), and indexing latency is low enough that a screenshot taken seconds before summoning is already queryable. Unverified — planning must confirm, with the configured screenshot-folder lookup as fallback.
- The user saves screenshots to disk (macOS default). Clipboard-only capture is explicitly out of scope.

---

## Outstanding Questions

**Deferred to planning**

- Exact auto-attach window default and whether it's exposed as a setting.
- Detection mechanism: one-shot Spotlight query vs. reading the configured screenshot folder directly — decide after verifying indexing latency.
- Attachment filename scheme on copy (collision-safe, sortable).
- Keystroke choices for detach and pull-in, and how the pull-in hint is presented without cluttering the capture box.
- Whether the editor's fold/expand state persists across reloads.
