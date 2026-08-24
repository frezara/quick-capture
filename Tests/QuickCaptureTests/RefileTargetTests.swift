import XCTest
@testable import QuickCapture

/// Module 5 — refile targets (issue #32). The user-configured destination
/// folders: persistence and the effective-list filtering.
final class RefileTargetTests: XCTestCase {

    func testDisplayNameUsesLabelWhenPresentElseBasename() {
        XCTAssertEqual(RefileTarget(path: "/Users/me/Code/project-a", label: "Project A").displayName, "Project A")
        XCTAssertEqual(RefileTarget(path: "/Users/me/Code/project-a", label: nil).displayName, "project-a",
                       "with no label the folder basename is shown")
        XCTAssertEqual(RefileTarget(path: "/Users/me/Code/project-a", label: "  ").displayName, "project-a",
                       "a blank label falls back to the basename")
    }

    func testTargetsRoundTripThroughUserDefaults() throws {
        let defaults = UserDefaults(suiteName: "quickcapture-refile-test-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().description) }
        let targets = [
            RefileTarget(path: "/Users/me/a", label: "A"),
            RefileTarget(path: "/Users/me/b", label: nil),
        ]

        defaults.set(try JSONEncoder().encode(targets), forKey: "refileTargets")
        let decoded = try JSONDecoder().decode([RefileTarget].self, from: defaults.data(forKey: "refileTargets")!)

        XCTAssertEqual(decoded, targets, "targets and their order survive a UserDefaults round-trip")
    }

    func testEffectiveExcludesCaptureFilesOwnFolder() throws {
        let capture = try makeTempDir(); defer { try? FileManager.default.removeItem(at: capture) }
        let other = try makeTempDir(); defer { try? FileManager.default.removeItem(at: other) }

        let targets = [RefileTarget(path: capture.path, label: nil), RefileTarget(path: other.path, label: nil)]
        let effective = RefileTarget.effective(targets, captureFolder: capture)

        XCTAssertEqual(effective.map(\.path), [other.path],
                       "the capture file's own folder is never offered as a target (R17)")
    }

    /// R17 compares the capture folder against each target, and that comparison
    /// has to survive the same folder having two names. A symlinked spelling
    /// used to pass the filter — and past it, the refile pipeline appends the
    /// subtree to the capture file and then overwrites it away.
    func testEffectiveExcludesCaptureFolderReachedThroughASymlink() throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("notes-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let effective = RefileTarget.effective([RefileTarget(path: link.path, label: nil)],
                                               captureFolder: real)

        XCTAssertTrue(effective.isEmpty,
                      "the capture folder under a symlinked name is still the capture folder (R17)")
    }

    func testEffectiveFiltersFoldersThatNoLongerExist() throws {
        let present = try makeTempDir(); defer { try? FileManager.default.removeItem(at: present) }
        let capture = try makeTempDir(); defer { try? FileManager.default.removeItem(at: capture) }
        let missing = present.appendingPathComponent("does-not-exist")

        let targets = [RefileTarget(path: present.path, label: nil), RefileTarget(path: missing.path, label: nil)]
        let effective = RefileTarget.effective(targets, captureFolder: capture)

        XCTAssertEqual(effective.map(\.path), [present.path],
                       "a configured folder that no longer exists is dropped (R18)")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-refile-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
