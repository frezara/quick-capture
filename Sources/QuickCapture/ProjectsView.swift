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
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var project: DiskProject? { selected.flatMap { store.project($0) } }

    @MainActor init(store: ProjectStore? = nil) { self.store = store ?? .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.s2) {
                Text("Projects").font(TypeScale.h1).tracking(Tracking.h1).foregroundStyle(t.ink)
                Spacer()
                Button("Add Existing Folder…") { if let id = store.chooseExisting() { selected = id } }
                    .buttonStyle(GhostButtonStyle(t: t))
                Button("New Project…") { creating = true }
                    .buttonStyle(AccentButtonStyle(t: t))
            }.padding(.horizontal, Metrics.s4).padding(.vertical, Metrics.s3)
            t.border.frame(height: 0.5)
            HSplitView {
                List(store.projects, selection: $selected) { project in
                    ProjectListRow(project: project, summary: summaries[project.id], t: t)
                        .tag(project.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(t.surfaceRail)
                .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
                if let project {
                    projectDetail(project)
                } else {
                    VStack(spacing: Metrics.s2) {
                        Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(t.inkSecondary)
                        Text("A folder for each project").font(Typeface.ui(16, .semibold)).foregroundStyle(t.ink)
                        Text("Add an existing folder or create a new one.\nManage it through the inbox.md in its root.")
                            .font(Typeface.ui(12)).foregroundStyle(t.inkSecondary).multilineTextAlignment(.center)
                        Button("Add Existing Folder…") { if let id = store.chooseExisting() { selected = id } }
                            .buttonStyle(GhostButtonStyle(t: t)).padding(.top, Metrics.s1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(t.surface)
        .tint(t.accent)
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
            VStack(alignment: .leading, spacing: Metrics.s3) {
                Text("New project").font(Typeface.ui(16, .semibold)).foregroundStyle(t.ink)
                ThemedField(placeholder: "Folder name", text: $newName, t: t).frame(width: 320)
                Text("Choose a parent folder next. A new inbox.md will be created inside your project.")
                    .font(Typeface.ui(12)).foregroundStyle(t.inkSecondary).frame(width: 320, alignment: .leading)
                HStack {
                    Button("Cancel") { creating = false }.buttonStyle(GhostButtonStyle(t: t))
                    Spacer()
                    Button("Choose Location…") {
                        creating = false
                        if let id = store.chooseNew(name: newName) { selected = id; newName = "" }
                    }
                    .buttonStyle(AccentButtonStyle(t: t))
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(Metrics.s4).background(t.surface)
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
    private func caption(_ text: String) -> some View {
        Text(text.uppercased()).font(TypeScale.caption).tracking(Tracking.caption).foregroundStyle(t.inkSecondary)
    }
    private func projectDetail(_ project: DiskProject) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s3) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(TypeScale.h1).tracking(Tracking.h1).foregroundStyle(t.ink)
                    Text(project.folder).font(TypeScale.code).foregroundStyle(t.inkSecondary)
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                }
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(project.folderURL) }
                    .buttonStyle(GhostButtonStyle(t: t))
            }
            HStack {
                Label(syncStatus.label, systemImage: syncStatus.symbol)
                    .foregroundStyle(project.conflict != nil ? t.priHigh : t.inkSecondary)
                Spacer()
                Text("Only inbox.md syncs").foregroundStyle(t.inkSecondary)
            }.font(Typeface.ui(11, .medium))
            if let problem = fileProblem ?? project.problem { WarningBanner(text: problem, t: t) }
            if let conflict = project.conflict {
                DisclosureGroup("Compare local and server versions") {
                    HStack(alignment: .top, spacing: Metrics.s2) {
                        ScrollView { Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Metrics.s2) }
                            .groupedSurface(t)
                        ScrollView { Text(conflict.item.body_markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Metrics.s2) }
                            .groupedSurface(t)
                    }.font(TypeScale.code).foregroundStyle(t.ink).frame(height: 180)
                }.font(Typeface.ui(12)).foregroundStyle(t.ink)
                HStack {
                    Button("Keep Local") { store.resolve(project.id, useRemote: false); reload() }
                    Button("Use Server Version") { store.resolve(project.id, useRemote: true); reload() }
                }
                .buttonStyle(GhostButtonStyle(t: t))
                .disabled(store.busy.contains(project.id) || conflict.item.deleted)
            }
            Picker("Project view", selection: $tab) {
                ForEach(ProjectTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 400)
            if fileProblem != nil {
                WarningBanner(text: "The inbox could not be read. Restore the root inbox.md to continue; no replacement or deletion has been sent.", t: t)
                Spacer()
            } else {
                switch tab {
                case .overview: overview(project)
                case .tasks: tasks(project)
                case .markdown: markdown(project)
                }
            }
        }.padding(Metrics.s4).frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func overview(_ project: DiskProject) -> some View {
        let tasks = document.tasks, done = tasks.filter { $0.status == .done }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: Metrics.s4) {
                VStack(alignment: .leading, spacing: Metrics.s1) {
                    HStack {
                        caption(document.status)
                        Spacer()
                        Button("Edit Overview") { overviewEditor = true }
                            .buttonStyle(GhostButtonStyle(t: t))
                            .disabled(hasDraft(project))
                    }
                    Text(document.goal.isEmpty ? "Add a goal to describe what this project should achieve." : document.goal)
                        .font(Typeface.ui(13))
                        .foregroundStyle(document.goal.isEmpty ? t.inkSecondary : t.ink)
                }
                VStack(alignment: .leading, spacing: Metrics.s3) {
                    HStack(spacing: Metrics.s4) {
                        metric("Open", tasks.count - done)
                        metric("Done", done)
                        metric("Blocked", tasks.filter { $0.status == .blocked }.count)
                        Spacer(minLength: 0)
                    }
                    if !tasks.isEmpty { ProgressView(value: Double(done), total: Double(tasks.count)) }
                }.padding(Metrics.s3).groupedSurface(t)
                VStack(alignment: .leading, spacing: Metrics.s1) {
                    caption("Next action")
                    Text(tasks.first { $0.status == .doing || $0.status == .next }?.title ?? "Choose a task and move it to Next or Doing.")
                        .font(Typeface.ui(13)).foregroundStyle(t.ink)
                }
                if let modified {
                    Text("Updated " + modified.formatted(date: .abbreviated, time: .shortened))
                        .font(TypeScale.caption).foregroundStyle(t.inkSecondary)
                }
                Text("Tasks, notes and project information live together in inbox.md. Use Markdown for notes, links and any additional sections.")
                    .font(Typeface.ui(12)).foregroundStyle(t.inkSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Metrics.s1)
        }
    }
    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(Typeface.ui(22, .semibold)).foregroundStyle(t.ink)
            caption(title)
        }
    }
    private func tasks(_ project: DiskProject) -> some View {
        let byStatus = Dictionary(grouping: document.tasks, by: \.status)
        return VStack(alignment: .leading, spacing: Metrics.s2) {
            HStack(spacing: Metrics.s2) {
                ThemedField(placeholder: "Capture a task in this project…", text: $taskText, t: t)
                    .onSubmit { addTask(project) }
                Button("Add") { addTask(project) }
                    .buttonStyle(AccentButtonStyle(t: t))
                    .disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Toggle("Board", isOn: $board).toggleStyle(.switch).controlSize(.small)
                    .font(Typeface.ui(12)).foregroundStyle(t.ink)
            }
            if hasDraft(project) { WarningBanner(text: "Save or discard your Markdown draft before moving tasks.", t: t) }
            if board {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.s2) {
                        ForEach(ProjectTaskStatus.allCases) { status in
                            VStack(alignment: .leading, spacing: Metrics.s2) {
                                caption(status.rawValue)
                                ForEach(byStatus[status] ?? []) { task in taskRow(task, project: project) }
                                Spacer()
                            }.padding(Metrics.s2).frame(width: 180).frame(maxHeight: .infinity, alignment: .top)
                                .groupedSurface(t)
                        }
                    }
                }
            } else {
                List {
                    ForEach(ProjectTaskStatus.allCases) { status in
                        if let tasks = byStatus[status], !tasks.isEmpty {
                            Section { ForEach(tasks) { task in taskRow(task, project: project) } }
                                header: { caption(status.rawValue) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
    private func taskRow(_ task: ProjectTask, project: DiskProject) -> some View {
        let snapshot = content
        return VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(Typeface.ui(13))
                .foregroundStyle(task.status == .done ? t.inkSecondary : t.ink)
                .strikethrough(task.status == .done)
                .textSelection(.enabled)
            Menu(task.status.rawValue) {
                ForEach(ProjectTaskStatus.allCases) { status in
                    Button(status.rawValue) {
                        store.change(project, expected: snapshot, text: ProjectDocument(text: snapshot).moving(task, to: status)); reload()
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .font(Typeface.ui(11)).foregroundStyle(t.inkSecondary)
            .disabled(hasDraft(project))
        }.padding(.vertical, 4)
    }
    private func addTask(_ project: DiskProject) {
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try store.addTask(taskText, project: project); taskText = ""; reload() }
        catch { store.message = error.localizedDescription }
    }
    private func markdown(_ project: DiskProject) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s2) {
            HStack(spacing: Metrics.s2) {
                Text(hasDraft(project) ? "Unsaved draft · retained locally" : "inbox.md")
                    .font(TypeScale.code).foregroundStyle(t.inkSecondary)
                Spacer()
                Button("Discard Draft") { pendingDraft = nil; store.discardDraft(project); reload() }
                    .buttonStyle(GhostButtonStyle(t: t))
                    .disabled(!hasDraft(project))
                Button("Save") { flushDraft(project.id); store.saveDraft(project); reload() }
                    .buttonStyle(AccentButtonStyle(t: t))
                    .disabled(!hasDraft(project))
            }
            TextEditor(text: Binding(
                get: { pendingDraft ?? store.draft(for: project)?.text ?? content },
                set: { text in
                    if pendingDraft == nil { pendingDraftBase = content }
                    pendingDraft = text
                }))
                .font(TypeScale.body)
                .foregroundStyle(t.ink)
                .scrollContentBackground(.hidden)
                .padding(Metrics.s2)
                .background(t.surfaceField, in: RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous))
        }
    }
}

private struct ProjectListRow: View {
    let project: DiskProject
    let summary: ProjectSummary?
    let t: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(project.name, systemImage: "folder").font(Typeface.ui(13, .medium)).foregroundStyle(t.ink)
            if let summary {
                Text(summary.line).font(TypeScale.caption).foregroundStyle(t.inkSecondary)
                if let next = summary.nextAction {
                    Text(next).font(Typeface.ui(11)).lineLimit(1).foregroundStyle(t.inkSecondary)
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
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    @State private var status: String
    @State private var goal: String
    @State private var problem: String?
    init(project: DiskProject, original: String, onSave: @escaping () -> Void) {
        self.project = project; self.original = original; self.onSave = onSave
        _status = State(initialValue: ProjectDocument(text: original).status)
        _goal = State(initialValue: ProjectDocument(text: original).goal)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s3) {
            Text("Project overview").font(Typeface.ui(16, .semibold)).foregroundStyle(t.ink)
            Picker("Status", selection: $status) { ForEach(["Active", "Paused", "Completed"], id: \.self) { Text($0).tag($0) } }
                .font(Typeface.ui(12))
            ThemedField(placeholder: "What should this project achieve?", text: $goal, t: t, lines: 3...6)
            if let problem { WarningBanner(text: problem, t: t) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle(t: t))
                Spacer()
                Button("Save") {
                    do {
                        try ProjectFiles.write(ProjectDocument(text: original).settingOverview(status: status, goal: goal), project: project, expected: original)
                        onSave(); dismiss()
                    } catch { problem = "The inbox changed. Close and reopen this form to review the current version. " + error.localizedDescription }
                }.buttonStyle(AccentButtonStyle(t: t))
            }
        }.padding(Metrics.s4).frame(width: 400).background(t.surface).tint(t.accent)
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

#Preview("Projects · empty · dark") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc-preview-projects-empty")
    try? FileManager.default.removeItem(at: root)
    return ProjectsView(store: ProjectStore(root: root)).frame(width: 900, height: 600)
        .preferredColorScheme(.dark)
}
