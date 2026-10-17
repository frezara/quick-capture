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

/// Short dates for list rows: "Today", a weekday within the last week, else
/// "12 October".
enum LibraryDate {
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE"; return f
    }()
    private static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMMM"; return f
    }()

    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        return (0..<7).contains(days) ? weekday.string(from: date) : dayMonth.string(from: date)
    }
}

/// "1 note", "3 notes".
func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

/// The lines under an item's first line, dedented, as a note's body.
func itemBody(_ item: WorkspaceItem) -> String {
    let rest = item.text.components(separatedBy: "\n").dropFirst()
    return FileWriter.dedent(rest.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Notes: a list beside a reading pane.
struct NotesView: View {
    let model: WorkspaceModel
    let onOpen: (WorkspaceItem) -> Void
    let onCopy: (WorkspaceItem) -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(model: model, title: "Notes", subtitle: count(model.visible.count, "note"), placeholder: "Search notes")
            t.border.frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    list
                    t.hairline.frame(height: 1)
                    KeyHints(pairs: [(["↑", "↓"], "move"), (["↵"], "open"), (["/"], "search")])
                }
                .frame(width: 340)
                t.border.frame(width: 1)
                reader.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.visible.isEmpty {
                        Text(model.libraryFilter.isEmpty ? "No notes yet. Capture into a Notes section, or add #note." : "No notes match.")
                            .font(TypeScale.meta).foregroundStyle(t.inkSecondary).padding(.top, 16)
                    }
                    ForEach(model.visible) { item in
                        NoteRow(item: item, hue: model.sectionHue(for: item), selected: item.id == model.selectedID)
                            .equatable()
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onOpen(item) }
                            .simultaneousGesture(TapGesture().onEnded { model.selectedID = item.id })
                    }
                }
                .padding(.leading, 24).padding(.trailing, 20).padding(.vertical, 12)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private var reader: some View {
        if let item = model.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.section).font(Typeface.ui(12, .semibold))
                        .foregroundStyle(model.sectionHue(for: item)?.label(dark: dark) ?? t.inkSecondary)
                    Text(item.title).font(Typeface.ui(24, .bold)).tracking(-0.4).foregroundStyle(t.ink)
                        .padding(.top, 4).fixedSize(horizontal: false, vertical: true)
                    Text(provenance(item)).font(Typeface.ui(12.5)).foregroundStyle(t.inkSecondary)
                        .padding(.top, 2).padding(.bottom, 18)
                    let body = itemBody(item)
                    if !body.isEmpty {
                        Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
                            .font(Typeface.mono(13.5)).lineSpacing(6).foregroundStyle(t.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        Button { onOpen(item) } label: { HStack(spacing: 6) { Text("Open in editor"); Keycap(text: "↵", t: t) } }
                        Button { onCopy(item) } label: { HStack(spacing: 6) { Text("Copy"); Keycap(text: "⌘C", t: t) } }
                    }
                    .buttonStyle(GhostButtonStyle(t: t))
                    .padding(.top, 22)
                }
                .padding(.horizontal, 44).padding(.vertical, 30)
            }
        } else {
            Text("Choose a note to read it here.").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                .padding(44)
        }
    }

    private func provenance(_ item: WorkspaceItem) -> String {
        let file = "in \(item.file.lastPathComponent)"
        guard let captured = item.captured else { return file.prefix(1).uppercased() + file.dropFirst() }
        return "Captured \(LibraryDate.short(captured).lowercased()) at \(NativeCalendarView.time(captured)), \(file)"
    }
}

private struct NoteRow: View, Equatable {
    let item: WorkspaceItem
    let hue: TagPalette.Entry?
    let selected: Bool

