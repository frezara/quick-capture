# ADR-0001: One panel, two modes

Status: Accepted — briefly amended by ADR-0003, restored by ADR-0004

> **History:** ADR-0003 amended this to a persistent-input "split" (editor
> beneath the capture box, both visible). ADR-0004 reverted that — the two
> surfaces are once again **mutually-exclusive modes** that crossfade, exactly
> as decided here. The mechanics below (warm web view, `⌘F` window intercept,
> mode-aware dismiss, activation-policy swap) hold as written. Read ADR-0004
> for the revert rationale and the gestures it adds (⌘W dismiss, vim-aware Esc).
>
> **Update (2026-06, epic #53):** the switch gesture moved from `⌘F` to `⌃⌘E`;
> `⌘F` is now native find inside the editor. The window-intercept *mechanism*
> is unchanged — bindings live in `ShortcutRegistry.swift`. Where this document
> says `⌘F`, read the registry's `toggleEditor` chord.

## Context

Quick Capture has two surfaces: a small **capture box** and a full
**editor**. The obvious implementation is two separate windows — an
`NSPanel` for capture and an `NSWindow` (or separate panel) hosting the
`WKWebView` editor. That keeps each surface simple but makes the
capture→editor transition a window swap: the editor's web view would be
created and torn down (or hidden behind another window) on every toggle,
losing cursor/scroll and paying CodeMirror's warm-up cost each time.

The editor is a `WKWebView` running CodeMirror 6. Re-instantiating it is
slow and stateful; we want toggling between capture and editor to feel
instant and to preserve where you were.

## Decision

Use a **single `NSPanel` (`MainPanel`) that hosts both surfaces at once**
and animates between them in place:

- A `CaptureView` hosting view and the editor `WKWebView` (inside an
  `EditorContainerView`) are both mounted for the panel's lifetime.
- `animateTransition` crossfades the two while animating the window frame.
  Capture mode is content-sized and centered; editor mode is a fixed
  900×700 centered frame.
- `switchToEditor` / `switchToCapture` / `showInEditor` drive the mode.
  `show()` always resets to capture, so re-summoning lands on the capture
  box. The "Open Editor…" menu item summons straight into editor mode.
- The web view stays **warm** across switches, preserving cursor/scroll.
  Typed-but-unsaved capture text survives a `⌘F` round-trip; it's cleared
  only on a full dismiss.

Consequences for input and lifecycle, all stemming from one-panel-two-modes:

- **`⌘F` is intercepted at the window** (`MainPanel.performKeyEquivalent`)
  *before* it reaches CodeMirror/WebKit (which would treat it as "find"),
  and toggles the mode. Vim owns Escape inside the editor, so `⌘F` (not
  Escape) is the back gesture.
- **Mode-aware dismiss**: `resignKey` only self-dismisses (click-away) in
  capture mode — the editor must survive losing focus so you can copy from
  other apps. `canBecomeMain` is true only in editor mode.
- **Activation policy** is `.regular` in editor mode (so the standard menu
  bar works) and `.accessory` in capture mode / on dismiss — see the
  `LSUIElement` constraint in `CLAUDE.md`.

## Consequences

- Toggling is instant and preserves editor state. ✅
- Only one window ever exists; the single-instance guard
  (`AppDelegate.applicationDidFinishLaunching`) keeps it that way.
- Cost: `MainPanel` concentrates a lot of responsibility (mode switching,
  the `⌘F` intercept, frame animation, the file watcher, and the JS↔Swift
  bridge). It is the most load-bearing file in the app; changes there are
  the highest-risk. If it grows further, splitting the file watcher and the
  bridge out are the natural seams.
- The two surfaces are **modes of one panel**, not tabs and not windows —
  see the language guidance in `CONTEXT.md`.
