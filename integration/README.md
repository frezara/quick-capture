# Quick Capture organiser handoff

Quick Capture now has an explicit **Send to organiser** action in the editor.
It copies the saved item subtree, keeps the local source editable, and delivers
an immutable snapshot through a local spool folder. Existing capture, `#cal`,
and refile remain independent. This is a local development integration, not a
production organiser or a device-sync implementation.

## Run the local receiver

Build the app using the repository README, including rebuilding the editor bundle
and regenerating the Xcode project. In Settings → Organiser, choose a dedicated
local spool folder and copy the Workspace UUID. Run the receiver with that UUID:

```sh
python3 scripts/organiser_receiver.py \
  --spool /tmp/quick-capture-spool \
  --storage /tmp/quick-capture-receiver \
  --workspace YOUR-WORKSPACE-UUID
```

The receiver requires Python 3.9+ and only its standard library. These temporary
paths are convenient for testing, but disappear with temporary-file cleanup; use
persistent private folders for development data you need to keep. Quick Capture's
own source and snapshot bundles remain independent of these paths.

Select the same spool folder in Settings, enable delivery, put the editor cursor
on an item, and click **Send to organiser**. The receiver writes its capability
file at startup; without it, requests remain Waiting for organiser. `--once` scans
once and exits, which is useful for tests. A workspace mismatch needs attention;
the receiver will not silently repurpose an existing spool for another workspace.

Delivery History is accessible from the editor and Settings. It includes Retry,
acceptance receipts, and Resume Import for interrupted staging. Disabling delivery
pauses future attempts; an attempt already executing can finish. Changing the
folder or workspace affects new sends only. Old sends retain their destination.

## Source and handoff identities

The first send adds `<!--qc-source:UUID-->` to the selected item's first line,
saves it, and then snapshots the subtree. The editor hides the comment in live
preview. User-authored text, child items, line breaks, and attachment links are
preserved; the identity comment is included in the saved snapshot. Legacy `qc:`
creation tokens retain their existing meaning.

Normal Send reopens the source item's existing handoff history. Retry never creates
an ID. **Send as new item** freezes another snapshot, even if the source was edited.
When the same identifier occurs more than once in the active capture file, ordinary
Send opens history and refuses to guess; **Send this copy as new** assigns the
selected copy a distinct source ID. Removing a marker makes that item new and can
therefore create another organiser item. We do not scan independent refile targets
for copied markers, and do not infer identity from filenames, text or timestamps.

Snapshot source identity, capture ID, operation ID, and organiser item ID are
separate concepts. The receiver deduplicates by workspace and capture ID and also
retains operation results. It does not deduplicate by the Markdown source comment.

## Contract and canonical bytes

See `request-v1.schema.json`, `receipt-v1.schema.json`, `error-v1.schema.json`, and
`capabilities-v1.schema.json`, with deterministic examples in `fixtures/`.

The wire request is `{ "payload": { "workspace_id", "operation_id", "capture" },
"payload_sha256" }`. The capture has the handover's v1 envelope fields; optional
fields are omitted when absent, not encoded as null. Empty title is permitted.
There is no automatic kind inference or date interpretation.

Canonical payload encoding is UTF-8 JSON with recursively sorted keys, no
insignificant whitespace, unescaped Unicode and forward slashes, standard JSON
string escaping, and integer numeric fields. There are no floating-point fields.
The lowercase SHA-256 covers those exact encoded `payload` bytes, including every
attachment digest and all metadata. The outer digest does not hash itself. The
Swift and Python fixture test verifies the same canonical bytes and digest.

Two explicit v1 extensions preserve source Markdown while making attachments
portable: each attachment includes `source_path` (the original relative Markdown
link) alongside `relative_path` (its safe generated bundle path), and the capture
has `omitted_attachments` containing only explicitly approved omitted local links.
Receivers must use this mapping, not resolve original links against arbitrary local
files. The body is not rewritten to conceal a missing file. An omission is visible
in metadata and does not claim the missing bytes were delivered. Remote HTTP(S)
image URLs stay links; no fetching occurs.

Runtime limits use UTF-8 bytes: body 1 MiB; 16 attachments, 64 MiB each and 128 MiB
total; 16 omissions; title 4 KiB, URL 8 KiB, original filename 1 KiB, media type
128 bytes, relative paths 4 KiB. Manifest/request files are bounded to 2 MiB,
receipts to 16 KiB, capabilities/errors to 4 KiB. JSON Schema string length is in
characters, so runtime byte limits are additionally authoritative. Attachment
capture currently recognises the inline image-link syntax used by the existing
screenshot editor; this is not a general Markdown attachment importer.

The receiver rejects unsafe or escaping paths, symlink traversal, nonregular
files, invalid checksums, wrong workspaces, and unsupported versions. Captured
content is never executed. Validation errors require attention and preserve local
data. Temporary absence/I/O errors retry with capped backoff and jitter; manual
Retry preserves IDs and bytes. No authentication tokens or content enter logs.

## Receiver obligations

