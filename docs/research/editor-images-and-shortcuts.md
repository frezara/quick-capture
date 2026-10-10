# Stable image previews and editor shortcuts

Research date: 2026-10-10. The recommendations below were subsequently implemented on `codex/unified-design`: stable attachment widgets, explicit undoable source edits, image-only atomic cursor ranges, registry-derived hints, and editor-local ⌥⌘J / ⌥⌘K shortcuts.

## What causes the image change

The attachment branch in `buildLivePreview` replaces Markdown with `ImageWidget` only when the selection does not overlap the image's line (or read mode is enabled). Entering that line therefore removes the image and exposes its Markdown. `ImageWidget` already cancels mouse-down events to avoid this during direct clicks, but that does not cover other selection movement. The image hover rule changes pill styling; it does not itself remove the preview. The reported hover-only trigger has not been reproduced. Evidence: [editor implementation](../../editor-web/src/editor.ts), `selectionOverlaps`, `ImageWidget`, and the attachment branch in `buildLivePreview`.

Obsidian documents the same broad live-preview convention: syntax appears when the cursor enters formatted content, while Source mode exposes all syntax explicitly. That establishes a familiar text-editing pattern, but is not evidence that collapsing a tall image into one line is desirable. [Obsidian: Views and editing mode](https://obsidian.md/help/edit-and-read).

## Recommended image interaction

Keep attachment previews visible when the pointer or text cursor approaches. Hover may reveal a small action affordance without changing image dimensions. Treat the attachment as a selectable object; provide an explicit **Edit Markdown** action accessible by keyboard as well as pointer. That action should expose a small source editor beneath the still-visible image, with **Done** and **Cancel**, rather than replacing the image. Reserve its action area so hover does not shift content. This is a product recommendation, not a requirement from the sources.

Implementation direction: keep the replacement decoration independent of ordinary selection, and expose only attachment ranges through `EditorView.atomicRanges`. CodeMirror documents these ranges as skipped by cursor movement commands; direct programmatic selections are still possible. `Decoration.replace` displays a widget instead of source, and widget event handling can keep UI controls separate from editor cursor handling. A deliberate source-edit state must therefore be distinct from normal selection. Do not make every Markdown decoration atomic. [CodeMirror reference: decorations](https://codemirror.net/docs/ref/#view.EditorView.decorations), [atomic ranges](https://codemirror.net/docs/ref/#view.EditorView.atomicRanges), [widget event handling](https://codemirror.net/docs/ref/#view.WidgetType.ignoreEvent).

Check arrow navigation, selection spanning an attachment, Backspace/Delete and undo, multiple identical attachment paths, source edits, missing images, and scroll position. Atomic cursor movement alone does not establish safe selection/deletion behaviour; those interactions need verification before shipping.

## Recommended shortcut pattern

Retain the established right-hand `⌥⌘` action family and extend it to the adjacent home row:

| Action | Proposed binding | Scope |
| --- | --- | --- |
| Refile | ⌥⌘U | Editor, existing |
| Toggle editor | ⌥⌘I | Panel, existing |
| Attach image | ⌥⌘O | Capture/editor, existing |
| Capture | ⌥⌘P | Global, existing default |
| Re-organize | **⌥⌘J** | Editor; replaces ⌘' |
| Archive completed | **⌥⌘K** | Editor; new |

This follows the spatial choice already documented in [ShortcutRegistry.swift](../../Sources/QuickCapture/ShortcutRegistry.swift): the left hand holds modifiers and the right hand chooses an action. J/K are proposals, not platform standards. Keep standard editing shortcuts such as ⌘S and ⌘F; do not put ordinary text editing into this family. Re-org and archive should not become global hotkeys.

Apple recommends Command as the principal modifier, reserving custom shortcuts for frequent actions, using Option sparingly for power features, preferring alphabetic keys when extra modifiers are needed, and displaying modifiers in Control–Option–Shift–Command order. Maintaining this app's existing small power-action family is a deliberate compromise with that guidance, rather than a claim that Apple recommends ⌥⌘ for everything. [Apple: Keyboards, custom keyboard shortcuts](https://developer.apple.com/design/human-interface-guidelines/keyboards?changes=_7).

Visually separate each action name from a right-aligned shortcut hint; use consistent key typography and column alignment. Current inspector/sidebar hints are hardcoded, while the registry pushes key bindings. Derive both hints and bindings from the registry so buttons and the Editor menu cannot drift. Expose **Archive completed** and **Attach image** in the Editor menu as well as the inspector (the attachment registry action currently has no menu title). Route keyboard and button invocation through the same save-before-archive path; a failed save must prevent archiving. These are application-specific recommendations based on the current registry and archive button implementation.
