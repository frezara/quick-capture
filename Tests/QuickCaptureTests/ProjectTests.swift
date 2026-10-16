import XCTest
@testable import QuickCapture

@MainActor
final class ProjectTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testCreateAndRegisterPreserveExistingFilesAndCanonicalIdentity() throws {
        let store = ProjectStore(root: root.appendingPathComponent("registry"))
        let project = try store.create(parent: root, name: "Example")
        let code = project.folderURL.appendingPathComponent("code.swift")
        try Data("private code".utf8).write(to: code)
        let text = try ProjectFiles.read(project)
        XCTAssertTrue(text.contains("## Next"))
        let again = try store.register(folder: project.folderURL)
        XCTAssertEqual(project.id, again.id)
        XCTAssertEqual(try ProjectFiles.read(project), text)
        XCTAssertEqual(try String(contentsOf: code), "private code")
        XCTAssertThrowsError(try store.create(parent: root, name: "Example"))
        XCTAssertEqual(ProjectStore(root: root.appendingPathComponent("registry")).projects.count, 1)
    }
    func testExistingInboxIsNotRewrittenAndSymlinkInboxIsRejected() throws {
        let store = ProjectStore(root: root.appendingPathComponent("registry"))
        let folder = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "# My existing project\n\nKeep everything here.\n"
        try Data(text.utf8).write(to: folder.appendingPathComponent("inbox.md"))
        let project = try store.register(folder: folder)
        XCTAssertEqual(try ProjectFiles.read(project), text)
        try FileManager.default.removeItem(at: project.file)
        let outside = root.appendingPathComponent("other.md")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.file, withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectFiles.read(project))
        XCTAssertThrowsError(try ProjectFiles.write("changed", project: project, expected: "outside"))
        XCTAssertEqual(try String(contentsOf: outside), "outside")
    }
    func testTaskMovesPreserveSubtreeAndNotes() throws {
        let text = "# Inbox\n\n## Next\n- [ ] Deliver\n  Details\n  ![image](assets/a.png)\n\n## Notes\nKeep me\n```\n- [ ] Example only\n```\n"
        let doc = ProjectDocument(text: text)
        XCTAssertEqual(doc.tasks.count, 1)
        let moved = doc.moving(doc.tasks[0], to: .done)
        XCTAssertTrue(moved.contains("## Done\n- [x] Deliver\n  Details\n  ![image](assets/a.png)"))
        XCTAssertTrue(moved.contains("## Notes\nKeep me"))
        let done = ProjectDocument(text: moved)
        XCTAssertEqual(done.tasks.first?.status, .done)
        XCTAssertTrue(done.moving(done.tasks[0], to: .doing).contains("## Doing\n- [ ] Deliver"))
    }
    func testOverviewPreservesUnknownFieldsAndOtherSections() {
        let doc = ProjectDocument(text: "# Inbox\n## Project\nStatus: Active\nOwner: Me\nGoal: Old\n\n## Notes\nKeep this\n")
        let updated = doc.settingOverview(status: "Paused", goal: "New goal")
        XCTAssertTrue(updated.contains("Owner: Me"))
        XCTAssertTrue(updated.contains("## Notes\nKeep this"))
        XCTAssertEqual(ProjectDocument(text: updated).status, "Paused")
        XCTAssertEqual(ProjectDocument(text: updated).goal, "New goal")
    }
    func testStaleDraftCannotOverwriteExternalEditsAndSurvivesRestart() throws {
        let storeURL = root.appendingPathComponent("registry")
        let store = ProjectStore(root: storeURL)
        let project = try store.create(parent: root, name: "Draft")
        let original = try ProjectFiles.read(project)
        store.editDraft("My unsaved draft", project: project, base: original)
        try ProjectFiles.write(original + "External edit\n", project: project, expected: original)
        store.saveDraft(project)
        XCTAssertNotNil(store.message)
        XCTAssertTrue(try ProjectFiles.read(project).contains("External edit"))
        XCTAssertEqual(ProjectStore(root: storeURL).draft(for: project)?.text, "My unsaved draft")
    }
    func testAddTaskWritesOnlyThatProjectInbox() throws {
        let store = ProjectStore(root: root.appendingPathComponent("registry"))
        let a = try store.create(parent: root, name: "A"), b = try store.create(parent: root, name: "B")
        try store.addTask("Do this", project: a)
        XCTAssertTrue(try ProjectFiles.read(a).contains("- [ ] Do this"))
        XCTAssertFalse(try ProjectFiles.read(b).contains("Do this"))
    }
    func testLiveWholeInboxSyncAndConcurrentEdits() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["ORGANISER_TEST_URL"], let tokenPath = env["ORGANISER_TEST_TOKEN_FILE"] else {
            throw XCTSkip("Requires disposable integration API.")
        }
        let token = try String(contentsOfFile: tokenPath).trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = (endpoint: endpoint, token: token)
        let registry = root.appendingPathComponent("registry")
        let store = ProjectStore(root: registry)
        let project = try store.create(parent: root, name: "Integration")
        try Data("never upload".utf8).write(to: project.folderURL.appendingPathComponent("private.txt"))
        let original = try ProjectFiles.read(project)
        await store.synchronise(project.id, connection: connection)
        XCTAssertEqual(store.project(project.id)?.baseline?.revision, 1)
        let http = OrganiserHTTP()
        let first = try await http.fetch(endpoint: endpoint, token: token, id: project.id)
        XCTAssertEqual(first.item.body_markdown, original)
        XCTAssertTrue(first.files.isEmpty)
        func serverEdit(_ text: String, revision: Int) async throws {
            let op = OrganiserOperation(operation_id: UUID().uuidString.lowercased(), item_id: project.id,
                expected_revision: revision, item: OrganiserItem(body_markdown: text, kind: "project"), attachments: [])
            let (_, status) = try await http.request(endpoint: endpoint, token: token, path: "/api/operations", data: HandoffJSON.encode(op))
            XCTAssertEqual(status, 200)
        }
        try await serverEdit(original + "Server note\n", revision: 1)
        await store.synchronise(project.id, connection: connection)
        let received = try ProjectFiles.read(project)
        XCTAssertTrue(received.contains("Server note"))
        let local = received + "Local change\n"
        try ProjectFiles.write(local, project: project, expected: received)
        try await serverEdit(received + "Concurrent remote change\n", revision: 2)
        await store.synchronise(project.id, connection: connection)
        XCTAssertEqual(try ProjectFiles.read(project), local)
        XCTAssertEqual(store.project(project.id)?.conflict?.revision, 3)
        let restarted = ProjectStore(root: registry)
        XCTAssertNotNil(restarted.project(project.id)?.pending)
        restarted.resolve(project.id, useRemote: false)
        await restarted.synchronise(project.id, connection: connection)
        let resolved = try await http.fetch(endpoint: endpoint, token: token, id: project.id)
        XCTAssertEqual(resolved.revision, 4)
        XCTAssertEqual(resolved.item.body_markdown, local)
        XCTAssertTrue(resolved.files.isEmpty)
        try FileManager.default.removeItem(at: project.file)
        await restarted.synchronise(project.id, connection: connection)
        XCTAssertNotNil(restarted.project(project.id)?.problem)
        let afterMissing = try await http.fetch(endpoint: endpoint, token: token, id: project.id)
        XCTAssertEqual(afterMissing.revision, 4)
        XCTAssertFalse(afterMissing.item.deleted)
    }

    func testManagementEditsIgnoreHeadingsInsideCodeExamples() {
        let example = "```markdown\n## Project\nStatus: Example\n## Inbox\n```\n"
        let text = example + "## Project\nStatus: Active\n## Inbox\n"
        let updated = ProjectDocument(text: text).settingOverview(status: "Paused", goal: "Ship")
        XCTAssertTrue(updated.hasPrefix(example))
        XCTAssertEqual(ProjectDocument(text: updated).status, "Paused")
        let captured = ProjectDocument.appending("- [ ] Real task", section: "Inbox", to: updated)
        XCTAssertTrue(captured.hasPrefix(example))
        XCTAssertEqual(ProjectDocument(text: captured).tasks.count, 1)
    }

    func testSummaryCountsOpenTasksAndNamesTheNextAction() {
        let text = "# Inbox\n## Project\nStatus: Paused\n## Backlog\n- [ ] Someday\n## Doing\n- [ ] Write intro\n## Next\n- [ ] Draft outline\n## Done\n- [x] Pick a name\n"
        let summary = ProjectSummary(text: text)
        XCTAssertEqual(summary.line, "Paused · 3 open")
        XCTAssertEqual(summary.nextAction, "Write intro")
    }

    func testSummaryOfAFreshTemplateHasNoNextAction() {
        let summary = ProjectSummary(text: ProjectDocument.template(name: "Fresh"))
        XCTAssertEqual(summary.line, "Active · 0 open")
        XCTAssertNil(summary.nextAction)
    }

    func testSummaryOfAnUnreadableInboxSaysSo() {
        let summary = ProjectSummary(text: nil)
        XCTAssertEqual(summary.line, "Inbox unavailable")
        XCTAssertNil(summary.nextAction)
    }

}