    static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.hue == b.hue && a.selected == b.selected }
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(Typeface.ui(14, .semibold)).foregroundStyle(t.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let captured = item.captured {
                    Text(LibraryDate.short(captured)).font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                }
            }
            let snippet = itemBody(item).replacingOccurrences(of: "\n", with: " ")
            if !snippet.isEmpty {
                Text(snippet).font(Typeface.ui(12.5)).foregroundStyle(t.inkSecondary).lineLimit(1)
            }
            Text(item.section).font(Typeface.ui(11.5, .semibold))
                .foregroundStyle(hue?.label(dark: scheme == .dark) ?? t.inkSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? t.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusField))
        .overlay { if selected { RoundedRectangle(cornerRadius: Metrics.radiusField).strokeBorder(t.accent, lineWidth: 2) } }
        .padding(.horizontal, -12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Saved links: a list with the selected link previewed.
struct LinksView: View {
    let model: WorkspaceModel
    let onOpen: (WorkspaceItem) -> Void
    let onCopy: (WorkspaceItem) -> Void
    let onEditor: (WorkspaceItem) -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(model: model, title: "Saved links", subtitle: count(model.visible.count, "link"), placeholder: "Search links")
            t.border.frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    list
                    t.hairline.frame(height: 1)
                    KeyHints(pairs: [(["↑", "↓"], "move"), (["↵"], "open in browser"), (["C"], "copy"),
                                     (["E"], "editor"), (["/"], "search")])
                }
                t.border.frame(width: 1)
                preview.frame(width: 300)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.visible.isEmpty {
                        Text(model.libraryFilter.isEmpty ? "No saved links yet. Capture a link to find it here." : "No links match.")
                            .font(TypeScale.meta).foregroundStyle(t.inkSecondary).padding(.top, 16)
                    }
                    ForEach(model.visible) { item in
                        LinkRow(item: item, hue: model.sectionHue(for: item), selected: item.id == model.selectedID)
                            .equatable()
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onOpen(item) }
                            .simultaneousGesture(TapGesture().onEnded { model.selectedID = item.id })
                    }
                }
                .padding(.leading, 36).padding(.trailing, 32).padding(.vertical, 14)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = model.selectedItem {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.section).font(Typeface.ui(12, .semibold))
                        .foregroundStyle(model.sectionHue(for: item)?.label(dark: dark) ?? t.inkSecondary)
                    Text(LinkRow.title(item)).font(TypeScale.heading).foregroundStyle(t.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = item.url {
                    field("Link") {
                        Text(url.absoluteString).font(Typeface.mono(12.5)).foregroundStyle(t.accent)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                let note = itemBody(item)
                if !note.isEmpty { field("Note") { Text(note).font(Typeface.ui(13.5)).foregroundStyle(t.ink) } }
                if let captured = item.captured {
                    field("Saved") {
                        Text("\(LibraryDate.short(captured)) at \(NativeCalendarView.time(captured))")
                            .font(Typeface.ui(13)).foregroundStyle(t.ink)
                    }
                }
                Spacer(minLength: 0)
                Button { onOpen(item) } label: {
                    HStack(spacing: 6) { Text("Open in browser"); Keycap(text: "↵", t: t) }.frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle(t: t))
                HStack(spacing: 8) {
                    Button { onCopy(item) } label: { HStack(spacing: 6) { Text("Copy link"); Keycap(text: "C", t: t) }.frame(maxWidth: .infinity) }
                    Button { onEditor(item) } label: { HStack(spacing: 6) { Text("In editor"); Keycap(text: "E", t: t) }.frame(maxWidth: .infinity) }
                }
                .buttonStyle(GhostButtonStyle(t: t))
            } else {
                Text("Nothing selected").font(TypeScale.heading).foregroundStyle(t.ink)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(t.sunken)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(TypeScale.meta).foregroundStyle(t.inkSecondary)
            content()
        }
    }
}

private struct LinkRow: View, Equatable {
    let item: WorkspaceItem
    let hue: TagPalette.Entry?
    let selected: Bool

    static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.hue == b.hue && a.selected == b.selected }
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    /// The item's text without its URL, or the URL's host and path when the
    /// text is only the link.
    static func title(_ item: WorkspaceItem) -> String {
        var text = item.title
        if let url = item.url { text = text.replacingOccurrences(of: url.absoluteString, with: "") }
        text = text.replacingOccurrences(of: #"#[\p{L}\p{N}_/-]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return text }
        return item.url.map { ($0.host ?? "") + $0.path } ?? item.title
    }

    private var host: String { item.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "" }

    var body: some View {
        HStack(spacing: 10) {
            Text(host.prefix(1).uppercased())
                .font(Typeface.ui(12, .bold)).foregroundStyle(t.inkSecondary)
                .frame(width: 24, height: 24)
                .background(t.surfaceField, in: RoundedRectangle(cornerRadius: Metrics.radiusChip))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(item)).font(Typeface.ui(13.5, .medium)).foregroundStyle(t.ink).lineLimit(1)
                Text(host).font(Typeface.mono(12)).foregroundStyle(t.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.section).font(Typeface.ui(12, .semibold))
                .foregroundStyle(hue?.label(dark: scheme == .dark) ?? t.inkSecondary)
            Text(item.captured.map { LibraryDate.short($0) } ?? "")
                .font(TypeScale.meta).foregroundStyle(t.inkSecondary).frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? t.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusField))
        .overlay { if selected { RoundedRectangle(cornerRadius: Metrics.radiusField).strokeBorder(t.accent, lineWidth: 2) } }
        .padding(.horizontal, -10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
