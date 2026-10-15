import Foundation

struct HandoffImportIntent: Codable {
    let id: String; let operation: String; let created: String; let body: String
    let sourceFile: String; let spool: String; let workspace: String; let installation: String; let omitted: [String]
}
struct HandoffPendingImport: Identifiable {
    let id: String
    let body: String
}

actor HandoffStore {
    let root: URL
    private var journal: HandoffJournal?
    private var initialized = false
    private(set) var recoveryWarnings: [String] = []
    var destination: CaptureDestination = SpoolDestination()
    /// Tests interrupt actual persistence boundaries through the same enqueue interface.
    var fault: ((String) throws -> Void)?
    init(root: URL) { self.root = root }
    func setFault(_ hook: ((String) throws -> Void)?) { fault = hook }
    func setDestination(_ value: CaptureDestination) { destination = value }
    private func prepare() throws {
        guard !initialized else { return }
        try HandoffFiles.directory(root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try HandoffFiles.directory(root.appendingPathComponent("bundles"))
        try HandoffFiles.directory(root.appendingPathComponent("staging"))
        journal = try HandoffJournal(url: root.appendingPathComponent("queue.sqlite"))
        for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("bundles"), includingPropertiesForKeys: nil) {
            do {
                let m = try loadBundle(url)
                guard url.lastPathComponent == m.request.payload.capture.capture_id else { throw HandoffError.invalid("bundle_identity") }
                try journal!.register(m)
            } catch { recoveryWarnings.append("A bundle needs recovery; it has been retained.") }
        }
        for r in try journal!.records() where r.state == "delivering" {
            try journal!.update(r.id, state: "pending", attempts: r.attempts)
        }
        initialized = true
    }
    private func loadBundle(_ url: URL) throws -> HandoffManifest {
        let m = try JSONDecoder().decode(HandoffManifest.self, from: HandoffFiles.read("manifest.json", in: url, limit: HandoffFiles.manifestLimit))
        guard m.manifest_version == 1, UUID(uuidString: m.source_id) != nil, m.spool_path.hasPrefix("/") else { throw HandoffError.invalid("manifest_version_or_identity") }
        try m.request.validate()
        guard try HandoffFiles.read("content.md", in: url, limit: 1_048_576) == Data(m.request.payload.capture.body_markdown.utf8) else { throw HandoffError.invalid("corrupt_content") }
        for a in m.request.payload.capture.attachments {
            let data = try HandoffFiles.read(a.relative_path, in: url, limit: HandoffFiles.attachmentLimit)
            guard data.count == a.byte_count, HandoffJSON.digest(data) == a.sha256 else { throw HandoffError.invalid("corrupt_attachment") }
        }
        return m
    }
    func records() throws -> [HandoffRecord] { try prepare(); return try journal!.records() }
    func warnings() throws -> [String] {
        try prepare()
        let incomplete = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path)
        return recoveryWarnings + (incomplete.isEmpty ? [] : ["Interrupted import data is retained. Use Resume Import below; unreadable staging data remains available for manual recovery."])
    }
    func enqueue(sourceID: String, body: String, sourceFile: URL, spool: URL, workspace: String,
                 installation: String, asNew: Bool = false, omit: Set<String> = []) throws -> String {
        try prepare()
        guard body.utf8.count <= 1_048_576, UUID(uuidString: workspace) != nil,
              UUID(uuidString: installation) != nil else { throw HandoffError.invalid("invalid_payload") }
        if !asNew, let prior = try journal!.records().first(where: { $0.manifest.source_id == sourceID }) { return prior.id }
        guard UUID(uuidString: sourceID) != nil else { throw HandoffError.invalid("source_identity") }
        // An intent fixes identity before copying. A retry resumes it even when the source changed.
        let intentKey = sourceID + (asNew ? "-new" : "")
        let intentURL = root.appendingPathComponent("staging").appendingPathComponent(intentKey)
        let intent: HandoffImportIntent
        if FileManager.default.fileExists(atPath: intentURL.appendingPathComponent("intent.json").path) {
            intent = try JSONDecoder().decode(HandoffImportIntent.self, from: HandoffFiles.read("intent.json", in: intentURL, limit: HandoffFiles.manifestLimit))
            if let prior = try journal!.records().first(where: { $0.id == intent.id }) {
                // Completed intents are removed only after registration, never incomplete staging.
                cleanupCompletedIntent(intentURL)
                return prior.id
            }
        } else {
            intent = HandoffImportIntent(id: UUID().uuidString.lowercased(), operation: UUID().uuidString.lowercased(), created: HandoffJSON.timestamp(), body: body,
                            sourceFile: sourceFile.path, spool: spool.resolvingSymlinksInPath().path,
                            workspace: workspace, installation: installation, omitted: omit.sorted())
            try HandoffFiles.directory(intentURL)
            try HandoffFiles.write(try HandoffJSON.encode(intent), to: intentURL.appendingPathComponent("intent.json"))
        }
        let alreadyPublished = root.appendingPathComponent("bundles").appendingPathComponent(intent.id)
        if FileManager.default.fileExists(atPath: alreadyPublished.path) {
            try journal!.register(loadBundle(alreadyPublished))
            cleanupCompletedIntent(intentURL)
            return intent.id
        }
        try fault?("intent")
        let stage = intentURL.appendingPathComponent("bundle")
        try HandoffFiles.directory(stage)
        let sourceRoot = URL(fileURLWithPath: intent.sourceFile).deletingLastPathComponent()
        let paths = SourceIdentity.localAttachments(in: intent.body)
        guard paths.count <= 16 else { throw HandoffError.invalid("attachment_limit") }
        var attachments: [HandoffAttachment] = [], missing: [String] = []
        let omissions = Set(intent.omitted).union(omit)
        for (index, path) in paths.enumerated() {
            try HandoffFiles.validateRelative(path)
            if omissions.contains(path) { continue }
            let relative = "attachments/\(index)"
            let bytes: Data
            do {
                if FileManager.default.fileExists(atPath: stage.appendingPathComponent(relative).path) {
                    bytes = try HandoffFiles.read(relative, in: stage, limit: HandoffFiles.attachmentLimit)
                } else {
                    bytes = try HandoffFiles.read(path, in: sourceRoot, limit: HandoffFiles.attachmentLimit)
                }
            } catch { missing.append(path); continue }
            guard attachments.reduce(0, { $0 + $1.byte_count }) + bytes.count <= 128 * 1024 * 1024 else {
                throw HandoffError.invalid("attachment_limit")
            }
            try HandoffFiles.write(bytes, to: stage.appendingPathComponent(relative))
            try fault?("attachment")
            attachments.append(HandoffAttachment(attachment_id: UUID().uuidString.lowercased(), relative_path: relative,
                source_path: path, original_name: (path as NSString).lastPathComponent,
                media_type: Self.mediaType(path), byte_count: bytes.count, sha256: HandoffJSON.digest(bytes)))
        }
        guard missing.isEmpty else { throw HandoffError.missing(missing) }
        let envelope = HandoffEnvelope(schema_version: 1, capture_id: intent.id, created_at: intent.created,
            source: HandoffSource(app: "Quick Capture", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development", installation_id: intent.installation),
            body_markdown: intent.body, attachments: attachments, omitted_attachments: paths.filter { omissions.contains($0) })
        let request = try HandoffRequest(payload: HandoffPayload(workspace_id: intent.workspace, operation_id: intent.operation, capture: envelope))
        try request.validate()
        let manifest = HandoffManifest(manifest_version: 1, source_id: sourceID, spool_path: intent.spool, request: request)
        try HandoffFiles.write(Data(intent.body.utf8), to: stage.appendingPathComponent("content.md"))
        try HandoffFiles.write(try HandoffJSON.encode(manifest), to: stage.appendingPathComponent("manifest.json"))
        try fault?("manifest")
        let complete = root.appendingPathComponent("bundles").appendingPathComponent(intent.id)
        if FileManager.default.fileExists(atPath: complete.path) {
            let existing = try loadBundle(complete)
            try journal!.register(existing)
        } else {
            try HandoffFiles.publish(stage, to: complete)
            try fault?("published")
            try journal!.register(manifest)
        }
        try fault?("registered")
        cleanupCompletedIntent(intentURL)
        return intent.id
    }
    private func cleanupCompletedIntent(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            try HandoffFiles.syncDirectory(url.deletingLastPathComponent())
        } catch {
            let warning = "A queued handoff has leftover import metadata. Delivery is safe; cleanup needs attention."
            if !recoveryWarnings.contains(warning) { recoveryWarnings.append(warning) }
        }
    }
    func pendingImports() throws -> [HandoffPendingImport] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("staging"), includingPropertiesForKeys: nil).compactMap { url in
            guard let data = try? HandoffFiles.read("intent.json", in: url, limit: HandoffFiles.manifestLimit),
                  let intent = try? JSONDecoder().decode(HandoffImportIntent.self, from: data) else { return nil }
            return HandoffPendingImport(id: url.lastPathComponent, body: intent.body)
        }
    }
    func resumeImport(_ key: String, omit: Set<String> = []) throws -> String {
        try prepare()
        let asNew = key.hasSuffix("-new")
        let sourceID = asNew ? String(key.dropLast(4)) : key
        guard UUID(uuidString: sourceID) != nil else { throw HandoffError.invalid("import_identity") }
        let dir = root.appendingPathComponent("staging").appendingPathComponent(key)
        let intent = try JSONDecoder().decode(HandoffImportIntent.self, from: HandoffFiles.read("intent.json", in: dir, limit: HandoffFiles.manifestLimit))
        return try enqueue(sourceID: sourceID, body: intent.body, sourceFile: URL(fileURLWithPath: intent.sourceFile),
            spool: URL(fileURLWithPath: intent.spool), workspace: intent.workspace, installation: intent.installation, asNew: asNew, omit: omit)
    }
    func retry(_ id: String) throws {
        try prepare()
        guard let r = try journal!.records().first(where: { $0.id == id }), r.state != "delivered" else { return }
        try journal!.update(id, state: "pending", attempts: r.attempts)
    }
    func deliverDue(enabled: Bool, now: Date = Date()) throws {
        try prepare()
        guard enabled else { return }
        for r in try journal!.records().filter({ ["pending", "retry_wait"].contains($0.state) && $0.nextAttempt <= now.timeIntervalSince1970 }).prefix(1) {
            try journal!.update(r.id, state: "delivering", attempts: r.attempts + 1)
            do {
                let bundle = root.appendingPathComponent("bundles").appendingPathComponent(r.id)
                let manifest = try loadBundle(bundle)
                guard try HandoffJSON.encode(manifest) == HandoffJSON.encode(r.manifest) else { throw HandoffError.invalid("journal_bundle_mismatch") }
                let receipt = try destination.deliver(manifest, bundle: bundle)
                try receipt.validate(for: manifest.request)
                try fault?("receipt")
                try journal!.update(r.id, state: "delivered", attempts: r.attempts + 1, receipt: receipt)
            } catch {
                let typed = error as? HandoffError
                let code = typed?.code ?? "io_error"
                let temporary = code == "unavailable" || code == "io_error"
                let delay = min(300.0, pow(2, Double(min(r.attempts + 1, 8)))) * Double.random(in: 0.8...1.2)
                try journal!.update(r.id, state: temporary ? "retry_wait" : "needs_attention", attempts: r.attempts + 1,
                                    next: now.timeIntervalSince1970 + delay, error: code)
            }
        }
    }
    private static func mediaType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}

enum SourceIdentity {
    static let pattern = #"<!--qc-source:([0-9a-fA-F-]{36})-->"#
    static func ids(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            let value = String(text[range]).lowercased()
            return UUID(uuidString: value) == nil ? nil : value
        }
    }
    static func localAttachments(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            let path = String(text[range])
            if path.lowercased().hasPrefix("https://") || path.lowercased().hasPrefix("http://") { return nil }
            return seen.insert(path).inserted ? path : nil
        }
    }
}
