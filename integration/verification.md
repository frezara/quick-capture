# Integration verification — 15 October 2026

Work branch: `feat/organiser-handoff`, based on `8fefd69` from
`codex/unified-design`. No real organiser, network transport or device sync is
claimed. Application builds/tests used macOS, Xcode, and `CODE_SIGNING_ALLOWED=NO`.
The original branch was exported to a separate temporary directory for comparison;
the working branch was not switched during implementation.

## Executed checks

- Original Swift baseline: **202 tests, zero failures**.
- Integrated Swift suite: **226 tests, zero failures, one opt-in timing test
  skipped in the ordinary run**. Timing was executed separately and passed.
- Editor TypeScript typecheck and production bundle build: **passed**.
- Editor persistence tests: **9 passed**.
- Python receiver tests: **12 passed**.
- Four schema fixtures and canonical digest checker: **passed**.
- Swift canonical JSON fixture agrees byte-for-byte with the Python fixture.
- `git diff --check`: **passed**.

Temporary execution logs: `/tmp/quick-capture-integration-baseline.log`,
`/tmp/quick-capture-integration-test.log`, `/tmp/quick-capture-latency-baseline.log`,
`/tmp/quick-capture-latency-after.log`. Xcode results are in the corresponding
`/tmp/quick-capture-*/Logs/Test` directories. These are machine-local evidence,
not portable repository artifacts.

## Measured timing

`CaptureLatencyTests` exercises the same recent-tag scan and panel show/focus
path as summon, waiting for an NSTextView first responder. It measures the
callback-to-input proxy, not synthetic keyboard event injection or macOS global
hotkey dispatch. Cold means constructing a new panel inside the test process,
not a cold boot of the Mac or a full process launch. Three cold samples and 30
warm/save samples were collected for each fixture, using the same harness on
baseline and updated sources. The test app was unsigned; no distribution-signing
or real hotkey/TCC scenario is implied.

| Fixture | Measurement | Baseline median / p95 (ms) | Updated median / p95 (ms) |
| --- | --- | --- | --- |
| 100 items | Cold panel | 28.94 / 119.30 | 28.57 / 112.54 |
| 100 items | Warm focus | 1.97 / 4.14 | 1.97 / 3.76 |
| 100 items | Text save | 0.24 / 0.86 | 4.65 / 5.05 |
| 10,000 items | Cold panel | 32.99 / 36.38 | 33.57 / 43.35 |
| 10,000 items | Warm focus | 9.38 / 12.62 | 11.50 / 13.31 |
| 10,000 items | Text save | 3.67 / 3.75 | 7.85 / 9.59 |

Explicit source/device-cache flushes account for a deliberate approximately 4 ms
increase in median save latency. No delivery work runs on the local save path.
Warm p95 differs by less than 1 ms; three cold samples are too few to infer a
statistical regression from their maximum. These measurements support the limited
claim above, not an assertion that all timings are unchanged. Existing local
screenshot copying remains synchronous; snapshot copying/hashing runs on the
handoff actor away from the UI thread.

Run the opt-in timing protocol with:

```sh
QC_MEASURE_LATENCY=1 TEST_RUNNER_QC_MEASURE_LATENCY=1 \
  xcodebuild -project QuickCapture.xcodeproj -scheme QuickCapture \
  -destination 'platform=macOS' -derivedDataPath /tmp/quick-capture-integration-build \
  CODE_SIGNING_ALLOWED=NO -only-testing:QuickCaptureTests/CaptureLatencyTests test
```

## Reliability matrix and evidence

| Scenario | Evidence |
| --- | --- |
| Receiver absent / disabled | Swift queue state tests; absence retries, disabled leaves attempts unchanged |
| Restart and frozen source | Swift restart and edited-source tests retain IDs/body |
| Intent, attachment, manifest, publication, registration interruption | Swift injected-boundary tests, including resumed copied bytes after deleting original |
| Published bundle without queue row | Swift fresh-store recovery rebuilds one entry |
| Receiver commit without receipt | Python fault hook plus restart returns persisted receipt |
| Real spool lost receipt | Swift launches Python receiver, removes receipt, retries and gets identical receipt bytes |
| Changed content under same identity | Receiver conflict test retains one accepted item |
| Receiver deletion/tombstone | Retry returns original receipt, leaves deleted record deleted |
| Attachment source disappears | Swift durable bundle copy and resumed-import tests; receiver has its own ordinary copy |
| Missing required attachment | Blocks acceptance; explicit omission preserves body and records omitted links |
| Permission failure | Swift staging directory made unwritable; no queue entry registered |
| Disk full | ENOSPC injected at publication boundaries; original intent/bundle remains recoverable; no actual disk was filled |
| Unicode, multiline, code fences | Fixed cross-language fixture, frozen-body and real-spool round-trip tests |
| Symlink/traversal/digest attacks | Swift bounded safe-read tests and Python rejection tests |
| Wrong workspace/version | Python rejection tests, sender validates capabilities and receipt identity |
| Concurrent triggers | Swift simultaneous enqueue returns one handoff; two Python workers accept one receiver item |
| Queue receipt interruption | Frozen request unchanged after retry; delivered result validated |
| Destination changed | Existing handoff retains original spool/workspace |
| Marker save acknowledgement | WKWebView Send test proves no handoff before successful save |
| Copied source identity | WKWebView refuses ordinary Send and opens history |
| Refile preserves unrelated bytes | Existing regression suite plus concurrent append/trailing-byte test |
| Refile target replaced | Reports uncertainty and leaves externally replaced file intact |
| Failed capture recovery | Independent recoverable drafts remain readable; successful removal preserves other drafts |
| Existing capture/editor/calendar/shortcuts | Original regression tests pass; source and screenshot durability flushes exercised through them |
| Historical captures | No import/migration path added; sending remains explicit |

## Explicit limits

- No production organiser, iPhone, second-Mac or cross-device sync test was run.
- No Apple distribution signing, notarisation, App Groups, or production TCC test
  was run. Existing signing configuration is unchanged.
- Authentication tests do not apply to the selected filesystem adapter. There is
  no HTTP listener or new credential system. File permissions protect local data.
- Fault injection simulates process/interruption boundaries; this is not a physical
  power-cut or full-disk hardware experiment.
- No claim of exactly-once append to an arbitrary agent-edited file. Advisory locks
  cannot prevent a non-cooperating writer replacing a file after the final check.
- No general Markdown attachment parser, external-note sync, capture-box Send,
  file-drop importer, or automatic retention cleanup is included.
- The queue fixture proves one-way local delivery, not the wider organiser product.
