import XCTest
@testable import QuickCapture

final class OrganiserOutboxTests: XCTestCase {
    var root: URL!
    var file: URL { root.appendingPathComponent("inbox.md") }
    var outbox: OrganiserOutbox { OrganiserOutbox(root: root.appendingPathComponent("queue")) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("organiser-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testCaptureSavesMarkerAndFrozenRequestWithoutNetwork() throws {
        let id = try OrganiserCapture.save("café !", tag: "work", file: file, timestamp: false, attachments: [], outbox: outbox, endpoint: nil)
        XCTAssertTrue(try FileWriter.read(file).contains("<!--qc-source:\(id)-->"))
        let (record, bytes) = try outbox.request(for: id, bindTo: "http://127.0.0.1:8788/")
        let request = try JSONDecoder().decode(OrganiserOperation.self, from: bytes)
        XCTAssertEqual(request.item.body_markdown, "- [ ] café !")
        XCTAssertEqual(request.item.section, "work")
        XCTAssertEqual(record.state, "pending")
        XCTAssertEqual(record.endpoint, "http://127.0.0.1:8788")
        try "# Inbox\n\n- [ ] changed elsewhere\n".write(to: file, atomically: true, encoding: .utf8)
        let (_, retry) = try outbox.request(for: id, bindTo: "https://different.example")
        XCTAssertEqual(bytes, retry)
        XCTAssertEqual(try outbox.records()[0].endpoint, record.endpoint)
    }
    func testCrashAfterSourceSaveRecoversPreparedRecord() throws {
        let id = try outbox.prepare(item: OrganiserItem(body_markdown: "- [ ] test"), sourceFile: file, attachmentPaths: [], endpoint: nil)
        try outbox.recoverPrepared()
        XCTAssertEqual(try outbox.records()[0].state, "prepared")
        try FileWriter.appendUnderHeading("Quick capture", item: "- [ ] test <!--qc-source:\(id)-->", to: file)
        let restarted = outbox
        try restarted.recoverPrepared()
        XCTAssertEqual(try restarted.records()[0].state, "pending")
    }
    func testDuplicatedMarkerDoesNotAuthoriseUnconfirmedSave() throws {
        let id = try outbox.prepare(item: OrganiserItem(body_markdown: "test"), sourceFile: file, attachmentPaths: [], endpoint: nil)
        try "# Inbox\n- [ ] a <!--qc-source:\(id)-->\n- [ ] b <!--qc-source:\(id)-->\n".write(to: file, atomically: true, encoding: .utf8)
        try outbox.recoverPrepared()
        XCTAssertEqual(try outbox.records()[0].state, "prepared")
    }
    func testAttachmentBytesSurviveSourceRemovalAndRetry() throws {
        let image = root.appendingPathComponent("image.png")
        try Data("image bytes".utf8).write(to: image)
        let id = try OrganiserCapture.save("screenshot", tag: nil, file: file, timestamp: false, attachments: ["image.png"], outbox: outbox, endpoint: nil)
        try FileManager.default.removeItem(at: image)
        let (record, data) = try outbox.request(for: id, bindTo: "http://localhost:8788")
        let operation = try JSONDecoder().decode(OrganiserOperation.self, from: data)
        XCTAssertEqual(Data(base64Encoded: operation.attachments[0].data_base64), Data("image bytes".utf8))
        try outbox.failed(id, problem: "offline", attention: false)
        XCTAssertGreaterThan(try outbox.records()[0].nextAttempt, Date())
        try outbox.retry(id)
        XCTAssertEqual(try outbox.request(for: id, bindTo: "https://new.example").1, data)
        try outbox.acknowledge(id, receipt: .init(operation_id: record.operationID, item_id: id, revision: 1))
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        try outbox.retry(id)
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
    }
    func testBadReceiptAndTamperedPayloadAreRejected() throws {
        let id = try OrganiserCapture.save("test", tag: nil, file: file, timestamp: false, attachments: [], outbox: outbox, endpoint: nil)
        XCTAssertThrowsError(try outbox.acknowledge(id, receipt: .init(operation_id: UUID().uuidString, item_id: id, revision: 1)))
        let payload = root.appendingPathComponent("queue/\(id)/request.json")
        try Data("{}".utf8).write(to: payload)
        XCTAssertThrowsError(try outbox.request(for: id, bindTo: "http://localhost:8788"))
        XCTAssertEqual(try outbox.records()[0].state, "pending")
    }
    func testMissingOrOversizedAttachmentsDoNotSavePartialCapture() throws {
        XCTAssertThrowsError(try OrganiserCapture.save("test", tag: nil, file: file, timestamp: false, attachments: ["missing.png"], outbox: outbox, endpoint: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data(count: 18 * 1024 * 1024 + 1).write(to: root.appendingPathComponent("large.png"))
        XCTAssertThrowsError(try OrganiserCapture.save("test", tag: nil, file: file, timestamp: false, attachments: ["large.png"], outbox: outbox, endpoint: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testCalendarCaptureIsLocalAndQueuedAsInternalEvent() throws {
        let event = CalendarEvent(title: "Meeting", start: Date(timeIntervalSince1970: 1_800_000_000), duration: 1800)
        let id = try OrganiserCapture.save("Meeting tomorrow", tag: "cal", file: file, timestamp: false, attachments: [], event: event, outbox: outbox, endpoint: nil)
        let data = try outbox.request(for: id, bindTo: "http://localhost:8788").1
        let operation = try JSONDecoder().decode(OrganiserOperation.self, from: data)
        XCTAssertEqual(operation.item.kind, "event")
        XCTAssertEqual(operation.item.starts_at, HandoffJSON.timestamp(event.start))
        XCTAssertEqual(operation.item.ends_at, HandoffJSON.timestamp(event.start.addingTimeInterval(1800)))
        XCTAssertTrue(try FileWriter.read(file).contains("Meeting tomorrow"))
    }
    func testExistingHistoryIsNotImported() throws {
        try "# Inbox\n- [ ] old item\n".write(to: file, atomically: true, encoding: .utf8)
        try outbox.recoverPrepared()
        XCTAssertTrue(try outbox.records().isEmpty)
    }
    func testOnlySecureOrLoopbackEndpointsAccepted() throws {
        for endpoint in ["http://192.168.0.50:8787", "https://user:secret@example.com", "https://example.com/path", "https://example.com?q=x", "file:///tmp/server"] {
            XCTAssertThrowsError(try OrganiserOutbox.endpoint(endpoint))
        }
        XCTAssertEqual(try OrganiserOutbox.endpoint("https://example.com/"), "https://example.com")
        XCTAssertEqual(try OrganiserOutbox.endpoint("http://127.0.0.1:8788"), "http://127.0.0.1:8788")
    }
}

extension OrganiserOutboxTests {
    func testWorkerRetriesLostResponsesWithSameOperation() async throws {
        let id = try OrganiserCapture.save("offline capture", tag: nil, file: file, timestamp: false, attachments: [], outbox: outbox, endpoint: nil)
        let queue = outbox
        let original = try queue.request(for: id, bindTo: "http://localhost:8788").1
        let result = await OrganiserController.deliver(outbox: queue, endpoint: "http://localhost:8788", enabled: true,
            credentials: { _ in "test-token" }, send: { _, _, data in
                XCTAssertEqual(data, original)
                throw URLError(.networkConnectionLost)
            })
        XCTAssertEqual(result.0.first?.state, "pending")
        XCTAssertEqual(result.0.first?.attempts, 1)
        let restarted = outbox
        try restarted.retry(id)
        let delivered = await OrganiserController.deliver(outbox: restarted, endpoint: "https://different.example", enabled: true,
            credentials: { endpoint in XCTAssertEqual(endpoint, "http://localhost:8788"); return "test-token" },
            send: { endpoint, _, data in
                XCTAssertEqual(endpoint, "http://localhost:8788"); XCTAssertEqual(data, original)
                let op = try JSONDecoder().decode(OrganiserOperation.self, from: data)
                return (try HandoffJSON.encode(OrganiserAcknowledgement(operation_id: op.operation_id, item_id: op.item_id, revision: 1)), 200)
            })
        XCTAssertEqual(delivered.0.first?.state, "delivered")
    }
    func testPausedOrUnconfiguredQueueDoesNotSend() async throws {
        _ = try OrganiserCapture.save("test", tag: nil, file: file, timestamp: false, attachments: [], outbox: outbox, endpoint: nil)
        let paused = await OrganiserController.deliver(outbox: outbox, endpoint: "http://localhost:8788", enabled: false,
            credentials: { _ in XCTFail("No credentials lookup while paused"); return nil })
        XCTAssertEqual(paused.0.first?.state, "pending")
        let unconfigured = await OrganiserController.deliver(outbox: outbox, endpoint: "http://localhost:8788", enabled: true,
            credentials: { _ in nil }, send: { _,_,_ in XCTFail("Must not send without credentials"); return (Data(), 500) })
        XCTAssertNil(unconfigured.0.first?.endpoint)
        XCTAssertEqual(unconfigured.0.first?.attempts, 0)
    }
    func testRejectedCredentialsAndBadReceiptNeedAttention() async throws {
        let id = try OrganiserCapture.save("test", tag: nil, file: file, timestamp: false, attachments: [], outbox: outbox, endpoint: nil)
        let rejected = await OrganiserController.deliver(outbox: outbox, endpoint: "http://localhost:8788", enabled: true,
            credentials: { _ in "test-token" }, send: { _,_,_ in (Data(), 401) })
        XCTAssertEqual(rejected.0.first?.state, "attention")
        try outbox.retry(id)
        let invalid = await OrganiserController.deliver(outbox: outbox, endpoint: "http://localhost:8788", enabled: true,
            credentials: { _ in "test-token" }, send: { _,_,_ in (Data("{}".utf8), 200) })
        XCTAssertEqual(invalid.0.first?.state, "attention")
        XCTAssertNil(invalid.0.first?.receipt)
    }
    func testLivePostgresDeliveryAndLostAcknowledgement() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["ORGANISER_TEST_URL"], let tokenPath = env["ORGANISER_TEST_TOKEN_FILE"] else {
            throw XCTSkip("Opt in with ORGANISER_TEST_URL and ORGANISER_TEST_TOKEN_FILE.")
        }
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("attachment proof".utf8).write(to: root.appendingPathComponent("proof.png"))
        let id = try OrganiserCapture.save("Native delivery verification", tag: "verification", file: file, timestamp: false,
            attachments: ["proof.png"], outbox: outbox, endpoint: endpoint)
        let (record, bytes) = try outbox.request(for: id, bindTo: endpoint)
        let first = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: bytes)
        XCTAssertEqual(first.1, 200)
        // Simulate losing the response before the local receipt is durable.
        let restarted = outbox
        let retryBytes = try restarted.request(for: id, bindTo: endpoint).1
        let second = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: retryBytes)
        let firstReceipt = try JSONDecoder().decode(OrganiserAcknowledgement.self, from: first.0)
        let receipt = try JSONDecoder().decode(OrganiserAcknowledgement.self, from: second.0)
        XCTAssertEqual(receipt.operation_id, firstReceipt.operation_id)
        XCTAssertEqual(receipt.item_id, record.id)
        XCTAssertEqual(receipt.revision, 1)
        try restarted.acknowledge(id, receipt: receipt)
        XCTAssertEqual(try restarted.records()[0].state, "delivered")
        var get = URLRequest(url: URL(string: endpoint + "/api/items/\(id)/attachment?path=proof.png")!)
        get.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (attachment, response) = try await URLSession.shared.data(for: get)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(attachment, Data("attachment proof".utf8))
        try replaceLocal("Native delivery verification", "Edited on Mac")
        try restarted.reconcileLocal(id, candidates: [])
        let editBytes = try restarted.request(for: id, bindTo: endpoint).1
        let edited = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: editBytes)
        XCTAssertEqual(edited.1, 200)
        try restarted.acknowledge(id, receipt: JSONDecoder().decode(OrganiserAcknowledgement.self, from: edited.0))
        var completed = try restarted.baseline(restarted.records()[0]).item
        completed.completed = true; completed.body_markdown = "- [ ] Edited in organiser\n  ![](proof.png)"
        let webEdit = OrganiserOperation(operation_id: UUID().uuidString.lowercased(), item_id: id, expected_revision: 2, item: completed,
            attachments: try restarted.baseline(restarted.records()[0]).files)
        let webResult = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: HandoffJSON.encode(webEdit))
        XCTAssertEqual(webResult.1, 200)
        let incoming = try await OrganiserHTTP().fetch(endpoint: endpoint, token: token, id: id)
        try restarted.receive(incoming, id: id, candidates: [])
        XCTAssertTrue(try FileWriter.read(file).contains("- [x] Edited in organiser"))
        try restarted.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try restarted.records()[0].state, "delivered")
        try "# Inbox\n".write(to: file, atomically: true, encoding: .utf8)
        try restarted.reconcileLocal(id, candidates: [])
        let deletion = try restarted.request(for: id, bindTo: endpoint).1
        let result = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: deletion)
        XCTAssertEqual(result.1, 200)
        try restarted.acknowledge(id, receipt: JSONDecoder().decode(OrganiserAcknowledgement.self, from: result.0))
        let tombstone = try await OrganiserHTTP().fetch(endpoint: endpoint, token: token, id: id)
        XCTAssertTrue(tombstone.item.deleted); XCTAssertEqual(tombstone.revision, 4)
        let browserID = UUID().uuidString.lowercased()
        var browserItem = OrganiserItem(body_markdown: "Created in organiser")
        browserItem.reminder_at = "2026-12-01T12:00:00Z"
        let browserCreate = OrganiserOperation(operation_id: UUID().uuidString.lowercased(), item_id: browserID,
            expected_revision: 0, item: browserItem, attachments: [])
        let created = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: HandoffJSON.encode(browserCreate))
        XCTAssertEqual(created.1, 200)
        let feed = try await OrganiserHTTP().request(endpoint: endpoint, token: token, path: "/api/changes")
        XCTAssertEqual(feed.1, 200)
        let changes = try JSONDecoder().decode(OrganiserChanges.self, from: feed.0)
        XCTAssertTrue(changes.changes.contains(where: { $0.item_id == browserID }))
        let browserSnapshot = try await OrganiserHTTP().fetch(endpoint: endpoint, token: token, id: browserID)
        try restarted.importItem(browserSnapshot, id: browserID, file: file, endpoint: endpoint, candidates: [])
        try outbox.importItem(browserSnapshot, id: browserID, file: file, endpoint: endpoint, candidates: [])
        XCTAssertEqual(SourceIdentity.ids(in: try FileWriter.read(file)), [browserID])
        try replaceLocal("Created in organiser", "Imported and edited on Mac")
        try outbox.reconcileLocal(browserID, candidates: [])
        let importedEdit = try outbox.request(for: browserID, bindTo: endpoint).1
        let accepted = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: importedEdit)
        XCTAssertEqual(accepted.1, 200)
        try outbox.acknowledge(browserID, receipt: JSONDecoder().decode(OrganiserAcknowledgement.self, from: accepted.0))
        browserItem.deleted = true
        let browserDelete = OrganiserOperation(operation_id: UUID().uuidString.lowercased(), item_id: browserID,
            expected_revision: 2, item: browserItem, attachments: [])
        let deletedResult = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: HandoffJSON.encode(browserDelete))
        XCTAssertEqual(deletedResult.1, 200)
        let remoteDeletion = try await OrganiserHTTP().fetch(endpoint: endpoint, token: token, id: browserID)
        try outbox.receive(remoteDeletion, id: browserID, candidates: [])
        XCTAssertTrue(SourceIdentity.ids(in: try FileWriter.read(file)).isEmpty)
    }
}

