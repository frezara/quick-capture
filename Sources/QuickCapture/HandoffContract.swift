import Foundation
import CryptoKit

enum HandoffError: Error, LocalizedError {
    case invalid(String), unavailable, conflict, missing([String]), uncertain, disabled
    var errorDescription: String? {
        switch self {
        case .invalid(let code): return "Delivery needs attention (\(code)). The local item is retained."
        case .unavailable: return "Waiting for organiser."
        case .conflict: return "The organiser rejected an identity or payload conflict."
        case .missing(let paths): return "Missing or unreadable attachments:\n" + paths.joined(separator: "\n")
        case .uncertain: return "The target may have received the item. Check both files before trying again; the source was retained where possible."
        case .disabled: return "Enable organiser delivery and select a spool folder in Settings."
        }
    }
    var code: String {
        switch self {
        case .invalid(let c): return c
        case .unavailable: return "unavailable"
        case .conflict: return "conflict"
        case .missing: return "missing_attachment"
        case .uncertain: return "uncertain"
        case .disabled: return "disabled"
        }
    }
}

enum HandoffJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func timestamp(_ date: Date = Date()) -> String { ISO8601DateFormatter().string(from: date) }
}

struct HandoffAttachment: Codable, Equatable {
    let attachment_id: String
    let relative_path: String
    let source_path: String
    let original_name: String
    let media_type: String
    let byte_count: Int
    let sha256: String
}
struct HandoffSource: Codable, Equatable {
    let app: String
    let version: String
    let installation_id: String
}
struct HandoffEnvelope: Codable, Equatable {
    let schema_version: Int
    let capture_id: String
    let created_at: String
    let source: HandoffSource
    let body_markdown: String
    let attachments: [HandoffAttachment]
    let omitted_attachments: [String]
    var title: String? = nil
    var source_url: String? = nil
    var kind_hint: String? = nil
}
struct HandoffPayload: Codable, Equatable {
    let workspace_id: String
    let operation_id: String
    let capture: HandoffEnvelope
}
struct HandoffRequest: Codable, Equatable {
    let payload: HandoffPayload
    let payload_sha256: String
    init(payload: HandoffPayload) throws {
        self.payload = payload
        payload_sha256 = HandoffJSON.digest(try HandoffJSON.encode(payload))
    }
    func validate() throws {
        let c = payload.capture
        guard c.schema_version == 1 else { throw HandoffError.invalid("unsupported_version") }
        guard UUID(uuidString: c.capture_id) != nil, UUID(uuidString: payload.operation_id) != nil,
              UUID(uuidString: payload.workspace_id) != nil,
              UUID(uuidString: c.source.installation_id) != nil,
              ISO8601DateFormatter().date(from: c.created_at) != nil,
              c.source.app == "Quick Capture", c.source.version.utf8.count <= 128,
              c.body_markdown.utf8.count <= 1_048_576,
              !c.body_markdown.isEmpty || c.source_url?.isEmpty == false || !c.attachments.isEmpty,
              c.attachments.count <= 16, c.omitted_attachments.count <= 16,
              (c.title?.utf8.count ?? 0) <= 4096, (c.source_url?.utf8.count ?? 0) <= 8192,
              c.kind_hint == nil || ["note", "task", "link", "document"].contains(c.kind_hint!),
              payload_sha256 == HandoffJSON.digest(try HandoffJSON.encode(payload)) else {
            throw HandoffError.invalid("invalid_payload")
        }
        var paths = Set<String>(), ids = Set<String>(), sources = Set<String>()
        var total = 0
        for a in c.attachments {
            try HandoffFiles.validateRelative(a.relative_path)
            try HandoffFiles.validateRelative(a.source_path)
            guard a.relative_path.hasPrefix("attachments/"), a.relative_path.split(separator: "/").count == 2,
                  UUID(uuidString: a.attachment_id) != nil, ids.insert(a.attachment_id).inserted,
                  paths.insert(a.relative_path).inserted, sources.insert(a.source_path).inserted,
                  a.byte_count >= 0, a.byte_count <= HandoffFiles.attachmentLimit,
                  a.original_name.utf8.count <= 1024, a.media_type.utf8.count <= 128,
                  a.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw HandoffError.invalid("invalid_attachment")
            }
            total += a.byte_count
        }
        guard total <= 128 * 1024 * 1024 else { throw HandoffError.invalid("attachment_limit") }
        guard Set(c.omitted_attachments).count == c.omitted_attachments.count else { throw HandoffError.invalid("invalid_omission") }
        for path in c.omitted_attachments {
            try HandoffFiles.validateRelative(path)
            guard !sources.contains(path) else { throw HandoffError.invalid("invalid_omission") }
        }
    }
}
struct HandoffReceipt: Codable, Equatable {
    let schema_version: Int
    let workspace_id: String
    let operation_id: String
    let capture_id: String
    let organiser_item_id: String
    let payload_sha256: String
    let accepted_at: String
    func validate(for request: HandoffRequest) throws {
        guard schema_version == 1, workspace_id == request.payload.workspace_id,
              operation_id == request.payload.operation_id, capture_id == request.payload.capture.capture_id,
              payload_sha256 == request.payload_sha256, UUID(uuidString: organiser_item_id) != nil,
              ISO8601DateFormatter().date(from: accepted_at) != nil else {
            throw HandoffError.invalid("invalid_receipt")
        }
    }
}
struct HandoffManifest: Codable {
    let manifest_version: Int
    let source_id: String
    let spool_path: String
    let request: HandoffRequest
}

