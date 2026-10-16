import Foundation

struct OrganiserSnapshot: Codable, Equatable {
    var revision: Int
    var item: OrganiserItem
    var files: [OrganiserFile]
}

struct OrganiserRemote: Decodable {
    let id: String
    let revision: Int
    let document: OrganiserItem
    let attachments: [Attachment]
    struct Attachment: Decodable {
        let path: String
        let media_type: String
        let byte_count: Int
    }
}

/// Only identities already enrolled by capture are inspected. Unmarked history
/// and records created on other devices are never implicitly imported.
struct OrganiserSource {
    let file: URL
    let content: String
    let range: Range<Int>?
    let item: OrganiserItem

    static func body(_ item: OrganiserItem) -> String {
        var lines = item.body_markdown.components(separatedBy: "\n")
        if lines[0].range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) != nil {
            lines[0] = lines[0].replacingOccurrences(of: #"^([-*+] )\[[ xX]\]"#,
                with: "$1[\(item.completed ? "x" : " ")]", options: .regularExpression)
        } else {
            // Organiser notes may contain plain Markdown; retain it inside the
            // linked item so its identity still has an unambiguous subtree.
            lines = ["- [\(item.completed ? "x" : " ")] " + lines[0]] + lines.dropFirst().map { "  " + $0 }
        }
        for index in lines.indices.dropFirst() {
            if FileWriter.indentWidth(lines[index]) < 2 { lines[index] = "  " + lines[index] }
        }
        return lines.joined(separator: "\n")
    }

    static func locate(_ record: OrganiserDelivery, base: OrganiserItem, candidates: [URL]) throws -> OrganiserSource {
        let source = URL(fileURLWithPath: record.sourceFile)
        let moveTarget = record.moveTarget.map { URL(fileURLWithPath: $0) }
        var urls = [source, FileWriter.archiveURL(for: source)] + candidates + (moveTarget.map { [$0] } ?? [])
        urls += candidates.map(FileWriter.archiveURL)
        var seen = Set<String>(), matches: [OrganiserSource] = []
        var sourceText: String?
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            if !FileManager.default.fileExists(atPath: url.path) {
                if url == source || url == moveTarget { throw HandoffError.invalid("The linked file is unavailable. Sync is waiting; no deletion was sent.") }
                continue
            }
            let text = try FileWriter.read(url, allowingMissing: false)
            if url == source {
                guard text.components(separatedBy: "\n").first == "# Inbox" else {
                    throw HandoffError.invalid("The linked file has no Inbox heading. Sync is waiting; no deletion was sent.")
                }
                sourceText = text
            }
            let lines = text.components(separatedBy: "\n")
            var section = FileWriter.untaggedSection
            for (index, line) in lines.enumerated() {
                if line.hasPrefix("## ") { section = String(line.dropFirst(3)) }
                let ids = SourceIdentity.ids(in: line)
                guard ids.contains(record.id) else { continue }
                guard ids == [record.id], let initialRange = FileWriter.subtreeRange(in: text, atLine: index), initialRange.lowerBound == index else {
                    throw HandoffError.invalid("The source marker is ambiguous. Restore it to one item before synchronising.")
                }
                var end = initialRange.upperBound
                let indent = FileWriter.indentWidth(line)
                while end < lines.count && FileWriter.indentWidth(lines[end]) > indent { end += 1 }
                let range = index..<end
                guard SourceIdentity.ids(in: lines[range].joined(separator: "\n")) == [record.id] else {
                    throw HandoffError.invalid("Linked items are nested inside one another. Move them to separate items before synchronising.")
                }
                var item = base
                let raw = FileWriter.dedent(lines[range].joined(separator: "\n"))
                    .replacingOccurrences(of: #" ?<!--qc-source:[0-9a-fA-F-]{36}-->"#, with: "", options: .regularExpression)
                // Preserve the server representation when only its local projection differs.
                item.body_markdown = raw == body(base) ? base.body_markdown : raw
                item.completed = line.range(of: #"^\s*[-*+] \[[xX]\]"#, options: .regularExpression) != nil
                item.section = section
                item.deleted = false
                matches.append(OrganiserSource(file: url, content: text, range: range, item: item))
            }
        }
        guard matches.count <= 1 else { throw HandoffError.invalid("This source identity occurs more than once. Remove the duplicate marker before synchronising.") }
        if let match = matches.first { return match }
        var deleted = base; deleted.deleted = true
        return OrganiserSource(file: source, content: sourceText!, range: nil, item: deleted)
    }

    func replacing(with item: OrganiserItem, id: String) throws -> String {
        var lines = content.components(separatedBy: "\n")
        if let range { lines.removeSubrange(range) }
        var remaining = lines.joined(separator: "\n")
        if item.deleted { return remaining }
        guard !item.section.contains("\n"), !item.section.contains("\r"), !item.section.isEmpty,
              SourceIdentity.ids(in: item.body_markdown).isEmpty else {
            throw HandoffError.invalid("The organiser version has an invalid section or source marker.")
        }
        var replacement = Self.body(item).components(separatedBy: "\n")
        replacement[0] += " <!--qc-source:\(id)-->"
        // Keep position and indentation for ordinary edits; section moves use
        // the same insertion rules as local capture.
        if let range, item.section == self.item.section {
            let oldLines = content.components(separatedBy: "\n")
            let indent = String(oldLines[range.lowerBound].prefix(while: { $0 == " " || $0 == "\t" }))
            lines.insert(contentsOf: replacement.map { indent + $0 }, at: range.lowerBound)
            remaining = lines.joined(separator: "\n")
        } else {
            remaining = FileWriter.insert(item: replacement[0], childLines: Array(replacement.dropFirst()), underHeading: item.section, in: remaining)
        }
        return remaining
    }
}

