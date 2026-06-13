import Foundation

/// Finds the most recent screenshot on disk. Spotlight is the primary source
/// (`kMDItemIsScreenCapture` covers every save location and localized name);
/// a direct scan of the configured screenshot folder is the fallback for
/// Spotlight indexing lag on seconds-old files. Both run per lookup and the
/// newest result wins — there is no persistent watcher (detection is
/// summon-time only by design).
enum ScreenshotLocator {
    struct Screenshot: Equatable {
        let url: URL
        let createdAt: Date
    }

    /// Outcome of a `recent`/`mostRecent` lookup. `accessDenied` is true when the
    /// folder scan hit a permission error (`contentsOfDirectory` threw EPERM under
    /// TCC) — Spotlight may still have returned names, but every thumbnail/preview
    /// would be a placeholder, so the caller should surface a permission hint
    /// rather than the (cosmetically broken) list.
    struct Result: Equatable {
        let screenshots: [Screenshot]
        let accessDenied: Bool
    }

    /// Outcome of a single folder scan: the screenshots found, plus whether the
    /// directory read was *denied* (a thrown error) as distinct from genuinely
    /// empty/missing (no matching files, no error).
    struct ScanResult: Equatable {
        let screenshots: [Screenshot]
        let accessDenied: Bool
    }

    /// Asynchronously find the newest screenshot. Must be called on the main
    /// thread (NSMetadataQuery needs a run loop); the completion fires on the
    /// main queue. `timeout` bounds a stalled Spotlight query — the folder
    /// scan result still answers when it fires.
    static func mostRecent(timeout: TimeInterval = 0.6, completion: @escaping (Screenshot?) -> Void) {
        recent(limit: 1, timeout: timeout) { completion($0.screenshots.first) }
    }

    /// Asynchronously find the newest `limit` screenshots, newest first. Same
    /// contract as `mostRecent` (main thread, main-queue completion) — the
    /// Spotlight and folder-scan results are merged, deduped by path, and the
    /// newest `limit` win. The `Result` also carries an `accessDenied` flag so
    /// the picker can show a permission hint instead of placeholder thumbnails.
    /// Drives the ⌥⌘O screenshot picker.
    static func recent(limit: Int = 5, timeout: TimeInterval = 0.6, completion: @escaping (Result) -> Void) {
        let folder = screenshotFolder()
        let folderPath = folder.standardizedFileURL.path
        let scan = self.scan(in: folder, limit: limit)
        if scan.accessDenied {
            // Once per lookup (one picker open), not once per file — the scan
            // itself returns a single denial signal rather than logging per entry.
            NSLog("ScreenshotLocator: Desktop read denied (TCC) — folder scan unavailable, falling back to Spotlight names only")
        }
        // Spotlight is home-wide, so fetch generously and keep only screenshots
        // that live *directly* in the screenshot folder. Without this, our own
        // attachment copies (named `screenshot-*.png`, and they keep the
        // `kMDItemIsScreenCapture` flag the original carried) sort to the very
        // top by copy time and crowd out the real, newest Desktop screenshots.
        let run = SpotlightRun { spotlightShots in
            var seen = Set<String>()
            let merged = (spotlightShots + scan.screenshots)
                .filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == folderPath }
                .sorted { $0.createdAt > $1.createdAt }
                .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
            completion(Result(screenshots: Array(merged.prefix(limit)), accessDenied: scan.accessDenied))
        }
        run.start(limit: max(limit, 50), timeout: timeout)
    }

    /// Where macOS saves screenshots: `com.apple.screencapture location`,
    /// defaulting to the Desktop.
    static func screenshotFolder() -> URL {
        if let path = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Newest screenshot-named image in `dir` by creation date, or nil.
    static func newestScreenshot(in dir: URL) -> Screenshot? {
        newestScreenshots(in: dir, limit: 1).first
    }

    /// Newest `limit` screenshot-named images in `dir`, newest first. Convenience
    /// over `scan(in:limit:)` that drops the access-denied signal.
    static func newestScreenshots(in dir: URL, limit: Int) -> [Screenshot] {
        scan(in: dir, limit: limit).screenshots
    }

    /// Scan `dir` for the newest `limit` screenshots, newest first, distinguishing
    /// a *denied* directory read (`contentsOfDirectory` threw — EPERM under TCC)
    /// from a genuinely empty or missing directory (no error, no matches). A
    /// non-existent path throws too, but that's a read we couldn't satisfy either
    /// way; callers treat the thrown case as "access unavailable".
    static func scan(in dir: URL, limit: Int) -> ScanResult {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // A missing directory and a permission-denied read both throw here;
            // distinguish them so a deleted/relocated screenshot folder doesn't
            // masquerade as a TCC denial. Only an *existing but unreadable* dir
            // is a true access denial.
            let denied = fm.fileExists(atPath: dir.path)
            return ScanResult(screenshots: [], accessDenied: denied)
        }

        // Resolve the configured base name once — CFPreferences is an IPC
        // round-trip, and a Desktop can hold a lot of files.
        let configuredName = CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String
        let shots = urls
            .filter { isScreenshotFile($0, configuredName: configuredName) }
            .compactMap { url -> Screenshot? in
                guard let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return nil }
                return Screenshot(url: url, createdAt: date)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
        return ScanResult(screenshots: shots, accessDenied: false)
    }

    /// Filename shape of a macOS screenshot: the configured base name
    /// (`com.apple.screencapture name`, default "Screenshot") plus an image
    /// extension. English-only by content; localized names are covered by the
    /// Spotlight path, this scan only backstops indexing lag.
    static func isScreenshotFile(_ url: URL, configuredName: String? = nil) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic"]
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }

        let prefixes = [configuredName, "Screenshot", "Screen Shot"].compactMap { $0 }
        let name = url.lastPathComponent
        return prefixes.contains { name.range(of: $0, options: [.caseInsensitive, .anchored]) != nil }
    }
}

/// One Spotlight query, self-retained until it finishes or times out.
private final class SpotlightRun {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var finished = false
    private var retainSelf: SpotlightRun?
    private let completion: ([ScreenshotLocator.Screenshot]) -> Void

    init(completion: @escaping ([ScreenshotLocator.Screenshot]) -> Void) {
        self.completion = completion
    }

    func start(limit: Int = 1, timeout: TimeInterval) {
        retainSelf = self
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)]

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.query.disableUpdates()
            let shots = (self.query.results as? [NSMetadataItem] ?? [])
                .prefix(limit)
                .compactMap { item -> ScreenshotLocator.Screenshot? in
                    guard let path = item.value(forAttribute: NSMetadataItemPathKey as String) as? String,
                          let date = item.value(forAttribute: NSMetadataItemFSCreationDateKey as String) as? Date
                    else { return nil }
                    return ScreenshotLocator.Screenshot(url: URL(fileURLWithPath: path), createdAt: date)
                }
            self.finish(shots)
        }

        guard query.start() else {
            finish([])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish([])
        }
    }

    private func finish(_ shots: [ScreenshotLocator.Screenshot]) {
        guard !finished else { return }
        finished = true
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        completion(shots)
        retainSelf = nil
    }
}
