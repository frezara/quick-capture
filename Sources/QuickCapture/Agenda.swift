import Foundation

/// One file Agenda reads open todos from, and the name its group shows.
struct AgendaSource: Equatable {
    let name: String
    let file: URL

    /// Today's note, the capture file, each project's inbox, then refile
    /// targets that aren't also projects (CONTEXT.md, **Open todos**). A file
    /// reached two ways is read once, under its first name.
    static func list(dailyNote: URL?, captureFile: URL, projects: [(name: String, file: URL)],
                     targets: [(name: String, file: URL)]) -> [AgendaSource] {
        var seen: Set<String> = []
        var result: [AgendaSource] = []
        func add(_ name: String, _ file: URL) {
            let key = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            result.append(AgendaSource(name: name, file: file))
        }
        if let dailyNote { add("Today", dailyNote) }
        add("Inbox", captureFile)
        for project in projects { add(project.name, project.file) }
        for target in targets { add(target.name, target.file) }
        return result
    }
}

struct AgendaRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// An event; `part` and `of` count the days a multi-day event covers.
        case event(allDay: Bool, part: Int, of: Int)
        /// A reminder. `overdueDays` is set when it is shown under today
        /// because its own day has passed without it being ticked.
        case reminder(overdueDays: Int?)
        case todo
    }

    let item: WorkspaceItem
    let kind: Kind
    /// The span day the row sits under; nil for open todos.
    let day: Date?

    /// Events repeat across the days they cover, so the day is part of a
    /// row's identity.
    var id: String { "\(day.map { String(Int($0.timeIntervalSince1970)) } ?? "todo")|\(item.id)" }
}

struct AgendaDay: Equatable {
    let date: Date
    let rows: [AgendaRow]
}

struct AgendaGroup: Equatable {
    let name: String
    let rows: [AgendaRow]
}

/// The Agenda list (CONTEXT.md): seven days from `start` with their events
/// and reminders, then open todos grouped by file.
struct AgendaProjection: Equatable {
    let days: [AgendaDay]
    let groups: [AgendaGroup]

    static let empty = AgendaProjection(days: [], groups: [])

    /// Every row in list order: what ↑ and ↓ step through.
    var rows: [AgendaRow] { days.flatMap(\.rows) + groups.flatMap(\.rows) }

    private init(days: [AgendaDay], groups: [AgendaGroup]) {
        self.days = days; self.groups = groups
    }

    /// `kept` holds items ticked during this visit: they stay on screen,
    /// struck through, so a row never vanishes under the cursor.
    init(items: [WorkspaceItem], sources: [AgendaSource], start: Date, now: Date,
         kept: Set<String> = [], calendar: Calendar = .current) {
        let shown = items.filter { !$0.completed || kept.contains($0.id) }
        let first = calendar.startOfDay(for: start)
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        let today = calendar.startOfDay(for: now)
        let spanHasToday = dates.contains(today)

        days = dates.map { day in
            var rows: [(order: Int, time: Date, row: AgendaRow)] = []
            for item in shown where item.depth == 0 {
                if let starts = item.starts {
                    guard item.occurs(on: day, calendar: calendar) else { continue }
                    let allDay = CalendarLayout.isAllDay(item, calendar: calendar)
                    let (part, of) = Self.part(of: item, on: day, calendar: calendar)
                    rows.append((allDay ? 1 : 2, allDay ? day : max(starts, day),
                                 AgendaRow(item: item, kind: .event(allDay: allDay, part: part, of: of), day: day)))
                } else if let reminder = item.reminder {
                    let reminderDay = calendar.startOfDay(for: reminder)
                    let overdue = reminderDay < today && !item.completed
                    if overdue, spanHasToday {
                        guard day == today else { continue }
                        let days = calendar.dateComponents([.day], from: reminderDay, to: today).day ?? 0
                        rows.append((0, reminder, AgendaRow(item: item, kind: .reminder(overdueDays: days), day: day)))
                    } else if reminderDay == day {
                        rows.append((2, reminder, AgendaRow(item: item, kind: .reminder(overdueDays: nil), day: day)))
                    }
                }
            }
            rows.sort { ($0.order, $0.time, $0.row.item.id) < ($1.order, $1.time, $1.row.item.id) }
            return AgendaDay(date: day, rows: rows.map(\.row))
        }

        groups = sources.compactMap { source in
            let rows = shown
                .filter { $0.file == source.file && $0.depth == 0 && $0.isTodo && $0.starts == nil }
                .sorted { ($0.priority, $0.line) < ($1.priority, $1.line) }
                .map { AgendaRow(item: $0, kind: .todo, day: nil) }
            return rows.isEmpty ? nil : AgendaGroup(name: source.name, rows: rows)
        }
    }

    /// Which day of a multi-day event `day` is, counted from 1.
    private static func part(of item: WorkspaceItem, on day: Date, calendar: Calendar) -> (Int, Int) {
        guard let starts = item.starts else { return (1, 1) }
        let ends = max(item.ends ?? starts, starts)
        let firstDay = calendar.startOfDay(for: starts)
        // An end at midnight belongs to the day before.
        let lastDay = calendar.startOfDay(for: ends > starts ? ends.addingTimeInterval(-1) : ends)
        let total = (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
        let index = (calendar.dateComponents([.day], from: firstDay, to: day).day ?? 0) + 1
        return (min(max(index, 1), total), total)
    }
}
