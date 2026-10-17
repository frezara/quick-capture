import SwiftUI

/// Agenda (CONTEXT.md): seven days of events and reminders, then open todos
/// from every inbox, with the selected row previewed on the right. Driven
/// from the keyboard through `MainPanel`.
struct AgendaView: View {
    let model: WorkspaceModel
    let onOpen: (AgendaRow) -> Void
    let onTick: (AgendaRow) -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        VStack(spacing: 0) {
            header
            t.border.frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    list
                    t.hairline.frame(height: 1)
                    hints
                }
                t.border.frame(width: 1)
                ItemPreview(row: model.agendaSelectedRow, hue: model.agendaSelectedRow.flatMap(hue(for:)),
                              onOpen: onOpen, onTick: onTick)
                    .frame(width: 300)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Agenda").font(TypeScale.title).tracking(Tracking.title).foregroundStyle(t.ink)
            Text(Self.rangeText(model.agenda.days.map(\.date)))
                .font(Typeface.ui(14)).foregroundStyle(t.inkSecondary).padding(.top, 8)
            Spacer()
            HStack(spacing: 4) {
                Button("‹") { model.moveAgendaWeek(-1) }
                    .help("Previous week  [").accessibilityLabel("Previous week")
                Button("Today") { model.agendaStart = Date() }
                    .help("Back to today  T")
                Button("›") { model.moveAgendaWeek(1) }
                    .help("Next week  ]").accessibilityLabel("Next week")
            }
            .buttonStyle(GhostButtonStyle(t: t))
        }
        .padding(.leading, 26).padding(.trailing, 20).padding(.top, 24).padding(.bottom, 14)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.agenda.days, id: \.date) { day in
                        dayHeading(day)
                        ForEach(day.rows) { row($0) }
                    }
                    if !model.agenda.groups.isEmpty {
                        Text("Open todos")
                            .font(Typeface.ui(16, .bold)).foregroundStyle(t.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 14)
                            .overlay(alignment: .top) { t.border.frame(height: 1) }
                            .padding(.top, 26).padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(model.agenda.groups, id: \.name) { group in
                            HStack(spacing: 8) {
                                Text(group.name).foregroundStyle(t.ink)
                                Text("\(group.rows.count)").foregroundStyle(t.inkTertiary).fontWeight(.medium)
                            }
                            .font(Typeface.ui(12.5, .bold))
                            .padding(.top, 12).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(group.rows) { row($0) }
                        }
                    }
                }
                .padding(.leading, 36).padding(.trailing, 32).padding(.bottom, 20)
            }
            .onChange(of: model.agendaSelectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private func dayHeading(_ day: AgendaDay) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        HStack(spacing: 8) {
            Text(Self.dayTitle(day.date))
                .font(Typeface.ui(13, day.rows.isEmpty ? .medium : .bold))
                .foregroundStyle(day.rows.isEmpty ? t.inkTertiary : t.ink)
            if isToday {
                Text("Today")
                    .font(Typeface.ui(11, .bold)).foregroundStyle(t.inkOnNow)
                    .padding(.horizontal, 5)
                    .background(t.now, in: RoundedRectangle(cornerRadius: Metrics.radiusKey))
            }
            if day.rows.isEmpty {
                Text("Nothing scheduled").font(TypeScale.meta).foregroundStyle(t.inkTertiary)
            }
        }
        .padding(.top, 14).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ row: AgendaRow) -> some View {
        AgendaRowView(row: row, hue: hue(for: row), selected: row.id == model.agendaSelectedID, now: Date())
            .equatable()
            .id(row.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen(row) }
            .simultaneousGesture(TapGesture().onEnded { model.agendaSelectedID = row.id })
    }

    /// Events and reminders take their section's hue (calendar teal when the
    /// section has none); todos show their section's hue only if it has one.
    private func hue(for row: AgendaRow) -> TagPalette.Entry? {
        row.kind == .todo ? model.sectionHue(for: row.item) : model.hue(for: row.item)
    }

    private var hints: some View {
        KeyHints(pairs: [(["↑", "↓"], "move"), (["⌥↑", "⌥↓"], "day or group"), (["[", "]"], "week"),
                         (["↵"], "open"), (["X"], "tick")])
    }

    private static let titleFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM"; return f
    }()

    /// "Saturday 17 October".
    static func dayTitle(_ date: Date) -> String { titleFormat.string(from: date) }

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMMM"; return f
    }()

    /// "17 to 23 October", or "28 October to 3 November" across a month end.
    static func rangeText(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let calendar = Calendar.current
        if calendar.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(calendar.component(.day, from: first)) to \(dayMonth.string(from: last))"
        }
        return "\(dayMonth.string(from: first)) to \(dayMonth.string(from: last))"
    }
}

