import SwiftUI

/// Native browsing surface; the existing editor remains the editing destination.
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    let onCapture: () -> Void
    let onEditor: () -> Void
    var onEditorSlot: (NSView?) -> Void = { _ in }
    var onFocusSchedule: () -> Void = {}
    var onTodayDayChange: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            t.border.frame(width: 0.5)
            if model.destination == .today {
                TodayView(model: model, onEditorSlot: onEditorSlot,
                          onFocusSchedule: onFocusSchedule, onDayChange: onTodayDayChange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.destination == .projects {
                ProjectsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.destination == .calendar {
                NativeCalendarView(model: model, onCapture: onCapture, onEditor: onEditor)
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

    /// Icon-only rail. Each icon names itself and its shortcut on hover and to
    /// VoiceOver; the current page takes the accent wash (accent = interaction).
    private var sidebar: some View {
        VStack(spacing: 6) {
            railButton(title: "Capture", symbol: "plus.circle", glyphs: "⌥⌘P", selected: false,
                       tint: t.accent, action: onCapture)
            t.border.frame(width: 28, height: 1).padding(.vertical, 4)
            ForEach([WorkspaceDestination.today, .todos, .calendar, .projects, .notes, .links]) { destination in
                railButton(title: destination.title, symbol: destination.symbol,
                           glyphs: destination.action.chord.displayGlyphs,
                           selected: model.destination == destination) { model.navigate(destination) }
            }
            Spacer()
            railButton(title: "Editor", symbol: "square.and.pencil", glyphs: "⌥⌘I", selected: false, action: onEditor)
        }
        .padding(.top, 22).padding(.bottom, 14)
        .frame(width: 64).frame(maxHeight: .infinity)
        .background(t.surfaceRail)
    }

    private func railButton(title: String, symbol: String, glyphs: String, selected: Bool,
                            tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(selected ? t.accent : (tint ?? t.inkSecondary))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusWell, style: .continuous)
                        .fill(selected ? t.accentSoft : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title)  \(glyphs)")
        .accessibilityLabel(title)
        .accessibilityHint("Shortcut \(glyphs)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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

#if DEBUG
#Preview("Workspace · todos") {
    WorkspaceView(model: .preview(destination: .todos), onCapture: {}, onEditor: {})
        .frame(width: 1000, height: 640)
}

#Preview("Workspace · todos · dark") {
    WorkspaceView(model: .preview(destination: .todos), onCapture: {}, onEditor: {})
        .frame(width: 1000, height: 640)
        .preferredColorScheme(.dark)
}
#endif
