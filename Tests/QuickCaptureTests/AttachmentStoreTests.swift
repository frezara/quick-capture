import XCTest
@testable import QuickCapture

final class AttachmentStoreTests: XCTestCase {

    func testCopyCreatesAttachmentsFolderAndReturnsRelativePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let captureFile = dir.appendingPathComponent("inbox.md")
        let source = try makeScreenshot(in: dir, named: "Screenshot 2026-06-07 at 14.30.12.png")

        let relative = try AttachmentStore.copy(source, besideFile: captureFile)

        XCTAssertTrue(relative.hasPrefix("attachments/screenshot-"),
                      "relative link should point into attachments/ with the normalized name; got \(relative)")
        XCTAssertTrue(relative.hasSuffix(".png"))
        XCTAssertFalse(relative.contains(" "), "link path must be space-free")
        let copied = dir.appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "original must be untouched")
    }

    func testCopyNameDerivesFromSourceCreationDate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let captureFile = dir.appendingPathComponent("inbox.md")
        let source = try makeScreenshot(in: dir, named: "Screenshot.png")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: fixed], ofItemAtPath: source.path)

        let relative = try AttachmentStore.copy(source, besideFile: captureFile)

        XCTAssertEqual(relative, "attachments/screenshot-\(AttachmentStore.timestamp(fixed)).png")
    }

    func testCopyNeverOverwritesCollisionsGetSuffix() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let captureFile = dir.appendingPathComponent("inbox.md")
        let source = try makeScreenshot(in: dir, named: "Screenshot.png", contents: "first")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: fixed], ofItemAtPath: source.path)

        let first = try AttachmentStore.copy(source, besideFile: captureFile)
        try "second".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: fixed], ofItemAtPath: source.path)
        let second = try AttachmentStore.copy(source, besideFile: captureFile)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasSuffix("-2.png"), "collision should get a -2 suffix; got \(second)")
        let firstContents = try String(contentsOf: dir.appendingPathComponent(first), encoding: .utf8)
        XCTAssertEqual(firstContents, "first", "existing attachment must never be overwritten")
    }

    func testCopyPreservesSourceExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let captureFile = dir.appendingPathComponent("inbox.md")
        let source = try makeScreenshot(in: dir, named: "Screenshot.JPG")

        let relative = try AttachmentStore.copy(source, besideFile: captureFile)

        XCTAssertTrue(relative.hasSuffix(".jpg"), "extension preserved (lowercased); got \(relative)")
    }

    func testCopyThrowsWhenSourceMissing() {
        let dir = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let captureFile = dir.appendingPathComponent("inbox.md")
        let ghost = dir.appendingPathComponent("Screenshot gone.png")

        XCTAssertThrowsError(try AttachmentStore.copy(ghost, besideFile: captureFile)) { error in
            guard case AttachmentStore.CopyError.sourceMissing = error else {
                return XCTFail("expected sourceMissing, got \(error)")
            }
        }
    }

    func testTimestampFormat() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let s = AttachmentStore.timestamp(fixed)
        let regex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#)
        XCTAssertEqual(regex.numberOfMatches(in: s, range: NSRange(location: 0, length: s.count)), 1,
                       "timestamp should be YYYY-MM-DD-HHMMSS; got \(s)")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-attach-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeScreenshot(in dir: URL, named name: String, contents: String = "fake-png") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
