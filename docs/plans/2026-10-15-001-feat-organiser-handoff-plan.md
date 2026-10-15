---
title: "Durable one-way organiser handoffs"
status: implemented-with-documented-verification-limits
date: 2026-10-15
type: feat
---

# Durable one-way organiser handoffs

## Outcome and scope

Extend Quick Capture with explicit Send to organiser from editor mode. A send
copies a saved item subtree into a durable, immutable handoff; local editing and
refile remain independent. Delivery runs asynchronously and survives restarts,
retries, and lost acknowledgements without duplicating receiver records.

Authority: `quick-capture-integration-handover.md` v1.1 and the five product
decisions accepted during the 15 October planning interview. See ADR-0007 and
ADR-0008. The user authorised all six stages on 15 October 2026. Implementation
is on `feat/organiser-handoff`; see `integration/README.md` and
`integration/verification.md` for the implemented contract, results and limits.

The first milestone includes text, URLs, existing screenshot attachments, a
durable queue, one local spool adapter, and a development receiver. It excludes
the organiser product itself, device sync, a new authentication system, capture-box
sending, arbitrary selection sending, historical import, and general file import.
Keep existing `#cal` behaviour; calendar interpretation is not part of handoff.

## Inspection evidence

| Existing code | Reuse and constraint |
| --- | --- |
| `MainPanel.swift`, `editor-web/src/editor.ts` | Preserve warm editor, editor save acknowledgement, subtree selection, bridge, and exclusive panel modes. Add a separate send action. |
| `FileWriter.swift` | Preserve ordinary checkbox/tag/timestamp formatting. Items currently lack stable IDs; old `qc:` comments are creation tokens. |
| `RefileService.swift` | Preserve move semantics: copy attachments, write destination, remove source. Current target read/replace can lose concurrent edits; uncertain partial success can duplicate on retry. |
| `AttachmentStore.swift` | Reuse existing attachment/link conventions, not synchronous copying as a durable snapshot implementation. |
| `CaptureView.swift`, `AppDelegate.swift` | Failed submits retain visible text, but full dismissal clears it. Add failure recovery without restoring every intentionally dismissed draft. |
| `AppState.swift`, `SettingsView.swift` | Reuse preference patterns. UserDefaults is not the delivery journal; no existing transactional delivery store was found. |
| `project.yml`, `QuickCapture.entitlements` | Swift/AppKit/SwiftUI plus CodeMirror; macOS 14+. Entitlements file is empty. Debug uses a local signing identity; distribution and App Groups are not assumed. |

No receiver or latency instrumentation was found in this repository. The companion
`markdown-library-implementation-plan.md` was not present. A receiver elsewhere
is not ruled out; the local fixture allows work without it.

## Accepted behaviour

1. Send selects the saved subtree using refile's current selection rules. Flush
   editor changes successfully before taking the snapshot. Source remains in place.
2. First send may insert a stable hidden source identifier. Use a new namespaced
   comment, provisionally `<!--qc-source:UUID-->`, distinct from legacy `qc:` tokens.
   Hide it in live preview and preserve it through editor operations and refile.
3. Source identity and handoff `capture_id` are different. Repeated Send opens
   existing handoff status; Retry preserves its exact request. If several sends
   exist, show their history. Edited source never silently changes a queued send;
   Send as new item creates another immutable handoff for that source identity.
4. Duplicate source identifiers block ordinary Send. View previous delivery or
   Send this copy as new resolves the situation explicitly. Missing identifiers
   are treated as new; never infer identity from matching text or filenames.
5. Full dismissal still discards ordinary capture drafts. Failed saves and
   interrupted imports/sends retain recoverable content. Clear recovered content
   only after successful completion or an explicit discard; recovery must never
   silently create an organiser send.
6. Missing/unreadable local attachments block sending. Offer an explicit list and
   Send without missing attachments. Record approved omissions with the handoff;
   do not rewrite user-authored Markdown or pretend missing bytes were delivered.
   Remote image URLs remain links; never fetch them automatically.
7. Bind each handoff to its destination at creation. Changing settings cannot
   reroute it. Disablement pauses delivery, including automatic retry.
8. No automatic cleanup of source items, pending bundles, or delivered history in
   this milestone. No bulk migration or forwarding of existing captures.

Snapshot content is the saved selected Markdown, including the identity comment
after its acknowledged insertion. Preserve user-authored bytes, line breaks, and
links; receiver interpretation must not use that comment as its deduplication key.
Represent source-relative attachment links and copied safe bundle paths separately
in the documented attachment mapping, so copying does not require rewriting the
source body. Receivers resolve only validated mappings, never arbitrary local paths.

