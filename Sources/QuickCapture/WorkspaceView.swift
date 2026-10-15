import SwiftUI

/// Native browsing surface; the existing editor remains the editing destination.
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    let onCapture: () -> Void
    let onEditor: () -> Void
    let onProjectCapture: (String) -> Void
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Capture").font(.headline).padding(.bottom, 12)
                Button(action: onCapture) {
                    Label("Capture", systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading)
                }.help("Return to capture · ⌥⌘P")
                Divider().padding(.vertical, 8)
                ForEach([WorkspaceDestination.calendar, .projects, .todos, .notes, .links]) { destination in
                    Button { model.navigate(destination) } label: {
                        HStack {
                            Label(destination.title, systemImage: destination.symbol)
                            Spacer()
                            Text(destination.action.chord.displayGlyphs).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(9)
                        .background(model.destination == destination ? Color.accentColor.opacity(0.13) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button(action: onEditor) { Label("Markdown editor", systemImage: "doc.text") }
                    .help("Edit your inbox · ⌥⌘I")
                Text("⌥⌘P returns to capture").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20).frame(width: 220).frame(maxHeight: .infinity)
            .background(.regularMaterial)
            Divider()
            if model.destination == .projects {
                ProjectsView(onCapture: onProjectCapture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.destination == .calendar {
                NativeCalendarView(model: model, onCapture: onCapture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(model.destination.title).font(.largeTitle.weight(.semibold))
                        Spacer()
                        Button("Capture", action: onCapture)
                    }
                    if let problem = model.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    library
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { model.refresh() }
        .onReceive(refresh) { _ in model.refresh() }
    }

    private var library: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                if model.visible.isEmpty { emptyState }
                else {
                    List(model.visible, selection: $model.selectedID) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).lineLimit(2)
                            Text(item.section).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(item.id)
                    }.listStyle(.plain)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let item = model.visible.first(where: { $0.id == model.selectedID }) { detail(item) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.destination.symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No \(model.destination.title.lowercased()) yet").font(.title3)
            Text(emptyHint).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 350)
            Button("Open capture", action: onCapture)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyHint: String {
        switch model.destination {
        case .projects: return "Add a project folder to manage its inbox.md."
        case .notes: return "Capture into the Notes section, or add #note to an item. Notes have their own space here."
        case .links: return "Capture a link to find it here. Browser extension capture will come later."
        default: return "Your inbox items appear here automatically."
        }
    }
    private func detail(_ item: WorkspaceItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.section).font(.caption).foregroundStyle(.secondary)
                Text(item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let starts = item.starts { Text(starts.formatted(date: .abbreviated, time: .shortened)).font(.callout) }
                if let url = item.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Link("Open saved link", destination: url)
                }
                Text("Read view · edit in Markdown editor").font(.caption).foregroundStyle(.secondary)
                if item.file == modelCaptureFile { Button("Open editor", action: onEditor) }
            }.padding(16)
        }.frame(width: 260).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private var modelCaptureFile: URL { model.captureFile }

}
