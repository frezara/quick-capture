# Quick Capture

A tiny macOS menu bar app: press a global hotkey, type a thought, hit Enter — it's appended as a `- [ ]` line to a markdown file (typically an Obsidian inbox).

Built for the moment when a thought hits you mid-task and you don't want to context-switch into a notes app to jot it down.

## Features

- Configurable global hotkey (default `⌥⌘P`)
- Appends to any markdown file — works great with Obsidian vaults
- `#tags` route entries under `## tag` headings; untagged items go under `## Quick capture`
- `#cal` interprets the input as a natural-language calendar event ("call Seb tomorrow at 2pm for 30 min") and saves it as an internal organiser event
- Optional Obsidian-Tasks-compatible timestamp on each capture
- Pick your input font (System / Rounded / Serif / Monospaced)
- Built-in markdown editor with live preview, optional Vim bindings, search, and autosave
- Screenshot attachments in capture and editor modes
- Priority sorting, completed-item archiving, and refile destinations
- Persistent section colours shared by capture tags and the editor

## Install

Download the latest `.dmg` from the [Releases page](https://github.com/frezara/quick-capture/releases), open it, and drag **Quick Capture** into **Applications**.

### First launch

Quick Capture isn't signed with an Apple Developer ID yet (see Roadmap), so Gatekeeper will block the first launch with something like *"Apple could not verify 'Quick Capture' is free of malware…"*. To allow it:

1. In the warning dialog, click **Done** (not "Move to Bin").
2. Open **System Settings → Privacy & Security** and scroll to the bottom.
3. Next to the "Quick Capture was blocked…" message, click **Open Anyway** and authenticate.
4. Re-launch the app. It may prompt one more time — click **Open**.

Power-user one-liner that skips the dialog dance (removes the quarantine flag):

```sh
xattr -dr com.apple.quarantine /Applications/Quick\ Capture.app
```

macOS remembers the choice; subsequent launches are silent.

## Usage

Press **⌥⌘P** (or whatever you've configured) to summon the capture panel anywhere in macOS. Type your thought and press Enter — it's appended to your file and the panel disappears.

- Add `#tag` after the text (Tab to focus the tag field) to route the entry under a `## tag` heading.
- `#cal` saves an internal calendar event locally and queues it for the organiser.
- Press **⌥⌘I** to switch between capture and editor modes; **⌘F** searches in the editor.
- Press **⌥⌘O** to pick screenshots, or **⌥⌘U** in the editor to refile an item.
- Press **⌘S** to save immediately or **⌥⌘J** to reorganise items by priority and completion.
- Press **⌥⌘K** to archive completed items after saving. Re-organise and Archive require the cursor to be on an item; both are disabled on blank lines and in read mode.
- Attachments stay visible inline. Press **⌥⌘L** on an image or its parent item to reveal its Markdown path in the main editor, edit with the usual Vim keys, then press **⌥⌘L** again to hide the source. The preview remains visible while editing.
- Click the menu bar icon for **Settings** — file path, hotkey, timestamp, and input font are all configurable.

## Saving and external edits

The editor autosaves after a short pause. Explicit saves show “Saved” only after the file write succeeds. Switching back to capture mode, dismissing, and quitting wait for pending edits to save.

If another app changes the file while you have unsaved edits, Quick Capture keeps your text in the editor and shows a choice: **Keep my edits** replaces the disk version, while **Use disk version** replaces the editor buffer. Failed writes show a persistent error with a retry button.

## Automatic organiser delivery

New capture-box entries, including `#cal` events, are saved locally and queued
for the PostgreSQL organiser automatically. Configure the API URL and access key
in Settings → Automatic organiser delivery. Offline delivery retries safely;
credentials live in Keychain. Existing history and editor-created lines are not
imported automatically, and native edits/deletions are not synchronised yet.
See [organiser setup](organiser/README.md) and [verification](organiser/VERIFICATION.md).

### Legacy development handoff

The editor's **Send to organiser** action creates an immutable copy of the selected
item subtree. Configure the local spool in Settings; delivery history shows pending
work, receipts, recovery and Retry. Existing capture and refile remain independent.
See [integration setup and contract](integration/README.md) and
[verification results](integration/verification.md). This includes a development
receiver, separate from the production PostgreSQL API above.

## Roadmap

### Pre-1.0 polish

- [ ] Sync `MARKETING_VERSION` from the git tag in CI
- [ ] "Reveal in Finder" complement to the open-file button in the panel header
- [ ] Inline warning in Settings when the chosen hotkey conflicts with a known macOS shortcut (⌘Space, ⌘Q, etc.)

### Beyond

- [ ] Per-tag default file destinations (e.g. `#work` writes to `work.md`)
- [ ] Configurable line format (`- [ ]`, `* TODO`, etc.)
- [ ] Double-tap-Option as an opt-in hotkey (requires Accessibility access)
- [ ] Code signing + notarization in CI
- [ ] Homebrew cask
- [ ] Sparkle auto-updates

## Build from source

Requires Xcode 16+, Node 20+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
npm ci --prefix editor-web
npm run build --prefix editor-web
# Local Debug signing identity (one-time setup):
bash scripts/make-signing-cert.sh
xcodegen generate
open QuickCapture.xcodeproj
```

Rerun `xcodegen generate` whenever Swift files are added or removed (the `.pbxproj` has a static file list).

After changing editor sources, run `npm run build --prefix editor-web` and commit the updated `editor-web/dist/editor.js` alongside the source.

Run checks with:

```sh
npm run typecheck --prefix editor-web
npm test --prefix editor-web
xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture test
```

## License

See [LICENSE](LICENSE).