## Implementation sequence and gates

### M1 — Baseline and local-file safety

- Run existing Swift and editor checks before changes. Record toolchain/build
  configuration and distinguish existing failures from regressions.
- Measure cold/warm shortcut-to-confirmed-input and representative text-save
  timings using repeatable fixtures, sample counts, and median/p95 results. Include
  a large capture file; existing tag scanning occurs before showing the panel.
- Add focused refile interleaving tests. Preserve unrelated destination bytes and
  avoid replacing a whole existing target merely to append. Separate new-file
  scaffolding from existing-file append; retain the established Inbox behaviour.
- Serialize Quick Capture's own writers; evaluate file coordination and changes
  by external editors. Advisory locks or read/compare checks alone cannot guarantee
  safety against arbitrary non-cooperating replacements. Record the actual limit.
- Report uncertain target-write/source-removal outcomes explicitly. Do not route
  refile through the delivery queue or automatically repeat an uncertain append.
- Add recoverable failed-save content before allowing later dismissal to lose it;
  retain the visible draft if even recovery storage fails.

Gate: regression suite passes, baseline is recorded, no unrelated-byte loss in
tested interleavings, and refile uncertainty is visible rather than reported as
an ordinary safe-to-retry failure. Do not claim exactly-once file append.

### M2 — Identity and versioned contract

- Add source-marker parsing and editor rendering; test priorities, timestamps,
  legacy tokens, reorganisation, archive, refile, duplicated and removed markers.
- Make first-send marker insertion an acknowledged source save. A failed write
  cannot produce a queued send. Revalidate selection after editor flush.
- Define JSON Schema v1 and deterministic fixtures for the handover envelope,
  frozen destination wrapper, attachment mapping/approved omissions, durable
  receipt, and typed errors. Document the mapping/omission extension explicitly.
- Specify canonical UTF-8 request serialization and digest coverage without a
  self-referential hash. Include attachment digests; freeze the exact resulting
  bytes. Add fixed hash vectors usable by a future receiver in another language.
- Define bounded parsing and documented input limits, safe path handling,
  timestamp/UUID validation, and receipt matching. Credentials never enter bundles.

Gate: fixtures validate; Unicode, code blocks and line endings survive unchanged;
same source/new handoff and duplicate-source cases have distinct tested semantics.

### M3 — Snapshot journal and recovery

- Introduce a handoff module exposing enqueue, history/status, retry, and pause.
  Internally use an app-owned SQLite journal and private snapshot bundles; keep
  source bodies and copied attachments accessible as ordinary files.
- Copy/hash attachments off the UI thread into restrictive-permission staging.
  Detect changed or incomplete inputs, preserve recoverable staging, and distinguish
  Importing from Queued. Bound work so large files do not starve capture input.
- Flush staged files/manifest and atomically publish on the same filesystem, then
  durably register the queue record. Document actual filesystem/SQLite guarantees,
  including power-loss limits; atomic rename alone is not a durability claim.
- Include enough identity/destination metadata in complete manifests to repair
  missing journal entries. Reconcile complete bundles at startup; quarantine
  unsafe/corrupt entries, and preserve incomplete staging for recovery.
- Persist source-to-handoff mappings transactionally with queue registration.
  Handle a crash after source-marker save but before snapshot publication; a marker
  without a completed handoff is not proof of delivery or successful queueing.
- Serialize enqueue attempts as well as workers: repeated activation during
  staging must resume the same send, not allocate another handoff.
- Implement pending/delivering/delivered/retry_wait/needs_attention, a persisted
  frozen wrapper, capped backoff with jitter, restart recovery, manual Retry,
  destination binding, and pause semantics. Never log content or sensitive paths.

Gate: fault injection at every file/journal transition retains source content,
reconstructs complete work, and never transmits partially published bundles.

### M4 — One adapter and durable development receiver

- Define `CaptureDestination` capability discovery and delivery of a frozen
  request, returning a validated durable receipt or typed error. Supply fake and
  local spool adapters; do not add HTTP/IPC implementations in parallel.
- Publish spool requests immutably and atomically. Scope a configured folder to
  its destination identity. Use polling plus notifications; do not treat the spool
  as a sync service. Retain local snapshots independently of spool availability.
- Build a command-line development receiver with its own private store. It must
  verify attachment bytes and commit inbox record, immutable acceptance result,
  and deduplication data before publishing a receipt.
