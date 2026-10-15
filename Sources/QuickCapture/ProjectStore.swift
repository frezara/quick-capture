import AppKit
import SwiftUI

struct ProjectDraft: Codable {
    let base: String
    var text: String
}

@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuickCapture/Projects"))
    struct State: Codable {
        var projects: [DiskProject] = []
        var drafts: [String: ProjectDraft] = [:]
    }
    @Published private(set) var state = State()
    @Published var message: String?
    @Published private(set) var busy: Set<String> = []
    private let root: URL
    private var readable = true
    private var worker: Task<Void, Never>?
    var projects: [DiskProject] { state.projects }
    init(root: URL) {
        self.root = root
        let file = root.appendingPathComponent("projects.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { readable = false; message = "Could not read the project registry. It has been left untouched: " + error.localizedDescription }
        }
    }
    private func persist(_ next: State) throws {
        guard readable else { throw HandoffError.invalid("Project registry needs recovery before it can be changed.") }
        try HandoffFiles.write(try JSONEncoder().encode(next), to: root.appendingPathComponent("projects.json"))
        state = next
    }
    private func update(_ project: DiskProject) throws {
        var next = state
        guard let index = next.projects.firstIndex(where: { $0.id == project.id }) else { return }
        next.projects[index] = project
        try persist(next)
    }
    func project(_ id: String) -> DiskProject? { projects.first { $0.id == id } }
    @discardableResult
    func register(folder: URL) throws -> DiskProject {
        guard readable else { throw HandoffError.invalid("Recover the project registry before adding folders.") }
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw HandoffError.invalid("Choose a project folder.") }
        if let existing = projects.first(where: { $0.folder == folder.path }) { return existing }
        let project = DiskProject(id: UUID().uuidString.lowercased(), folder: folder.path)
        if !FileManager.default.fileExists(atPath: project.file.path) {
            try Data(ProjectDocument.template(name: project.name).utf8).write(to: project.file, options: .withoutOverwriting)
        }
        let text = try ProjectFiles.read(project)
        guard SourceIdentity.ids(in: text).isEmpty else {
            throw HandoffError.invalid("This inbox contains individually synced captures. Register a different project folder for now; conversion of existing item-level sync needs a separate migration.")
        }
        var next = state; next.projects.append(project); try persist(next)
        return project
    }
    func create(parent: URL, name: String) throws -> DiskProject {
        guard readable else { throw HandoffError.invalid("Recover the project registry before creating folders.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\n") else { throw HandoffError.invalid("Enter a single folder name.") }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw HandoffError.invalid("That folder already exists. Use Add Existing Folder.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return try register(folder: folder)
    }
    func chooseExisting() -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Add Project"; panel.message = "Only inbox.md in this folder will sync. Other files stay on disk."
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        do { return try register(folder: folder).id } catch { message = error.localizedDescription; return nil }
    }
    func chooseNew(name: String) -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Create Here"; panel.message = "Choose the parent folder for your new project."
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        do { return try create(parent: folder, name: name).id } catch { message = error.localizedDescription; return nil }
    }
    func draft(for project: DiskProject) -> ProjectDraft? { state.drafts[project.id] }
    func editDraft(_ text: String, project: DiskProject, base: String) {
        var next = state
        next.drafts[project.id] = ProjectDraft(base: next.drafts[project.id]?.base ?? base, text: text)
        do { try persist(next) }
        catch { state = next; message = "Draft is in memory only; keep the app open. Could not save recovery copy: " + error.localizedDescription }
    }
    func discardDraft(_ project: DiskProject) {
        do { var next = state; next.drafts.removeValue(forKey: project.id); try persist(next) }
        catch { message = error.localizedDescription }
    }
    func saveDraft(_ project: DiskProject) {
        guard let draft = draft(for: project) else { return }
        do {
            try ProjectFiles.write(draft.text, project: project, expected: draft.base)
            discardDraft(project)
        } catch { message = "The file changed or could not be saved. Your draft is retained. " + error.localizedDescription }
    }
    func change(_ project: DiskProject, expected: String, text: String) {
        do {
            guard draft(for: project) == nil else { throw HandoffError.invalid("Save or discard the Markdown draft before changing the overview or tasks.") }
            try ProjectFiles.write(text, project: project, expected: expected)
        } catch { message = error.localizedDescription }
    }
    func capture(_ text: String, tag: String?, attachments: [URL], project: DiskProject) throws {
        guard tag?.lowercased() != "cal" else { throw HandoffError.invalid("For calendar events, choose the main inbox as the capture destination. Project calendar capture is not available yet.") }
        let old = try ProjectFiles.read(project)
        var block = FileWriter.todoLine(text, includeTimestamp: false)
        for file in attachments {
            let path = try AttachmentStore.copy(file, besideFile: project.file)
            block += "\n" + FileWriter.attachmentChildLine(path)
        }
        let section = (tag?.isEmpty == false) ? tag! : "Inbox"
        guard !section.contains("\n"), !section.contains("\r") else { throw HandoffError.invalid("Use a single-line tag.") }
        try ProjectFiles.write(ProjectDocument.appending(block, section: section, to: old), project: project, expected: old)
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if OrganiserController.shared.enabled {
                    for id in self.projects.map(\.id) { await self.synchronise(id) }
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }
    /// Immutable operations are persisted before sending; lost acknowledgements
    /// replay the same operation ID. Missing local files never become deletions.
    func synchronise(_ id: String, connection: (endpoint: String, token: String)? = nil) async {
        guard !busy.contains(id), var project = project(id), project.conflict == nil else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            let local = try ProjectFiles.read(project)
            if project.endpoint == nil {
                project.endpoint = try OrganiserOutbox.endpoint(connection?.endpoint ?? OrganiserController.shared.endpoint)
                try update(project)
            }
            let endpoint = project.endpoint!
            guard let token = try connection?.token ?? OrganiserCredentials.read(endpoint) else { throw HandoffError.invalid("Waiting for the sync access key in Settings.") }
            if project.pending == nil, local != project.baseline?.item.body_markdown {
                let item = OrganiserItem(body_markdown: local, kind: "project", section: project.name)
                project.pending = OrganiserOperation(operation_id: UUID().uuidString.lowercased(), item_id: id,
                    expected_revision: project.baseline?.revision ?? 0, item: item, attachments: [])
                try update(project)
            }
            let http = OrganiserHTTP()
            if let pending = project.pending {
                let (data, status) = try await http.request(endpoint: endpoint, token: token, path: "/api/operations", data: HandoffJSON.encode(pending))
                guard connection != nil || OrganiserController.shared.enabled else { return }
                if status == 409 {
                    project.conflict = try await http.fetch(endpoint: endpoint, token: token, id: id)
                    project.problem = "Both versions changed. Choose which version to keep."
                    try update(project); return
                }
                guard status == 200 else { throw HandoffError.invalid("Project sync returned HTTP \(status). Local files and pending changes are retained.") }
                let receipt = try JSONDecoder().decode(OrganiserAcknowledgement.self, from: data)
                guard receipt.item_id == id, receipt.operation_id == pending.operation_id, receipt.revision == pending.expected_revision + 1 else { throw HandoffError.invalid("Invalid project acknowledgement.") }
                project.baseline = OrganiserSnapshot(revision: receipt.revision, item: pending.item, files: [])
                project.pending = nil; project.problem = nil; try update(project)
            }
            guard project.baseline != nil else { return }
            let remote = try await http.fetch(endpoint: endpoint, token: token, id: id, known: project.baseline)
            guard connection != nil || OrganiserController.shared.enabled else { return }
            guard remote.item.kind == "project", remote.files.isEmpty else { throw HandoffError.invalid("Unexpected project data from server; local inbox is unchanged.") }
            if remote.revision != project.baseline?.revision {
                let current = try ProjectFiles.read(project)
                if remote.item.deleted || current != project.baseline?.item.body_markdown {
                    project.conflict = remote; project.problem = "The server version changed. Your local inbox is retained."
                } else {
                    try ProjectFiles.write(remote.item.body_markdown, project: project, expected: current)
                    project.baseline = remote
                }
            }
            if project.conflict == nil { project.problem = nil }
            try update(project)
        } catch {
            if var current = self.project(id) { current.problem = error.localizedDescription; try? update(current) }
        }
    }
    func resolve(_ id: String, useRemote: Bool) {
        guard !busy.contains(id), var project = project(id), let remote = project.conflict else { return }
        do {
            guard !remote.item.deleted, remote.item.kind == "project", remote.files.isEmpty else { throw HandoffError.invalid("The server project was removed or is incompatible. Your folder is retained; automatic replacement is disabled.") }
            let current = try ProjectFiles.read(project)
            if useRemote {
                guard draft(for: project) == nil else { throw HandoffError.invalid("Save or discard your Markdown draft first.") }
                try ProjectFiles.write(remote.item.body_markdown, project: project, expected: current)
            }
            project.baseline = remote; project.pending = nil; project.conflict = nil; project.problem = nil
            try update(project)
        } catch { message = error.localizedDescription }
    }
}