extension OrganiserOutbox {
    func prepareMove(ids: [String], to target: URL) throws {
        try locked {
            for id in ids {
                guard FileManager.default.fileExists(atPath: try directory(id).appendingPathComponent("record.json").path) else { continue }
                var record = try read(id); record.moveTarget = target.path; try save(record)
            }
        }
    }

    func cancelMove(ids: [String]) {
        try? locked {
            for id in ids {
                guard FileManager.default.fileExists(atPath: try directory(id).appendingPathComponent("record.json").path) else { continue }
                var record = try read(id); record.moveTarget = nil; try save(record)
            }
        }
    }

    func operation(_ record: OrganiserDelivery) throws -> OrganiserOperation {
        let bytes = try HandoffFiles.read(record.requestFile ?? "request.json", in: directory(record.id), limit: 26 * 1024 * 1024)
        guard HandoffJSON.digest(bytes) == record.digest else { throw HandoffError.invalid("The retained request failed its integrity check.") }
        return try JSONDecoder().decode(OrganiserOperation.self, from: bytes)
    }

    func baseline(_ record: OrganiserDelivery) throws -> OrganiserSnapshot {
        if let baseline = record.baseline { return baseline }
        let op = try operation(record)
        return OrganiserSnapshot(revision: record.receipt?.revision ?? 0, item: op.item, files: op.attachments)
    }

