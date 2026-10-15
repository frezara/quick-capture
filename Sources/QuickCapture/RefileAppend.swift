import Foundation
import Darwin

/// An append never replaces unrelated target bytes. Locks coordinate cooperating
/// writers only; a non-cooperating rename is detected and reported as uncertain.
enum RefileAppend {
    enum AppendError: Error, LocalizedError {
        case unavailable, invalidHeading, uncertain
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The target inbox cannot be opened safely. Check its location and permissions."
            case .invalidHeading: return "The existing target must start with # Inbox. Its bytes were left unchanged."
            case .uncertain: return "The target may have received the item. Check both files before trying again; repeating this refile could duplicate it."
            }
        }
    }
    static func append(_ subtree: String, to url: URL, beforeWrite: (() throws -> Void)? = nil) throws {
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppendError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AppendError.unavailable }
        defer { flock(fd, LOCK_UN) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG else { throw AppendError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { throw FileWriter.WriteError.encodingFailed }
        guard text.isEmpty || text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) == "# Inbox" else {
            throw AppendError.invalidHeading
        }
        try beforeWrite?()
        var current = stat()
        guard lstat(url.path, &current) == 0, current.st_ino == original.st_ino,
              current.st_dev == original.st_dev else { throw AppendError.uncertain }
        // A concurrent append may have added content; append at the current EOF,
        // never a stale offset. A separating newline leaves every prior byte intact.
        let suffix = (text.isEmpty ? "# Inbox\n\n" : "\n") + subtree + "\n"
        let bytes = Data(suffix.utf8)
        var written = 0
        do {
            try bytes.withUnsafeBytes { raw in
                while written < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                    guard n > 0 else { if errno == EINTR { continue }; throw AppendError.uncertain }
                    written += n
                }
            }
            guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw AppendError.uncertain }
            guard lstat(url.path, &current) == 0, current.st_ino == original.st_ino,
                  current.st_dev == original.st_dev else { throw AppendError.uncertain }
            try HandoffFiles.syncDirectory(url.deletingLastPathComponent())
        } catch { throw AppendError.uncertain }
    }
}
