import AppKit
import Security
import SwiftUI

enum OrganiserCredentials {
    private static func query(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.quickcapture.organiser",
         kSecAttrAccount as String: endpoint]
    }
    /// What the keychain last said for an endpoint. The sync workers poll every
    /// few seconds, so an answer is kept until a save or an explicit retry
    /// rather than asked for again — on a keychain that can't be unlocked,
    /// each ask was another password dialog.
    private enum Answer { case token(String), missing, refused }
    private static let lock = NSLock()
    private static var answers: [String: Answer] = [:]
    private static var lookup: (String) -> (OSStatus, String?) = keychainLookup

    static func read(_ endpoint: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let answer: Answer
        if let cached = answers[endpoint] {
            answer = cached
        } else {
            let (status, token) = lookup(endpoint)
            switch status {
            case errSecSuccess where token != nil: answer = .token(token!)
            case errSecItemNotFound: answer = .missing
            default: answer = .refused
            }
            answers[endpoint] = answer
        }
        switch answer {
        case .token(let token): return token
        case .missing: return nil
        case .refused:
            throw HandoffError.invalid("Keychain didn't release the organiser access key (it may be locked). Unlock it in Keychain Access, then choose Retry Keychain in Settings.")
        }
    }

    /// Forget refusals so the next read asks the keychain again.
    static func retry() {
        lock.lock(); defer { lock.unlock() }
        answers = answers.filter { if case .refused = $0.value { return false } else { return true } }
    }

    static func resetForTesting(lookup: @escaping (String) -> (OSStatus, String?) = keychainLookup) {
        lock.lock(); defer { lock.unlock() }
        answers = [:]
        self.lookup = lookup
    }

    private static func keychainLookup(_ endpoint: String) -> (OSStatus, String?) {
        var q = query(endpoint)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        // Background delivery must never summon a dialog. The flag above only
        // covers LocalAuthentication-protected items; the login keychain still
        // prompts to unlock, or to approve a differently-signed build, unless
        // interaction is switched off for the read.
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        let token = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return (status, token)
    }
    static func save(_ token: String, endpoint: String) throws {
        guard (32...4096).contains(token.utf8.count), token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw HandoffError.invalid("Enter a valid organiser access key.")
        }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let result = SecItemUpdate(query(endpoint) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var q = query(endpoint); q[kSecValueData as String] = Data(token.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw HandoffError.invalid("Could not save the access key to Keychain.") }
        } else if result != errSecSuccess { throw HandoffError.invalid("Could not update the access key in Keychain.") }
        lock.lock(); answers[endpoint] = .token(token); lock.unlock()
    }
}

