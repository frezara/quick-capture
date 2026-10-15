import Foundation
import Darwin

enum HandoffFiles {
    static let attachmentLimit = 64 * 1024 * 1024
    static let manifestLimit = 2 * 1024 * 1024
    static func validateRelative(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"), !path.contains("\\"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HandoffError.invalid("unsafe_path")
        }
    }
    static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw HandoffError.invalid("unsafe_directory") }
    }
    static func directory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            try directory(parent)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try syncDirectory(parent)
        }
        try checkDirectory(url)
    }
    static func read(_ relative: String, in root: URL, limit: Int) throws -> Data {
        try validateRelative(relative)
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw HandoffError.invalid("unreadable_directory") }
        defer { close(fd) }
        let parts = relative.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw HandoffError.invalid("unsafe_path") }
            close(fd); fd = next
        }
        let file = openat(fd, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw HandoffError.invalid("unreadable_file") }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else { throw HandoffError.invalid("file_limit_or_type") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(file, &buffer, buffer.count)
            guard n >= 0 else { if errno == EINTR { continue }; throw HandoffError.invalid("read_failed") }
            if n == 0 { break }
            guard result.count + n <= limit else { throw HandoffError.invalid("file_limit") }
            result.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(file, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw HandoffError.invalid("file_changed") }
        return result
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw HandoffError.invalid("directory_sync") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw HandoffError.invalid("directory_sync") }
    }
    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try directory(parent)
        let temp = parent.appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HandoffError.invalid("write_failed") }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { if errno == EINTR { continue }; throw HandoffError.invalid("write_failed") }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw HandoffError.invalid("file_sync") }
        // F_FULLFSYNC asks macOS to flush device caches as well; fail closed if unsupported.
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw HandoffError.invalid("full_sync") }
        guard rename(temp.path, url.path) == 0 else { throw HandoffError.invalid("publish_failed") }
        try syncDirectory(parent)
    }
    static func publish(_ source: URL, to destination: URL) throws {
        try syncDirectory(source)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw HandoffError.invalid("publish_conflict") }
        try syncDirectory(destination.deletingLastPathComponent())
    }
}
