import XCTest
@testable import QuickCapture

/// The allocation rule behind #102: a section takes the next unused hue the
/// first time it is seen and keeps it. These exercise the value type directly —
/// `AppState` only adds persistence on top.
final class TagHueAssignmentTests: XCTestCase {

    // MARK: - First-sight allocation

    func testAssignsHuesInOrderOfFirstSight() {
        var hues = TagHueAssignment()
        hues.assign(["work", "design", "home"])

        XCTAssertEqual(hues.index(for: "work"), 0)
        XCTAssertEqual(hues.index(for: "design"), 1)
        XCTAssertEqual(hues.index(for: "home"), 2)
    }

    func testUnseenTagHasNoHue() {
        var hues = TagHueAssignment()
        hues.assign(["work"])
        XCTAssertNil(hues.index(for: "never-seen"))
    }

    func testAssignIsCaseAndWhitespaceInsensitive() {
        var hues = TagHueAssignment()
        hues.assign(["Design"])

        XCTAssertEqual(hues.index(for: "design"), 0)
        XCTAssertEqual(hues.index(for: "  DESIGN  "), 0)
        // …and a second sighting under different casing allocates nothing new.
        XCTAssertFalse(hues.assign(["DESIGN"]))
    }

    func testEmptyAndBlankTagsAreSkipped() {
        var hues = TagHueAssignment()
        XCTAssertFalse(hues.assign(["", "   "]))
        XCTAssertTrue(hues.indices.isEmpty)
    }

    func testAssignReportsWhetherAnythingChanged() {
        var hues = TagHueAssignment()
        XCTAssertTrue(hues.assign(["work"]))
        XCTAssertFalse(hues.assign(["work"]))
        XCTAssertTrue(hues.assign(["work", "design"]))
    }

    // MARK: - Stability (the whole point of persisting the map)

    func testHueSurvivesReorderingTheFile() {
        var hues = TagHueAssignment()
        hues.assign(["work", "design", "home"])
        let before = hues.indices

        // The user moves `home` to the top and deletes `work`; the sections
        // that remain must keep the hues they already had.
        hues.assign(["home", "design"])

        XCTAssertEqual(hues.indices, before)
        XCTAssertEqual(hues.index(for: "home"), 2)
        XCTAssertEqual(hues.index(for: "design"), 1)
    }

    func testDeletedSectionKeepsItsHueWhenItComesBack() {
        var hues = TagHueAssignment()
        hues.assign(["work", "design"])
        hues.assign(["work"])                 // `design` deleted from the file
        hues.assign(["work", "design"])       // …and pasted back

        XCTAssertEqual(hues.index(for: "design"), 1)
    }

    func testInsertingASectionAboveDoesNotShiftExistingHues() {
        var hues = TagHueAssignment()
        hues.assign(["work", "design"])
        hues.assign(["newest", "work", "design"])

        XCTAssertEqual(hues.index(for: "work"), 0)
        XCTAssertEqual(hues.index(for: "design"), 1)
        XCTAssertEqual(hues.index(for: "newest"), 2)
    }

    // MARK: - Running out of hues

    func testFillsEveryHueBeforeReusingOne() {
        var hues = TagHueAssignment()
        let names = (0..<TagPalette.count).map { "section-\($0)" }
        hues.assign(names)

        XCTAssertEqual(Set(hues.indices.values).count, TagPalette.count)
    }

    func testReusesTheLeastRecentlyAssignedHuePastThePalette() {
        var hues = TagHueAssignment()
        let names = (0..<TagPalette.count).map { "section-\($0)" }
        hues.assign(names)

        // Every hue is spoken for, so the next section takes the one handed out
        // longest ago — hue 0, `section-0`'s.
        hues.assign(["overflow"])
        XCTAssertEqual(hues.index(for: "overflow"), 0)

        // And the one after that takes the next-oldest, not hue 0 again.
        hues.assign(["overflow-2"])
        XCTAssertEqual(hues.index(for: "overflow-2"), 1)
    }

    func testReuseIsDeterministic() {
        func run() -> [Int?] {
            var hues = TagHueAssignment()
            hues.assign((0..<TagPalette.count).map { "section-\($0)" })
            hues.assign(["a", "b", "c"])
            return ["a", "b", "c"].map { hues.index(for: $0) }
        }
        // Guards the tie-break: picking the min over a dictionary would vary
        // run to run once several hues share the same last-use position.
        XCTAssertEqual(run(), run())
    }

    // MARK: - Persistence

    func testRoundTripsThroughCodable() throws {
        var hues = TagHueAssignment()
        hues.assign(["work", "design", "home"])

        let data = try JSONEncoder().encode(hues)
        let decoded = try JSONDecoder().decode(TagHueAssignment.self, from: data)

        XCTAssertEqual(decoded, hues)
        XCTAssertEqual(decoded.index(for: "design"), 1)
        // The order list has to survive too, or the reuse rule resets.
        decodedKeepsAllocatingFromWhereItLeftOff(decoded)
    }

    private func decodedKeepsAllocatingFromWhereItLeftOff(_ decoded: TagHueAssignment) {
        var hues = decoded
        hues.assign(["fresh"])
        XCTAssertEqual(hues.index(for: "fresh"), 3)
    }

    // MARK: - Palette

    func testSlateIsRetired() {
        // #102: a grey gives a section no identity. 7 hues, none of them slate.
        XCTAssertEqual(TagPalette.count, 7)
        XCTAssertFalse(TagPalette.entries.contains { $0.lightHex == 0x64748B })
    }

    func testEntryAtWrapsRatherThanTrapping() {
        XCTAssertEqual(TagPalette.entry(at: TagPalette.count).lightHex,
                       TagPalette.entry(at: 0).lightHex)
    }

    // MARK: - Section extraction

    func testSectionNamesAreFileOrderWithoutTheCatchAll() {
        let content = """
        # Inbox

        ## Quick capture
        - [ ] untagged

        ## design
        - [ ] a
        ### not a section
        ## work
        - [ ] b

        ## design
        - [ ] duplicate heading
        """

        XCTAssertEqual(AppState.sectionNames(in: content), ["design", "work"])
    }
}