@MainActor @Observable
final class OrganiserController {
    static let shared = OrganiserController()
    var endpoint: String { didSet { UserDefaults.standard.set(endpoint, forKey: "organiser.api.endpoint") } }
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "organiser.api.enabled") } }
    var status = "New captures are retained locally until an organiser connection is configured."
    var records: [OrganiserDelivery] = []
    let outbox: OrganiserOutbox
    private var worker: Task<Void, Never>?
    private var pollIndex = 0
    private var importProblem: String?
    private var importFile: URL {
        let path = UserDefaults.standard.string(forKey: "captureFilePath")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("QuickCapture/inbox.md")
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    private func pullChanges() async {
        do {
            let destination = try OrganiserOutbox.endpoint(endpoint)
            guard let token = try OrganiserCredentials.read(destination) else { return }
            let cursor = try outbox.cursor(for: destination)
            let http = OrganiserHTTP()
            let (bytes, code) = try await http.request(endpoint: destination, token: token,
                path: "/api/changes?after=\(cursor)&limit=20")
            guard code == 200 else { throw HandoffError.invalid("Incoming sync returned HTTP \(code). Check the organiser connection and server version.") }
            let page = try JSONDecoder().decode(OrganiserChanges.self, from: bytes)
            var previous = cursor
            for change in page.changes {
                guard enabled, try OrganiserOutbox.endpoint(endpoint) == destination else { return }
                guard change.sequence > previous, UUID(uuidString: change.item_id) != nil else {
                    throw HandoffError.invalid("Invalid organiser change cursor.")
                }
                let remote = try await http.fetch(endpoint: destination, token: token, id: change.item_id)
                guard enabled, try OrganiserOutbox.endpoint(endpoint) == destination else { return }
                guard remote.revision >= change.revision else { throw HandoffError.invalid("The organiser returned an older item version. Sync will retry.") }
                // Whole project inbox documents are managed by ProjectStore. Never
                // project them into the global capture inbox as an individual item.
                if remote.item.kind != "project" {
                    try outbox.importItem(remote, id: change.item_id, file: importFile, endpoint: destination, candidates: syncCandidates)
                }
                try outbox.advanceCursor(change.sequence, endpoint: destination)
                previous = change.sequence
            }
            importProblem = nil
        } catch { importProblem = error.localizedDescription }
    }
    private var syncCandidates: [URL] {
        guard let data = UserDefaults.standard.data(forKey: "refileTargets"),
              let targets = try? JSONDecoder().decode([RefileTarget].self, from: data) else { return [] }
        return targets.map { $0.folderURL.appendingPathComponent("inbox.md") }
    }
    private func synchroniseLocal() {
        for record in (try? outbox.records()) ?? [] {
            do {
                if let incoming = record.incoming {
                    try outbox.receive(incoming, id: record.id, candidates: syncCandidates)
                } else { try outbox.reconcileLocal(record.id, candidates: syncCandidates) }
            } catch { outbox.syncProblem(record.id, error.localizedDescription) }
        }
    }
    private func pullOne() async {
        let linked = ((try? outbox.records()) ?? []).filter {
            ($0.receipt != nil || $0.baseline != nil) && $0.conflict == nil && $0.incoming == nil && $0.endpoint != nil
                && $0.baseline?.item.deleted != true
        }
        guard !linked.isEmpty else { return }
        let record = linked[pollIndex % linked.count]; pollIndex = (pollIndex + 1) % linked.count
        do {
            guard let token = try OrganiserCredentials.read(record.endpoint!) else { return }
            let remote = try await OrganiserHTTP().fetch(endpoint: record.endpoint!, token: token, id: record.id, known: try outbox.baseline(record))
            // All local file reconciliation runs on the main actor, between
            // native saves/moves. The editor's existing disk-conflict path
            // preserves any unsaved buffer when this changes the file.
            guard enabled else { return }
            try outbox.receive(remote, id: record.id, candidates: syncCandidates)
        } catch { outbox.syncProblem(record.id, error.localizedDescription) }
    }
    func resolve(_ id: String, useOrganiser: Bool) {
        do {
            if useOrganiser, let remote = try outbox.records().first(where: { $0.id == id })?.conflict {
                try outbox.receive(remote, id: id, candidates: syncCandidates, force: true)
            } else { try outbox.keepLocal(id, candidates: syncCandidates) }
            records = try outbox.records()
            status = "Conflict resolved. Synchronisation will continue."
        } catch { status = error.localizedDescription }
    }
    private init() {
        let defaults = UserDefaults.standard
        endpoint = defaults.string(forKey: "organiser.api.endpoint") ?? "http://127.0.0.1:8788"
        enabled = defaults.object(forKey: "organiser.api.enabled") as? Bool ?? true
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        outbox = OrganiserOutbox(root: support.appendingPathComponent("QuickCapture/OrganiserOutbox"))
    }
    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.enabled { self.synchroniseLocal() }
                let outbox = self.outbox, endpoint = self.endpoint, enabled = self.enabled
                let result = await Task.detached(priority: .utility) {
                    await Self.deliver(outbox: outbox, endpoint: endpoint, enabled: enabled)
                }.value
                if self.enabled { await self.pullChanges(); await self.pullOne() }
                records = (try? outbox.records()) ?? result.0; status = result.1
                if records.contains(where: { $0.conflict != nil || $0.syncProblem != nil }) {
                    status = "Synchronisation needs attention. See the records below."
                }
                await OrganiserReminders.shared.reconcile(outbox: outbox, records: records)
                if self.enabled, let importProblem { status = importProblem }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    nonisolated static func deliver(outbox: OrganiserOutbox, endpoint: String, enabled: Bool,
        credentials: @Sendable (String) throws -> String? = OrganiserCredentials.read,
        send: @Sendable (String, String, Data) async throws -> (Data, Int) = { endpoint, token, data in
            try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: data)
        }) async -> ([OrganiserDelivery], String) {
        do {
            try outbox.recoverPrepared()
            let records = try outbox.records()
            guard enabled else { return (records, "Delivery paused. New captures remain in the local queue.") }
            let destination = try OrganiserOutbox.endpoint(endpoint)
            var message = "No pending captures."
            for record in records where record.state == "pending" && record.nextAttempt <= Date() {
                let target = record.endpoint ?? destination
                guard let token = try credentials(target) else {
                    message = "Save an access key for \(target) to deliver queued captures."
                    continue
                }
                do {
                    let (bound, data) = try outbox.request(for: record.id, bindTo: destination)
                    let (body, status) = try await send(bound.endpoint!, token, data)
                    if status == 200 {
                        let receipt = try JSONDecoder().decode(OrganiserAcknowledgement.self, from: body)
                        try outbox.acknowledge(record.id, receipt: receipt)
                        message = "Capture saved to organiser."
                    } else {
                        let permanent = (400..<500).contains(status) && status != 408 && status != 429
                        let problem = status == 401 ? "Access key rejected. Update the key in Settings, then retry."
                            : status == 409 ? "The server reported an identity conflict. The local capture is retained."
                            : "Organiser returned HTTP \(status). The local capture is retained."
                        try outbox.failed(record.id, problem: problem, attention: permanent)
                        message = problem
                    }
                } catch {
                    let permanent = error is HandoffError || error is DecodingError
                    try outbox.failed(record.id, problem: permanent ? error.localizedDescription : "Waiting for organiser; check the server or SSH tunnel.", attention: permanent)
                    message = "Delivery pending. The local capture is retained."
                }
                break
            }
            let current = try outbox.records()
            let attention = current.filter { $0.state == "attention" }.count
            if attention > 0 { message = "\(attention) deliveries need attention. See the records below." }
            else if current.contains(where: { $0.state == "pending" }) && message == "No pending captures." { message = "Waiting to retry queued captures." }
            return (current, message)
        } catch { return ((try? outbox.records()) ?? [], "Could not inspect the delivery queue: " + error.localizedDescription) }
    }
    func saveKey(_ token: String) {
        do {
            let normalized = try OrganiserOutbox.endpoint(endpoint)
            try OrganiserCredentials.save(token.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: normalized)
            endpoint = normalized
            for record in try outbox.records() where record.endpoint == normalized || record.endpoint == nil { try outbox.retry(record.id) }
            status = "Access key saved in Keychain. Delivery will resume automatically."; start()
        } catch { status = error.localizedDescription }
    }
    func configureFromArguments(_ arguments: [String]) {
        guard let endpointIndex = arguments.firstIndex(of: "--organiser-url"),
              let keyIndex = arguments.firstIndex(of: "--organiser-key-file"),
              arguments.indices.contains(endpointIndex + 1), arguments.indices.contains(keyIndex + 1) else { return }
        do {
            let destination = try OrganiserOutbox.endpoint(arguments[endpointIndex + 1])
            let file = URL(fileURLWithPath: arguments[keyIndex + 1])
            let bytes = try HandoffFiles.read(file.lastPathComponent, in: file.deletingLastPathComponent().resolvingSymlinksInPath(), limit: 4096)
            guard let token = String(data: bytes, encoding: .utf8) else { throw HandoffError.invalid("Invalid key file.") }
            try OrganiserCredentials.save(token.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: destination)
            endpoint = destination; enabled = true
            status = "Organiser configured. New captures will be delivered automatically."
        } catch { status = "Organiser configuration failed: " + error.localizedDescription }
    }
    func importKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the organiser access-key file. Its contents will be saved in Keychain."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw HandoffError.invalid("Invalid access-key file.") }
            saveKey(text)
        } catch { status = "Could not import the access-key file." }
    }
    func retry(_ id: String) {
        do { try outbox.retry(id); status = "Queued for retry." } catch { status = error.localizedDescription }
    }
}

