import Foundation
import ImageIO

enum AttachmentStore {
    enum CopyError: LocalizedError {
        case sourceMissing(URL)
        var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "The screenshot is no longer at \(url.path)."
            }
        }
    }

    static let folderName = "attachments"

    /// Copy `source` into an `attachments/` folder beside `file` and return
    /// the relative link path (`attachments/<name>`). The copy is named
    /// `screenshot-YYYY-MM-DD-HHMMSS.<ext>` from the source's creation date —
    /// space-free so markdown links and bridge URLs need no escaping — and
    /// never overwrites: collisions get `-2`, `-3`, … suffixes.
    static func copy(_ source: URL, besideFile file: URL, now: Date = Date()) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw CopyError.sourceMissing(source) }

        let dir = file.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let attributes = try? fm.attributesOfItem(atPath: source.path)
        let created = attributes?[.creationDate] as? Date ?? now
        let base = "screenshot-\(timestamp(created))"
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()

        var candidate = "\(base).\(ext)"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n).\(ext)"
            n += 1
        }

        try fm.copyItem(at: source, to: dir.appendingPathComponent(candidate))
        return "\(folderName)/\(candidate)"
    }

    // MARK: - Refile relocation (issue #32)

    /// Copy an in-folder attachment (referenced as `relativePath`, e.g.
    /// `attachments/a.png`, beside `sourceFile`) into the `attachments/` folder
    /// beside `targetFile`, **preserving its basename**. On a name collision in
    /// the target a `-2`/`-3`/… suffix is added (the existing file is never
    /// overwritten) and the renamed relative path is returned, so the caller can
    /// rewrite the link only when a rename actually happened. Returns nil when
    /// the source is missing — best-effort: there's nothing to move and the link
    /// text is carried verbatim (issue #32 R26).
    static func copyForRefile(_ relativePath: String, from sourceFile: URL, to targetFile: URL) throws -> String? {
        let fm = FileManager.default
        let sourceURL = sourceFile.deletingLastPathComponent().appendingPathComponent(relativePath)
        guard fm.fileExists(atPath: sourceURL.path) else {
            NSLog("Refile: attachment missing at \(sourceURL.path); carrying link text verbatim")
            return nil
        }

        let dir = targetFile.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = (relativePath as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var candidate = name
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            n += 1
        }

        try fm.copyItem(at: sourceURL, to: dir.appendingPathComponent(candidate))
        return "\(folderName)/\(candidate)"
    }

    /// Delete a refiled source attachment after a successful move — but only if
    /// the post-removal source content no longer references that exact relative
    /// path (the shared-path safety check, issue #32 R28), so a move never
    /// breaks an item that stayed behind. Missing file or a still-referenced
    /// path is a no-op. Never throws — best-effort cleanup is logged, not
    /// surfaced.
    static func removeRefiledOriginal(_ relativePath: String, besideFile sourceFile: URL, ifNotReferencedIn remaining: String) {
        guard !remaining.contains("](\(relativePath))") else { return }
        let url = sourceFile.deletingLastPathComponent().appendingPathComponent(relativePath)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("Refile: could not remove moved original \(url.path): \(error)")
        }
    }

    /// `YYYY-MM-DD-HHMMSS` in the local timezone, POSIX locale for stable digits.
    static func timestamp(_ date: Date) -> String {
        return formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// Downscaled decode shared by the capture chip (small) and the editor's
    /// bridge-served preview (large). One home for the ImageIO options dance.
    static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
