# Home organiser — backend foundation

This is the first PostgreSQL-backed organiser. It stores captures, tasks, notes,
bookmarks, manually entered calendar events, and reminder dates. The browser can
create, edit, complete, delete, search and filter records. Attachments are stored
in PostgreSQL alongside their item, in the same transaction.

**Connected to new native capture-box entries.** Configure the API URL and
access key in Quick Capture Settings → Automatic organiser delivery. New entries
are retained in a durable local queue and delivered automatically; `#cal` creates
an internal event rather than opening an external calendar app. Existing explicit
spool handoff remains available under Legacy development spool. Linked items now
synchronise edits, completion and deletion in both directions. Organiser-created items now import into the active Mac inbox. The Calendar tab
provides a month view and date-based creation; native reminder notifications can
be enabled in Quick Capture Settings. Editor-created unmarked entries and bulk
historical import remain outside automatic intake.

## Local setup

Docker with Compose is required. From the repository root:

```sh
bash organiser/setup.sh
```

Open <http://127.0.0.1:8787>. Read the access key from
`organiser/secrets/organiser_token` and paste it into the login form. The key stays
in browser memory, not local storage. Locking or reloading forgets it.
`setup.sh` creates a random database password and a separate random access key
only when absent. Keep both out of Git. The host secret directory is private;
the token file is readable by the unprivileged app container through a Docker
secret mount.

PostgreSQL has no published port. The web service binds only to loopback. For
remote devices, use an SSH tunnel initially; do not publish unencrypted HTTP to
the LAN. A later TLS endpoint can replace the tunnel.

## Deploy to the home Linux server

The verified server is SSH alias `remote`, `fahad@192.168.0.50`. Its existing app
directory is `/home/fahad/apps`, not `/app`. Deploy committed feature-branch code:

```sh
bash scripts/deploy-organiser.sh remote /home/fahad/apps/organiser
ssh -N -L 127.0.0.1:8788:127.0.0.1:8787 remote
```

Open <http://127.0.0.1:8788>. Retrieve the **server's** key over SSH:

```sh
ssh remote cat /home/fahad/apps/organiser/organiser/secrets/organiser_token
```

Deployment transfers a Git bundle over SSH, clones `feat/home-organiser` on first
install, and requires a clean checkout and fast-forward update subsequently. It
needs no GitHub credentials on the server and never transfers your Mac's secrets.
Before updating an existing install, it creates a database backup. It builds the
app and waits for PostgreSQL and API health checks. A failed update reports an
error; it does not remove volumes or pretend to roll back database changes.

For an ordinary GitHub clone with working server credentials, `bash
organiser/update.sh` backs up, pulls the current tracked branch with `--ff-only`,
and rebuilds. The bundle deployment's origin points to its received bundle;
continue deploying from the Mac, or explicitly change origin to GitHub before
switching to server-side pulls.

## Data and recovery

The named Compose volume retains PostgreSQL data across container rebuilds and
restarts. **Never run `docker compose down -v` on a deployment you want to keep.**

```sh
bash organiser/backup.sh
```

Backups include all item, attachment, operation and tombstone records. Copy them
to another machine; files on the same server are not an off-server backup. Keep
the `.env` and access key separately. Restore a dump into a fresh database with
`pg_restore -U organiser -d organiser --no-owner --exit-on-error`; stop the app
while restoring. Do not overwrite the running database as a routine test.

## API contract

All `/api/*` routes require `Authorization: Bearer <access-key>`. `/health`
checks database connectivity and exposes no records. The UI serves content as
text, including Markdown and user-entered HTML. There is no external calendar
integration or fetching of bookmark/image URLs.

- `GET /api/changes?after=0&limit=100` returns changed item identities and revisions,
  ordered by a durable sequence, including tombstones. Save the cursor only after
  applying each returned item. Multiple edits may be coalesced to the latest
  revision; fetch each item by identity for its current document and attachments.