struct OrganiserSettingsView: View {
    @Bindable var controller = OrganiserController.shared
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUTOMATIC ORGANISER DELIVERY").font(.headline)
            Toggle("Deliver captures and synchronise changes", isOn: $controller.enabled)
            TextField("Organiser URL", text: $controller.endpoint)
            SecureField("Access key", text: $key)
            HStack {
                Button("Save Access Key") { controller.saveKey(key); key = "" }.disabled(key.isEmpty)
                Button("Import Key File…") { controller.importKey() }
                Button("Retry Keychain") { OrganiserCredentials.retry(); controller.start() }
                Button("Open Organiser") {
                    if let endpoint = try? OrganiserOutbox.endpoint(controller.endpoint), let url = URL(string: endpoint) { NSWorkspace.shared.open(url) }
                }
            }
            Text(controller.status).font(.caption)
            Text("New capture-box entries and #cal events are queued automatically. Existing unmarked Markdown history is not imported. Organiser items arrive automatically. Edits, completion and deletion synchronise both ways for linked items. Archive and refile preserve identity. Conflicts retain both versions. Pending deliveries keep their original server once bound.").font(.caption).foregroundStyle(.secondary)
            OrganiserReminderSettings()
            DisclosureGroup("Delivery records (\(controller.records.count))") {
                ForEach(controller.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.summary).lineLimit(2)
                        Text(record.state == "prepared" ? "Local save not yet confirmed; retained for recovery" : record.state.capitalized).font(.caption)
                        if let problem = record.problem { Text(problem).font(.caption) }
                        if let problem = record.syncProblem { Text(problem).font(.caption) }
                        if let conflict = record.conflict {
                            Text("Organiser version (revision \(conflict.revision))").font(.caption.bold())
                            Text(conflict.item.deleted ? "Deleted" : conflict.item.body_markdown).font(.caption).textSelection(.enabled)
                            Text("Your local version remains in the Markdown file; the queued version is retained in the outbox.").font(.caption)
                            HStack {
                                Button("Use organiser version") { controller.resolve(record.id, useOrganiser: true) }
                                if !conflict.item.deleted {
                                    Button("Keep local version") { controller.resolve(record.id, useOrganiser: false) }
                                }
                            }
                        }
                        if let endpoint = record.endpoint { Text(endpoint).font(.caption).foregroundStyle(.secondary) }
                        if record.state == "attention" || record.state == "pending" { Button("Retry") { controller.retry(record.id) } }
                    }.padding(.vertical, 4)
                }
            }
        }.padding().onAppear { controller.start() }
    }
}

