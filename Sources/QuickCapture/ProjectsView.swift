import SwiftUI
import AppKit

enum ProjectTab: String, CaseIterable {
    case overview = "Overview", tasks = "Tasks", markdown = "Markdown"
}

struct ProjectsView: View {
    private let store: ProjectStore
    @Bindable private var model: WorkspaceModel
    let onOpen: (URL) -> Void
    private var selected: String? {
        get { model.projectSelection }
        nonmutating set { model.projectSelection = newValue }
    }
    private var tab: ProjectTab {
        get { model.projectTab }
        nonmutating set { model.projectTab = newValue }
    }
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
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var project: DiskProject? { selected.flatMap { store.project($0) } }

    @MainActor init(store: ProjectStore? = nil, model: WorkspaceModel, onOpen: @escaping (URL) -> Void = { _ in }) {
        self.store = store ?? .shared
        self.model = model
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("Projects").font(TypeScale.title).tracking(Tracking.title).foregroundStyle(t.ink)
                Text(store.projects.count == 1 ? "1 folder with its own inbox.md" : "\(store.projects.count) folders, each with its own inbox.md")
                    .font(Typeface.ui(14)).foregroundStyle(t.inkSecondary).padding(.top, 8)
                Spacer()
                Button("Add folder…") { if let id = store.chooseExisting() { selected = id } }
                    .buttonStyle(GhostButtonStyle(t: t))
                Button("New project") { creating = true }
                    .buttonStyle(AccentButtonStyle(t: t))
            }
            .padding(.leading, 26).padding(.trailing, 20).padding(.top, 24).padding(.bottom, 14)
            t.border.frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    projectList
                    t.hairline.frame(height: 1)
                    KeyHints(pairs: [(["↑", "↓"], "project"), (["1", "2", "3"], "tab"), (["↵"], "open")])
                }
                .frame(width: 280)
                t.border.frame(width: 1)
                if let project {
                    projectDetail(project)
                        .background(t.sunken)
                } else {
                    VStack(spacing: Metrics.s2) {
                        Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(t.inkSecondary)
                        Text("A folder for each project").font(Typeface.ui(16, .semibold)).foregroundStyle(t.ink)
                        Text("Add an existing folder or create a new one.\nManage it through the inbox.md in its root.")
                            .font(Typeface.ui(12)).foregroundStyle(t.inkSecondary).multilineTextAlignment(.center)
                        Button("Add folder…") { if let id = store.chooseExisting() { selected = id } }
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
    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.projects) { project in
                    ProjectListRow(project: project, summary: summaries[project.id], selected: project.id == selected, t: t)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onOpen(project.file) }
                        .simultaneousGesture(TapGesture().onEnded { selected = project.id })
                }
            }
            .padding(.leading, 24).padding(.trailing, 20).padding(.vertical, 14)
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
        Text(text).font(Typeface.ui(12, .bold)).foregroundStyle(t.inkSecondary)
    }

    /// The tab switch, each tab with its number key.
    private var tabSwitch: some View {
        HStack(spacing: 2) {
            ForEach(Array(ProjectTab.allCases.enumerated()), id: \.element) { index, item in
                let on = item == tab
                Button { tab = item } label: {
                    HStack(spacing: 6) {
                        Text(item.rawValue)
                        Text("\(index + 1)").font(TypeScale.key)
                            .foregroundStyle(on ? t.accent : t.inkSecondary)
                            .padding(.horizontal, 4)
                            .background(on ? t.accentSoft : t.keycap, in: RoundedRectangle(cornerRadius: Metrics.radiusKey))
                    }
                    .font(Typeface.ui(12.5, on ? .semibold : .regular))
                    .foregroundStyle(on ? t.accent : t.inkSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(on ? t.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: on ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help("\(item.rawValue)  \(index + 1)")
            }
        }
        .padding(2)
        .background(t.keycap, in: RoundedRectangle(cornerRadius: Metrics.radiusField))
    }
    private func projectDetail(_ project: DiskProject) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s3) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(Typeface.ui(24, .bold)).tracking(-0.4).foregroundStyle(t.ink)
                    Text(project.file.path).font(Typeface.mono(12)).foregroundStyle(t.inkSecondary)
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                }
                Spacer()
                tabSwitch
            }
            HStack {
                Label(syncStatus.label, systemImage: syncStatus.symbol)
                    .foregroundStyle(project.conflict != nil ? t.priHigh : t.inkSecondary)
                Text("Only inbox.md syncs").foregroundStyle(t.inkTertiary)
                Spacer()
                Button("Open folder") { NSWorkspace.shared.open(project.folderURL) }
                    .buttonStyle(GhostButtonStyle(t: t))
            }.font(Typeface.ui(12))
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
        }
        .padding(.horizontal, 34).padding(.vertical, 26)
        .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func overview(_ project: DiskProject) -> some View {
        let tasks = document.tasks, done = tasks.filter { $0.status == .done }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: Metrics.s4) {
                VStack(alignment: .leading, spacing: Metrics.s1) {
                    HStack {
                        caption(document.status)
                        Spacer()
                        Button("Edit overview") { overviewEditor = true }
                            .buttonStyle(GhostButtonStyle(t: t))
                            .disabled(hasDraft(project))
                    }
                    Text(document.goal.isEmpty ? "Add a goal to describe what this project should achieve." : document.goal)
                        .font(Typeface.ui(13))
                        .foregroundStyle(document.goal.isEmpty ? t.inkSecondary : t.ink)
                }
                VStack(alignment: .leading, spacing: Metrics.s2) {
                    metrics(tasks)
                    if !tasks.isEmpty { ProgressView(value: Double(done), total: Double(tasks.count)) }
                }
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
    private func metrics(_ tasks: [ProjectTask]) -> some View {
        let done = tasks.filter { $0.status == .done }.count
        let blocked = tasks.filter { $0.status == .blocked }.count
        return HStack(spacing: 10) {
            metric("Open", tasks.count - done)
            metric("Done", done)
            metric("Blocked", blocked, color: blocked > 0 ? t.priHigh : nil)
        }
    }

    private func metric(_ title: String, _ count: Int, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(count)").font(Typeface.ui(26, .bold)).foregroundStyle(color ?? t.ink)
            Text(title).font(TypeScale.meta).foregroundStyle(t.inkSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusWell))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusWell).strokeBorder(t.border, lineWidth: 1))
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
            }
            metrics(document.tasks)
            if hasDraft(project) { WarningBanner(text: "Save or discard your Markdown draft before moving tasks.", t: t) }
            // Empty columns fold away so the ones in use get the room.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ProjectTaskStatus.allCases.filter { !(byStatus[$0] ?? []).isEmpty || $0 == .next || $0 == .doing }) { status in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(status.rawValue).foregroundStyle(status == .doing ? t.accent : t.inkSecondary)
                                Text("\((byStatus[status] ?? []).count)").foregroundStyle(t.inkTertiary).fontWeight(.medium)
                            }
                            .font(Typeface.ui(12, .bold))
                            ForEach(byStatus[status] ?? []) { task in taskRow(task, project: project) }
                            Spacer(minLength: 0)
                        }
                        .frame(width: 170).frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
    }
    private func taskRow(_ task: ProjectTask, project: DiskProject) -> some View {
        let snapshot = content
        return VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(Typeface.ui(12.5))
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
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusField))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusField).strokeBorder(t.border, lineWidth: 1))
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
    let selected: Bool
    let t: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name).font(Typeface.ui(14, .semibold)).foregroundStyle(t.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let summary { Text("\(summary.open) open").font(TypeScale.meta).foregroundStyle(t.inkSecondary) }
            }
            Text(project.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Typeface.mono(11.5)).foregroundStyle(t.inkSecondary)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(selected ? t.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusField))
        .overlay { if selected { RoundedRectangle(cornerRadius: Metrics.radiusField).strokeBorder(t.accent, lineWidth: 2) } }
        .padding(.horizontal, -12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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

#if DEBUG
#Preview("Projects · sample") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc-preview-projects")
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ProjectStore(root: root.appendingPathComponent("registry"))
    if let garden = try? store.create(parent: root, name: "Garden") {
        try? store.addTask("Order seeds", project: garden)
    }
    _ = try? store.create(parent: root, name: "Kitchen refit")
    return ProjectsView(store: store, model: .preview(destination: .projects)).frame(width: 900, height: 600)
}

#Preview("Projects · empty · dark") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc-preview-projects-empty")
    try? FileManager.default.removeItem(at: root)
    return ProjectsView(store: ProjectStore(root: root), model: .preview(destination: .projects)).frame(width: 900, height: 600)
        .preferredColorScheme(.dark)
}
#endif
