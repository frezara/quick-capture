# CLAUDE.md

Project hand-off doc for Claude Code. Read this first.

## What this is

**Quick Capture** is a personal macOS menu bar app. A single floating
`NSPanel` (`MainPanel`) hosts two surfaces and animates between them:

1. **Capture mode** — global hotkey (default `⌥T`) summons a small floating
   box. Type a thought, hit Enter, it's appended as `- [ ] <text>` to
   a markdown file. Tags route entries under `## tag` headings; untagged
   items go under `## Quick capture`. `#cal` re-interprets the input as a
   natural-language calendar event and opens an `.ics`.
2. **Editor mode** — `⌥⌘E` crossfades the panel (frame animation + alpha
   crossfade) to a full CodeMirror 6 editor hosted in a `WKWebView`, with
   Obsidian-style live preview (checkbox widgets, hidden syntax marks, indent
   guides), vim mode (optional), priority orbs, a floating action cluster, and
   file-watcher reload. The editor is headerless — its bottom status bar carries
   the filename, vim mode, and item count. `⌥⌘E` crossfades back to the capture
   box. The menu-bar "Open Editor…" summons straight into editor mode.

The two are **mutually-exclusive modes** — only one surface is ever on screen
(see ADR-0004). One window, one file (always the capture file). The editor's web
view stays warm across mode switches, so toggling is instant and preserves
cursor/scroll. Typed-but-unsaved capture text is preserved when you ⌥⌘E into the
editor and back; it's only cleared on a full dismiss.

LSUIElement app (no dock icon by default). Editor mode bumps the activation
policy to `.regular` so the standard menu bar (⌘H/⌘Q/⌘W/Cut/Copy/Paste) works;
capture mode and full dismiss drop it back to `.accessory`.

## Code layout

```
project.yml                        XcodeGen config — single source of truth for the .xcodeproj
QuickCapture.xcodeproj/            Generated; do not hand-edit
QuickCapture.entitlements
Sources/QuickCapture/
  QuickCaptureApp.swift            @main; SwiftUI Settings scene binds ⌘, to SettingsView
  AppDelegate.swift                NSStatusItem, main menu, hotkey, panel lifecycle, launch-at-login
  AppState.swift                   ObservableObject; UserDefaults-backed settings + recent-tag scan
  HotKeyConfig.swift               Codable hotkey model used by KeyRecorderView
  ShortcutRegistry.swift           Single source of truth for app shortcuts: chords, scopes,
                                   window-intercept flags, Editor-menu titles, editor keymap push
  MainPanel.swift                  The one NSPanel: hosts CaptureView + the editor WKWebView
                                   (both warm), mutually-exclusive mode switching (capture↔editor),
                                   shortcut intercepts, frame/crossfade animation, file watcher, JS↔Swift bridge
  CaptureView.swift                SwiftUI capture UI (multi-line input, tag field, shake-on-empty)
  KeyRecorderView.swift            Settings widget for re-binding the global hotkey
  SettingsView.swift               SwiftUI Settings form (file path, hotkey, font, timestamp, refile targets)
  SettingsWindowController.swift   Plain NSWindow fallback path for Settings (menu-bar item route)
  FileWriter.swift                 Append/insert/archive logic + refile core (subtree span,
                                   verify-and-remove, dedent, attachment-paths, append-under-inbox)
  RefileService.swift              ⌥⌘R disk pipeline: verify→copy→rewrite/dedent→write target→write source→delete
  RefileTarget.swift               Settings model for a refile destination folder + effective-list filtering
  EventParser.swift                "#cal" NL → calendar event parser
  ICSWriter.swift                  Calendar event → temp .ics file
  TagColor.swift                   Hue palette for tag chips
  Assets.xcassets/                 Menu bar icon, app icon
editor-web/
  package.json                     CodeMirror + esbuild deps
  src/editor.ts                    The whole editor (~1000 lines): live preview, vim, priorities, sidebar
  dist/                            Bundled HTML/JS shipped inside the .app (folder reference in project.yml)
Tests/QuickCaptureTests/
  FileWriterTests.swift            Insertion + priority + archive behavior
  FileWriterRefileTests.swift      Refile core: subtree span, verify-and-remove, dedent, paths, append
  RefileServiceTests.swift         Refile pipeline over temp dirs (happy path, scaffold, drift, failure intact)
  AttachmentStoreRefileTests.swift Copy-preserving-name, shared-path-safe delete
  RefileTargetTests.swift          Target persistence + effective-list filtering
  EventParserTests.swift
  ICSWriterTests.swift
```

