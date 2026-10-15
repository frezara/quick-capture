# Verification — 15 October 2026

- Real PostgreSQL 18 integration suite: **10 tests passed**. Covers auth,
  idempotent replay, changed-content operation reuse, optimistic conflicts,
  concurrent create/update, deletion tombstones, attachment replacement and
  retention, invalid input, app restart, and transaction rollback after an
  injected database error while storing an attachment.
- Headless Chrome: login, creation, editing, completion, server conflict with
  local draft preservation, safe text rendering and 390px layout passed.
  Desktop and mobile screenshots inspected.
- Compose app and PostgreSQL health checks pass locally and on the Linux server.
- Backup restored successfully into a separate temporary PostgreSQL database;
  the restored database contained the expected item and four operation receipts.
- Shell syntax, JavaScript syntax, Python compilation and Git whitespace checks
  pass.

One non-failing test warning: the installed Starlette test client deprecates its
httpx adapter in favour of httpx2. This affects the test harness, not API runtime.

Native automatic-delivery milestone: **239 Swift tests passed, one opt-in latency
test skipped**. The 13 new outbox tests cover crash recovery, duplicate source
markers, frozen attachments, immutable retries, bound destinations, pause and
missing credentials, rejected authentication, bad receipts, integrity failures,
input limits, old-history exclusion and internal calendar events. A live test
against the Linux PostgreSQL service delivered an attachment and retried after a
simulated lost acknowledgement, receiving the same original receipt. Its test
item was deleted afterward.

Bidirectional linked-item milestone: the full Swift suite executed **253 tests**,
with **252 passed and one opt-in latency test skipped**. The organiser suite now
contains 27 tests, including an opt-in live PostgreSQL round trip. It covers native
edits, completion and deletion on one identity; immutable pending operations;
incoming edits, completion and deletion without echo; explicit conflict choices;
tombstone non-resurrection; duplicate identities; archive/refile moves; missing
and truncated files; incoming crash recovery; metadata preservation; attachment
collisions/retention; and upgrading previously delivered records.

The live native test ran against a disposable PostgreSQL 18 Compose deployment
on loopback port 18789, not the home server. It verified lost-acknowledgement replay,
an outgoing Mac edit, incoming organiser text/completion with an attachment, and
an outgoing deletion acknowledged at revision 4. All 27 organiser tests passed
with the live test enabled. Ad-hoc signing and isolated DerivedData were used
because the configured local development signing key failed in this session.

Existing editor persistence tests cover preserving unsaved text on an external
disk update; the new incoming path uses that same file-watcher boundary. No native
UI automation was performed for the new Settings conflict controls.

## Home-Mac completion work

- PostgreSQL suite: **12 tests passed**, including migration/backfill of existing
  items into schema 2, change-feed pagination, idempotent retries and tombstones.
- Swift suite: **256 tests executed, 255 passed, one opt-in latency test skipped**,
  with the live PostgreSQL test enabled against the disposable loopback service.
  Incoming creation imports once, retains the organiser identity/revision, allows
  a Mac edit on that revision, and accepts a subsequent organiser deletion.
- Calendar date tests: **3 passed**, including DST, multi-day midnight boundaries,
  month/year navigation data and zero-duration events.
- Browser smoke test passed creation/edit/conflict/completion plus calendar event
  creation, month navigation, safe text rendering and narrow-width layout. The
  desktop calendar screenshot was inspected.
- Home-Mac launch agent installed and health checked. Terminating its SSH child
  was followed by an automatic reconnect and a successful health response.
- Reminder date parsing and completed/deleted-item exclusion are covered by Swift
  tests. macOS permission was enabled in the installed app, and the user
  confirmed seeing the scheduled “Home Mac notification verification” banner.

The work Mac and iPhone are explicitly deferred. Browser-created organiser items
now import into the active Mac inbox. The editor bundle is unchanged.

Home deployment on 15 October 2026:

- Server code and schema 2 deployed successfully, with a database backup before
  migration; app and PostgreSQL health checks passed.
- A deployment-script bug was found by checking the actual container age: the
  backup process consumed the remote shell's remaining input. Redirecting backup
  stdin from `/dev/null` fixed it; the rebuilt server's `/api/changes` was checked.
- The signed native build replaced `~/Applications/Quick Capture.app`, using the
  existing Apple Development identity. The previous app, inbox, and outbox were
  backed up before replacement.
- The running installed app imported a live verification calendar event exactly
  once and retained its reminder instant. With the managed tunnel stopped, an
  edit to that test item queued locally; after reconnect, the same operation was
  acknowledged at revision 2 and the server contained the edited text.
- A post-migration production backup restored into a separate temporary database.
- Native notification permission was enabled and confirmed in System Settings.
  The user confirmed the test reminder appeared. The verification item was then
  tombstoned at revision 4; the installed app removed its inbox marker.
- System Settings lists Quick Capture under Open at Login. The Settings toggle
  now refreshes its displayed value after registration.
- The backup restore verifier also checked schema 2 change-feed revisions against
  every restored item successfully.


## Native workspace foundation — 15 October 2026

The product direction is now native Quick Capture as the daily interface. The
web organiser remains an optional database inspection interface. Work and
priority filters are deferred at the user's request.

- Added same-panel native Calendar, Projects, Todos, Notes and Saved Links views,
  with visible navigation and ⌥⌘1–5 shortcuts. Calendar supports day/week/month,
  period navigation and Today. These are read views; the existing Markdown
  editor remains the editing surface. Projects currently groups explicit
  `#project/name` tags; dedicated project editing and Chrome capture are deferred.
- Swift suite executed 260 tests: 258 passed, two opt-in tests skipped. Coverage
  includes Markdown projection, note classification, explicit project tags,
  code-fence exclusion, calendar midnight/zero-duration boundaries and shortcut
  routing. Signed native build and Git whitespace checks passed.
- Installed-app Computer Use checks opened all five destinations, switched
  calendar day/week modes, inspected the month layout, read existing todos and
  notes, and moved from editor to calendar. A temporary unsaved capture draft
  survived navigation and return via the Capture button, then was cleared
  without being saved. The original app was backed up before replacement.
- Final build also handles the configured summon chord locally while a native
  view has focus, and hides the capture surface from accessibility while that
  view is open. These final focus changes were compile-checked; UI automation
  could not reattach after the last restart because no panel was open.


## Cal dropdown Enter regression — 15 October 2026

Keyboard selection in an empty tag field previously lost the selected Cal row;
a partial Cal match also submitted immediately instead of revealing the preview.
The capture submission decision now records explicit arrow/Tab selection and
accepts Cal for preview before invoking the save callback on the next Enter.
Ordinary blank-tag capture still saves untagged; ordinary tag completion still
saves in one press. Clicking Cal and typing its full name retain their preview.

The regression test failed before the fix with `save(nil)` / `save(cal)` instead
of `previewCalendar`, then passed. Full Swift suite: 262 executed, 260 passed,
two opt-in tests skipped. Signed build succeeded and was installed. Native UI
verification selected Cal using arrows from an empty tag field: first Enter
showed the event preview with no disk write; second Enter produced exactly one
delivered event with the previewed start/end. The test event was tombstoned afterward.
