import XCTest
@testable import QuickCapture

/// The palette's pure list helpers (U3): flattening sections to a single
/// selectable list, and clamped highlight movement across that list. The
/// AppKit panel + SwiftUI layout are manual-QA; only this decision-carrying
/// logic is unit-tested.
final class PaletteViewTests: XCTestCase {

    private func sample() -> [PaletteSection] {
        [
            PaletteSection(title: "Recent captures", rows: [
                PaletteRow(title: "a", kind: .capture(priority: 3, line: 1)),
                PaletteRow(title: "b", kind: .capture(priority: 1, line: 2)),
            ]),
            PaletteSection(title: "Jump to tag", rows: [
                PaletteRow(title: "work", kind: .tag(name: "work"), detail: "2"),
            ]),
            PaletteSection(title: "Commands", rows: [
                PaletteRow(title: "Settings", kind: .command(.settings)),
            ]),
        ]
    }

    // MARK: - flatten

    func testFlattenConcatenatesRowsInSectionOrder() {
        let rows = PaletteList.flatten(sample())
        XCTAssertEqual(rows.map(\.title), ["a", "b", "work", "Settings"])
    }

    func testFlattenSkipsEmptySectionsImplicitly() {
        let sections = [
            PaletteSection(title: "Empty", rows: []),
            PaletteSection(title: "One", rows: [PaletteRow(title: "x", kind: .command(.settings))]),
        ]
        XCTAssertEqual(PaletteList.flatten(sections).map(\.title), ["x"])
    }

    func testFlattenEmptyIsEmpty() {
        XCTAssertTrue(PaletteList.flatten([]).isEmpty)
    }

    // MARK: - moveHighlight

    func testMoveHighlightStepsDownAndUp() {
        XCTAssertEqual(PaletteList.moveHighlight(0, by: 1, count: 4), 1)
        XCTAssertEqual(PaletteList.moveHighlight(2, by: -1, count: 4), 1)
    }

    func testMoveHighlightClampsAtBothEndsNoWrap() {
        XCTAssertEqual(PaletteList.moveHighlight(0, by: -1, count: 4), 0)
        XCTAssertEqual(PaletteList.moveHighlight(3, by: 1, count: 4), 3)
    }

    func testMoveHighlightWithZeroCountPinsToZero() {
        XCTAssertEqual(PaletteList.moveHighlight(5, by: 1, count: 0), 0)
        XCTAssertEqual(PaletteList.moveHighlight(0, by: -1, count: 0), 0)
    }

    /// Used to clamp a stale index after the (future) filter shrinks the list:
    /// `moveHighlight(current, by: 0, count:)` re-pins into range.
    func testMoveHighlightByZeroClampsStaleIndex() {
        XCTAssertEqual(PaletteList.moveHighlight(9, by: 0, count: 3), 2)
        XCTAssertEqual(PaletteList.moveHighlight(1, by: 0, count: 3), 1)
    }
}
