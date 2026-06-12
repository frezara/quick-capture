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

    func testNewestScreenshotsReturnsNewestFirstUpToLimit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create six screenshots with ascending creation dates.
        var urls: [URL] = []
        for i in 1...6 {
            let url = try makeFile(in: dir, named: "Screenshot 2026-06-0\(i) at 10.00.00.png")
            try setCreationDate(Date(timeIntervalSince1970: TimeInterval(i) * 1_000_000), on: url)
            urls.append(url)
        }

        let result = ScreenshotLocator.newestScreenshots(in: dir, limit: 5)

        XCTAssertEqual(result.count, 5, "limit caps the result count")
        // Newest first: 2026-06-06 … 2026-06-02 (the oldest, 2026-06-01, is dropped).
        XCTAssertEqual(result.map { $0.url.lastPathComponent },
                       urls.reversed().prefix(5).map { $0.lastPathComponent })
    }

    // MARK: - Access-denied vs empty distinction

    func testScanReportsEmptyDirectoryAsNotDenied() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = ScreenshotLocator.scan(in: dir, limit: 5)

        XCTAssertTrue(result.screenshots.isEmpty, "empty directory yields no screenshots")
        XCTAssertFalse(result.accessDenied,
                       "a readable but empty directory must not report access denied")
    }

    func testScanReportsMissingDirectoryAsNotDenied() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)

        let result = ScreenshotLocator.scan(in: missing, limit: 5)

        XCTAssertTrue(result.screenshots.isEmpty, "missing directory yields no screenshots")
        XCTAssertFalse(result.accessDenied,
                       "a missing directory is not an access denial — it just isn't there")
    }

    func testScanReportsUnreadableDirectoryAsDenied() throws {
        let dir = try makeTempDir()
        defer {
            // Restore perms so cleanup can recurse into it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        // A real screenshot lives inside, but the directory itself is unreadable —
        // contentsOfDirectory will throw EPERM, which must read as access-denied,
        // not as an empty folder.
        _ = try makeFile(in: dir, named: "Screenshot 2026-06-01 at 10.00.00.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)

        let result = ScreenshotLocator.scan(in: dir, limit: 5)

        XCTAssertTrue(result.screenshots.isEmpty,
                      "an unreadable directory yields no screenshots (the read threw)")
        XCTAssertTrue(result.accessDenied,
                      "an existing directory whose read throws must report access denied")
    }

    func testNewestScreenshotsIgnoresNonScreenshotFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let shot = try makeFile(in: dir, named: "Screenshot 2026-06-01 at 10.00.00.png")
        let photo = try makeFile(in: dir, named: "IMG_0042.png")
        try setCreationDate(Date(timeIntervalSince1970: 1_000_000), on: shot)
        try setCreationDate(Date(timeIntervalSince1970: 9_000_000), on: photo)

        let result = ScreenshotLocator.newestScreenshots(in: dir, limit: 5)

        XCTAssertEqual(result.map { $0.url.lastPathComponent }, [shot.lastPathComponent],
                       "non-screenshot files are excluded from the picker list")
    }

    func testIsScreenshotFileMatchesDefaultAndLegacyNames() {
        XCTAssertTrue(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/Screenshot 2026-06-07 at 14.30.12.png")))
        XCTAssertTrue(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/Screen Shot 2021-01-01 at 09.00.00.png")))
        XCTAssertFalse(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/Screenshot notes.txt")))
        XCTAssertFalse(ScreenshotLocator.isScreenshotFile(URL(fileURLWithPath: "/x/holiday.png")))
    }

    func testIsScreenshotFileMatchesConfiguredName() {
        // A file whose prefix matches configuredName should be detected.
        XCTAssertTrue(
            ScreenshotLocator.isScreenshotFile(
                URL(fileURLWithPath: "/x/Grab 2026-06-07.png"),
                configuredName: "Grab"
            ),
            "file prefixed with configured name should be recognised as a screenshot"
        )
        // Same path with no configuredName: "Grab" is not a built-in prefix, so it must not match.
        XCTAssertFalse(
            ScreenshotLocator.isScreenshotFile(
                URL(fileURLWithPath: "/x/Grab 2026-06-07.png"),
                configuredName: nil
            ),
            "file with non-standard prefix must not match when configuredName is nil"
        )
        // When configuredName is "Grab", the built-in "Screenshot…" names must still match.
        XCTAssertTrue(
            ScreenshotLocator.isScreenshotFile(
                URL(fileURLWithPath: "/x/Screenshot 2026-06-07 at 14.30.12.png"),
                configuredName: "Grab"
            ),
            "default Screenshot prefix must still match even when a custom configuredName is set"
        )
        XCTAssertTrue(
            ScreenshotLocator.isScreenshotFile(
                URL(fileURLWithPath: "/x/Screen Shot 2021-01-01 at 09.00.00.png"),
                configuredName: "Grab"
            ),
            "legacy Screen Shot prefix must still match even when a custom configuredName is set"
        )
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