/// One row of the list. Plain values, so moving the selection redraws two
/// rows rather than the whole list.
private struct AgendaRowView: View, Equatable {
    let row: AgendaRow
    let hue: TagPalette.Entry?
    let selected: Bool
    let now: Date
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var dark: Bool { scheme == .dark }

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.hue == b.hue && a.selected == b.selected
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(time).font(Typeface.mono(12)).foregroundStyle(t.inkSecondary).frame(width: 52, alignment: .leading)
            mark.frame(width: 16)
            HStack(spacing: 8) {
                Text(row.item.title)
                    .font(Typeface.ui(13.5, .medium))
                    .foregroundStyle(row.item.completed ? t.inkTertiary : (row.kind == .todo ? t.ink : (hue?.label(dark: dark) ?? t.ink)))
                    .strikethrough(row.item.completed, color: t.inkTertiary)
                    .lineLimit(1)
                if let color = priorityColor { Circle().fill(color).frame(width: 7, height: 7) }
            }
            Spacer(minLength: 8)
            meta
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(background, in: RoundedRectangle(cornerRadius: Metrics.radiusField))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: Metrics.radiusField).strokeBorder(t.accent, lineWidth: 2) }
        }
        .padding(.horizontal, -10)
        .opacity(isPast && !selected ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var isAllDay: Bool {
        if case .event(true, _, _) = row.kind { return true }
        return false
    }

    private var time: String {
        switch row.kind {
        case .event(let allDay, let part, _):
            if allDay { return "All day" }
            return part > 1 ? "" : row.item.starts.map(NativeCalendarView.time) ?? ""
        case .reminder(let overdue): return overdue == nil ? row.item.reminder.map(NativeCalendarView.time) ?? "" : ""
        case .todo: return ""
        }
    }

    @ViewBuilder private var mark: some View {
        let color = hue?.dot(dark: dark) ?? t.inkTertiary
        switch row.kind {
        case .event: Circle().fill(color).frame(width: 8, height: 8)
        case .reminder(let overdue):
            Image(systemName: "bell").font(.system(size: 11, weight: .medium))
                .foregroundStyle(overdue == nil ? color : t.priHigh)
        case .todo:
            // Edged in the section's hue, as in the editor.
            RoundedRectangle(cornerRadius: 3.5)
                .strokeBorder(color, lineWidth: 1.5)
                .background(row.item.completed ? color : .clear, in: RoundedRectangle(cornerRadius: 3.5))
                .frame(width: 13, height: 13)
        }
    }

    @ViewBuilder private var meta: some View {
        switch row.kind {
        case .event(_, let part, let of):
            if of > 1 { Text("day \(part) of \(of)").font(TypeScale.meta).foregroundStyle(t.inkSecondary) }
            else if let ends = row.item.ends, let starts = row.item.starts, ends > starts, !isAllDay {
                Text("to \(NativeCalendarView.time(ends))").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
            }
        case .reminder(let overdue):
            if let overdue {
                Text(overdue == 1 ? "yesterday" : "\(overdue) days ago")
                    .font(Typeface.ui(12, .semibold)).foregroundStyle(t.priHigh)
            } else {
                Text("Reminder").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
            }
        case .todo:
            HStack(spacing: 10) {
                if row.item.childTasks > 0 {
                    Text("\(row.item.childTasksDone)/\(row.item.childTasks)")
                        .font(Typeface.mono(12)).foregroundStyle(t.inkSecondary)
                }
                Text(row.item.section).font(TypeScale.meta)
                    .foregroundStyle(hue?.label(dark: dark) ?? t.inkTertiary)
            }
        }
    }

    private var background: Color {
        if selected { return t.accentSoft }
        if isAllDay, let hue { return hue.tint(dark: dark) }
        return .clear
    }

    private var isPast: Bool {
        guard case .event(false, _, _) = row.kind, let day = row.day, Calendar.current.isDateInToday(day) else { return false }
        return (row.item.ends ?? row.item.starts ?? now) <= now
    }

    private var priorityColor: Color? {
        switch row.item.priority {
        case 0: return t.priHigh
        case 1: return t.priMed
        case 2: return t.priLow
        default: return nil
        }
    }
}