struct HandoffCapabilities: Codable {
    let schema_version: Int
    let workspace_id: String
    let durable_receipts: Bool
}
protocol CaptureDestination {
    func capabilities(at spool: URL) throws -> HandoffCapabilities
    func deliver(_ manifest: HandoffManifest, bundle: URL) throws -> HandoffReceipt
}

struct SpoolDestination: CaptureDestination {
    func capabilities(at spool: URL) throws -> HandoffCapabilities {
        guard FileManager.default.fileExists(atPath: spool.appendingPathComponent("capabilities.json").path) else { throw HandoffError.unavailable }
        return try JSONDecoder().decode(HandoffCapabilities.self, from: HandoffFiles.read("capabilities.json", in: spool, limit: 4096))
    }
    func deliver(_ manifest: HandoffManifest, bundle: URL) throws -> HandoffReceipt {
        let root = URL(fileURLWithPath: manifest.spool_path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { throw HandoffError.unavailable }
        try HandoffFiles.checkDirectory(root)
        let caps = try capabilities(at: root)
        guard caps.schema_version == 1, caps.durable_receipts,
              caps.workspace_id == manifest.request.payload.workspace_id else { throw HandoffError.invalid("destination_mismatch") }
        let requests = root.appendingPathComponent("requests")
        let receipts = root.appendingPathComponent("receipts")
        try HandoffFiles.directory(requests); try HandoffFiles.directory(receipts)
        let id = manifest.request.payload.capture.capture_id
        let target = requests.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: target.path) {
            let bytes = try HandoffFiles.read("request.json", in: target, limit: HandoffFiles.manifestLimit)
            guard bytes == (try HandoffJSON.encode(manifest.request)) else { throw HandoffError.conflict }
        } else {
            let staging = requests.appendingPathComponent(".staging-" + UUID().uuidString)
            try HandoffFiles.directory(staging)
            for a in manifest.request.payload.capture.attachments {
                let data = try HandoffFiles.read(a.relative_path, in: bundle, limit: HandoffFiles.attachmentLimit)
                guard data.count == a.byte_count, HandoffJSON.digest(data) == a.sha256 else { throw HandoffError.invalid("corrupt_attachment") }
                try HandoffFiles.write(data, to: staging.appendingPathComponent(a.relative_path))
            }
            try HandoffFiles.write(Data(manifest.request.payload.capture.body_markdown.utf8), to: staging.appendingPathComponent("content.md"))
            try HandoffFiles.write(try HandoffJSON.encode(manifest.request), to: staging.appendingPathComponent("request.json"))
            try HandoffFiles.publish(staging, to: target)
        }
        let receiptName = id + ".json"
        guard FileManager.default.fileExists(atPath: receipts.appendingPathComponent(receiptName).path) else {
            let errors = root.appendingPathComponent("errors")
            if FileManager.default.fileExists(atPath: errors.appendingPathComponent(receiptName).path) {
                let data = try HandoffFiles.read(receiptName, in: errors, limit: 4096)
                if let response = try JSONSerialization.jsonObject(with: data) as? [String: String],
                   response["payload_sha256"] == manifest.request.payload_sha256 {
                    let code = response["code"] ?? "receiver_rejected"
                    if code == "io_error" { throw HandoffError.unavailable }
                    let allowed = ["conflict", "unsupported_version", "wrong_workspace", "digest_mismatch", "corrupt_attachment", "invalid_payload", "unsafe_path"]
                    throw HandoffError.invalid(allowed.contains(code) ? code : "receiver_rejected")
                }
            }
            throw HandoffError.unavailable
        }
        let receipt = try JSONDecoder().decode(HandoffReceipt.self, from: HandoffFiles.read(receiptName, in: receipts, limit: 16384))
        try receipt.validate(for: manifest.request)
        return receipt
    }
}
