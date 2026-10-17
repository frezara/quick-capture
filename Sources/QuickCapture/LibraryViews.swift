import SwiftUI

/// The filter field shared by Todos, Notes and Saved links. `/` focuses it
/// (through `WorkspaceModel.filterFocused`); Return or Esc hands the keys back
/// to the list.
struct LibraryFilterField: View {
    @Bindable var model: WorkspaceModel
    let placeholder: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(t.inkTertiary)
            TextField(placeholder, text: $model.libraryFilter)
                .textFieldStyle(.plain)
                .font(Typeface.ui(12.5)).foregroundStyle(t.ink)
                .focused($focused)
                .onSubmit { model.filterFocused = false }
            Keycap(text: "/", t: t)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 220)
        .background(t.surfaceField, in: RoundedRectangle(cornerRadius: Metrics.radiusField))
        .onChange(of: model.filterFocused) { _, value in focused = value }
        .onChange(of: focused) { _, value in model.filterFocused = value }
    }
}

/// Title, count and filter along the top of a library view.
struct LibraryHeader: View {
    let model: WorkspaceModel
    let title: String
    let subtitle: String
    let placeholder: String
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(TypeScale.title).tracking(Tracking.title).foregroundStyle(t.ink)
            Text(subtitle).font(Typeface.ui(14)).foregroundStyle(t.inkSecondary).padding(.top, 8)
            Spacer()
            LibraryFilterField(model: model, placeholder: placeholder)
        }
        .padding(.leading, 26).padding(.trailing, 20).padding(.top, 24).padding(.bottom, 14)
    }
}

/// Todos: open todos by section, sorted by priority, with the selected one
/// previewed. Driven from the keyboard through `MainPanel`.
struct TodosView: View {
    let model: WorkspaceModel
    let onOpen: (WorkspaceItem) -> Void
    let onTick: (WorkspaceItem) -> Void
    let onPlan: (WorkspaceItem) -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(model: model, title: "Todos", subtitle: subtitle, placeholder: "Filter todos")
            t.border.frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    list
                    t.hairline.frame(height: 1)
                    KeyHints(pairs: [(["↑", "↓"], "move"), (["⌥↑", "⌥↓"], "section"), (["↵"], "open"),
                                     (["X"], "tick"), (["P"], "plan for today"), (["/"], "filter")])
                }
                t.border.frame(width: 1)
                ItemPreview(row: model.selectedItem.map { AgendaRow(item: $0, kind: .todo, day: nil) },
                            hue: model.selectedItem.flatMap(model.sectionHue(for:)),
                            onOpen: { onOpen($0.item) }, onTick: { onTick($0.item) }, onPlan: { onPlan($0.item) })
                    .frame(width: 300)
            }
        }
    }

    private var subtitle: String {
        let open = model.visible.filter { !$0.completed }.count
        return model.libraryFilter.isEmpty ? "\(open) open" : "\(open) open matching"
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.projection.groups.isEmpty {
                        Text(model.libraryFilter.isEmpty ? "No open todos. Capture one with ⌥⌘P." : "No todos match.")
                            .font(TypeScale.meta).foregroundStyle(t.inkSecondary).padding(.top, 20)
                    }
                    ForEach(model.projection.groups, id: \.name) { group in
                        caption(group)
                        ForEach(group.items) { item in row(item) }
                    }
                }
                .padding(.leading, 36).padding(.trailing, 32).padding(.bottom, 20)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }

    private func caption(_ group: LibraryGroup) -> some View {
        let hue = group.items.first.flatMap(model.sectionHue(for:))?.label(dark: dark)
        return HStack(spacing: 8) {
            Text(group.name).foregroundStyle(hue ?? t.inkSecondary)
            Text("\(group.items.count)").foregroundStyle(t.inkTertiary).fontWeight(.medium)
            Spacer()
        }
        .font(Typeface.ui(13, .bold))
        .padding(.top, 18).padding(.bottom, 5)
        .overlay(alignment: .bottom) { (hue ?? t.border).opacity(hue == nil ? 1 : 0.2).frame(height: 1) }
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: WorkspaceItem) -> some View {
        AgendaRowView(row: AgendaRow(item: item, kind: .todo, day: nil), hue: model.sectionHue(for: item),
                      selected: item.id == model.selectedID, now: Date(), showsTime: false, showsSection: false)
            .equatable()
            .id(item.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen(item) }
            .simultaneousGesture(TapGesture().onEnded { model.selectedID = item.id })
    }
}
