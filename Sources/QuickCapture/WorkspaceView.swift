import SwiftUI

/// Native browsing surface; the existing editor remains the editing destination.
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    let onCapture: () -> Void
    let onEditor: () -> Void
    var onAgendaOpen: (AgendaRow) -> Void = { _ in }
    var onAgendaTick: (AgendaRow) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            t.border.frame(width: 0.5)
            if model.destination == .agenda {
                AgendaView(model: model, onOpen: onAgendaOpen, onTick: onAgendaTick)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeCalendarView(model: model, onCapture: onCapture, onEditor: onEditor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ForEach(WorkspaceDestination.allCases) { destination in
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

}

#if DEBUG
#Preview("Workspace · agenda") {
    WorkspaceView(model: .preview(destination: .agenda), onCapture: {}, onEditor: {})
        .frame(width: 1000, height: 640)
}

#Preview("Workspace · agenda · dark") {
    WorkspaceView(model: .preview(destination: .agenda), onCapture: {}, onEditor: {})
        .frame(width: 1000, height: 640)
        .preferredColorScheme(.dark)
}
#endif
