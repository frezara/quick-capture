# Quick Capture

A tiny macOS menu bar app: press a global hotkey, type a thought, hit Enter — it's appended as a `- [ ]` line to a markdown file (typically an Obsidian inbox).

Built for the moment when a thought hits you mid-task and you don't want to context-switch into a notes app to jot it down.

## Features

- Configurable global hotkey (default `⌥T`)
- Appends to any markdown file — works great with Obsidian vaults
- `#tags` route entries under `## tag` headings; untagged items go under `## Quick capture`
- `#cal` interprets the input as a natural-language calendar event ("call Seb tomorrow at 2pm for 30 min") and opens an `.ics` in your default calendar app
- Optional Obsidian-Tasks-compatible timestamp on each capture
- Pick your input font (System / Rounded / Serif / Monospaced)
- One-click "open my capture file" — prefers Obsidian if installed, falls back to the system default

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

Press **⌥T** (or whatever you've configured) to summon the capture panel anywhere in macOS. Type your thought and press Enter — it's appended to your file and the panel disappears.

- Add `#tag` after the text (Tab to focus the tag field) to route the entry under a `## tag` heading.
- `#cal` turns the input into a calendar event instead of a todo — open `.ics` in Calendar, BusyCal, etc.
- Press **⌘F** while the panel is open to jump to the capture file (Obsidian-first).
- Click the menu bar icon for **Settings** — file path, hotkey, timestamp, and input font are all configurable.

## Roadmap

- [ ] Per-tag default file destinations (e.g. `#work` writes to `work.md`)
- [ ] Configurable line format (`- [ ]`, `* TODO`, etc.)
- [ ] Double-tap-Option as an opt-in hotkey (requires Accessibility access)
- [ ] Launch at login
- [ ] Code signing + notarization in CI
- [ ] Homebrew cask
- [ ] Sparkle auto-updates

## Build from source

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open QuickCapture.xcodeproj
```

Rerun `xcodegen generate` whenever Swift files are added or removed (the `.pbxproj` has a static file list).

## License

See [LICENSE](LICENSE).
