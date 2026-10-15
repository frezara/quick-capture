# Home organiser — backend foundation

This is the first PostgreSQL-backed organiser. It stores captures, tasks, notes,
bookmarks, manually entered calendar events, and reminder dates. The browser can
create, edit, complete, delete, search and filter records. Attachments are stored
in PostgreSQL alongside their item, in the same transaction.

**Not yet connected to the native Quick Capture app.** Its existing explicit
spool handoff remains unchanged. Automatic native capture delivery, bidirectional
sync, historical import, reminder notifications and a full calendar layout are
subsequent work. The category tabs and date fields are a foundation, not a claim
that those features are finished.

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
