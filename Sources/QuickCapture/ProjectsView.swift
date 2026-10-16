import SwiftUI
import AppKit

enum ProjectTab: String, CaseIterable {
    case overview = "Overview", tasks = "Tasks", markdown = "Markdown"
}

struct ProjectsView: View {
    private let store: ProjectStore
    @State private var selected: String?
    @State private var tab = ProjectTab.overview
    @State private var content = ""
    @State private var document = ProjectDocument(text: "")
    @State private var modified: Date?
    @State private var summaries: [String: ProjectSummary] = [:]
    @State private var fileProblem: String?
    /// Markdown typed since the last flush to the store. Persisting a draft
    /// rewrites the whole project registry, so keystrokes collect here and are
    /// flushed after a pause, or at once before anything reads the draft.
    @State private var pendingDraft: String?
    @State private var pendingDraftBase = ""
    @State private var newName = ""
    @State private var creating = false
    @State private var overviewEditor = false
    @State private var taskText = ""
    @State private var board = false
    private var project: DiskProject? { selected.flatMap { store.project($0) } }

    @MainActor init(store: ProjectStore? = nil) { self.store = store ?? .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects").font(.title2.weight(.semibold))
                Spacer()
                Button("Add Existing Folder…") { if let id = store.chooseExisting() { selected = id } }
                Button("New Project…") { creating = true }
            }.padding(20)
            Divider()
            HSplitView {
                List(store.projects, selection: $selected) { project in
                    ProjectListRow(project: project, summary: summaries[project.id])
                        .tag(project.id)
                }.listStyle(.sidebar).frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
                if let project {
                    projectDetail(project)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("A folder for each project").font(.title2)
                        Text("Add an existing folder or create a new one.\nManage it through the inbox.md in its root.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Add Existing Folder…") { if let id = store.chooseExisting() { selected = id } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selected == nil { selected = store.projects.first?.id }; reload() }
        .onChange(of: selected) { old, _ in flushDraft(old); tab = .overview; reload() }
        .onChange(of: tab) { _, _ in flushDraft(selected) }
        .onChange(of: store.projects.map(\.id)) { _, _ in reload() }
        .onDisappear { flushDraft(selected) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                reload()
            }
        }
        .task(id: pendingDraft) {
            guard pendingDraft != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushDraft(selected)
        }
        .alert("Project", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New project").font(.title2)
                TextField("Folder name", text: $newName).frame(width: 320)
                Text("Choose a parent folder next. A new inbox.md will be created inside your project.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 320)
                HStack {
                    Button("Cancel") { creating = false }
                    Spacer()
                    Button("Choose Location…") {
                        creating = false
                        if let id = store.chooseNew(name: newName) { selected = id; newName = "" }
                    }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24)
        }
        .sheet(isPresented: $overviewEditor) {
            if let project { ProjectOverviewEditor(project: project, original: content) { reload() } }
        }
    }
    private func reload() {
        var next: [String: ProjectSummary] = [:]
        for project in store.projects {
            let result = Result { try ProjectFiles.read(project) }
            next[project.id] = ProjectSummary(text: try? result.get())
            guard project.id == selected else { continue }
            switch result {
            case .success(let text):
                if text != content { content = text; document = ProjectDocument(text: text) }
                fileProblem = nil
            case .failure(let error):
                fileProblem = error.localizedDescription
            }
            modified = try? project.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        if project == nil, !content.isEmpty { content = ""; document = ProjectDocument(text: "") }
        if next != summaries { summaries = next }
    }
    private func hasDraft(_ project: DiskProject) -> Bool {
        pendingDraft != nil || store.draft(for: project) != nil
    }
    private func flushDraft(_ id: String?) {
        guard let text = pendingDraft else { return }
        pendingDraft = nil
        guard let project = id.flatMap({ store.project($0) }) else { return }
        guard text != (store.draft(for: project)?.text ?? pendingDraftBase) else { return }
        store.editDraft(text, project: project, base: pendingDraftBase)
    }
    private var syncStatus: (label: String, symbol: String) {
        guard let project else { return ("", "") }
        if project.conflict != nil { return ("Sync conflict", "exclamationmark.triangle") }
        let label = project.pending != nil ? "Sync queued" : project.baseline != nil ? "Synced" : "Local · waiting to sync"
        return (label, "arrow.triangle.2.circlepath")
    }
    private func projectDetail(_ project: DiskProject) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.title.weight(.semibold))
                    Text(project.folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(project.folderURL) }
            }
            HStack {
                Label(syncStatus.label, systemImage: syncStatus.symbol)
                Spacer()
                Text("Only inbox.md syncs").foregroundStyle(.secondary)
            }.font(.caption)
            if let problem = fileProblem ?? project.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            if let conflict = project.conflict {
                DisclosureGroup("Compare local and server versions") {
                    HStack(alignment: .top) {
                        ScrollView { Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        ScrollView { Text(conflict.item.body_markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.font(.system(.caption, design: .monospaced)).frame(height: 180)
                }
                HStack {
                    Button("Keep Local") { store.resolve(project.id, useRemote: false); reload() }
                    Button("Use Server Version") { store.resolve(project.id, useRemote: true); reload() }
                }.disabled(store.busy.contains(project.id) || conflict.item.deleted)
            }
            Picker("Project view", selection: $tab) {
                ForEach(ProjectTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 400)
            if fileProblem != nil {
                Text("The inbox could not be read. Restore the root inbox.md to continue; no replacement or deletion has been sent.")
                Spacer()
            } else {
                switch tab {
                case .overview: overview(project)
                case .tasks: tasks(project)
                case .markdown: markdown(project)
                }
            }
        }.padding(20).frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func overview(_ project: DiskProject) -> some View {
        let tasks = document.tasks, done = tasks.filter { $0.status == .done }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(document.status).font(.headline)
                    Spacer()
                    Button("Edit Overview") { overviewEditor = true }.disabled(hasDraft(project))
                }
                Text(document.goal.isEmpty ? "Add a goal to describe what this project should achieve." : document.goal)
                    .foregroundStyle(document.goal.isEmpty ? .secondary : .primary)
                HStack(spacing: 30) {
                    metric("Open", tasks.count - done)
                    metric("Done", done)
                    metric("Blocked", tasks.filter { $0.status == .blocked }.count)
                }
                if !tasks.isEmpty { ProgressView(value: Double(done), total: Double(tasks.count)) }
                Text("Next action").font(.headline)
                Text(tasks.first { $0.status == .doing || $0.status == .next }?.title ?? "Choose a task and move it to Next or Doing.")
                if let modified {
                    Text("Updated " + modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text("Tasks, notes and project information live together in inbox.md. Use Markdown for notes, links and any additional sections.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
    }
    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading) { Text("\(count)").font(.title); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func tasks(_ project: DiskProject) -> some View {
        let byStatus = Dictionary(grouping: document.tasks, by: \.status)
        return VStack(alignment: .leading) {
            HStack {
                TextField("Capture a task in this project…", text: $taskText).onSubmit { addTask(project) }
                Button("Add") { addTask(project) }.disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Toggle("Board", isOn: $board).toggleStyle(.switch).controlSize(.small)
            }
            if hasDraft(project) { Text("Save or discard your Markdown draft before moving tasks.").font(.caption).foregroundStyle(.orange) }
            if board {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(ProjectTaskStatus.allCases) { status in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(status.rawValue).font(.headline)
                                ForEach(byStatus[status] ?? []) { task in taskRow(task, project: project) }
                                Spacer()
                            }.padding(12).frame(width: 180).frame(maxHeight: .infinity)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else {
                List {
                    ForEach(ProjectTaskStatus.allCases) { status in
                        if let tasks = byStatus[status], !tasks.isEmpty {
                            Section(status.rawValue) { ForEach(tasks) { task in taskRow(task, project: project) } }
                        }
                    }
                }.listStyle(.inset)
            }
        }
    }
    private func taskRow(_ task: ProjectTask, project: DiskProject) -> some View {
        let snapshot = content
        return VStack(alignment: .leading, spacing: 6) {
            Text(task.title).strikethrough(task.status == .done).textSelection(.enabled)
            Menu(task.status.rawValue) {
                ForEach(ProjectTaskStatus.allCases) { status in
                    Button(status.rawValue) {
                        store.change(project, expected: snapshot, text: ProjectDocument(text: snapshot).moving(task, to: status)); reload()
                    }
                }
            }.menuStyle(.borderlessButton).fixedSize()
                .disabled(hasDraft(project))
        }.padding(.vertical, 4)
    }
    private func addTask(_ project: DiskProject) {
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try store.addTask(taskText, project: project); taskText = ""; reload() }
        catch { store.message = error.localizedDescription }
    }
    private func markdown(_ project: DiskProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(hasDraft(project) ? "Unsaved draft · retained locally" : "inbox.md").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Discard Draft") { pendingDraft = nil; store.discardDraft(project); reload() }.disabled(!hasDraft(project))
                Button("Save") { flushDraft(project.id); store.saveDraft(project); reload() }.disabled(!hasDraft(project))
            }
            TextEditor(text: Binding(
                get: { pendingDraft ?? store.draft(for: project)?.text ?? content },
                set: { text in
                    if pendingDraft == nil { pendingDraftBase = content }
                    pendingDraft = text
                }))
                .font(.system(size: 13, design: .monospaced))
        }
    }
}

private struct ProjectListRow: View {
    let project: DiskProject
    let summary: ProjectSummary?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(project.name, systemImage: "folder")
            if let summary {
                Text(summary.line).font(.caption).foregroundStyle(.secondary)
                if let next = summary.nextAction {
                    Text(next).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 5)
    }
}

private struct ProjectOverviewEditor: View {
    let project: DiskProject
    let original: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: String
    @State private var goal: String
    @State private var problem: String?
    init(project: DiskProject, original: String, onSave: @escaping () -> Void) {
        self.project = project; self.original = original; self.onSave = onSave
        _status = State(initialValue: ProjectDocument(text: original).status)
        _goal = State(initialValue: ProjectDocument(text: original).goal)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project overview").font(.title2)
            Picker("Status", selection: $status) { ForEach(["Active", "Paused", "Completed"], id: \.self) { Text($0).tag($0) } }
            TextField("What should this project achieve?", text: $goal, axis: .vertical).lineLimit(3...6)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Save") {
                    do {
                        try ProjectFiles.write(ProjectDocument(text: original).settingOverview(status: status, goal: goal), project: project, expected: original)
                        onSave(); dismiss()
                    } catch { problem = "The inbox changed. Close and reopen this form to review the current version. " + error.localizedDescription }
                }
            }
        }.padding(24).frame(width: 400)
    }
}

#Preview("Projects · sample") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc-preview-projects")
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ProjectStore(root: root.appendingPathComponent("registry"))
    if let garden = try? store.create(parent: root, name: "Garden") {
        try? store.addTask("Order seeds", project: garden)
    }
    _ = try? store.create(parent: root, name: "Kitchen refit")
    return ProjectsView(store: store).frame(width: 900, height: 600)
}
