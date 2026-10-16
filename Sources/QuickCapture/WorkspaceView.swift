import SwiftUI

/// Native browsing surface; the existing editor remains the editing destination.
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    let onCapture: () -> Void
    let onEditor: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            t.border.frame(width: 0.5)
            if model.destination == .projects {
                ProjectsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.destination == .calendar {
                NativeCalendarView(model: model, onCapture: onCapture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: Metrics.s3) {
                    HStack {
                        Text(model.destination.title)
                            .font(TypeScale.h1).tracking(Tracking.h1)
                            .foregroundStyle(t.ink)
                        Spacer()
                        Button("Capture", action: onCapture).buttonStyle(AccentButtonStyle(t: t))
                    }
                    if let problem = model.problem { WarningBanner(text: problem, t: t) }
                    library
                }.padding(Metrics.s4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(t.surface)
        .tint(t.accent)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
        .onAppear { model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Quick Capture")
                .font(Typeface.ui(13, .semibold))
                .foregroundStyle(t.ink)
                .padding(.horizontal, Metrics.s2)
                .padding(.bottom, Metrics.s3)
            sidebarRow(title: "Capture", symbol: "plus.circle", glyphs: "⌥⌘P", selected: false, action: onCapture)
                .help("Return to capture · ⌥⌘P")
            t.border.frame(height: 0.5).padding(.vertical, Metrics.s2)
            ForEach([WorkspaceDestination.calendar, .projects, .todos, .notes, .links]) { destination in
                sidebarRow(title: destination.title, symbol: destination.symbol,
                           glyphs: destination.action.chord.displayGlyphs,
                           selected: model.destination == destination) { model.navigate(destination) }
            }
            Spacer()
            sidebarRow(title: "Editor", symbol: "doc.text", glyphs: "⌥⌘I", selected: false, action: onEditor)
                .help("Edit your inbox · ⌥⌘I")
        }
        .padding(Metrics.s3).frame(width: 220).frame(maxHeight: .infinity)
        .background(t.surfaceRail)
    }

    /// Selection is interaction, so it takes the accent wash (ADR-0005).
    private func sidebarRow(title: String, symbol: String, glyphs: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? t.accentInk : t.inkSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(Typeface.ui(12, selected ? .medium : .regular))
                    .foregroundStyle(selected ? t.accentInk : t.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Keycap(text: glyphs, t: t)
            }
            .padding(.horizontal, Metrics.s2)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(selected ? t.accentSoft : .clear)
            )
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var library: some View {
        HStack(alignment: .top, spacing: Metrics.s3) {
            VStack(alignment: .leading) {
                if model.visible.isEmpty { emptyState }
                else {
                    List(model.visible, selection: $model.selectedID) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(Typeface.ui(13)).foregroundStyle(t.ink).lineLimit(2)
                            Text(item.section).font(TypeScale.caption).foregroundStyle(t.inkSecondary)
                        }.padding(.vertical, 5).tag(item.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let item = model.visible.first(where: { $0.id == model.selectedID }) { detail(item) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Metrics.s2) {
            Image(systemName: model.destination.symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(t.inkSecondary)
            Text("No \(model.destination.title.lowercased()) yet")
                .font(Typeface.ui(16, .semibold)).foregroundStyle(t.ink)
            Text(emptyHint)
                .font(Typeface.ui(12)).foregroundStyle(t.inkSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 350)
            Button("Open capture", action: onCapture)
                .buttonStyle(GhostButtonStyle(t: t))
                .padding(.top, Metrics.s1)
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
            VStack(alignment: .leading, spacing: Metrics.s3) {
                Text(item.section.uppercased())
                    .font(TypeScale.caption).tracking(Tracking.caption)
                    .foregroundStyle(t.inkSecondary)
                Text(item.text)
                    .font(Typeface.ui(13)).foregroundStyle(t.ink)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let starts = item.starts {
                    Label(starts.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(Typeface.ui(12)).foregroundStyle(t.inkSecondary)
                }
                if let url = item.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Link("Open saved link", destination: url).font(Typeface.ui(12))
                }
                Text("Read view · edit in Markdown editor").font(TypeScale.caption).foregroundStyle(t.inkSecondary)
                if item.file == model.captureFile {
                    Button("Open editor", action: onEditor).buttonStyle(GhostButtonStyle(t: t))
                }
            }.padding(Metrics.s3)
        }
        .frame(width: 260)
        .groupedSurface(t)
    }
}

#Preview("Workspace · todos") {
    WorkspaceView(model: .preview(destination: .todos), onCapture: {}, onEditor: {})
        .frame(width: 1000, height: 640)
}

#Preview("Workspace · todos · dark") {
    WorkspaceView(model: .preview(destination: .todos), onCapture: {}, onEditor: {})
        .frame(width: 1000, height: 640)
        .preferredColorScheme(.dark)
}
