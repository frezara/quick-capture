import XCTest
@testable import QuickCapture

final class HandoffTests: XCTestCase {
    var root: URL!
    let workspace = "11111111-1111-4111-8111-111111111111"
    let installation = "22222222-2222-4222-8222-222222222222"
    let sourceID = "33333333-3333-4333-8333-333333333333"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func enqueue(_ store: HandoffStore, body: String = "- [ ] café 🪴\n  ```swift\n  print(\"hello\")\n  ```", asNew: Bool = false, omit: Set<String> = []) async throws -> String {
        try await store.enqueue(sourceID: sourceID, body: body, sourceFile: root.appendingPathComponent("source.md"),
            spool: root.appendingPathComponent("spool"), workspace: workspace, installation: installation, asNew: asNew, omit: omit)
    }
    func testFrozenSnapshotAndExplicitNewSend() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        let first = try await enqueue(store)
        let repeatID = try await enqueue(store, body: "changed")
        XCTAssertEqual(first, repeatID)
        let fresh = try await enqueue(store, body: "changed", asNew: true)
        XCTAssertNotEqual(first, fresh)
        let records = try await store.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.first(where: { $0.id == first })!.manifest.request.payload.capture.body_markdown.contains("café"))
        let restarted = HandoffStore(root: root.appendingPathComponent("queue"))
        let after = try await restarted.records()
        XCTAssertEqual(after.count, 2)
    }
    func testPublishedBundleRebuildsMissingQueueEntry() async throws {
        let location = root.appendingPathComponent("queue")
        let store = HandoffStore(root: location)
        await store.setFault { if $0 == "published" { throw HandoffError.invalid("injected") } }
        do { _ = try await enqueue(store); XCTFail("expected interruption") } catch {}
        let recovered = HandoffStore(root: location)
        let records = try await recovered.records()
        XCTAssertEqual(records.count, 1)
        let retryID = try await enqueue(recovered)
        XCTAssertEqual(retryID, records[0].id)
    }
    func testInterruptedIntentKeepsOriginalBodyAndID() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        await store.setFault { if $0 == "intent" { throw HandoffError.invalid("injected") } }
        do { _ = try await enqueue(store, body: "original"); XCTFail() } catch {}
        let restart = HandoffStore(root: root.appendingPathComponent("queue"))
        _ = try await enqueue(restart, body: "changed later")
        let records = try await restart.records()
        XCTAssertEqual(records[0].manifest.request.payload.capture.body_markdown, "original")
    }
    func testMissingAttachmentRequiresExplicitOmission() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        let body = "- [ ] receipt\n  ![receipt](attachments/missing.png)"
        do { _ = try await enqueue(store, body: body); XCTFail() }
        catch HandoffError.missing(let paths) { XCTAssertEqual(paths, ["attachments/missing.png"]) }
        _ = try await enqueue(store, body: body, omit: ["attachments/missing.png"])
        let record = try await store.records()[0]
        XCTAssertEqual(record.manifest.request.payload.capture.body_markdown, body)
        XCTAssertEqual(record.manifest.request.payload.capture.omitted_attachments, ["attachments/missing.png"])
    }
    func testAttachmentCopySurvivesOriginalDeletion() async throws {
        let folder = root.appendingPathComponent("attachments")
        try HandoffFiles.directory(folder)
        let file = folder.appendingPathComponent("receipt.png")
        try Data("bytes".utf8).write(to: file)
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        let id = try await enqueue(store, body: "- [ ] receipt\n  ![](attachments/receipt.png)")
        try FileManager.default.removeItem(at: file)
        let records = try await store.records()
        let path = records[0].manifest.request.payload.capture.attachments[0].relative_path
        XCTAssertEqual(try HandoffFiles.read(path, in: root.appendingPathComponent("queue/bundles/" + id), limit: 100), Data("bytes".utf8))
    }
    func testSymlinkAndTraversalRefused() throws {
        let external = root.appendingPathComponent("outside")
        try Data("secret".utf8).write(to: external)
        let bundle = root.appendingPathComponent("bundle")
        try HandoffFiles.directory(bundle)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("link"), withDestinationURL: external)
        XCTAssertThrowsError(try HandoffFiles.read("link", in: bundle, limit: 100))
        XCTAssertThrowsError(try HandoffFiles.read("../outside", in: bundle, limit: 100))
        XCTAssertThrowsError(try HandoffFiles.read("/outside", in: bundle, limit: 100))
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("dir"), withDestinationURL: root)
        XCTAssertThrowsError(try HandoffFiles.read("dir/outside", in: bundle, limit: 100))
    }
    func testDisabledDeliveryAndDestinationBinding() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        _ = try await enqueue(store)
        try await store.deliverDue(enabled: false)
        var records = try await store.records()
        XCTAssertEqual(records[0].attempts, 0)
        let id = try await store.enqueue(sourceID: sourceID, body: "other", sourceFile: root.appendingPathComponent("source.md"), spool: root.appendingPathComponent("other"), workspace: UUID().uuidString, installation: installation)
        records = try await store.records()
        XCTAssertEqual(id, records[0].id)
        XCTAssertEqual(records[0].manifest.spool_path, root.appendingPathComponent("spool").path)
        try await store.deliverDue(enabled: true)
        records = try await store.records()
        XCTAssertEqual(records[0].state, "retry_wait")
    }
    struct AcceptingDestination: CaptureDestination {
        func capabilities(at spool: URL) throws -> HandoffCapabilities { HandoffCapabilities(schema_version: 1, workspace_id: "", durable_receipts: true) }
        func deliver(_ m: HandoffManifest, bundle: URL) throws -> HandoffReceipt {
            HandoffReceipt(schema_version: 1, workspace_id: m.request.payload.workspace_id,
                operation_id: m.request.payload.operation_id, capture_id: m.request.payload.capture.capture_id,
                organiser_item_id: "44444444-4444-4444-8444-444444444444", payload_sha256: m.request.payload_sha256,
                accepted_at: "2026-10-15T12:00:00Z")
        }
    }
    func testDeliveryReceiptAndManualRetryKeepIdentity() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        let id = try await enqueue(store)
        await store.setDestination(AcceptingDestination())
        try await store.deliverDue(enabled: true)
        try await store.retry(id)
        let records = try await store.records()
        XCTAssertEqual(records[0].state, "delivered")
        XCTAssertEqual(records[0].receipt?.capture_id, id)
    }
    func testCorruptBundleNeedsAttentionWithoutDeletion() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        let id = try await enqueue(store)
        let file = root.appendingPathComponent("queue/bundles/" + id + "/content.md")
        try Data("changed".utf8).write(to: file)
        try await store.deliverDue(enabled: true)
        let records = try await store.records()
        XCTAssertEqual(records[0].state, "needs_attention")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testSimultaneousEnqueueIsOneHandoff() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        async let a = enqueue(store)
        async let b = enqueue(store)
        let ids = try await [a, b]
        XCTAssertEqual(ids[0], ids[1])
        let records = try await store.records()
        XCTAssertEqual(records.count, 1)
    }
    func testSourceMarkerAndRemoteImageHandling() {
        let marker = "<!--qc-source:\(sourceID)-->"
        XCTAssertEqual(SourceIdentity.ids(in: "- [ ] item !! \(marker)"), [sourceID])
        XCTAssertEqual(FileWriter.priorityBucket(for: "- [ ] item !! <!--qc:old--> \(marker)"), 1)
        XCTAssertEqual(SourceIdentity.localAttachments(in: "![](https://example.com/x) ![](attachments/a.png) ![](attachments/a.png)"), ["attachments/a.png"])
    }
    func testRefileAppendPreservesConcurrentAppendAndTrailingBytes() throws {
        let file = root.appendingPathComponent("inbox.md")
        let original = "# Inbox\n- [ ] old\n\n\n"
        try Data(original.utf8).write(to: file)
        try RefileAppend.append("- [ ] sent", to: file) {
            let h = try FileHandle(forWritingTo: file)
            try h.seekToEnd(); try h.write(contentsOf: Data("- [ ] agent\n".utf8)); try h.close()
        }
        let content = try String(contentsOf: file)
        XCTAssertTrue(content.hasPrefix(original + "- [ ] agent\n"))
        XCTAssertTrue(content.hasSuffix("- [ ] sent\n"))
    }
    func testRefileRenameReportsUncertaintyWithoutReplacingNewFile() throws {
        let file = root.appendingPathComponent("inbox.md")
        try "# Inbox\nold".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RefileAppend.append("sent", to: file) {
            try "# Inbox\nexternal".write(to: file, atomically: true, encoding: .utf8)
        })
        XCTAssertEqual(try String(contentsOf: file), "# Inbox\nexternal")
    }
    func testFailedCaptureRecoveryIsIndependentAndReadable() throws {
        let location = root.appendingPathComponent("recovery")
        let first = try CaptureRecovery.save(text: "first", tag: nil, attachments: [], root: location)
        _ = try CaptureRecovery.save(text: "second", tag: "work", attachments: [], root: location)
        XCTAssertEqual(CaptureRecovery.drafts(root: location).count, 2)
        try CaptureRecovery.remove(first.id, root: location)
        XCTAssertEqual(CaptureRecovery.drafts(root: location).first?.text, "second")
    }
    func testDraftSavedWithRetiredProjectFieldStillLoads() throws {
        let location = root.appendingPathComponent("recovery")
        let id = UUID().uuidString
        let folder = location.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = """
        {"id":"\(id)","text":"typed before upgrade","tag":"work","attachments":[],"projectID":"/Users/me/Projects/old"}
        """
        try Data(legacy.utf8).write(to: folder.appendingPathComponent("draft.json"))
        let drafts = CaptureRecovery.drafts(root: location)
        XCTAssertEqual(drafts.map(\.text), ["typed before upgrade"])
        XCTAssertEqual(drafts.first?.tag, "work")
    }
    func testRealSpoolReceiverRoundTripAndLostAcknowledgement() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let spool = root.appendingPathComponent("spool")
        func runReceiver() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [repo.appendingPathComponent("scripts/organiser_receiver.py").path,
                "--spool", spool.path, "--storage", root.appendingPathComponent("receiver").path,
                "--workspace", workspace, "--once"]
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try runReceiver()
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        let id = try await enqueue(store)
        try await store.deliverDue(enabled: true)
        try runReceiver()
        let receiptFile = spool.appendingPathComponent("receipts/" + id + ".json")
        let firstReceipt = try Data(contentsOf: receiptFile)
        try FileManager.default.removeItem(at: receiptFile)
        try await store.retry(id)
        try await store.deliverDue(enabled: true)
        var records = try await store.records()
        XCTAssertEqual(records[0].state, "retry_wait")
        try runReceiver()
        XCTAssertEqual(try Data(contentsOf: receiptFile), firstReceipt)
        try await store.retry(id)
        try await store.deliverDue(enabled: true)
        records = try await store.records()
        XCTAssertEqual(records[0].state, "delivered")
        let receivedBody = try String(contentsOf: root.appendingPathComponent("receiver/items/" + records[0].receipt!.organiser_item_id + "/content.md"))
        XCTAssertEqual(receivedBody, records[0].manifest.request.payload.capture.body_markdown)
    }
    func testInterruptedAttachmentResumesCopiedBytes() async throws {
        try HandoffFiles.directory(root.appendingPathComponent("attachments"))
        let source = root.appendingPathComponent("attachments/a.png")
        try Data("original".utf8).write(to: source)
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        await store.setFault { if $0 == "attachment" { throw HandoffError.invalid("interrupted_copy") } }
        do { _ = try await enqueue(store, body: "- [ ] item\n  ![](attachments/a.png)"); XCTFail() } catch {}
        try FileManager.default.removeItem(at: source)
        let restarted = HandoffStore(root: root.appendingPathComponent("queue"))
        let pending = try await restarted.pendingImports()
        XCTAssertEqual(pending.count, 1)
        _ = try await restarted.resumeImport(sourceID)
        let records = try await restarted.records()
        XCTAssertEqual(records[0].manifest.request.payload.capture.attachments.first?.sha256, HandoffJSON.digest(Data("original".utf8)))
    }
    func testWriteFailureCannotRegisterQueue() async throws {
        let location = root.appendingPathComponent("queue")
        let store = HandoffStore(root: location)
        _ = try await store.records()
        let staging = location.appendingPathComponent("staging")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path) }
        do { _ = try await enqueue(store); XCTFail("write must fail") } catch {}
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
    }
    func testReceiptCannotAcknowledgeAnotherRequest() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        _ = try await enqueue(store)
        let request = try await store.records()[0].manifest.request
        let wrong = HandoffReceipt(schema_version: 1, workspace_id: workspace,
            operation_id: UUID().uuidString, capture_id: request.payload.capture.capture_id,
            organiser_item_id: UUID().uuidString, payload_sha256: request.payload_sha256, accepted_at: HandoffJSON.timestamp())
        XCTAssertThrowsError(try wrong.validate(for: request))
    }

    func testEachRemainingPublicationBoundaryAndDiskFullRecovery() async throws {
        for point in ["manifest", "registered"] {
            let location = root.appendingPathComponent(point)
            let store = HandoffStore(root: location)
            await store.setFault { if $0 == point { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) } }
            do { _ = try await enqueue(store); XCTFail("Expected simulated disk-full interruption") } catch {}
            let restart = HandoffStore(root: location)
            let id = try await restart.resumeImport(sourceID)
            let records = try await restart.records()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].id, id)
        }
    }
    func testFrozenRequestIsUnchangedWhenRetryingAfterReceiptInterruption() async throws {
        let store = HandoffStore(root: root.appendingPathComponent("queue"))
        let id = try await enqueue(store)
        let original = try await store.records()[0].manifest.request
        await store.setDestination(AcceptingDestination())
        await store.setFault { if $0 == "receipt" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) } }
        try await store.deliverDue(enabled: true)
        await store.setFault(nil)
        try await store.retry(id)
        try await store.deliverDue(enabled: true)
        let record = try await store.records()[0]
        XCTAssertEqual(record.manifest.request, original)
        XCTAssertEqual(record.state, "delivered")
    }

    func testCanonicalFixtureMatchesPythonDigest() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: repo.appendingPathComponent("integration/fixtures/request-v1.json"))
        let request = try JSONDecoder().decode(HandoffRequest.self, from: bytes)
        try request.validate()
        XCTAssertEqual(try HandoffJSON.encode(request), bytes)
    }
}
