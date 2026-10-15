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

Native record edits/deletions and incoming synchronisation remain unimplemented.
Reminder dates do not trigger notifications yet. Editor-web sources are unchanged.
