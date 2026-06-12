import Foundation

/// Pure, AppKit-free logic that turns parsed capture items + tag counts + a
/// query string into the `[PaletteSection]` the `PaletteView` renders. All I/O
/// (reading the capture file) happens at the edge in `PalettePanel`/`MainPanel`;
/// this is the testable core (`PaletteViewModelTests`).
///
/// Section model:
/// - **Empty query** → Recent captures (recency-sorted via
///   `CaptureItemParser.recencySorted`, capped to `recentCap`) + Jump to tag
///   (non-empty tags, with counts). Commands is left empty here — U7 fills it.
/// - **Non-empty query** → captures whose `displayText` contains the query
///   (substring, case-insensitive), plus tags whose name matches the query.
///   Empty sections are dropped so the list shows only what hit.
///
/// Row kinds carry their navigation target so a later unit (U6) can act on a
/// selection unambiguously: a capture row carries its 0-based `line`, a tag row
/// carries its `## section` name. They are *distinct* `PaletteRow.Kind` cases,
/// so "activate a capture" and "activate a tag" never collide.
enum PaletteViewModel {

    /// How many items the empty-query **Recent captures** section shows. Tuned
    /// to fill the palette's result area without scrolling on a typical capture
    /// file while still surfacing a useful window of recent thoughts.
    static let defaultRecentCap = 10

    /// Build the sections for the current `query`. Pass the parser's `items` and
    /// `tagSummary` (already computed from the capture file text) plus the
    /// recent cap. Pure — same inputs always yield the same sections.
    static func sections(items: [CaptureItem],
                         tagSummary: [CaptureTagSummary],
                         query: String,
                         recentCap: Int = defaultRecentCap) -> [PaletteSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? emptyQuerySections(items: items, tagSummary: tagSummary, recentCap: recentCap)
            : filteredSections(items: items, tagSummary: tagSummary, query: trimmed)
    }

    // MARK: - Empty query

    /// Recent captures (recency order, capped) + Jump to tag (non-empty tags).
    /// Commands is intentionally omitted until U7.
    private static func emptyQuerySections(items: [CaptureItem],
                                           tagSummary: [CaptureTagSummary],
                                           recentCap: Int) -> [PaletteSection] {
        let recent = Array(CaptureItemParser.recencySorted(items).prefix(max(0, recentCap)))
        let tags = tagSummary.filter { $0.count > 0 }

        var sections: [PaletteSection] = []
        if !recent.isEmpty {
            sections.append(PaletteSection(title: "Recent captures", rows: recent.map(captureRow)))
        }
        if !tags.isEmpty {
            sections.append(PaletteSection(title: "Jump to tag", rows: tags.map(tagRow)))
        }
        return sections
    }

    // MARK: - Non-empty query

    /// Substring, case-insensitive filter over capture `displayText` and (in the
    /// Jump-to-tag section) tag names. Empty sections are dropped.
    private static func filteredSections(items: [CaptureItem],
                                         tagSummary: [CaptureTagSummary],
                                         query: String) -> [PaletteSection] {
        let needle = query.lowercased()

        let matchedCaptures = items.filter {
            $0.displayText.lowercased().contains(needle)
        }
        // Keep matched captures in recency order so the filtered list ranks the
        // same way the empty-query Recent list does.
        let captures = CaptureItemParser.recencySorted(matchedCaptures)

        let tags = tagSummary.filter {
            $0.count > 0 && $0.tag.lowercased().contains(needle)
        }

        var sections: [PaletteSection] = []
        if !captures.isEmpty {
            sections.append(PaletteSection(title: "Captures", rows: captures.map(captureRow)))
        }
        if !tags.isEmpty {
            sections.append(PaletteSection(title: "Jump to tag", rows: tags.map(tagRow)))
        }
        return sections
    }

    // MARK: - Row builders

    /// A capture row: priority orb (bucket) + text + its tag as the trailing
    /// detail. Carries the item's `line` so U6 can reveal it.
    private static func captureRow(_ item: CaptureItem) -> PaletteRow {
        PaletteRow(
            title: item.displayText,
            kind: .capture(priority: item.priorityBucket, line: item.line),
            detail: item.tag
        )
    }

    /// A jump-to-tag row: the `## section` name + its item count. Carries the
    /// name so U6 can reveal that section.
    private static func tagRow(_ summary: CaptureTagSummary) -> PaletteRow {
        PaletteRow(
            title: summary.tag,
            kind: .tag(name: summary.tag),
            detail: String(summary.count)
        )
    }
}
