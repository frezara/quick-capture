import XCTest
@testable import QuickCapture

/// The palette's pure section/row builder (U5): substring filtering, recency
/// ordering, the recent cap, and the capture-line vs tag-name distinction the
/// row model carries for U6 navigation. AppKit/SwiftUI rendering is manual-QA;
/// only this decision-carrying logic is unit-tested.
final class PaletteViewModelTests: XCTestCase {

    private func item(_ text: String,
                      priority: Int = 3,
                      tag: String = "Quick capture",
                      line: Int,
                      createdAt: Date? = nil) -> CaptureItem {
        CaptureItem(displayText: text, priorityBucket: priority, tag: tag,
                    line: line, createdAt: createdAt)
    }

    /// Flatten a section's rows for assertion convenience.
    private func rows(_ sections: [PaletteSection], titled title: String) -> [PaletteRow] {
        sections.first { $0.title == title }?.rows ?? []
    }

    // MARK: - 1. Substring, case-insensitive filter

    func testQueryMatchesCaseInsensitiveSubstring() {
        let items = [
            item("Buy milk", line: 1),
            item("BUY a stamp", line: 2),
            item("Renew passport", line: 3),
        ]
        let sections = PaletteViewModel.sections(items: items, tagSummary: [], query: "buy")
        let captureTitles = sections.flatMap { $0.rows }.map(\.title)
        XCTAssertEqual(captureTitles, ["Buy milk", "BUY a stamp"])
        XCTAssertFalse(captureTitles.contains("Renew passport"))
    }

    // MARK: - 2. Empty query → recency order + tags

    func testEmptyQueryShowsRecentInOrderPlusTags() {
        let newest = item("newest", line: 1, createdAt: Date(timeIntervalSince1970: 300))
        let mid = item("mid", line: 2, createdAt: Date(timeIntervalSince1970: 200))
        let tokenless = item("tokenless", line: 3, createdAt: nil)
        let oldest = item("oldest", line: 4, createdAt: Date(timeIntervalSince1970: 100))

        let tags = [
            CaptureTagSummary(tag: "work", count: 3),
            CaptureTagSummary(tag: "errands", count: 1),
        ]

        let sections = PaletteViewModel.sections(
            items: [mid, oldest, newest, tokenless], tagSummary: tags, query: "")

        let recent = rows(sections, titled: "Recent captures").map(\.title)
        // Newest createdAt first; tokenless falls to the end.
        XCTAssertEqual(recent, ["newest", "mid", "oldest", "tokenless"])

        let tagRows = rows(sections, titled: "Jump to tag")
        XCTAssertEqual(tagRows.map(\.title), ["work", "errands"])
    }

    // MARK: - 3. Capture row exposes priority bucket + tag

    func testCaptureRowExposesPriorityBucketAndTag() {
        let items = [item("Draft email", priority: 1, tag: "work", line: 7)]
        let sections = PaletteViewModel.sections(items: items, tagSummary: [], query: "")
        let row = rows(sections, titled: "Recent captures").first
        XCTAssertEqual(row?.kind, .capture(priority: 1, line: 7))
        XCTAssertEqual(row?.detail, "work")
    }

    // MARK: - 4. No matches → empty sections, no crash

