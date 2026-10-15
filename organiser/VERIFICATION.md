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

Native Swift and editor-web sources are unchanged in this milestone; their prior
regression suite has not been rerun. Automatic capture delivery and native sync
remain unimplemented. Reminder dates do not trigger notifications yet.