Acceptance means the content files and a transaction containing the inbox record,
payload digest and durable receipt have committed. Only then may the receipt be
published. The fixture uses its own SQLite database and ordinary files; Quick
Capture never writes it directly.

Same capture/operation and digest returns the original receipt. A reused identity
with changed payload conflicts. Acceptance records survive moves and logical
deletions: a retried create must not restore an item. A crash after commit but
before receipt publication is repaired by returning that persisted receipt.
Deduplication records have no automatic expiry. Transmission is at least once;
exactly-once network transmission is not claimed. The development fixture's database
records deletion with a tombstone; it is not a complete organiser UI.

Requests are published as complete directories beneath `requests/CAPTURE-ID`;
receipts are `receipts/CAPTURE-ID.json`. Receiver errors are under `errors/` and
include the request digest. Receipts must match contract version, workspace,
operation, capture and payload digest before the sender marks Delivered. No
open-item URL support is exposed in this version.

A receipt proves local receiver acceptance only. Real organiser integration and
availability on a second Mac or iPhone require a future end-to-end test.

## Storage, recovery and rollback

Quick Capture owns:

```text
~/Library/Application Support/QuickCapture/
  Handoffs/
    queue.sqlite              # transactional delivery state and source mapping
    staging/SOURCE-ID[-new]/  # frozen import intent; resumable copied bytes
    bundles/CAPTURE-ID/       # content.md, manifest.json, attachments/
  Recovery/DRAFT-ID/          # failed local save/import: content.md and draft.json
```

The queue never contains the only copy of note content. An intent fixes the
handoff ID and body before attachment copying. Complete bundle publication
precedes queue registration; startup scans complete manifests to repair a missing
row. Invalid bundles are retained, excluded from delivery, and reported. Incomplete
staging is retained for Resume Import. If it cannot be parsed, inspect the private
folder manually; startup does not erase it. Resuming uses the intent's original
body, copied bytes, and destination even when the source later changes or moves.
Missing source attachments still require explicit omission approval.

Files use mode 0600 and private newly created directories 0700. Writes use
same-filesystem staging, file `fsync` plus macOS `F_FULLFSYNC`, atomic publication,
and parent-directory `fsync`. SQLite uses WAL, synchronous FULL, and fullfsync.
Unsupported flush operations fail closed. These are the actual API boundaries,
not a certification against every filesystem, storage controller or hardware
power-loss behaviour. Use a local Mac filesystem; cloud-synced/network folders
are not supported spool transports.

Source/editor writes and copied local attachments now flush file/device caches
and their containing directory before success is reported. A failure after writing
but before flush confirmation is explicitly uncertain; inspect the file before
repeating a local save.

Ordinary Escape/click-away still discards ordinary capture drafts. Failed local
saves retain recoverable text and available attachments. The capture box offers
Restore/Discard; a restored draft is removed after successful save. If even the
recovery write fails, automatic dismissal and quitting are blocked until save or
explicit discard. Screenshot imports first persist a recovery intent. Existing
local screenshot copying remains synchronous; organiser copying/hashing is off the
UI thread. Recovery never automatically creates an organiser item. A crash after
a source save but before recovery cleanup can leave a recovery candidate for an
already saved item: inspect before restoring it.

No source-history migration or bulk forwarding occurs. New local manifests and
journal schema are v1; unsupported versions stop delivery without deleting data.
To roll back, disable integration and retain the Handoffs and Recovery directories.
The old app can still read the Markdown source. Do not remove source IDs or queue
files as a casual cleanup: that removes duplicate-recognition/recovery evidence.
No automatic retention cleanup is implemented.

## Refile safety

Refile still copies attachments, appends the subtree to the selected target, then
removes it from the source. Existing target bytes, including trailing newlines,
are preserved. A nonempty target without the required `# Inbox` heading is refused
rather than rewritten. Target appends use `O_APPEND`, a cooperative lock, flushes,
and identity checks; target replacement or a later source-removal failure reports
an uncertain outcome. Inspect both files before repeating it.

There is no transaction across two arbitrary Markdown files and no receipt from a
coding agent. Non-cooperating external writers can replace/truncate files despite
advisory locking, including after the final check. The app does not claim immunity
to all such races or exactly-once append. Refile never enters the organiser queue.

## Verification

See [verification.md](verification.md) for measured results, test coverage and
explicit limitations. Reproduce the ordinary checks with:

```sh
npm run typecheck --prefix editor-web
npm test --prefix editor-web
npm run build --prefix editor-web
python3 scripts/check_handoff_contract.py
python3 -m unittest discover -s scripts -p test_organiser_receiver.py -v
xcodegen generate
xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture \
  -destination 'platform=macOS' -derivedDataPath /tmp/quick-capture-integration-build \
  CODE_SIGNING_ALLOWED=NO test
```

The contract checker validates only the JSON Schema vocabulary used by these
fixtures; it is an offline development check, not a general-purpose JSON Schema
implementation. The receiver separately enforces its runtime validation rules.
