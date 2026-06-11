import Foundation

/// A user-configured refile destination: a folder whose `inbox.md` receives
/// items sent with ⌥⌘R (issue #32). Persisted as an ordered list in
/// `UserDefaults`; the order is the dropdown order. `label` disambiguates
/// folders whose basenames collide (e.g. two "inbox" repos).
struct RefileTarget: Codable, Equatable, Identifiable {
    var path: String
    var label: String?

    var id: String { path }

    /// What the dropdown shows: the label when set, otherwise the folder's
    /// basename so the list stays readable (R13/R14).
    var displayName: String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent
    }

    /// The folder URL, with `~` expanded.
    var folderURL: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The list actually offered in the editor dropdown: drop the capture
    /// file's own folder (you can't refile into the file you're editing, R17)
    /// and any folder that no longer exists on disk (R18). Order is preserved.
    static func effective(_ targets: [RefileTarget], captureFolder: URL, fileManager: FileManager = .default) -> [RefileTarget] {
        let capturePath = captureFolder.standardizedFileURL.path
        return targets.filter { target in
            let url = target.folderURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
            return url.path != capturePath
        }
    }
}
