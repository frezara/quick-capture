import XCTest
@testable import QuickCapture

/// The pure tag-completion cycle arithmetic behind ⇥ / ⇧⇥ in the capture box's
/// tag field (#91). The SwiftUI wiring is manual-QA; only the wrap logic — the
/// part with off-by-one risk — is unit-tested.
final class CaptureViewTests: XCTestCase {

    func testForwardCycleAdvancesAndWraps() {
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 0, count: 3, forward: true), 1)
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 1, count: 3, forward: true), 2)
        // Wraps from the last item back to the first.
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 2, count: 3, forward: true), 0)
    }

    func testBackwardCycleRetreatsAndWraps() {
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 2, count: 3, forward: false), 1)
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 1, count: 3, forward: false), 0)
        // Wraps from the first item back to the last.
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 0, count: 3, forward: false), 2)
    }

    func testSingleItemStaysPut() {
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 0, count: 1, forward: true), 0)
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 0, count: 1, forward: false), 0)
    }

    func testEmptyListIsZero() {
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 0, count: 0, forward: true), 0)
        XCTAssertEqual(CaptureView.cycledTagIndex(from: 5, count: 0, forward: false), 0)
    }

    func testStaleCurrentIndexStillWrapsIntoRange() {
        // `current` can momentarily exceed the (shrunk) list; the modulo keeps
        // the result valid rather than crashing or returning out-of-bounds.
        let next = CaptureView.cycledTagIndex(from: 9, count: 3, forward: true)
        XCTAssertTrue((0..<3).contains(next), "got \(next)")
    }

    // MARK: - Picker preselection (#99)

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).png") }

    /// Reopening the ⌥⌘O picker preselects the screenshots already attached,
    /// intersected with the picker's current items so a stale attachment can't
    /// create a phantom selection.
    func testSeededSelectionIsAttachedIntersectItems() {
        let a = url("a"), b = url("b"), c = url("c")
        XCTAssertEqual(CaptureView.seededPickerSelection(items: [c, b, a], attached: [a, b]),
                       Set([a, b]))
    }

    func testSeededSelectionEmptyWhenNothingAttached() {
        XCTAssertEqual(CaptureView.seededPickerSelection(items: [url("a"), url("b")], attached: []),
                       Set())
    }

    func testSeededSelectionDropsAttachmentsNotInItems() {
        let a = url("a"), ghost = url("ghost")
        XCTAssertEqual(CaptureView.seededPickerSelection(items: [a], attached: [a, ghost]),
                       Set([a]))
    }
}
