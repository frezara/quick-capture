import Foundation

/// A single capture surfaced by the command palette: the readable text, its
/// priority bucket, the `## section` it lives under, the 0-based line index of
/// its own line (for editor reveal), and an optional creation time parsed from
/// the hidden `<!--qc:…-->` token.
///
/// `displayText` is the bare, human-readable text: the hidden token, the visible
/// `➕ DATE TIME` suffix, AND trailing priority markers (`!`/`!!`/`!!!`) are all
/// stripped, along with the `- [ ] ` / `- [x] ` list-and-checkbox syntax. The
/// priority lives on `priorityBucket` and the done-state is implied by it
/// (bucket 4 = checked), so the text reads clean in a results row.
struct CaptureItem: Equatable {
    /// Readable text with token, `➕` suffix, list/checkbox syntax, and trailing
    /// priority markers removed.
    let displayText: String
    /// 0 = `!!!`, 1 = `!!`, 2 = `!`, 3 = plain, 4 = checked `[x]` — same scale
    /// as `FileWriter.priorityBucket`.
    let priorityBucket: Int
    /// The enclosing `## section` name; `Quick capture` for the catch-all.
    let tag: String
    /// 0-based index of the item's own line in the file (for editor reveal).
    let line: Int
    /// Creation time from the hidden token, or nil for hand-authored / external
    /// items that carry no token.
    let createdAt: Date?
}

/// A `## section` and how many top-level items it holds, for the palette's
/// Jump-to-tag section.
struct CaptureTagSummary: Equatable {
    let tag: String
    let count: Int
}

/// A **pure** parser turning the capture file text into the structured items the
/// command palette searches, ranks, and navigates to.
///
/// Only **top-level task lines** (`^[-*+]\s+\[[ xX]\]\s+…`, no leading indent)
/// become items. Nested child items, attachment image lines, and continuation
/// notes are skipped — they are part of their parent's subtree, not separate
/// captures. The enclosing `## section` becomes the item's `tag`; items before
/// any `## section` (which shouldn't happen in a well-formed file, since
/// untagged items route under `## Quick capture`) are tolerated and tagged as
/// `Quick capture`.
///
/// **Empty-tag handling:** `tagSummary` reports **every** `## section` heading,
/// including those with zero items (count 0). The palette's Jump-to-tag list
/// wants to show a section the user created even before they've filed anything
/// under it; callers that want only non-empty tags can filter on `count > 0`.
enum CaptureItemParser {

    /// Parse `text` into `[CaptureItem]` in file order. Only top-level task
    /// lines surface as items.
    static func parse(_ text: String) -> [CaptureItem] {
        let lines = text.components(separatedBy: "\n")
        var items: [CaptureItem] = []
        var currentTag = FileWriter.untaggedSection

        for (index, line) in lines.enumerated() {
            if let heading = sectionHeading(in: line) {
                currentTag = heading
                continue
            }
            guard isTopLevelTaskLine(line) else { continue }
            items.append(
                CaptureItem(
                    displayText: displayText(for: line),
                    priorityBucket: FileWriter.priorityBucket(for: line),
                    tag: currentTag,
                    line: index,
                    createdAt: FileWriter.creationDate(in: line)
                )
            )
        }
        return items
    }

    /// Every `## section` in the file with its top-level item count, in file
    /// order. Sections with zero items are included (count 0) — see the type
    /// doc-comment.
    static func tagSummary(_ text: String) -> [CaptureTagSummary] {
        let lines = text.components(separatedBy: "\n")
        var order: [String] = []
        var counts: [String: Int] = [:]
        var currentTag: String? = nil

        for line in lines {
            if let heading = sectionHeading(in: line) {
                currentTag = heading
                if counts[heading] == nil {
                    counts[heading] = 0
                    order.append(heading)
                }
                continue
            }
            guard isTopLevelTaskLine(line) else { continue }
            // Items before any `## section` (malformed file) fall under the
            // catch-all, registering the section on first sight.
            let tag = currentTag ?? FileWriter.untaggedSection
            if counts[tag] == nil {
                counts[tag] = 0
                order.append(tag)
            }
            counts[tag, default: 0] += 1
        }

        return order.map { CaptureTagSummary(tag: $0, count: counts[$0] ?? 0) }
    }

    /// Items ordered for the palette's Recent section: timestamped items first,
    /// newest `createdAt` to oldest; tokenless items after them, preserving
    /// their original file order. Stable for ties.
    static func recencySorted(_ items: [CaptureItem]) -> [CaptureItem] {
        let withDate = items.enumerated().filter { $0.element.createdAt != nil }
        let withoutDate = items.enumerated().filter { $0.element.createdAt == nil }

        let timestamped = withDate.sorted { a, b in
            // Both have a date here. Newest first; original order breaks ties so
            // the sort is stable.
            if a.element.createdAt! == b.element.createdAt! {
                return a.offset < b.offset
            }
            return a.element.createdAt! > b.element.createdAt!
        }

        return timestamped.map(\.element) + withoutDate.map(\.element)
    }

    // MARK: - Private

    /// The trimmed `## section` name in `line`, or nil if it isn't an H2. Matches
    /// `extractCompletedItems`' `## ` detection (exactly two hashes + a space),
    /// so an H3+ heading isn't mistaken for a section.
    private static func sectionHeading(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## "), !trimmed.hasPrefix("### ") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    /// A top-level (un-indented) task line: `- [ ] …` / `- [x] …` with no
    /// leading whitespace, so nested child items are excluded. Mirrors
    /// `FileWriter`'s `isTopLevelTaskLine` but also requires the checkbox so a
    /// bare `- ` bullet isn't surfaced as a capture.
    private static func isTopLevelTaskLine(_ line: String) -> Bool {
        return line.range(of: #"^[-*+]\s+\[[ xX]\]\s"#, options: .regularExpression) != nil
    }

    /// The bare display text for an item line: strip the hidden token and `➕`
    /// suffix (via `FileWriter.strippingCreationToken`), then the leading
    /// `- [ ] ` / `- [x] ` syntax, then any trailing `!`/`!!`/`!!!` priority
    /// markers — leaving just the readable thought.
    private static func displayText(for line: String) -> String {
        var text = FileWriter.strippingCreationToken(line)
        text = text.replacingOccurrences(
            of: #"^\s*[-*+]\s+\[[ xX]\]\s+"#, with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\s+!{1,3}\s*$"#, with: "", options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespaces)
    }
}