    func files(for item: OrganiserItem, at file: URL, retaining baseline: [OrganiserFile], previousItem: OrganiserItem) throws -> [OrganiserFile] {
        if item.deleted { return baseline }
        let paths = SourceIdentity.localAttachments(in: item.body_markdown).sorted()
        guard paths.count <= 16, item.body_markdown.utf8.count <= 1024 * 1024 else { throw HandoffError.invalid("Item exceeds organiser limits.") }
        var total = 0
        let oldPaths = Set(SourceIdentity.localAttachments(in: previousItem.body_markdown))
        let unreferenced = baseline.filter { !oldPaths.contains($0.path) && !paths.contains($0.path) }
        let referenced = try paths.map { path in
            let data = try HandoffFiles.read(path, in: file.deletingLastPathComponent().resolvingSymlinksInPath(), limit: 18 * 1024 * 1024)
            total += data.count
            guard total <= 18 * 1024 * 1024 else { throw HandoffError.invalid("Attachments exceed 18 MiB.") }
            let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
            return OrganiserFile(path: path, media_type: baseline.first(where: { $0.path == path })?.media_type
                ?? types[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream", data_base64: data.base64EncodedString())
        }
        guard referenced.count + unreferenced.count <= 16 else { throw HandoffError.invalid("Item exceeds the organiser attachment limit.") }
        return (referenced + unreferenced).sorted { $0.path < $1.path }
    }

    func queue(_ snapshot: OrganiserSnapshot, record: inout OrganiserDelivery) throws {
        let opID = UUID().uuidString.lowercased()
        let op = OrganiserOperation(operation_id: opID, item_id: record.id, expected_revision: snapshot.revision,
                                    item: snapshot.item, attachments: snapshot.files)
        let data = try HandoffJSON.encode(op)
        guard data.count <= 26 * 1024 * 1024 else { throw HandoffError.invalid("Item exceeds the organiser request limit.") }
        // Publish immutable bytes before atomically switching the record pointer.
        let name = opID + ".json"
        try HandoffFiles.write(data, to: directory(record.id).appendingPathComponent(name))
        record.operationID = opID; record.requestFile = name; record.digest = HandoffJSON.digest(data)
        record.state = "pending"; record.problem = nil; record.syncProblem = nil
        record.attempts = 0; record.nextAttempt = .distantPast
        record.summary = String(snapshot.item.body_markdown.prefix(120))
        try save(record)
    }

    func reconcileLocal(_ id: String, candidates: [URL]) throws {
        try locked {
            var record = try read(id)
            guard record.state == "delivered", record.conflict == nil, record.incoming == nil else { return }
            let base = try baseline(record)
            // A tombstone is terminal, even if an old Markdown copy reappears.
            guard !base.item.deleted else { return }
            let local = try OrganiserSource.locate(record, base: base.item, candidates: candidates)
            let attachments = try files(for: local.item, at: local.file, retaining: base.files, previousItem: base.item)
            let metadataChanged = record.sourceFile != local.file.path || record.syncProblem != nil || record.moveTarget != nil
            record.sourceFile = local.file.path; record.syncProblem = nil; record.moveTarget = nil
            if local.item != base.item || attachments != base.files {
                try queue(OrganiserSnapshot(revision: base.revision, item: local.item, files: attachments), record: &record)
            } else if metadataChanged { try save(record) }
        }
    }

    func syncProblem(_ id: String, _ problem: String) {
        try? locked {
            var record = try read(id)
            guard record.syncProblem != problem else { return }
            record.syncProblem = problem; try save(record)
        }
    }

    func receive(_ remote: OrganiserSnapshot, id: String, candidates: [URL], force: Bool = false) throws {
        try locked {
            var record = try read(id)
            let base = try baseline(record)
            guard remote.revision >= base.revision else { return }
            guard remote.revision > base.revision || record.incoming != nil else { return }
            let local = try OrganiserSource.locate(record, base: base.item, candidates: candidates)
            let localFiles = try files(for: local.item, at: local.file, retaining: base.files, previousItem: base.item)
            let sameMarkdown = OrganiserSource.body(local.item) == OrganiserSource.body(remote.item)
                && local.item.section == remote.item.section && local.item.completed == remote.item.completed
                && local.item.deleted == remote.item.deleted
            let alreadyApplied = (local.item.deleted && remote.item.deleted) || (sameMarkdown && localFiles == remote.files)
            let changed = local.item != base.item || localFiles != base.files
            let authorisedIncoming = (record.state == "importing" && local.range == nil)
                || (record.incoming == remote && record.incomingSourceDigest == HandoffJSON.digest(Data(local.content.utf8)))
            if !force && !authorisedIncoming && !alreadyApplied && (changed || record.state != "delivered") {
                record.conflict = remote; record.incoming = nil; record.incomingSourceDigest = nil; record.state = "conflict"
                record.problem = "Both versions are retained. Choose which version to keep."
                try save(record); return
            }
            // Incoming attachment replacement must not overwrite a file shared
            // with another item. New bytes are written only to unused paths.
            let folder = local.file.deletingLastPathComponent().resolvingSymlinksInPath()
            for attachment in remote.files {
                try HandoffFiles.validateRelative(attachment.path)
                guard let bytes = Data(base64Encoded: attachment.data_base64) else { throw HandoffError.invalid("Invalid attachment bytes.") }
                let url = folder.appendingPathComponent(attachment.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    let existing = try HandoffFiles.read(attachment.path, in: folder, limit: 18 * 1024 * 1024)
                    guard existing == bytes else { throw HandoffError.invalid("An incoming attachment has the same path as a different local file. Rename it in the organiser before retrying.") }
                } else {
                    // Do not traverse an existing symlink in a parent directory.
                    var parent = folder
                    for component in attachment.path.split(separator: "/").dropLast() {
                        parent.appendPathComponent(String(component)); try HandoffFiles.directory(parent)
                    }
                    try HandoffFiles.write(bytes, to: url)
                }
            }
            let content = try local.replacing(with: remote.item, id: id)
            record.incoming = remote; record.incomingSourceDigest = HandoffJSON.digest(Data(local.content.utf8)); record.sourceFile = local.file.path
            try save(record)
            try FileWriter.write(Data(content.utf8), to: local.file, ifStillMatching: local.content)
            record.baseline = remote; record.incoming = nil; record.incomingSourceDigest = nil; record.conflict = nil
            record.state = "delivered"; record.problem = nil; record.syncProblem = nil
            record.summary = String(remote.item.body_markdown.prefix(120))
            try save(record)
        }
    }

    func keepLocal(_ id: String, candidates: [URL]) throws {
        try locked {
            var record = try read(id)
            guard let remote = record.conflict, !remote.item.deleted else {
                throw HandoffError.invalid("A deleted organiser identity cannot be restored. Keep the text locally or capture it as a new item.")
            }
            let base = try baseline(record)
            let local = try OrganiserSource.locate(record, base: base.item, candidates: candidates)
            let attachments = try files(for: local.item, at: local.file, retaining: base.files, previousItem: base.item)
            record.sourceFile = local.file.path; record.baseline = remote; record.conflict = nil
            try queue(OrganiserSnapshot(revision: remote.revision, item: local.item, files: attachments), record: &record)
        }
    }
}

extension OrganiserHTTP {
    func fetch(endpoint: String, token: String, id: String, known: OrganiserSnapshot? = nil) async throws -> OrganiserSnapshot {
        guard UUID(uuidString: id) != nil else { throw HandoffError.invalid("Invalid item identity.") }
        let path = "/api/items/" + id
        let (data, status) = try await request(endpoint: endpoint, token: token, path: path)
        guard status == 200 else { throw HandoffError.invalid("Could not read organiser item (HTTP \(status)).") }
        let remote = try JSONDecoder().decode(OrganiserRemote.self, from: data)
        guard remote.id == id, remote.revision > 0, remote.attachments.count <= 16,
              remote.attachments.reduce(0, { $0 + $1.byte_count }) <= 18 * 1024 * 1024 else {
            throw HandoffError.invalid("Invalid or oversized organiser item.")
        }
        if let known, known.revision == remote.revision { return known }
        var files: [OrganiserFile] = []
        for attachment in remote.attachments.sorted(by: { $0.path < $1.path }) {
            try HandoffFiles.validateRelative(attachment.path)
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "path", value: attachment.path)]
            let (bytes, code) = try await request(endpoint: endpoint, token: token, path: path + "/attachment?" + query.percentEncodedQuery!)
            guard code == 200, bytes.count == attachment.byte_count else { throw HandoffError.invalid("Attachment changed during sync; retrying is safe.") }
            files.append(OrganiserFile(path: attachment.path, media_type: attachment.media_type, data_base64: bytes.base64EncodedString()))
        }
        if !files.isEmpty {
            let (check, code) = try await request(endpoint: endpoint, token: token, path: path)
            guard code == 200, try JSONDecoder().decode(OrganiserRemote.self, from: check).revision == remote.revision else {
                throw HandoffError.invalid("Item changed while downloading attachments; retrying is safe.")
            }
        }
        return OrganiserSnapshot(revision: remote.revision, item: remote.document, files: files)
    }
}

