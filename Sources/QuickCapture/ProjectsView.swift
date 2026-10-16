import SwiftUI
import AppKit

struct ProjectsView: View {
    @ObservedObject private var store = ProjectStore.shared
    @State private var selected: String?
    @State private var tab = "Overview"
    @State private var content = ""
    @State private var fileProblem: String?
    @State private var newName = ""
    @State private var creating = false
    @State private var overviewEditor = false
    @State private var taskText = ""
    @State private var board = false
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private var project: DiskProject? { selected.flatMap { store.project($0) } }
    private var document: ProjectDocument { ProjectDocument(text: content) }

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
                    ProjectListRow(project: project).tag(project.id)
                }.listStyle(.sidebar).frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
                if let project {
                    projectDetail(project)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("A folder for each project").font(.title2)
                        Text("Add an existing folder or create a new one.\nManage it through the inbox.md in its root.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Add Existing Folder…") { selected = store.chooseExisting() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selected == nil { selected = store.projects.first?.id }; reload() }
        .onChange(of: selected) { _, _ in tab = "Overview"; reload() }
        .onReceive(refresh) { _ in reload() }
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
        guard let project else { content = ""; return }
        do { content = try ProjectFiles.read(project); fileProblem = nil }
        catch { fileProblem = error.localizedDescription }
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
                Label(project.conflict != nil ? "Sync conflict" : project.pending != nil ? "Sync queued" : project.baseline != nil ? "Synced" : "Local · waiting to sync",
                      systemImage: project.conflict != nil ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
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
                ForEach(["Overview", "Tasks", "Markdown"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 400)
            if fileProblem != nil {
                Text("The inbox could not be read. Restore the root inbox.md to continue; no replacement or deletion has been sent.")
                Spacer()
            } else if tab == "Overview" { overview(project) }
            else if tab == "Tasks" { tasks(project) }
            else { markdown(project) }
        }.padding(20).frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func overview(_ project: DiskProject) -> some View {
        let tasks = document.tasks, done = tasks.filter { $0.status == .done }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(document.status).font(.headline)
                    Spacer()
                    Button("Edit Overview") { overviewEditor = true }.disabled(store.draft(for: project) != nil)
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
                if let modified = try? project.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
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
        VStack(alignment: .leading) {
            HStack {
                TextField("Capture a task in this project…", text: $taskText).onSubmit { addTask(project) }
                Button("Add") { addTask(project) }.disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Toggle("Board", isOn: $board).toggleStyle(.switch).controlSize(.small)
            }
            if store.draft(for: project) != nil { Text("Save or discard your Markdown draft before moving tasks.").font(.caption).foregroundStyle(.orange) }
            if board {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(ProjectTaskStatus.allCases) { status in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(status.rawValue).font(.headline)
                                ForEach(document.tasks.filter { $0.status == status }) { task in taskRow(task, project: project) }
                                Spacer()
                            }.padding(12).frame(width: 180).frame(maxHeight: .infinity)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else {
                List {
                    ForEach(ProjectTaskStatus.allCases) { status in
                        let tasks = document.tasks.filter { $0.status == status }
                        if !tasks.isEmpty {
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
                .disabled(store.draft(for: project) != nil)
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
                Text(store.draft(for: project) == nil ? "inbox.md" : "Unsaved draft · retained locally").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Discard Draft") { store.discardDraft(project); reload() }.disabled(store.draft(for: project) == nil)
                Button("Save") { store.saveDraft(project); reload() }.disabled(store.draft(for: project) == nil)
            }
            TextEditor(text: Binding(get: { store.draft(for: project)?.text ?? content },
                                    set: { store.editDraft($0, project: project, base: content) }))
                .font(.system(size: 13, design: .monospaced))
        }
    }
}

private struct ProjectListRow: View {
    let project: DiskProject
    var body: some View {
        let text = try? ProjectFiles.read(project)
        let document = ProjectDocument(text: text ?? "")
        VStack(alignment: .leading, spacing: 5) {
            Label(project.name, systemImage: "folder")
            Text(text == nil ? "Inbox unavailable" : "\(document.status) · \(document.tasks.filter { $0.status != .done }.count) open")
                .font(.caption).foregroundStyle(.secondary)
            if let next = document.tasks.first(where: { $0.status == .next || $0.status == .doing }) {
                Text(next.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
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