extension OrganiserOutboxTests {
    func linked(_ text: String = "original", attachments: [String] = []) throws -> String {
        let id = try OrganiserCapture.save(text, tag: nil, file: file, timestamp: false,
            attachments: attachments, outbox: outbox, endpoint: nil)
        try accept(id)
        return id
    }
    func accept(_ id: String) throws {
        let op = try JSONDecoder().decode(OrganiserOperation.self, from: outbox.request(for: id, bindTo: "http://localhost:8788").1)
        try outbox.acknowledge(id, receipt: .init(operation_id: op.operation_id, item_id: id, revision: op.expected_revision + 1))
    }
    func replaceLocal(_ before: String, _ after: String) throws {
        let content = try FileWriter.read(file).replacingOccurrences(of: before, with: after)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }
    func remote(_ id: String, body: String = "- [ ] remote", completed: Bool = false, deleted: Bool = false) throws -> OrganiserSnapshot {
        var snapshot = try outbox.baseline(outbox.records().first(where: { $0.id == id })!)
        snapshot.revision += 1; snapshot.item.body_markdown = body
        snapshot.item.completed = completed; snapshot.item.deleted = deleted
        return snapshot
    }
    func testEditsCompletionAndDeletionAdvanceOneIdentity() throws {
        let id = try linked()
        try replaceLocal("original", "edited")
        try outbox.reconcileLocal(id, candidates: [])
        let bytes = try outbox.request(for: id, bindTo: "http://localhost:8788").1
        let op = try JSONDecoder().decode(OrganiserOperation.self, from: bytes)
        XCTAssertEqual(op.item_id, id); XCTAssertEqual(op.expected_revision, 1)
        XCTAssertEqual(op.item.body_markdown, "- [ ] edited")
        // A later edit cannot mutate an operation that may already be accepted.
        try replaceLocal("- [ ]", "- [x]")
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.request(for: id, bindTo: "http://localhost:8788").1, bytes)
        try accept(id)
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertTrue(try outbox.operation(outbox.records()[0]).item.completed)
        try accept(id)
        try "# Inbox\n".write(to: file, atomically: true, encoding: .utf8)
        try outbox.reconcileLocal(id, candidates: [])
        let deletion = try outbox.operation(outbox.records()[0])
        XCTAssertEqual(deletion.expected_revision, 3); XCTAssertTrue(deletion.item.deleted)
        try accept(id)
        try FileWriter.appendUnderHeading("Quick capture", item: "- [ ] stale <!--qc-source:\(id)-->", to: file)
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        XCTAssertTrue(try outbox.baseline(outbox.records()[0]).item.deleted)
    }
    func testIncomingEditCompletionAndDeletionUpdateMarkdownWithoutEcho() throws {
        let id = try linked()
        let update = try remote(id, completed: true)
        try outbox.receive(update, id: id, candidates: [])
        XCTAssertTrue(try FileWriter.read(file).contains("- [x] remote <!--qc-source:\(id)-->") )
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        try outbox.receive(remote(id, deleted: true), id: id, candidates: [])
        XCTAssertFalse(try FileWriter.read(file).contains(id))
        XCTAssertTrue(try outbox.baseline(outbox.records()[0]).item.deleted)
    }
    func testConflictKeepsLocalFileAndExplicitLocalResolutionUsesRemoteRevision() throws {
        let id = try linked()
        try replaceLocal("original", "local version")
        try outbox.reconcileLocal(id, candidates: [])
        let remote = try remote(id)
        try outbox.receive(remote, id: id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "conflict")
        XCTAssertTrue(try FileWriter.read(file).contains("local version"))
        try outbox.keepLocal(id, candidates: [])
        let op = try outbox.operation(outbox.records()[0])
        XCTAssertEqual(op.expected_revision, remote.revision)
        XCTAssertEqual(op.item.body_markdown, "- [ ] local version")
        try accept(id)
        XCTAssertEqual(try outbox.records()[0].receipt?.revision, 3)
    }
    func testConflictCanAcceptRemoteDeletionWithoutResurrection() throws {
        let id = try linked()
        try replaceLocal("original", "local version")
        let remote = try remote(id, deleted: true)
        try outbox.receive(remote, id: id, candidates: [])
        XCTAssertThrowsError(try outbox.keepLocal(id, candidates: []))
        XCTAssertTrue(try FileWriter.read(file).contains("local version"))
        try outbox.receive(remote, id: id, candidates: [], force: true)
        XCTAssertFalse(try FileWriter.read(file).contains(id))
    }
    func testArchiveAndRefileAreMovesAndMissingFileIsNotDeletion() throws {
        let id = try linked()
        try replaceLocal("- [ ]", "- [x]")
        try FileWriter.archiveCompleted(at: file)
        try outbox.reconcileLocal(id, candidates: [])
        let op = try outbox.operation(outbox.records()[0])
        XCTAssertTrue(op.item.completed); XCTAssertFalse(op.item.deleted)
        XCTAssertEqual(try outbox.records()[0].sourceFile, FileWriter.archiveURL(for: file).path)
        try accept(id)
        try FileManager.default.removeItem(at: FileWriter.archiveURL(for: file))
        XCTAssertThrowsError(try outbox.reconcileLocal(id, candidates: []))
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
    }
    func testRefileTracksOnlyKnownIdentityAtDestination() throws {
        let id = try linked()
        let folder = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = try FileWriter.read(file)
        let lines = content.components(separatedBy: "\n")
        let start = lines.firstIndex(where: { $0.contains(id) })!
        let range = FileWriter.subtreeRange(in: content, atLine: start)!
        try RefileService.refile(subtree: lines[range].joined(separator: "\n"), range: range, from: file, toFolder: folder)
        let target = folder.appendingPathComponent("inbox.md")
        try outbox.reconcileLocal(id, candidates: [target])
        XCTAssertEqual(try outbox.records()[0].sourceFile, target.path)
        XCTAssertFalse(try outbox.baseline(outbox.records()[0]).item.deleted)
        XCTAssertEqual(try outbox.records().count, 1)
    }
    func testDuplicateIdentityBlocksUpdatesAndDeletes() throws {
        let id = try linked()
        try FileWriter.appendUnderHeading("Quick capture", item: "- [ ] duplicate <!--qc-source:\(id)-->", to: file)
        XCTAssertThrowsError(try outbox.reconcileLocal(id, candidates: []))
        XCTAssertThrowsError(try outbox.receive(remote(id), id: id, candidates: []))
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
    }
    func testIncomingPlainMarkdownAndMetadataDoNotEchoBack() throws {
        let id = try linked()
        var update = try remote(id, body: "Plain organiser text\nsecond line")
        update.item.kind = "bookmark"; update.item.source_url = "https://example.com"
        update.item.reminder_at = "2026-10-17T12:00:00Z"
        try outbox.receive(update, id: id, candidates: [])
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        try replaceLocal("Plain organiser text", "Locally edited")
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.operation(outbox.records()[0]).item.source_url, "https://example.com")
        XCTAssertEqual(try outbox.operation(outbox.records()[0]).item.reminder_at, update.item.reminder_at)
    }
    func testIncomingJournalRecoversAfterDiskWriteBeforeRecordCommit() throws {
        let id = try linked()
        var update = try remote(id, body: "A plain organiser note\n\nWith another paragraph")
        update.item.kind = "note"
        update.item.reminder_at = "2026-10-18T12:00:00Z"
        var record = try outbox.records()[0]
        record.incoming = update
        try outbox.save(record)
        let local = try OrganiserSource.locate(record, base: outbox.baseline(record).item, candidates: [])
        try local.replacing(with: update.item, id: id).write(to: file, atomically: true, encoding: .utf8)
        try outbox.receive(update, id: id, candidates: [])
        XCTAssertNil(try outbox.records()[0].incoming)
        XCTAssertNil(try outbox.records()[0].conflict)
        XCTAssertEqual(SourceIdentity.ids(in: try FileWriter.read(file)), [id])
    }
    func testIncomingAttachmentsNeverOverwriteSharedLocalFiles() throws {
        let id = try linked()
        var update = try remote(id, body: "- [ ] remote\n  ![](new.png)")
        update.files = [.init(path: "new.png", media_type: "image/png", data_base64: Data("remote bytes".utf8).base64EncodedString())]
        try Data("local bytes".utf8).write(to: root.appendingPathComponent("new.png"))
        XCTAssertThrowsError(try outbox.receive(update, id: id, candidates: []))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.png")), "local bytes")
        XCTAssertTrue(try FileWriter.read(file).contains("original"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("new.png"))
        try outbox.receive(update, id: id, candidates: [])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.png")), "remote bytes")
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
    }
}