- Deduplicate within workspace by capture ID and digest, and retain operation
  results. Same ID/different payload is a conflict. Retain deduplication records
  after moving/deleting items; retry returns the original receipt, never recreates.
- Verify receipt version, operation/capture IDs, destination context and digest
  before marking delivered. Allowlist any open-item links.

Gate: kill/restart the receiver after acceptance but before receipt publication;
retry returns the original receipt and exactly one logical accepted inbox item.
Test tombstones, corrupt input, unsupported versions, missed notifications and
simultaneous delivery triggers. The fixture proves only local integration.

### M5 — Minimal UI and existing attachments

- Add editor Send without changing existing shortcut bindings or capture defaults.
  Use the existing bridge and selection mechanism; do not grow delivery logic
  inside MainPanel. Settings contain destination configuration and enablement.
- Provide compact history/status with Retry, View previous delivery, Send as new
  item, duplicate-copy resolution, and explicit missing-attachment omission.
- Show Saved locally independently of Waiting for organiser, Delivered, and
  Delivery needs attention. Never infer cross-device availability from a receipt.
- Source stays editable during copying and delivery. Snapshot selection must be
  fixed even if source edits/refiles occur before import finishes.
- Integrate screenshot copying into the reliable handoff path. General file import
  and direct capture-box Send remain follow-up milestones after this gate.

Gate: organiser unavailable does not block capture, editor, refile or `#cal`;
identity and attachment error choices behave as agreed; queue failure cannot
misrepresent a successful local source save as failed or lose the source.

### M6 — Reliability evidence and receiver handover

- Execute every applicable row of the integration handover's acceptance matrix,
  including disk-full/permission faults, symlink/traversal attacks, changed digests,
  lost receipts, destination changes, source edits/refiles, and explicit new sends.
- Add the agreed identity cases, marker-save interruption, incomplete imports,
  missing-attachment omission, and recovery-dismissal cases to that matrix.
- Rerun the same latency protocol and report before/after distributions. Investigate
  material regressions; delivery work may not enter shortcut or source-save paths.
- Deliver an integration README with setup, schema/fixtures, receiver obligations,
  durability guarantees, recovery instructions, input limits, redacted diagnostics,
  commands/results, and an explicit list of untested signing/device scenarios.
- No destructive migration is expected. Version the new journal/manifest formats,
  fail safely on unsupported versions, preserve existing data, and document rollback:
  disabling integration leaves source Markdown and all snapshots recoverable.

Gate: build/tests and fault matrix pass with evidence. Production end-to-end and
Mac-to-Mac/iPhone sync remain unproven until the real organiser is connected.

## Build and verification commands

Use these during implementation, not as evidence of checks already performed:

```sh
npm run typecheck --prefix editor-web
npm test --prefix editor-web
npm run build --prefix editor-web
xcodegen generate
xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture -destination 'platform=macOS' -derivedDataPath /tmp/quick-capture-integration-build CODE_SIGNING_ALLOWED=NO test
git diff --check
```

Regenerate the Xcode project when Swift files change and commit the bundled editor
output when editor sources change. Unsigned test builds do not establish signed
app permissions or real hotkey/UI timing; measure those using an identified local
development build and report its signing configuration separately.

## Review and execution order

Implement M1 through M6 as reviewable changes in dependency order. Keep identity
and contract work separate from queue internals, receiver work, and UI integration
so failures are attributable. Do not publish GitHub issues, send messages to an
organiser agent, or deploy anything merely because this local plan exists.

All five product questions are resolved. Technical defaults above can be refined
when implementation evidence requires it; return to the user only for a changed
product behaviour, access decision, or consequential constraint. The final shared-understanding and implementation approval was received before
application changes began.


## Completion record

All six capture-side stages are implemented. M1 adds durable source/attachment
flushes, recoverable failed captures, and append-preserving refile with explicit
uncertainty. M2 supplies source identity, schemas and cross-language fixtures. M3
supplies the private snapshot journal and resumable import intents. M4 supplies
fake/spool adapters and the idempotent Python receiver. M5 supplies editor Send,
settings, history, Retry, copied-identity handling and missing-attachment choices.
M6 supplies tests, measured timing and receiver setup documentation.

Verification limits are explicit: timing covers a callback-to-focus proxy rather
than OS hotkey dispatch, fault injection rather than hardware power loss, and a
local development receiver rather than production or cross-device sync. Durable
source flushes add approximately 4 ms to median text save. Existing ordinary
screenshot copying is preserved as synchronous; organiser import copying/hashing
runs away from the UI thread. See the verification record for exact evidence.