- `GET /api/items?offset=0&limit=200` lists active items; `include_deleted=true`
  includes tombstones. This is pagination, not a sync change-feed.
- `GET /api/items/{uuid}` returns an item and attachment metadata.
- `GET /api/items/{uuid}/attachment?path=…` downloads an attachment.
- `POST /api/operations` accepts `{operation_id, item_id, expected_revision, item,
  attachments?}`. UUIDs are client-generated. Revision zero creates an item.
  The item contains `body_markdown`, `kind`, `section`, `completed`, `deleted`,
  `starts_at`, `ends_at`, `reminder_at`, and `source_url`. Dates need timezones.
- Attachments contain `path`, `media_type`, `data_base64`; omit the field to retain
  files, or provide an empty list to remove them. Limits: 16 files, 26 MiB total
  request including base64, 1 MiB Markdown characters. This API's limits differ
  from the older filesystem-spool contract; a native adapter must account for it.
- A committed operation returns `{operation_id, item_id, revision}`. Exact retry
  returns the original receipt, including after later edits or deletion. Reusing
  an operation UUID with different content returns 409.
- A stale expected revision returns 409 with the current document. No change is
  accepted. The browser retains the draft and shows the server version.
- Deleted identities retain tombstones. Neither old creates nor later mutations
  can resurrect them. Recovery requires an explicit new identity in this version.

The single-owner API serialises mutations with a PostgreSQL transaction lock.
Item, attachments and receipt commit together before acknowledgement. It has no
multi-user authorisation or notification scheduler yet.

## Verification

```sh
bash organiser/test.sh
node --check organiser/static/app.js
```

Tests run against real PostgreSQL in a separate Compose project with a disposable
in-memory data directory. They do not connect to the deployment's database.
The integration suite covers auth, duplicate retries, conflicting operations,
concurrent creates and updates, tombstones, attachment retention/replacement and
validation failures. To release its resources after testing:

```sh
docker compose -p quick-capture-organiser-test -f organiser/compose.test.yml down
```

For browser smoke checks, run `npm ci --prefix organiser` and `npm run test:browser --prefix organiser` with the service running. The check uses an
installed Chrome (`CHROME_PATH` can override its path), reads the local access
key from disk without printing it, creates a uniquely named verification item,
and deletes it afterward (leaving the normal deletion tombstone). Set
`ORGANISER_URL` and `ORGANISER_TOKEN_FILE` to target a separate test deployment.


To test a backup without overwriting the live database:

```sh
bash organiser/verify-backup.sh backups/organiser-YYYYMMDDTHHMMSSZ.dump
```

The verifier restores into a uniquely named temporary database, checks all three
record tables, and removes only that temporary database on exit.


## Native Mac connection and offline delivery

In Settings → Automatic organiser delivery, use `http://127.0.0.1:8788` with the
home server SSH tunnel. Import the server access-key file or paste its contents
and choose Save Access Key. Credentials are stored in macOS Keychain per endpoint,
not UserDefaults. The URL and pause toggle are ordinary preferences.

For scripted first setup, launch a stopped app with:

```sh
open "/path/to/Quick Capture.app" --args \
  --organiser-url http://127.0.0.1:8788 \
  --organiser-key-file /path/to/server_token
```

The key itself never appears in process arguments. HTTPS is required except for
loopback HTTP. Redirects are rejected so credentials cannot follow a redirect.
Install the persistent per-user connection with:

```sh
bash scripts/install-organiser-tunnel.sh remote 8788
```

It starts at login and reconnects after network loss. Stop an old manually started
tunnel using the same port before installation. The service is
`com.quickcapture.organiser-tunnel`; its log is under
`~/Library/Logs/QuickCapture/organiser-tunnel.log`. It binds only to loopback and
requires the SSH alias to work with key-based authentication.

New capture-box entries are queued even while delivery is paused or unconfigured.
Their immutable request and attachment bytes live under
`~/Library/Application Support/QuickCapture/OrganiserOutbox`. The request is saved
before the Markdown entry; a source marker repairs an interrupted confirmation
on launch. A prepared record without a saved source marker is retained, but never
automatically sent. After the first delivery attempt binds a server, changing the
Settings URL cannot retarget that operation. Each server requires its own saved key.

