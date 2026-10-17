# Today view: scaffold, focus, daily notes and rollover

Research date: 2026-10-17. Input for the planning/grill session on the "B · Today" view: today's schedule on the left (time spine, now-line, events), the existing CodeMirror editor on the right where the mockup had a grouped todo list. Four questions: (1) should the Today editor have permanent headings, (2) should it open with the editor focused, (3) how do daily notes differ from the inbox and where do they live, (4) how should undone todos roll over to the next day. The user's constraint is to keep it useful and not over-feature it. Recommendations are product judgements unless a source is cited.

## What Quick Capture already has

- **One capture file, one warm editor.** `MainPanel` holds a single `WKWebView` bound to `loadedFileURL`, which is initialised to the capture file ([MainPanel.swift](../../Sources/QuickCapture/MainPanel.swift), `init`). `reconcileEditorFile` already re-points the editor at a different file safely: flush the pending save, stop the watcher, push the new content, start watching again. A Today view that edits a different file can reuse that sequence. A web view has only one superview, so Today and editor mode would have to stay mutually exclusive (the ADR-0004 premise) and the web view would be reparented between them.
- **Disk is canonical, writes are guarded.** Saves go through `FileWriter.write(_:to:ifStillMatching:)`, which refuses to overwrite a file that changed since it was read, then writes atomically and fsyncs ([FileWriter.swift](../../Sources/QuickCapture/FileWriter.swift)). `RefileService` writes the source **last**, so a failure leaves it intact ([RefileService.swift](../../Sources/QuickCapture/RefileService.swift)). Any rollover that touches two files should keep that ordering.
- **The schedule data exists.** `WorkspaceProjection` already builds `eventsByDay` for a one-day span, and items get `starts`/`ends` from organiser metadata keyed by source identity, not from Markdown dates ([WorkspaceModel.swift](../../Sources/QuickCapture/WorkspaceModel.swift)). The calendar day view already draws the hour gutter, the now pill and scroll-to-two-hours-before-now ([NativeCalendarView.swift](../../Sources/QuickCapture/NativeCalendarView.swift), `hourGutter`, `firstVisibleHour`). THEME.md reserves highlighter for "now": today, the now-line, the current time ([THEME.md](../../design/highlighter/THEME.md)).
- **Shortcuts.** `⌥⌘1`–`⌥⌘5` open workspace destinations (Calendar, Projects, Todos, Notes, Saved links); `⌥⌘I/O/U/P` is the right-hand action cluster; `⌥⌘J` re-org, `⌥⌘K` archive, `⌥⌘↑/↓` section jumps ([ShortcutRegistry.swift](../../Sources/QuickCapture/ShortcutRegistry.swift)). CLAUDE.md still lists re-org as `⌘'`; the registry is the source of truth.
- **Gotcha for a split view.** `handleCalendarViewKey` swallows bare letters and arrows (T, N, D/W/M, arrows) unless the first responder is an editable `NSTextView` ([MainPanel.swift](../../Sources/QuickCapture/MainPanel.swift)). A focused `WKWebView` is not an `NSTextView`, so if that routing were reused unchanged in Today, typing in CodeMirror would trigger calendar commands.
- **Identity.** Delivered items carry a `<!--qc-source:…-->` marker. Duplicate identifiers block sending, and archive and refile count as moves, not deletions ([ADR-0008](../adr/0008-source-identity-for-organiser-sends.md), [ADR-0009](../adr/0009-automatic-intake-for-home-organiser.md)). Copying a line copies its identity, which matters for Q4.

## 1. Permanent headings in the Today editor

