import Foundation

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

    /// `YYYY-MM-DD-HHMMSS` in the local timezone, POSIX locale for stable digits.
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }
}