A lost response retries the same operation, so the backend returns the original
receipt. Authentication/validation/conflict failures require attention in Settings;
network failures retry with backoff. Pause stops new attempts after an in-flight
attempt finishes. The queue currently retains delivered snapshots and receipts.

Limits for native capture are 1 MiB UTF-8 text, 16 attachments and 18 MiB combined
attachment bytes (to fit the API's base64 request limit). Exceeding these limits
keeps the draft available and does not silently omit files. Existing history and
new lines typed directly into the editor are not automatically imported yet.

## Synchronising linked items

A successfully delivered capture retains its organiser identity and revision.
Saved Markdown edits, checkbox changes and removal of a linked item queue a new
immutable operation against that revision. Changes made while an operation is
pending are picked up after it is acknowledged. Lost responses retry the same
operation; deleted identities remain tombstones and cannot be recreated by a
stale Markdown copy. Removing an entire file, or losing its `# Inbox` heading,
pauses synchronisation rather than deleting its items.

The Mac also polls linked organiser records, including deleted records. Incoming
changes update the Markdown file with a compare-before-write check. The editor's
existing disk-conflict UI preserves unsaved text. A durable incoming record lets
an interrupted file update finish on restart. The durable change feed also imports previously unseen organiser items into the
active capture file. Import retains their existing identity and revision, without
sending a create operation. Replayed pages do not duplicate Markdown items;
unseen tombstones do not create source lines. Cursor files are scoped to their
organiser endpoint.

Concurrent changes retain both versions. Settings → Automatic organiser delivery
shows the organiser version and offers **Use organiser version** or **Keep local
version**. Keeping local creates a fresh operation against the displayed remote
revision; a further server change causes another conflict. A remote deletion can
be accepted but cannot be overwritten with the old identity. Copy any wanted text
into a new capture to create a new item.

Archive and refile are moves. The scanner follows a known identity into its
archive or configured refile target, without importing other target contents.
A refile destination hint is saved before moving, so an interrupted move cannot
become a deletion. Duplicate or nested linked identities pause that item's sync
until its Markdown markers are unambiguous. Keep the hidden `qc-source` marker
with its item: removing the marker detaches the text and is treated as removal
of the linked item.

Incoming attachment bytes are downloaded before applying the item and checked
against a stable server revision. A path collision with different local bytes
requires attention rather than overwriting a possibly shared file. Unreferenced
local attachment files are not automatically deleted. Organiser category, event,
reminder and URL metadata survive ordinary Markdown edits.

Each worker cycle reads up to 20 feed entries and checks one linked record as a
fallback. It normally runs every three seconds plus network time. The pause toggle
stops outgoing delivery and incoming polling. Existing delivery records upgrade in
place. Server schema version 2 adds and backfills a durable change index in one
transaction; deployment backs up the database first.

## Calendar and reminder notifications

The Calendar tab displays a month grid in the browser's local timezone, including
multi-day events. Select a date to create an event at 09:00, then adjust its times.
Use the arrows or Today to navigate; select an event to edit it. The Reminders tab
includes reminder dates on any item type, not just records categorised as reminders.
The browser refreshes the list every ten seconds without replacing an open draft.

In Quick Capture Settings, choose **Enable Reminder Notifications** and allow the
macOS notification prompt. The next 64 pending reminders are scheduled with the
system and can fire while Quick Capture is closed or offline. Opening the app
replenishes that schedule. Reminder edits replace pending notifications; completion
and deletion cancel them after sync. Previously unseen overdue reminders notify
once when the app next syncs. Notifications open the organiser when selected.
Disabling notifications removes pending local reminders but retains reminder dates.

Offline devices cannot know about remote changes until the connection returns;
an already scheduled reminder can therefore still fire while disconnected after
another client has completed or deleted its item.