## Build & run

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node 18+.

```sh
# One-time / after adding-removing Swift files:
xcodegen generate

# Editor bundle (re-run after editing editor-web/src/editor.ts):
cd editor-web && npm install && npm run build
# or `npm run dev` for esbuild watch mode

# Build:
xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture -configuration Debug build

# Tests:
xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture test
```

`editor-web/dist/` is bundled into the `.app` as a folder reference (see
`project.yml`), so `Bundle.main.url(forResource:..., subdirectory: "dist")`
finds `editor.html` at runtime. **You must `npm run build` after editing
`editor.ts`** — the Swift build doesn't trigger it.

## Architecture notes / gotchas

- **Capture file format.** First line is always `# Inbox`. Items live under
  `## section` H2s. `FileWriter.appendTodo` enforces both. `## Quick capture`
  is the catch-all for untagged items; tag values become H2 names verbatim.
- **Priority buckets.** Trailing `!`/`!!`/`!!!` on a task = priority levels
  2/1/0; no marker = 3; `[x]` checked = 4. `FileWriter.priorityBucket` is
  tolerant of an Obsidian Tasks `➕ YYYY-MM-DD HH:MM` suffix so timestamped
  captures still classify correctly. Insertion in `FileWriter.insert` walks
  through a section and lands a new item just before the first task whose
  bucket is `>=` its own (so high-priority captures float to the top).
- **Archive.** `FileWriter.archiveCompleted` moves every `- [x]` line to a
  sibling `<name>_archive.<ext>` file, preserving the source's H2 sections.
  Indented checked items are flattened to the top level in the archive.
- **One panel, two mutually-exclusive modes (ADR-0004).** `MainPanel` keeps
  both surfaces mounted at once inside a `PanelContainerView` (a `CaptureView`
  hosting view and the editor `WKWebView` inside an `EditorContainerView`) and
  **crossfades** between them while animating the window frame (`animateFrame`
  fades the editor to α and the capture box to 1−α, so exactly one shows). The
  editor host always fills the window; the capture host fills the window in
  capture mode (so its SwiftUI content measures and drives the window height)
  and is pinned to a centred fixed-size box in editor mode / during the
  crossfade, so it dissolves in place rather than stretching. Capture mode is
  content-sized and centered; editor mode is a comfortable fixed-width,
  full-visible-height centered frame. `openEditor` / `closeEditor` /
  `showInEditor` drive the mode; `show()` always resets to capture so
  re-summoning lands on the capture box.
