import XCTest
@testable import QuickCapture

final class ScreenshotLocatorTests: XCTestCase {

    func testNewestScreenshotPicksLatestByCreationDate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = try makeFile(in: dir, named: "Screenshot 2026-06-01 at 10.00.00.png")
        let newer = try makeFile(in: dir, named: "Screenshot 2026-06-02 at 10.00.00.png")
        try setCreationDate(Date(timeIntervalSince1970: 1_000_000), on: older)
        try setCreationDate(Date(timeIntervalSince1970: 2_000_000), on: newer)

        let result = ScreenshotLocator.newestScreenshot(in: dir)

        XCTAssertEqual(result?.url.lastPathComponent, newer.lastPathComponent)
    }

    func testNewestScreenshotIgnoresNonScreenshotFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let shot = try makeFile(in: dir, named: "Screenshot 2026-06-01 at 10.00.00.png")
        let photo = try makeFile(in: dir, named: "IMG_0042.png")
        let note = try makeFile(in: dir, named: "notes.txt")
        try setCreationDate(Date(timeIntervalSince1970: 1_000_000), on: shot)
        try setCreationDate(Date(timeIntervalSince1970: 9_000_000), on: photo)
        try setCreationDate(Date(timeIntervalSince1970: 9_000_000), on: note)

        let result = ScreenshotLocator.newestScreenshot(in: dir)

        XCTAssertEqual(result?.url.lastPathComponent, shot.lastPathComponent,
                       "newer non-screenshot files must not win")
    }

    func testNewestScreenshotReturnsNilForEmptyOrMissingDir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(ScreenshotLocator.newestScreenshot(in: dir))
        XCTAssertNil(ScreenshotLocator.newestScreenshot(in: dir.appendingPathComponent("missing")))
    }

    func testIsScreenshotFileMatchesDefaultAndLegacyNames() {
        XCTAssertTrue(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/Screenshot 2026-06-07 at 14.30.12.png")))
        XCTAssertTrue(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/Screen Shot 2021-01-01 at 09.00.00.png")))
        XCTAssertFalse(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/Screenshot notes.txt")))
        XCTAssertFalse(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/holiday.png")))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-locator-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(in dir: URL, named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "fake".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func setCreationDate(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    }
}