/// A capture is authorised for delivery only after the Markdown save succeeds.
/// The marker repairs a crash between that save and confirming the outbox record.
enum OrganiserCapture {
    static func save(_ text: String, tag: String?, file: URL, timestamp: Bool, attachments: [String],
                     event: CalendarEvent? = nil, outbox: OrganiserOutbox, endpoint: String?, now: Date = Date()) throws -> String {
        let line = FileWriter.todoLine(text, includeTimestamp: timestamp, now: now)
        let children = Array(Set(attachments)).sorted().map(FileWriter.attachmentChildLine)
        var item = OrganiserItem(body_markdown: ([line] + children).joined(separator: "\n"), section: FileWriter.sectionName(for: tag))
        if let event {
            item.kind = "event"
            item.starts_at = HandoffJSON.timestamp(event.start)
            item.ends_at = HandoffJSON.timestamp(event.start.addingTimeInterval(event.duration))
        }
        let id = try outbox.prepare(item: item, sourceFile: file, attachmentPaths: attachments, endpoint: endpoint)
        try FileWriter.appendUnderHeading(item.section, item: line + " <!--qc-source:\(id)-->", childLines: children, to: file)
        // The source marker is durable evidence if this metadata update fails.
        do { try outbox.confirmSaved(id) }
        catch { NSLog("Organiser delivery will recover its saved source marker on the next scan.") }
        return id
    }
}
