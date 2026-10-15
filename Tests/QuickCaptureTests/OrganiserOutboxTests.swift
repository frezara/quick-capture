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
        var deleted = try JSONDecoder().decode(OrganiserOperation.self, from: bytes).item
        deleted.deleted = true
        let cleanup = OrganiserOperation(operation_id: UUID().uuidString.lowercased(), item_id: id, expected_revision: 1, item: deleted, attachments: [])
        let result = try await OrganiserHTTP().send(endpoint: endpoint, token: token, data: HandoffJSON.encode(cleanup))
        XCTAssertEqual(result.1, 200)
    }
}