/// The selected row in full: its children, images and where it lives.
private struct ItemPreview: View {
    let row: AgendaRow?
    let hue: TagPalette.Entry?
    let onOpen: (AgendaRow) -> Void
    let onTick: (AgendaRow) -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let row {
                content(row)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button { onOpen(row) } label: { HStack(spacing: 6) { Text("Open"); Keycap(text: "↵", t: t) }.frame(maxWidth: .infinity) }
                    Button { onTick(row) } label: {
                        HStack(spacing: 6) { Text(row.item.completed ? "Untick" : "Tick"); Keycap(text: "X", t: t) }.frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(GhostButtonStyle(t: t))
            } else {
                Text("Nothing selected").font(TypeScale.heading).foregroundStyle(t.ink)
                Text("Events, reminders and open todos appear here as you move through the list.")
                    .font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(t.sunken)
    }

    @ViewBuilder private func content(_ row: AgendaRow) -> some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 2) {
            Text(row.item.section).font(Typeface.ui(12, .semibold))
                .foregroundStyle(hue?.label(dark: dark) ?? t.inkSecondary)
            Text(row.item.title).font(TypeScale.heading).foregroundStyle(t.ink)
                .strikethrough(row.item.completed, color: t.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let priority = priorityLabel(row.item.priority) {
                Text(priority.0).font(Typeface.ui(12, .semibold)).foregroundStyle(priority.1).padding(.top, 4)
            }
        }
        if let when = whenText(row) {
            field("When") {
                Text(when.0).font(Typeface.ui(13.5)).foregroundStyle(t.ink)
                if let time = when.1 { Text(time).font(Typeface.mono(12.5)).foregroundStyle(t.inkSecondary) }
            }
        }
        let lines = Self.childLines(row.item.text)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in childLine(line) }
            }
        }
        if let captured = row.item.captured {
            field("Captured") {
                Text(captured.formatted(.dateTime.day().month(.wide).hour().minute()))
                    .font(Typeface.mono(12.5)).foregroundStyle(t.inkSecondary)
            }
        }
        if row.item.sourceID != nil {
            field("Organiser") { Text("Sent").font(Typeface.ui(13)).foregroundStyle(t.ink) }
        }
        field("From") {
            Text("\(row.item.file.lastPathComponent), \(row.item.section)")
                .font(Typeface.mono(12.5)).foregroundStyle(t.inkSecondary)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(TypeScale.meta).foregroundStyle(t.inkSecondary)
            content()
        }
    }

    enum ChildLine: Equatable { case task(String, done: Bool, depth: Int), image(String), text(String) }

    /// The lines under an item's first line, as the preview draws them.
    static func childLines(_ text: String) -> [ChildLine] {
        text.components(separatedBy: "\n").dropFirst().compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let depth = max(0, FileWriter.indentWidth(line) / 2 - 1)
            if let m = trimmed.range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) {
                return .task(String(trimmed[m.upperBound...]), done: !trimmed.hasPrefix("- [ ]") && !trimmed.hasPrefix("* [ ]") && !trimmed.hasPrefix("+ [ ]"), depth: depth)
            }
            if let m = trimmed.range(of: #"^!\[[^\]]*\]\(([^)]+)\)"#, options: .regularExpression) {
                let path = trimmed[m].replacingOccurrences(of: #"^!\[[^\]]*\]\(|\)$"#, with: "", options: .regularExpression)
                return .image((path as NSString).lastPathComponent)
            }
            return .text(trimmed.replacingOccurrences(of: #"^[-*+] "#, with: "", options: .regularExpression))
        }
    }

    @ViewBuilder private func childLine(_ line: ChildLine) -> some View {
        switch line {
        case .task(let text, let done, let depth):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3.5).strokeBorder(t.inkTertiary, lineWidth: 1.5)
                    .background(done ? t.inkTertiary : .clear, in: RoundedRectangle(cornerRadius: 3.5))
                    .frame(width: 13, height: 13)
                Text(text).font(Typeface.ui(13.5))
                    .foregroundStyle(done ? t.inkTertiary : t.ink).strikethrough(done, color: t.inkTertiary)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .image(let name):
            Label(name, systemImage: "photo").font(Typeface.ui(12)).foregroundStyle(t.inkSecondary)
        case .text(let text):
            Text(text).font(Typeface.ui(13.5)).foregroundStyle(t.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func priorityLabel(_ priority: Int) -> (String, Color)? {
        switch priority {
        case 0: return ("High priority", t.priHigh)
        case 1: return ("Medium priority", t.priMed)
        case 2: return ("Low priority", t.priLow)
        default: return nil
        }
    }

    private func whenText(_ row: AgendaRow) -> (String, String?)? {
        switch row.kind {
        case .event(let allDay, _, _):
            guard let starts = row.item.starts else { return nil }
            return (AgendaView.dayTitle(starts), allDay ? "All day" : NativeCalendarView.timeRange(row.item))
        case .reminder:
            guard let reminder = row.item.reminder else { return nil }
            return (AgendaView.dayTitle(reminder), "Reminder at \(NativeCalendarView.time(reminder))")
        case .todo:
            return nil
        }
    }
}

/// The key legend along the bottom of a workspace list.
struct KeyHints: View {
    let pairs: [([String], String)]
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 4) {
                    ForEach(pair.0, id: \.self) { Keycap(text: $0, t: t) }
                    Text(pair.1).lineLimit(1).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .font(TypeScale.meta).foregroundStyle(t.inkSecondary)
        .padding(.horizontal, 22).padding(.vertical, 8)
    }
}
