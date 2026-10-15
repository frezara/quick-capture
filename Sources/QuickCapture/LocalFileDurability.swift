import Foundation
import Darwin

enum LocalFileDurability {
    enum FlushError: Error, LocalizedError {
        case uncertain
        var errorDescription: String? {
            "The file may have been written, but its durable save could not be confirmed. Your draft is retained. Inspect the file before saving it again."
        }
    }
    static func sync(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        let fd = open(resolved.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw FlushError.uncertain }
        defer { close(fd) }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw FlushError.uncertain }
        do { try HandoffFiles.syncDirectory(resolved.deletingLastPathComponent()) }
        catch { throw FlushError.uncertain }
    }
}