    func testQueryMatchingNothingYieldsNoSections() {
        let items = [item("Buy milk", line: 1)]
        let tags = [CaptureTagSummary(tag: "work", count: 2)]
        let sections = PaletteViewModel.sections(
            items: items, tagSummary: tags, query: "zzzznotfound")
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - 5. Tag rows show counts; kind distinct from capture kind

    func testTagRowKindIsNavigateWithNameDistinctFromCaptureRow() {
        let items = [item("Buy milk", priority: 3, tag: "Quick capture", line: 2)]
        let tags = [CaptureTagSummary(tag: "work", count: 5)]
        let sections = PaletteViewModel.sections(items: items, tagSummary: tags, query: "")

        let tagRow = rows(sections, titled: "Jump to tag").first
        XCTAssertEqual(tagRow?.detail, "5")
        XCTAssertEqual(tagRow?.kind, .tag(name: "work"))

        let captureRow = rows(sections, titled: "Recent captures").first
        XCTAssertEqual(captureRow?.kind, .capture(priority: 3, line: 2))

        // The two row kinds are different enum cases — a capture carries its
        // line, a tag carries its name — so U6 can route on kind unambiguously.
        XCTAssertNotEqual(tagRow?.kind, captureRow?.kind)
    }

    // MARK: - 6. Recent cap

    func testRecentSectionCapsAtN() {
        let cap = 4
        let items = (0..<10).map {
            item("item \($0)", line: $0, createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let sections = PaletteViewModel.sections(
            items: items, tagSummary: [], query: "", recentCap: cap)
        let recent = rows(sections, titled: "Recent captures")
        XCTAssertEqual(recent.count, cap)
        // Newest-first: line 9 (largest timestamp) leads, down to line 6.
        XCTAssertEqual(recent.map(\.title), ["item 9", "item 8", "item 7", "item 6"])
    }

    // MARK: - Tag filtering by name when a query is active

    func testQueryFiltersTagsByName() {
        let items = [item("unrelated", line: 1)]
        let tags = [
            CaptureTagSummary(tag: "work", count: 2),
            CaptureTagSummary(tag: "errands", count: 1),
        ]
        let sections = PaletteViewModel.sections(items: items, tagSummary: tags, query: "work")
        let tagRows = rows(sections, titled: "Jump to tag")
        XCTAssertEqual(tagRows.map(\.title), ["work"])
    }

    // MARK: - Empty-count tags excluded

    func testEmptyTagsExcludedFromJumpToTag() {
        let tags = [
            CaptureTagSummary(tag: "work", count: 2),
            CaptureTagSummary(tag: "empty", count: 0),
        ]
        let sections = PaletteViewModel.sections(items: [], tagSummary: tags, query: "")
        XCTAssertEqual(rows(sections, titled: "Jump to tag").map(\.title), ["work"])
    }

    // MARK: - 7. Global commands (U7)

    /// Pull the `PaletteCommand` id out of a command row, or nil if it isn't one.
    private func commandID(_ row: PaletteRow?) -> PaletteCommand? {
        guard case .command(let command)? = row?.kind else { return nil }
        return command
    }

    func testEmptyQueryShowsAllCommands() {
        let sections = PaletteViewModel.sections(items: [], tagSummary: [], query: "")
        let commands = rows(sections, titled: "Commands")
        XCTAssertEqual(
            commands.map(\.title),
            ["Open Editor", "Archive completed", "Re-organize", "Refile", "Settings", "New capture"])
    }

    func testQueryArchSurfacesArchiveCompletedCommand() {
        let sections = PaletteViewModel.sections(items: [], tagSummary: [], query: "arch")
        let commands = rows(sections, titled: "Commands")
        XCTAssertEqual(commands.map(\.title), ["Archive completed"])
    }

    func testCommandTitlesMatchCaseInsensitively() {
        let sections = PaletteViewModel.sections(items: [], tagSummary: [], query: "SETTINGS")
        let commands = rows(sections, titled: "Commands")
        XCTAssertEqual(commands.map(\.title), ["Settings"])
    }

    func testQueryMatchingNoCommandHidesCommandsSection() {
        // "buy" matches no command title — the Commands section is dropped.
        let sections = PaletteViewModel.sections(
            items: [item("Buy milk", line: 1)], tagSummary: [], query: "buy")
        XCTAssertNil(sections.first { $0.title == "Commands" })
    }

    func testCommandRowCarriesStableIdentifierForTitle() {
        let sections = PaletteViewModel.sections(items: [], tagSummary: [], query: "")
        let commands = rows(sections, titled: "Commands")

        XCTAssertEqual(commandID(commands.first { $0.title == "Open Editor" }), .openEditor)
        XCTAssertEqual(commandID(commands.first { $0.title == "Archive completed" }), .archiveCompleted)
        XCTAssertEqual(commandID(commands.first { $0.title == "Re-organize" }), .reorganize)
        XCTAssertEqual(commandID(commands.first { $0.title == "Refile" }), .refile)
        XCTAssertEqual(commandID(commands.first { $0.title == "Settings" }), .settings)
        XCTAssertEqual(commandID(commands.first { $0.title == "New capture" }), .newCapture)
    }

    func testQueryMatchingOnlyCommandShowsJustCommandsSection() {
        // A query that hits a command but no capture/tag yields exactly the
        // Commands section (the others are dropped as empty).
        let sections = PaletteViewModel.sections(
            items: [item("Buy milk", line: 1)],
            tagSummary: [CaptureTagSummary(tag: "work", count: 2)],
            query: "refile")
        XCTAssertEqual(sections.map(\.title), ["Commands"])
        XCTAssertEqual(commandID(rows(sections, titled: "Commands").first), .refile)
    }
}