- **Shortcuts live in `ShortcutRegistry.swift`** (epic #53). Scheme: plain ⌘
  keys keep their native/Obsidian editor meaning (⌘F find, ⌘S save, ⌘E read
  mode, ⌘L toggle task); **⌥⌘ is the app's namespace** for panel-level actions
  (⌥⌘E mode toggle, ⌥⌘R refile). `MainPanel.performKeyEquivalent` is a generic
  registry lookup; editor-local bindings are pushed into CodeMirror via
  `qcEditor.setKeymap` on boot. Adding a shortcut = one registry case + a
  handler arm (`MainPanel.perform(shortcut:)`) or one `appCommands` entry
  (editor.ts). ⌘R is intercepted as a deliberate no-op in editor mode — WebKit
  would otherwise reload the warm editor. Vim owns Escape inside the editor,
  so ⌥⌘E (not Escape) is the switch gesture; ⌘F opens CodeMirror's search
  panel (top-anchored, themed).
- **Mode-aware dismiss.** `resignKey` only self-dismisses (click-away) in
  capture mode — the editor must survive losing focus so you can copy from
  other apps. `canBecomeMain` is true only in editor mode.
- **Single-instance guard.** `AppDelegate.applicationDidFinishLaunching`
  hands off to any other running copy of the bundle and quits, so the menu
  bar never grows two icons.
- **WKWebView clipboard.** Vim's `p` needs `navigator.clipboard.readText()`,
  which is blocked unless `javaScriptCanAccessClipboard` and `DOMPasteAllowed`
  are set on `WKPreferences` via KVC (the Swift API doesn't expose them).
  See `MainPanel.init`.
- **File watcher.** `MainPanel` watches the capture file with a
  `DispatchSourceFileSystemObject` (so capture-mode appends reload the warm
  editor). Atomic writes (`String.write(..., atomically: true)`) replace the
  file via temp+rename, so we re-open the fd on `.rename`/`.delete` events.
  `lastSyncedContent` suppresses our own writes from looping back as
  "external changes".
- **JS ↔ Swift bridge.** JS posts JSON dicts of the form
  `{ type: "ready" | "save" | "archive", content?: String }` to the
  `editorBridge` `WKScriptMessageHandler`. See `EditorBridge` at the bottom
  of `MainPanel.swift`.
- **Settings has two entry points.** `⌘,` opens the SwiftUI `Settings`
  scene (`QuickCaptureApp.swift`); the menu bar's "Settings…" item and the
  app-menu item route through `SettingsWindowController` (a plain
  `NSWindow`). Both render the same `SettingsView`. The dual path exists
  because the SwiftUI Settings scene is unreliable for LSUIElement apps
  when no window is foreground.
- **Editor live preview.** `editor-web/src/editor.ts` builds a `ViewPlugin`
  that scans every visible line and emits decorations: hide `- [ ] ` syntax
  when the cursor isn't on the line, replace it with a `CheckboxWidget`,
  draw indent guides for nested items (`/^( {2,}|\t)\S/` — 2+ spaces or a
  tab; single-space indent is NOT treated as a child), and render priority
  dots from trailing `!`/`!!`/`!!!`.
- **Re-org (`⌘'`).** Moves checked items to the bottom of their section
  (FLIP-animated, focus preserved), sorts unchecked items by priority bucket
  (`!!!` → `!!` → `!` → plain), and strips priority markers from checked
  items so they read as plain done items.
- **Refile (`⌥⌘R`).** Editor-only. Moves the subtree under the cursor (item +
  attachments + nested children, resolved by the shared child-indent rule, a
  cursor-on-child resolving up) into a chosen **refile target**'s `inbox.md`,
  appended at top level (dedented) in arrival order, with its screenshots. The
  editor resolves the span and posts `{ type: "refile", target, fromLine,
  toLine, subtree }`; `RefileService` does the disk surgery and the file watcher
  reloads the editor — same pattern as archive. The source file is written
  **last** so any failure leaves it byte-for-byte intact (the item never
  vanishes); a byte-for-byte verify of the editor's subtree against disk guards
  against the file drifting between flush and move. Targets are configured in
  Settings (folders, optional labels, reorderable); Swift **pushes** the
  effective list into the editor (it can't read settings) on entry and on
  change. `⌥⌘R` is window-intercepted and drives `qcEditor.invoke("refile")`
  over the bridge; the editor keeps an `Alt-Mod-r` keymap entry for the
  browser harness.

## When you're asked to…

- **Add or rename a Swift source file** → edit it, then `xcodegen generate`,
  then build. The `.pbxproj` has a static file list.
- **Change editor behavior** → edit `editor-web/src/editor.ts`, then
  `npm run build` in `editor-web/`, then rebuild the app. (The bundled
  `dist/editor.js` is committed — yes, intentionally — so the Swift build
  alone is enough for a fresh checkout to run.)
- **Change capture file structure or insertion logic** → `FileWriter.swift`
  + add a test in `FileWriterTests.swift`. Existing tests cover priority
  ordering and timestamp tolerance — match that style.
- **Add a setting** → `AppState.swift` (new `@Published` property +
  UserDefaults key) and a control in `SettingsView.swift`. Reads in the
  editor go through `UserDefaults.standard` directly (the AppState object
  isn't accessible from inside the editor web layer).
- **Change the global hotkey behavior** → `AppDelegate.rebindHotKey` +
  `HotKeyConfig.swift`. The hotkey rebind is broadcast over the
  `.hotKeyDidChange` notification when Settings changes it.

## Conventions

- No comments that just restate the code. Comments are reserved for
  *why* something non-obvious is done (the WKWebView clipboard KVC dance,
  the activation-policy switching, the single-instance guard, etc.).
- Atomic writes everywhere we touch the user's file
  (`.write(to:options:.atomic)` or `String.write(...atomically: true)`).
- `NSLog` for editor-side failures that shouldn't interrupt the user (file
  watcher, archive, save). `NSAlert` for capture-flow failures the user
  needs to see.
- LSUIElement is non-negotiable — don't ship a permanent dock icon. The
  `.regular` ↔ `.accessory` swap in `MainPanel` (editor mode ↔ capture
  mode / dismiss) is the approved way to get a menu bar during editing.

## Agent skills

### Issue tracker

Issues and PRDs are tracked as GitHub issues (`frezara/quick-capture`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