extension OrganiserOutboxTests {
    func testParagraphsRoundTripAndIncomingRecoveryPreservesLaterLocalEdit() throws {
        let id = try linked()
        let update = try remote(id, body: "- [ ] Paragraph one\n\nParagraph two")
        try outbox.receive(update, id: id, candidates: [])
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        var next = update; next.revision += 1; next.item.body_markdown = "- [ ] Next remote"
        var record = try outbox.records()[0]
        record.incoming = next
        record.incomingSourceDigest = HandoffJSON.digest(Data(try FileWriter.read(file).utf8))
        try outbox.save(record)
        try replaceLocal("Paragraph one", "Later local edit")
        try outbox.receive(next, id: id, candidates: [])
        XCTAssertNotNil(try outbox.records()[0].conflict)
        XCTAssertTrue(try FileWriter.read(file).contains("Later local edit"))
    }
    func testRefileIntentAndTruncatedSourceNeverBecomeDeletion() throws {
        let id = try linked()
        let target = root.appendingPathComponent("unavailable/inbox.md")
        try outbox.prepareMove(ids: [id], to: target)
        try "# Inbox\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try outbox.reconcileLocal(id, candidates: []))
        outbox.cancelMove(ids: [id])
        try "".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try outbox.reconcileLocal(id, candidates: []))
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
    }
}

