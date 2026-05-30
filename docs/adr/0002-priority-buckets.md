# ADR-0002: Priority buckets

Status: Accepted

## Context

Captured items need an ordering so that what matters floats to the top of a
section, both when a new item is inserted and when a section is re-organized.
Two constraints shaped the design:

1. The source of truth is a **plain markdown file** the user also edits in
   Obsidian. Priority can't live in sidecar metadata or a database — it has
   to be expressed in the line text itself, in a way that round-trips
   through Obsidian without looking broken.
2. Captures may carry an Obsidian Tasks **creation-date suffix**
   (`➕ YYYY-MM-DD HH:MM`) appended after the text. Priority classification
   must survive that suffix.

## Decision

Encode priority as **trailing bang markers** on the item text and classify
each item into one of five **priority buckets** (lower = higher priority):

| Item                | Bucket |
|---------------------|--------|
| `- [ ] text !!!`    | 0      |
| `- [ ] text !!`     | 1      |
| `- [ ] text !`      | 2      |
| `- [ ] text`        | 3      |
| `- [x] text` (done) | 4      |

- `FileWriter.priorityBucket` computes the bucket and is **tolerant of the
  `➕ YYYY-MM-DD HH:MM` timestamp suffix**, so timestamped captures still
  classify correctly.
- **Insertion** (`FileWriter.insert`) walks a section and lands a new item
  just before the first task whose bucket is `>=` its own, so higher-priority
  captures float above lower-priority ones already present.
- **Re-org / sweep** (`⌘'`) sorts unchecked items by bucket (`!!!` → `!!` →
  `!` → plain), moves checked items to the section bottom, and **strips
  priority markers off checked items** so done work reads as plain.
- The editor renders the marker as a **priority dot** in live preview rather
  than showing the raw bangs.

## Consequences

- Priority is visible and editable as plain text; nothing breaks in Obsidian
  or in a diff. ✅
- The timestamp tolerance is load-bearing and easy to regress — it's covered
  by `FileWriterTests` and any change to the marker grammar must keep the
  `➕`-suffix cases passing.
- The bucket scheme is closed (0–4). Adding a sixth level means touching
  `priorityBucket`, `insert`, the re-org sort, and the editor's dot
  rendering together — keep them in sync.
- Checked = bucket 4 means completion dominates priority for ordering: a
  done `!!!` item still sorts below an open plain item. This is intentional
  (done work sinks).
