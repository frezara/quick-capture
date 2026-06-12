---
title: "feat: ⌥⌘ + letter toggle family for panel shortcuts"
status: completed
date: 2026-06-12
type: feat
---

# feat: ⌥⌘ + letter toggle family for panel shortcuts

## Summary

Make QuickCapture's three panel toggles a consistent, easy-to-tap family under the
`⌥⌘` namespace, each pressable to flip *in and out*:

| Action | Today | Becomes | Wiring |
|---|---|---|---|
| Show/hide capture | `⌥T` (shipped default) | **`⌥⌘P`** | global Carbon hotkey default |
| Capture ↔ editor | `⌥⌘E` | `⌥⌘E` | unchanged |
| Capture ↔ screenshot | `⌘⇧S`, Esc-only exit | **`⌥⌘S`**, same-key toggles out | registry chord + handler |

The work is three small changes plus a documentation sweep: flip the global hotkey
default, move the screenshot picker onto `⌥⌘S` and make a second press close it, then
sync every user-facing string, code comment, and doc that names the old chords.

---

## Problem Frame

Shortcuts accreted one at a time. The capture↔editor toggle already landed cleanly on
`⌥⌘E` (epic #53, namespace revised to `⌥⌘` by #69), but two siblings are out of family:

- The **global summon** ships as `⌥T`. The user runs `⌥⌘P` via a personal Settings
  rebind stored in UserDefaults, so `CLAUDE.md`, the website, and the code default all
  disagree with the actual install — documentation drift, not a real disagreement.
- **Screenshot capture** sits on `⌘⇧S`, outside the `⌥⌘` namespace, and only Esc closes
  the picker. It doesn't read as part of the toggle family and you can't tap the same
  chord to back out.

Goal: one mnemonic `⌥⌘ + letter` family (`P` panel, `E` editor, `S` screenshot — `R`
refile already fits), each a press-to-toggle. This is the convention decided in the
2026-06-12 brainstorm; planning only sequences the edits.

---

## Requirements

- **R1.** The shipped global-summon default is `⌥⌘P`. A never-rebound install summons on
  `⌥⌘P`; any existing custom rebind in UserDefaults is left untouched (no migration).
- **R2.** Screenshot capture is bound to `⌥⌘S` and `⌘⇧S` no longer triggers it (full
  replacement, no alias).
- **R3.** `⌥⌘S` is a toggle: pressed in plain capture it opens the picker; pressed again
  while the picker is open it closes the picker without changing attachments — identical
  to the existing Esc-cancel. It stays capture-mode-scoped (no-op in editor mode).
- **R4.** `⌥⌘E` capture↔editor behavior is unchanged.
- **R5.** Every user-visible string and project doc that names `⌥T` or `⌘⇧S` reflects the
  new chords. Historical records (`docs/plans/`, `docs/adr/`) are left as-is.

---

## Key Technical Decisions

- **Global hotkey is wired separately from the registry, by design.** `⌥⌘P` is a Carbon
  registration (`HotKeyConfig` / `AppDelegate.rebindHotKey`) that must fire while the app
  has no key window; `⌥⌘E`/`⌥⌘S` are `performKeyEquivalent` window intercepts via
  `ShortcutRegistry`. They share the `⌥⌘` look but not the mechanism — this plan changes a
  value in each layer, not the layering.
- **No migration for the default change.** UserDefaults is only written on an explicit
  rebind, so existing custom bindings survive and only the bare default moves `⌥T → ⌥⌘P`.
  Acceptable and intended for a single-user personal app whose owner already runs `⌥⌘P`.
- **Toggle lives in the dispatch handler, not the registry.** `attachScreenshot` keeps
  `.captureMode` scope, which is active whenever `!editorOpen` — true both before and
  after the picker opens — so the same `⌥⌘S` event keeps resolving to `attachScreenshot`.
  `MainPanel.perform(shortcut:)` branches on the existing `pickerOpen` flag to choose
  open-vs-close. This reuses `closePickerSurface(attaching: nil)`, the exact path Esc
  already takes (`CaptureView` → `onPickerCancel`).
- **`⌥⌘S` does not collide.** In capture mode the only window-intercepted chords are
  `⌥⌘E`, `⌘W`, and `attachScreenshot`; `⌘S` save is editor-scoped. No overlap.

---

## Implementation Units

### U1. Global summon default → ⌥⌘P

- **Goal:** Ship `⌥⌘P` as the default global hotkey so code, docs, and the actual install
  agree (R1).
- **Dependencies:** none.
- **Files:**
  - `Sources/QuickCapture/HotKeyConfig.swift` — `static let default`
  - `Tests/QuickCaptureTests/HotKeyConfigTests.swift` *(new, optional — see scenarios)*
- **Approach:** Change `keyCode` from `17` (`kVK_ANSI_T`) to `35` (`kVK_ANSI_P`),
  `modifiers` from `[.option]` to `[.option, .command]`, and `displayName` from `"T"` to
  `"P"`. `displayString` already composes the glyphs, so the Settings recorder and any
  display string update for free.
- **Patterns to follow:** the existing `HotKeyConfig.default` literal; keyCode comment
  style (`// kVK_ANSI_P`).
- **Test scenarios:**
  - `HotKeyConfig.default.displayString == "⌥⌘P"` (asserts keyCode, both modifiers, and
    display name compose correctly). If a standalone test for a constant feels like
    overhead, fold this assertion into U2's registry test file instead.
  - `Test expectation: none` for the migration behavior — it is the *absence* of a
    UserDefaults write, verified by manual QA (existing rebind survives an upgrade).
- **Verification:** Fresh launch with no saved hotkey summons on `⌥⌘P`; a machine with a
  prior custom rebind still summons on that rebind.

### U2. Screenshot capture → ⌥⌘S, with same-key toggle-out

- **Goal:** Move screenshot capture into the `⌥⌘` family and make a second `⌥⌘S` close the
  picker (R2, R3).
- **Requirements:** R2, R3, R4 (must not disturb `⌥⌘E`).
- **Dependencies:** none (independent of U1).
- **Files:**
  - `Sources/QuickCapture/ShortcutRegistry.swift` — `attachScreenshot` chord
  - `Sources/QuickCapture/MainPanel.swift` — `perform(shortcut:)` `attachScreenshot` arm
  - `Tests/QuickCaptureTests/ShortcutRegistryTests.swift` *(new)*
- **Approach:**
  - Registry: change `attachScreenshot` chord modifiers `[.command, .shift]` →
    `[.command, .option]` (key stays `"s"`). Scope and `isWindowIntercepted` are already
    correct and stay as-is.
  - Handler: branch the `attachScreenshot` case on `pickerOpen` —
    open via the existing `openScreenshotPicker()` when closed, close via
    `closePickerSurface(attaching: nil)` when open. The cancel path matches Esc exactly,
    so no attachment state changes on toggle-out.
- **Technical design** *(directional, not implementation spec):*
  ```
  case .attachScreenshot:
      pickerOpen ? closePickerSurface(attaching: nil)   // second press == Esc-cancel
                 : openScreenshotPicker()
  ```
- **Patterns to follow:** the existing `perform(shortcut:)` switch; `closePickerSurface`
  is already the Esc-cancel target (`CaptureView.onPickerCancel`).
- **Test scenarios** (registry resolution — pure function, no UI):
  - `interceptedAction(key: "s", modifiers: [.command, .option], editorOpen: false)` → `.attachScreenshot`.
  - `interceptedAction(key: "s", modifiers: [.command, .shift], editorOpen: false)` → `nil` (old chord retired).
  - `interceptedAction(key: "s", modifiers: [.command, .option], editorOpen: true)` → `nil` (capture-scoped; no-op in editor).
  - `interceptedAction(key: "e", modifiers: [.command, .option], editorOpen: false)` → `.toggleEditor` (regression guard — `⌥⌘E` family-mate intact).
  - `Test expectation: none` for the open↔close toggle itself — it depends on `MainPanel`
    instance state (`pickerOpen`) and window animation; cover by manual QA below.
- **Verification:** `⌥⌘S` in capture opens the picker; `⌥⌘S` again returns to the capture
  box with the prior attachment unchanged; Esc still closes; `⌘⇧S` does nothing; `⌥⌘S` in
  editor mode does nothing.

### U3. Sync user-facing strings, comments, and project docs

- **Goal:** No surface still tells the user `⌥T` or `⌘⇧S` (R5).
- **Dependencies:** U1, U2 (docs describe the chords those units land).
- **Files:**
  - **User-visible strings (must change):**
    - `Sources/QuickCapture/CaptureView.swift:549` — `"Tab to tag · ⌘⇧S to attach"`
    - `Sources/QuickCapture/CaptureView.swift:567` — `"⌘⇧S to attach screenshot"` hint
    - `Sources/QuickCapture/SettingsView.swift:78` — note: "…`⌘⇧S` pulls in the latest…"
    - `Sources/QuickCapture/FileWriter.swift:23` — welcome-file line ("press ⌥T … ⌥⌘E …")
  - **Code comments (accuracy hygiene, `⌘⇧S → ⌥⌘S`):** `AppState.swift` (124, 133, 138),
    `ScreenshotLocator.swift:26`, `MainPanel.swift` (79, 522, 575),
    `CaptureView.swift` (37, 40, 63, 182, 682, 710, 716, 721)
  - **Project docs:**
    - `CLAUDE.md:10` — capture default `⌥T → ⌥⌘P`; add `⌥⌘S` screenshot to the
      `⌥⌘`-namespace note (around lines 126–136) so the family list is complete.
    - `docs/index.html` (4 spots: meta description ~7, tagline ~764, hotkey section ~818,
      footer defaults ~930) — `⌥T → ⌥⌘P`.
- **Approach:** Mechanical find-and-replace of the two glyphs in the listed surfaces. Keep
  the welcome-file line's existing shape (`⌥⌘P to capture … ⌥⌘E to open the editor`). Do
  **not** touch `docs/plans/*` or `docs/adr/0004-*` — those are historical records.
- **Test scenarios:** `Test expectation: none — string/comment/doc edits, no behavioral
  change.` Verified by build + visual check of the capture hint and Settings note.
- **Verification:** App builds; the capture box reads "⌥⌘S to attach", the Settings note
  and a freshly-created capture file name the new chords, and `grep -rn "⌘⇧S\|⌥T"
  Sources/ CLAUDE.md docs/index.html` returns nothing.

---

## Scope Boundaries

**In scope:** the global-hotkey default, the screenshot chord + toggle behavior, and the
doc/string sweep across app code, `CLAUDE.md`, and `docs/index.html`.

**Out of scope / non-goals:**
- `⌥⌘E` behavior — already correct.
- The editor web layer (`editor-web/src/editor.ts`) — the screenshot picker is
  capture-side only; no `npm run build` needed.
- Per-action user-rebinding UI for the window shortcuts (registry makes it cheap later;
  not now).
- Rewriting historical `docs/plans/` and `docs/adr/` chord mentions.

### Deferred to Follow-Up Work
- None outstanding — the website update was pulled into U3 by decision.

---

## Build & Verification Notes

- New test file(s) under `Tests/QuickCaptureTests/` require `xcodegen generate` before
  `xcodebuild … test` (the `.pbxproj` has a static file list — per `CLAUDE.md`).
- Build: `xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture -configuration Debug build`.
- Test: `xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture test`.
- Manual QA covers the two state-dependent behaviors unit tests can't reach: the `⌥⌘S`
  open↔close toggle, and the no-migration guarantee (an existing rebind surviving).

---

## Risks & Mitigations

- **Bare-default users shift `⌥T → ⌥⌘P` on upgrade.** Intended; the sole user already runs
  `⌥⌘P`. Mitigation: documented in U1 verification; the hotkey remains rebindable in
  Settings.
- **A missed string leaves a stale `⌘⇧S`/`⌥T` in the UI.** Mitigation: U3's closing `grep`
  gate over `Sources/`, `CLAUDE.md`, and `docs/index.html`.
- **Rapid double-tap of `⌥⌘S` before the async screenshot lookup returns** could fire two
  lookups (the picker isn't `pickerOpen` yet during the lookup window). Low impact — the
  existing `attachLookupGeneration` guard discards the stale result. Not worth special
  handling; noted for the implementer.

## Origin

Decisions carried from the 2026-06-12 shortcut-ergonomics brainstorm (capture↔editor
already on `⌥⌘E`; screenshot chosen as `⌥⌘S` replacing `⌘⇧S`; website docs included).