extension OrganiserOutboxTests {
    func testDeliveredLegacyRecordUpgradesWithoutRecreatingItem() throws {
        let id = try linked()
        var legacy = try outbox.records()[0]
        legacy.baseline = nil
        try outbox.save(legacy)
        try replaceLocal("original", "after upgrade")
        try outbox.reconcileLocal(id, candidates: [])
        let op = try outbox.operation(outbox.records()[0])
        XCTAssertEqual(op.item_id, id)
        XCTAssertEqual(op.expected_revision, 1)
        XCTAssertEqual(op.item.body_markdown, "- [ ] after upgrade")
    }
    func testRemoteUnreferencedAttachmentIsRetainedWithoutEcho() throws {
        let id = try linked()
        var update = try remote(id)
        update.files = [.init(path: "retained.png", media_type: "image/png", data_base64: Data("retained".utf8).base64EncodedString())]
        try outbox.receive(update, id: id, candidates: [])
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        try replaceLocal("remote", "local edit")
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.operation(outbox.records()[0]).attachments, update.files)
    }
}

extension OrganiserOutboxTests {
    func testIncomingNewItemImportsOnceWithoutSendingCreate() throws {
        let id = UUID().uuidString.lowercased()
        let remote = OrganiserSnapshot(revision: 3, item: OrganiserItem(body_markdown: "From browser"), files: [])
        try outbox.importItem(remote, id: id, file: file, endpoint: "http://localhost:8788", candidates: [])
        try outbox.importItem(remote, id: id, file: file, endpoint: "http://localhost:8788", candidates: [])
        XCTAssertEqual(SourceIdentity.ids(in: try FileWriter.read(file)), [id])
        XCTAssertNil(try outbox.records()[0].receipt)
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.records()[0].state, "delivered")
        try replaceLocal("From browser", "Changed on Mac")
        try outbox.reconcileLocal(id, candidates: [])
        XCTAssertEqual(try outbox.operation(outbox.records()[0]).expected_revision, 3)
    }
    func testIncomingTombstoneDoesNotCreateFileAndCursorSurvivesRestart() throws {
        let id = UUID().uuidString.lowercased()
        var item = OrganiserItem(body_markdown: "Already deleted"); item.deleted = true
        try outbox.importItem(.init(revision: 2, item: item, files: []), id: id, file: file,
            endpoint: "http://localhost:8788", candidates: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try outbox.advanceCursor(42, endpoint: "http://localhost:8788")
        XCTAssertEqual(try outbox.cursor(for: "http://localhost:8788"), 42)
        XCTAssertEqual(try outbox.cursor(for: "https://other.example"), 0)
        XCTAssertTrue(try outbox.baseline(outbox.records()[0]).item.deleted)
    }
}

extension OrganiserOutboxTests {
    func testReminderDatesAndCancellation() throws {
        var item = OrganiserItem(body_markdown: "- [ ] Call home")
        item.reminder_at = "2026-10-16T10:30:00.000+01:00"
        let reminder = try XCTUnwrap(OrganiserReminder.make(id: "test", item: item))
        XCTAssertEqual(reminder.text, "Call home")
        item.reminder_at = "2026-10-16T09:30:00Z"
        XCTAssertEqual(OrganiserReminder.make(id: "test", item: item)?.identifier, reminder.identifier)
        item.completed = true
        XCTAssertNil(OrganiserReminder.make(id: "test", item: item))
        item.completed = false; item.deleted = true
        XCTAssertNil(OrganiserReminder.make(id: "test", item: item))
        item.deleted = false; item.reminder_at = "invalid"
        XCTAssertNil(OrganiserReminder.make(id: "test", item: item))
    }
}
