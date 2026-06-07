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

    /// Asynchronously find the newest screenshot. Must be called on the main
    /// thread (NSMetadataQuery needs a run loop); the completion fires on the
    /// main queue. `timeout` bounds a stalled Spotlight query — the folder
    /// scan result still answers when it fires.
    static func mostRecent(timeout: TimeInterval = 0.6, completion: @escaping (Screenshot?) -> Void) {
        let folderShot = newestScreenshot(in: screenshotFolder())
        let run = SpotlightRun { spotlightShot in
            let best = [spotlightShot, folderShot]
                .compactMap { $0 }
                .max { $0.createdAt < $1.createdAt }
            completion(best)
        }
        run.start(timeout: timeout)
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
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return urls
            .filter { isScreenshotFile($0) }
            .compactMap { url -> Screenshot? in
                guard let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return nil }
                return Screenshot(url: url, createdAt: date)
            }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Filename shape of a macOS screenshot: the configured base name
    /// (`com.apple.screencapture name`, default "Screenshot") plus an image
    /// extension. English-only by content; localized names are covered by the
    /// Spotlight path, this scan only backstops indexing lag.
    static func isScreenshotFile(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic"]
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }

        let configuredName = CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String
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
    private let completion: (ScreenshotLocator.Screenshot?) -> Void

    init(completion: @escaping (ScreenshotLocator.Screenshot?) -> Void) {
        self.completion = completion
    }

    func start(timeout: TimeInterval) {
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
            var shot: ScreenshotLocator.Screenshot?
            if let item = self.query.results.first as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey as String) as? String,
               let date = item.value(forAttribute: NSMetadataItemFSCreationDateKey as String) as? Date {
                shot = ScreenshotLocator.Screenshot(url: URL(fileURLWithPath: path), createdAt: date)
            }
            self.finish(shot)
        }

        guard query.start() else {
            finish(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    private func finish(_ shot: ScreenshotLocator.Screenshot?) {
        guard !finished else { return }
        finished = true
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        completion(shot)
        retainSelf = nil
    }
}
