import Foundation

/// Only failed saves and attachment imports enter recovery, never ordinary typing.
/// Each attempt is independent so a later failure cannot overwrite an older draft.
enum CaptureRecovery {
    struct Draft: Codable, Identifiable {
        let id: String
        let text: String
        let tag: String?
        let attachments: [String]
        var projectID: String? = nil
    }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuickCapture/Recovery")
    }
    static func beginImport(text: String, tag: String?, attachments: [URL], root: URL = root) throws -> Draft {
        let draft = Draft(id: UUID().uuidString, text: text, tag: tag, attachments: attachments.map(\.path))
        let folder = root.appendingPathComponent(draft.id)
        try HandoffFiles.directory(folder)
        try HandoffFiles.write(Data(text.utf8), to: folder.appendingPathComponent("content.md"))
        try HandoffFiles.write(try HandoffJSON.encode(draft), to: folder.appendingPathComponent("draft.json"))
        return draft
    }
    static func save(text: String, tag: String?, attachments: [URL], projectID: String? = nil, root: URL = root) throws -> Draft {
        let id = UUID().uuidString
        let folder = root.appendingPathComponent(id)
        try HandoffFiles.directory(folder)
        try HandoffFiles.write(Data(text.utf8), to: folder.appendingPathComponent("content.md"))
        // Publish text first. Interrupted attachment recovery still preserves it.
        let initial = Draft(id: id, text: text, tag: tag, attachments: attachments.map(\.path), projectID: projectID)
        try HandoffFiles.write(try HandoffJSON.encode(initial), to: folder.appendingPathComponent("draft.json"))
        var paths: [String] = []
        for (index, url) in attachments.enumerated() {
            do {
                let data = try HandoffFiles.read(url.lastPathComponent, in: url.deletingLastPathComponent(), limit: HandoffFiles.attachmentLimit)
                let copy = folder.appendingPathComponent("\(index).\(url.pathExtension)")
                try HandoffFiles.write(data, to: copy)
                paths.append(copy.path)
            } catch { paths.append(url.path) }
        }
        let draft = Draft(id: id, text: text, tag: tag, attachments: paths, projectID: projectID)
        try HandoffFiles.write(try HandoffJSON.encode(draft), to: folder.appendingPathComponent("draft.json"))
        return draft
    }
    static func drafts(root: URL = root) -> [Draft] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? HandoffFiles.read("draft.json", in: dir, limit: HandoffFiles.manifestLimit) else { return nil }
            return try? JSONDecoder().decode(Draft.self, from: data)
        }.sorted { $0.id < $1.id }
    }
    static func remove(_ id: String, root: URL = root) throws {
        guard UUID(uuidString: id) != nil else { throw HandoffError.invalid("recovery_identity") }
        try FileManager.default.removeItem(at: root.appendingPathComponent(id))
        try HandoffFiles.syncDirectory(root)
    }
}