**What the sources do.** Obsidian Daily notes creates "a note based on today's date" and fills it from an optional user template. Its sample template is just an empty `## Tasks` checklist, and the plugin itself fixes no headings ([Obsidian: Daily notes](https://obsidian.md/help/plugins/daily-notes)). Things 3 has exactly two fixed parts: Today, plus a This Evening section at the bottom ([Cultured Code: Today and Upcoming](https://culturedcode.com/things/support/articles/4001304/)). An org-capture datetree generates only the date headings: year, month, day ([Org manual: Template elements](https://orgmode.org/manual/Template-elements.html)).

**Options.**

- **A. No scaffold.** A blank page under a date H1. Simplest, but rollover (Q4) then has nowhere defined to land, and the app can't tell planned tasks from notes.
- **B. Two fixed sections: `## Tasks` and `## Notes`.** Rollover and "plan this today" write under `## Tasks`; anything goes under `## Notes`. This matches how `FileWriter` already treats `# Inbox` and `## Quick capture`: one enforced heading the code depends on, recreated if missing, everything else free.
- **C. A schedule section mirroring the events.** Rejected. The left panel already is the schedule, and copying events into text makes a second, drifting copy of organiser data.
- **D. A user-configurable template.** Flexible, but it's a settings surface, a template language and a migration problem for a personal app.

**Recommendation: B.** Write `# Saturday 17 October 2026` (or the ISO date) as the H1, then `## Tasks` and `## Notes`. Only `## Tasks` should be load-bearing: recreate it when rollover needs it, as `appendTodo` does for `# Inbox`. Never delete or reorder anything the user wrote. Additional H2s are allowed and take tag hues like any other section.

## 2. Should Today open with the editor focused?

**What the sources do.** Org's daily agenda is a read-only buffer. You work in it by jumping back to the source ("commands to visit the corresponding locations in the original Org files, and even to edit these files remotely") ([Org manual: Agenda Views](https://orgmode.org/manual/Agenda-Views.html)). In org the agenda is a launcher; the text is where you work.

**Options.**

- **A. Editor focused (recommended).** The left panel has little to type into: events are created through capture (`N` → `#cal`), and opening one goes to the editor anyway. Vim users land in normal mode with the cursor at the end of `## Tasks`, so `o` starts a new task immediately. Cost: the calendar's bare-key commands can't be live while the editor has focus (see the gotcha above). That's acceptable, because Today is a single fixed day.
- **B. Agenda focused.** Arrow keys step through events and Enter opens one. Useful only when the day is full of events, and every visit then needs one extra keystroke before you can write, which works against the point of putting an editor there.
- **C. Remember the last focus.** Cheap to build, but the landing becomes unpredictable, and predictable landing is why `show()` always resets to capture.

**Recommendation: A.** Add one press-again chord in the `⌥⌘` namespace to move focus between editor and agenda, following the toggle pattern of `⌥⌘I`/`⌥⌘O`. Don't use Tab or Esc, because vim and CodeMirror own both (ADR-0004 §4). With the agenda focused, ↑/↓ steps events and Enter opens one, using the existing `stepEvent`/open commands. Gate `handleCalendarViewKey` on "agenda has focus", not on `NSTextView`. A Today shortcut fits the destination family: `⌥⌘0`, or move Today to `⌥⌘1` (see open questions).

## 3. Daily notes vs the inbox, and where they live

**What the sources do.** Obsidian uses one file per day, named `YYYY-MM-DD` by default, in a configurable folder; the date format can create subfolders ([Obsidian: Daily notes](https://obsidian.md/help/plugins/daily-notes)). org-journal supports a file per day, week, month or year (`org-journal-file-type`), with `'daily` meaning "each file represent[s] a day". Non-daily files need a `CREATED` property on each entry ([org-journal README](https://github.com/bastibe/org-journal)). Org's datetree keeps everything in one file under year/month/day headings ([Org manual: Template elements](https://orgmode.org/manual/Template-elements.html)). The Logseq journals page could not be fetched (the docs page exceeded the fetch size limit), so it is not used here.

**How they differ.** The inbox is a holding area: unprocessed items with no date, appended by capture, worked down by re-org, archive and refile, and never "finished". A daily note is a record bound to one date: what you meant to do today and what happened. It closes when the day ends and is rarely edited afterwards. The two have different lifecycles, so they shouldn't share a file. Putting a `## Today` section inside the capture file would mix them up: archive would strip done items out of the day's record, and there would be no history.

**Options on disk.**

- **A. One file per day in a folder next to the capture file** (for example `daily/2026-10-17.md`). This is the Obsidian and org-journal default, so the vault keeps working in Obsidian with no conversion. Each day's file is small. Rollover reads one closed file and writes one new file. The editor re-points with the existing `reconcileEditorFile` sequence, and the watcher follows it. Cost: one more folder setting, and history is spread over many files.
- **B. One journal file with `## YYYY-MM-DD` headings** (datetree style). One file, easy to grep. But date H2s clash with the capture file's rule that H2s are sections with tag hues, the file grows without limit, and every keystroke saves the whole history. This is the format most exposed to `ifStillMatching` drift with Obsidian open.
- **C. A `## Today` section in the capture file.** No new files, but it mixes the two lifecycles as described above.

**Recommendation: A**, with the filename in Obsidian's default `YYYY-MM-DD.md` and the folder defaulting next to the capture file. How it relates to the rest of the app:

- Capture still goes to the inbox. Today never changes which file is the capture file (CONTEXT.md, **Capture file**).
- Add **one** new move: "plan for today", which moves an inbox item's subtree into today's `## Tasks`. It reuses `RefileService`'s verify → write target → write source last pipeline with a different destination writer. This is the main way work gets from the inbox into a day. Today's note is not a refile *target* in Settings (targets are folders holding `inbox.md`), so the target list stays as it is.
- Moving an item out of Today and back to the inbox, or onward to a project, is ordinary refile, if refile is enabled on daily files.

## 4. Rollover of undone todos

**What the sources do.**

- **View-only forwarding (org-agenda).** A scheduled item appears on its date, and if it isn't done, "the task is automatically forwarded until completed" ([Org manual: Deadlines and Scheduling](https://orgmode.org/manual/Deadlines-and-Scheduling.html)). No text moves: `org-scheduled-past-days` is the "number of days to continue listing scheduled items not marked DONE", and overdue items are prefixed `Sched.%2dx:` "due to automatic rescheduling of unfinished items for the following day" (`org-agenda-scheduled-leaders`). Past-scheduled warnings "are always turned off when the item is DONE" (`org-agenda-skip-scheduled-if-done`) ([org-agenda.el defcustoms](https://cgit.git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org-agenda.el)). Obsidian Tasks does the same with query blocks (`not done`, plus dates relative to today), and `happens` matches start, scheduled *or* due ([Tasks: Filters](https://publish.obsidian.md/tasks/Queries/Filters)). That needs `⏳`/`📅`/`🛫` date fields on each task ([Tasks: Dates](https://publish.obsidian.md/tasks/Getting+Started/Dates)).
- **Move (org-journal default).** When a new day's file is created, org-journal carries over the previous day's TODO items (`org-journal-carryover-items`, default `TODO="TODO"`, `""` disables it). The default `org-journal-handle-old-carryover` then removes the old entries, though the README shows a variant that tags them instead ([org-journal README](https://github.com/bastibe/org-journal)).
- **Migration by hand (Bullet Journal).** At the end of the month you strike out what isn't worth doing and turn "•" into ">" for what you carry forward. Rewriting is meant to be work: "If an entry isn't even worth the effort to rewrite it, then it's probably not that important" ([Bullet Journal: Migration](https://bulletjournal.com/pages/migration), [Migration 101](https://bulletjournal.com/blogs/faq/migration)).
- **No rollover (Things 3).** A to-do appears in Today when "the start date, deadline, or repeating rule … matches today's date". For what's left over, the guidance is to "reschedule the remaining items for another day" yourself ([Cultured Code: Today and Upcoming](https://culturedcode.com/things/support/articles/4001304/)).

**Options for Quick Capture.**

| Model | Writes | Fits "editor on the right"? | Main risk here |
|---|---|---|---|
| A. View-only (org-agenda) | none | No. Overdue items live in old files, so the right pane would need a second, read-only list or the editor would have to merge files | Needs per-task date syntax, which is the Tasks/org machinery the user wants kept out |
| B. Move on new day (org-journal) | two files (new note, then old note) | Yes | Changes history: yesterday's note no longer shows what was open. Two writes, so it must follow refile's order and `ifStillMatching` |
| C. Copy on new day, old file untouched | one new file | Yes | Duplicated text. The copied line also carries a duplicate `qc-source` identity (ADR-0008) |
| D. Migrate on request (BuJo) | one or two files | Yes | Friction, and it fails silently if you forget to run it |

**Least destructive: C, copy on create.** When today's note doesn't exist yet and Today is opened, create it in one atomic write. Fill `## Tasks` with the unchecked top-level subtrees (item, attachments, children, using the existing subtree span rule) from the **most recent earlier** daily note. Nothing else is written. Yesterday's file is never touched, so it stays an accurate record of what was open when the day ended. Only the newest earlier note is read, so an item carried for five days doesn't multiply: each day copies from the day before. Creating a file that doesn't exist can't overwrite anyone's edits, and no watcher is pointed at it yet. There's no midnight timer: rollover runs lazily on the first open of a new date, which also handles the Mac being asleep and days skipped.

Two refinements, with the trade-offs they bring:

- **Strip `qc-source` markers from the copies.** Otherwise yesterday's line and today's line share an identity and sending is blocked (ADR-0008). If daily-note items are delivered to the organiser, though, a copy becomes a *new* organiser item each day, and any reminder stays on the old one. If daily items do sync, **B (move, written in refile order)** is what preserves identity, consistent with ADR-0009 treating refile and archive as moves. This is the main fork for the grill session.
- **Copy only, don't migrate.** An optional "drop it" (BuJo's strike-out) is just deleting the line today. No new syntax is needed.

Inbox items never roll over: the inbox doesn't expire. Rollover applies only to items in daily notes.

## Keep out (to avoid over-featuring)

- Per-task date syntax (`⏳ 📅 🛫`), a query language or ```` ```tasks ```` blocks, and overdue counters like "Sched. 3x". The `➕` created suffix stays as it is.
- A template engine or configurable scaffold. Two fixed sections only.
- Events copied into the note as text. The left panel is the schedule.
- A midnight background rollover job, weekly/monthly review flows, and BuJo-style `[>]` migrated states (they aren't GFM checkboxes and the editor would need a new widget).
- A This Evening section, a multi-day agenda in Today, a past-notes calendar or heatmap, backlinks.
- Dragging todos onto the time spine (time-blocking), and natural-language dates on todos outside `#cal`.
- A separate Today todo list widget. The editor is the list.

## Open questions for the grilling session

1. Are daily-note items delivered to the organiser automatically like capture-box entries? This decides between copy (C) and move (B) for rollover.
2. Daily folder: next to the capture file (`daily/`), inside the Obsidian vault's existing Daily notes folder, or a Settings path? Is the filename strictly `YYYY-MM-DD.md`?
3. Section names: `## Tasks` / `## Notes`, or `## Today` / `## Log`? Do they take tag hues, or stay neutral as `## Quick capture` does?
4. Shortcut: Today at `⌥⌘0`, or does Today become `⌥⌘1` and the others shift? Which chord toggles editor/agenda focus?
5. Is "plan for today" (inbox → today's `## Tasks`) wanted in v1? Is it a refile-picker entry or its own chord? Should the capture box get a `#today` route, or is that a second way to do the same thing?
6. Can you open past days in Today (‹ ›), or does Today show today only and past notes open as plain files?
7. Does re-org/archive (`⌥⌘J`/`⌥⌘K`) apply inside daily notes? Archive would strip the day's record, so the suggestion is re-org yes, archive no.
8. Should the left panel also show inbox items that have organiser dates but aren't calendar events (reminders)?
