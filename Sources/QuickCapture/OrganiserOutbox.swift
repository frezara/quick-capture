import Foundation

struct OrganiserItem: Codable, Equatable {
    var body_markdown: String
    var kind = "capture"
    var section = "Quick capture"
    var completed = false
    var deleted = false
    var starts_at: String?
    var ends_at: String?
}
struct OrganiserFile: Codable {
    let path: String
    let media_type: String
    let data_base64: String
}
struct OrganiserOperation: Codable {
    let operation_id: String
    let item_id: String
    let expected_revision: Int
    let item: OrganiserItem
    let attachments: [OrganiserFile]
}
struct OrganiserAcknowledgement: Codable {
    let operation_id: String
    let item_id: String
    let revision: Int
}
struct OrganiserDelivery: Codable, Identifiable {
    let id: String
    let operationID: String
    let sourceFile: String
    let summary: String
    let digest: String
    var endpoint: String?
    var state: String
    var attempts = 0
    var nextAttempt = Date.distantPast
    var problem: String?
    var receipt: OrganiserAcknowledgement?
}

/// The request is immutable. Only its small delivery record changes on retry.
/// Shared by the capture callback and background worker; no lock spans network I/O.
final class OrganiserOutbox: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    init(root: URL) { self.root = root }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw HandoffError.invalid("invalid_item_id") }
        return root.appendingPathComponent(id)
    }
    private func save(_ record: OrganiserDelivery) throws {
        try HandoffFiles.write(HandoffJSON.encode(record), to: directory(record.id).appendingPathComponent("record.json"))
    }
    private func read(_ id: String) throws -> OrganiserDelivery {
        let record = try JSONDecoder().decode(OrganiserDelivery.self, from: HandoffFiles.read("record.json", in: directory(id), limit: 16384))
        guard record.id == id, UUID(uuidString: record.operationID) != nil else { throw HandoffError.invalid("Invalid delivery identity.") }
        return record
    }
    static func endpoint(_ text: String) throws -> String {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
        else { throw HandoffError.invalid("Use HTTPS, or HTTP on localhost through an SSH tunnel.") }
        var normalized = url; normalized.path = ""
        return normalized.string!
    }
    func prepare(item: OrganiserItem, sourceFile: URL, attachmentPaths: [String], endpoint: String?) throws -> String {
        try locked {
            guard item.body_markdown.utf8.count <= 1024 * 1024, attachmentPaths.count <= 16 else {
                throw HandoffError.invalid("Capture exceeds the organiser's text or attachment limit.")
            }
            let id = UUID().uuidString.lowercased(), operationID = UUID().uuidString.lowercased()
            var total = 0
            let files = try Array(Set(attachmentPaths)).sorted().map { path in
                let bytes = try HandoffFiles.read(path, in: sourceFile.deletingLastPathComponent().resolvingSymlinksInPath(), limit: 18 * 1024 * 1024)
                total += bytes.count
                guard total <= 18 * 1024 * 1024 else { throw HandoffError.invalid("Attachments exceed 18 MiB. Reduce them before saving; the draft is retained.") }
                let types = ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp"]
                return OrganiserFile(path: path, media_type: types[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream", data_base64: bytes.base64EncodedString())
            }
            let request = OrganiserOperation(operation_id: operationID, item_id: id, expected_revision: 0, item: item, attachments: files)
            let data = try HandoffJSON.encode(request)
            guard data.count <= 26 * 1024 * 1024 else { throw HandoffError.invalid("Capture exceeds the organiser request limit.") }
            let folder = try directory(id)
            try HandoffFiles.write(data, to: folder.appendingPathComponent("request.json"))
            try save(OrganiserDelivery(id: id, operationID: operationID, sourceFile: sourceFile.path,
                summary: String(item.body_markdown.prefix(120)), digest: HandoffJSON.digest(data),
                endpoint: try endpoint.map(Self.endpoint), state: "prepared"))
            return id
        }
    }
    func confirmSaved(_ id: String) throws {
        try locked {
            var record = try read(id)
            guard record.state == "prepared" else { return }
            record.state = "pending"; record.problem = nil
            try save(record)
        }
    }
    func records() throws -> [OrganiserDelivery] {
        try locked {
            try HandoffFiles.directory(root)
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
                .compactMap { folder in
                    // An interrupted request write has not yet authorised a source-file save.
                    guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("record.json").path) else { return nil }
                    return try read(folder.lastPathComponent)
                }.sorted { $0.id < $1.id }
        }
    }
    func recoverPrepared() throws {
        for record in try records() where record.state == "prepared" {
            guard let source = try? FileWriter.read(URL(fileURLWithPath: record.sourceFile), allowingMissing: false),
                  SourceIdentity.ids(in: source).filter({ $0.lowercased() == record.id }).count == 1 else { continue }
            try confirmSaved(record.id)
        }
    }
    func request(for id: String, bindTo endpoint: String) throws -> (OrganiserDelivery, Data) {
        try locked {
            var record = try read(id)
            guard record.state == "pending" else { throw HandoffError.invalid("delivery_not_pending") }
            if record.endpoint == nil { record.endpoint = try Self.endpoint(endpoint); try save(record) }
            let data = try HandoffFiles.read("request.json", in: directory(id), limit: 26 * 1024 * 1024)
            guard HandoffJSON.digest(data) == record.digest else { throw HandoffError.invalid("The retained request failed its integrity check.") }
            return (record, data)
        }
    }
    func acknowledge(_ id: String, receipt: OrganiserAcknowledgement) throws {
        try locked {
            var record = try read(id)
            guard receipt.item_id == record.id, receipt.operation_id == record.operationID, receipt.revision == 1 else {
                throw HandoffError.invalid("The server acknowledgement did not match this capture.")
            }
            record.receipt = receipt; record.state = "delivered"; record.problem = nil
            try save(record)
        }
    }
    func failed(_ id: String, problem: String, attention: Bool, now: Date = Date()) throws {
        try locked {
            var record = try read(id)
            guard record.state != "delivered" else { return }
            record.attempts += 1; record.problem = problem
            record.state = attention ? "attention" : "pending"
            record.nextAttempt = now.addingTimeInterval(min(300, pow(2, Double(min(record.attempts, 9)))))
            try save(record)
        }
    }
    func retry(_ id: String) throws {
        try locked {
            var record = try read(id)
            guard record.state == "attention" || record.state == "pending" else { return }
            record.state = "pending"; record.nextAttempt = .distantPast; record.problem = nil
            try save(record)
        }
    }
}

/// Never follow a redirect with an organiser credential attached.
final class OrganiserHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(endpoint: String, token: String, data: Data) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: try OrganiserOutbox.endpoint(endpoint) + "/api/operations")!)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HandoffError.unavailable }
        return (body, response.statusCode)
    }
}