struct OrganiserChanges: Decodable {
    struct Change: Decodable {
        let sequence: Int
        let item_id: String
        let revision: Int
    }
    let changes: [Change]
    let cursor: Int
}

extension OrganiserOutbox {
    private func cursorURL(_ endpoint: String) -> URL {
        root.appendingPathComponent("feed-" + HandoffJSON.digest(Data(endpoint.utf8)) + ".json")
    }
    func cursor(for endpoint: String) throws -> Int {
        try locked {
            let url = cursorURL(endpoint)
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            return try JSONDecoder().decode(Int.self, from: HandoffFiles.read(url.lastPathComponent, in: root, limit: 128))
        }
    }
    func advanceCursor(_ cursor: Int, endpoint: String) throws {
        try locked { try HandoffFiles.write(HandoffJSON.encode(cursor), to: cursorURL(endpoint)) }
    }

    /// Persist enrolment before touching Markdown. An interrupted import resumes
    /// through the same incoming journal as an update, without creating an item
    /// or fabricating a server delivery receipt.
    func importItem(_ remote: OrganiserSnapshot, id: String, file: URL, endpoint: String, candidates: [URL]) throws {
        try locked {
            let folder = try directory(id)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("record.json").path) {
                let record = try read(id)
                guard record.endpoint == endpoint else { throw HandoffError.invalid("This item identity is already linked to another organiser.") }
                return
            }
            if !remote.item.deleted {
                if !FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileWriter.write(Data("# Inbox\n".utf8), to: file, ifStillMatching: "")
                }
                let text = try FileWriter.read(file, allowingMissing: false)
                guard !SourceIdentity.ids(in: text).contains(id) else {
                    throw HandoffError.invalid("An untracked copy of this item already exists in the capture file. Its contents have been preserved.")
                }
            }
            let opID = UUID().uuidString.lowercased()
            let operation = OrganiserOperation(operation_id: opID, item_id: id, expected_revision: remote.revision,
                                              item: remote.item, attachments: remote.files)
            let bytes = try HandoffJSON.encode(operation)
            try HandoffFiles.write(bytes, to: folder.appendingPathComponent("request.json"))
            var absent = remote; absent.revision = 0; absent.item.deleted = true
            var record = OrganiserDelivery(id: id, operationID: opID, sourceFile: file.path,
                summary: String(remote.item.body_markdown.prefix(120)), digest: HandoffJSON.digest(bytes),
                endpoint: endpoint, state: remote.item.deleted ? "delivered" : "importing")
            record.baseline = remote.item.deleted ? remote : absent
            record.incoming = remote.item.deleted ? nil : remote
            try save(record)
        }
        try receive(remote, id: id, candidates: candidates)
    }
}
