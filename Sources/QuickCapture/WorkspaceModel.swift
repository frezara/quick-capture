import Foundation
import SwiftUI

/// Native destinations share one panel. Saved filters are deferred.
enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case today, todos, calendar, projects, notes, links
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .todos: return "Todos"
        case .calendar: return "Calendar"
        case .projects: return "Projects"
        case .notes: return "Notes"
        case .links: return "Saved links"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .todos: return "checklist"
        case .calendar: return "calendar"
        case .projects: return "folder"
        case .notes: return "note.text"
        case .links: return "bookmark"
        }
    }
    var action: ShortcutAction {
        switch self {
        case .today: return .showToday
        case .todos: return .showTodos
        case .calendar: return .showCalendar
        case .projects: return .showProjects
        case .notes: return .showNotes
        case .links: return .showLinks
        }
    }
}

enum WorkspaceCalendarMode: String, CaseIterable {
    case day = "Day", week = "Week", month = "Month"
}

struct WorkspaceItem: Identifiable, Equatable {
    let id: String
    let text: String
    let section: String
    let file: URL
    let completed: Bool
    let priority: Int
    let tags: Set<String>
    let kind: String
    let starts: Date?
    let ends: Date?
    let url: URL?
    /// 0-based line of the item in `file`.
    var line = 0
    /// Indent width of the item's line; 0 is top level.
    var depth = 0
    var reminder: Date?
    /// Ticked and total task lines nested under the item.
    var childTasksDone = 0
    var childTasks = 0
    var title: String { text.components(separatedBy: "\n").first ?? text }
    var isTodo: Bool { kind == "capture" || kind == "task" }
    var projects: [String] { tags.filter { $0.hasPrefix("project/") }.map { String($0.dropFirst(8)) }.sorted() }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    // Compiled once: parse runs over every inbox on each refresh.
    private static let tagPattern = try! NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\p{N}_/-]+)"#)
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Reads existing Markdown without enrolling old items in sync or changing it.
    static func parse(_ text: String, file: URL, metadata: [String: OrganiserItem]) -> [WorkspaceItem] {
        let lines = text.components(separatedBy: "\n")
        var section = "Quick capture", result: [WorkspaceItem] = []
        var inFence = false
        let tagPattern = Self.tagPattern, detector = Self.linkDetector
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence else { continue }
            if line.hasPrefix("## ") { section = String(line.dropFirst(3)); continue }
            guard line.range(of: #"^\s*[-*+] \[[ xX]\] "#, options: .regularExpression) != nil else { continue }
            let sourceID = SourceIdentity.ids(in: line).first
            let meta = sourceID.flatMap { metadata[$0] }
            var end = index + 1
            while end < lines.count, lines[end].hasPrefix("  ") || lines[end].hasPrefix("\t") { end += 1 }
            let body = lines[index..<end].joined(separator: "\n")
                .replacingOccurrences(of: #" ?<!--qc-source:[0-9a-fA-F-]{36}-->"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s*[-*+] \[[ xX]\] "#, with: "", options: .regularExpression)
            let first = line.replacingOccurrences(of: #" ?<!--qc-source:[0-9a-fA-F-]{36}-->"#, with: "", options: .regularExpression)
            let tags = Set(tagPattern.matches(in: first, range: NSRange(first.startIndex..., in: first)).compactMap {
                Range($0.range(at: 1), in: first).map { String(first[$0]).lowercased() }
            })
            let link = meta?.source_url.flatMap(URL.init(string:)) ?? detector?.firstMatch(in: body, range: NSRange(body.startIndex..., in: body))?.url
            var kind = meta?.kind ?? "capture"
            if kind == "capture" || kind == "task" {
                if tags.contains("note") || ["note", "notes"].contains(section.lowercased()) { kind = "note" }
                else if tags.contains("bookmark") || section.lowercased() == "bookmarks" { kind = "bookmark" }
            }
            let childTasks = lines[(index + 1)..<end].filter { $0.range(of: #"^\s+[-*+] \[[ xX]\]"#, options: .regularExpression) != nil }
            result.append(WorkspaceItem(id: sourceID ?? "\(file.path):\(index)", text: body, section: section, file: file,
                completed: line.range(of: #"^\s*[-*+] \[[xX]\]"#, options: .regularExpression) != nil,
                priority: FileWriter.priorityBucket(for: first), tags: tags, kind: kind,
                starts: date(meta?.starts_at), ends: date(meta?.ends_at), url: link,
                line: index, depth: FileWriter.indentWidth(line), reminder: date(meta?.reminder_at),
                childTasksDone: childTasks.filter { $0.range(of: #"\[[xX]\]"#, options: .regularExpression) != nil }.count,
                childTasks: childTasks.count))
        }
        return result
    }

    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        guard let starts, let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        let end = max(ends ?? starts, starts)
        return end == starts ? interval.contains(starts) : starts < interval.end && end > interval.start
    }
}

/// Everything the workspace views derive from the loaded items, computed once
/// per change of input rather than on each read — the month grid used to
/// re-filter and re-sort every item for each of its ~35 day cells.
struct WorkspaceProjection {
    let visible: [WorkspaceItem]
    let days: [Date]
    /// Dated items keyed by the start of each day they touch, in start order.
    let eventsByDay: [Date: [WorkspaceItem]]

    static let empty = WorkspaceProjection(visible: [], days: [], eventsByDay: [:])

    private init(visible: [WorkspaceItem], days: [Date], eventsByDay: [Date: [WorkspaceItem]]) {
        self.visible = visible; self.days = days; self.eventsByDay = eventsByDay
    }

    init(items: [WorkspaceItem], destination: WorkspaceDestination, project: String?,
         date: Date, mode: WorkspaceCalendarMode, calendar: Calendar = .current) {
        visible = items.filter { item in
            switch destination {
            case .todos: return item.isTodo && !item.completed
            case .notes: return item.kind == "note"
            case .links: return item.kind == "bookmark" || item.url != nil
            case .projects: return project.map { item.projects.contains($0) } ?? !item.projects.isEmpty
            case .calendar, .today: return item.starts != nil && !item.completed
            }
        }.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
        days = Self.days(around: date, mode: destination == .today ? .day : mode, calendar: calendar)
        guard destination == .calendar || destination == .today else { eventsByDay = [:]; return }
        let dated = visible.sorted { ($0.starts ?? .distantPast, $0.id) < ($1.starts ?? .distantPast, $1.id) }
        var byDay: [Date: [WorkspaceItem]] = [:]
        for day in days {
            let events = dated.filter { $0.occurs(on: day, calendar: calendar) }
            if !events.isEmpty { byDay[day] = events }
        }
        eventsByDay = byDay
    }

    private static func days(around date: Date, mode: WorkspaceCalendarMode, calendar base: Calendar) -> [Date] {
        var calendar = base; calendar.firstWeekday = 2
        let start: Date, count: Int
        switch mode {
        case .day:
            start = calendar.startOfDay(for: date); count = 1
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date); count = 7
        case .month:
            guard let month = calendar.dateInterval(of: .month, for: date)?.start,
                  let gridStart = calendar.dateInterval(of: .weekOfYear, for: month)?.start,
                  let end = calendar.date(byAdding: .month, value: 1, to: month),
                  let span = calendar.dateComponents([.day], from: gridStart, to: end).day else { return [] }
            start = gridStart; count = ((span + 6) / 7) * 7
        }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

@MainActor @Observable
final class WorkspaceModel {
    var destination: WorkspaceDestination = .todos { didSet { recompute() } }
    var calendarMode: WorkspaceCalendarMode = .month { didSet { recompute() } }
    /// The selected day — the calendar's keyboard cursor. The visible month,
    /// week or day is whichever contains it, so moving it past an edge turns
    /// the page.
    var date = Date() {
        didSet {
            recompute()
            if let id = selectedEventID, !eventsOnSelectedDay.contains(where: { $0.id == id }) { selectedEventID = nil }
        }
    }
    /// The event the arrows have landed on (or that was clicked), if any.
    var selectedEventID: String?
    /// Today: true while the schedule panel, not the editor, has focus.
    var scheduleFocused = false
    /// The calendar day that was today when Today last checked, so crossing
    /// midnight moves a Today that was showing today, and leaves a stepped-to
    /// day alone.
    @ObservationIgnored private var todayAnchor = Calendar.current.startOfDay(for: Date())
    var project: String? { didSet { recompute() } }
    var selectedID: String?
    private(set) var items: [WorkspaceItem] = [] { didSet { recompute() } }
    private(set) var problem: String?
    private(set) var projection = WorkspaceProjection.empty
    var visible: [WorkspaceItem] { projection.visible }
    var days: [Date] { projection.days }
    var captureFile: URL { appState.captureFileURL }
    private let appState: AppState
    /// Inboxes are watched rather than polled; a watcher event or an explicit
    /// refresh starts a load, and a newer load supersedes an older one.
    private var watchers: [URL: FileWatcher] = [:]
    private var loadGeneration = 0
    private var pendingRefresh: Task<Void, Never>?
    /// Previews hold fixed items and never read the real inboxes.
    @ObservationIgnored private var frozen = false
    init(appState: AppState) {
        self.appState = appState
        recompute()
    }

    func refresh() {
        guard !frozen else { return }
        let controller = OrganiserController.shared
        var metadata: [String: OrganiserItem] = [:]
        for record in controller.records {
            if record.state == "pending", let operation = try? controller.outbox.operation(record) { metadata[record.id] = operation.item }
            else { metadata[record.id] = record.baseline?.item }
        }
        let files = [appState.captureFileURL] + appState.effectiveRefileTargets.map { $0.folderURL.appendingPathComponent("inbox.md") }
        watch(files)
        loadGeneration += 1
        // The first load is synchronous so the workspace never opens on a
        // false "No todos yet"; later loads keep the previous items on screen.
        if loadGeneration == 1 {
            (items, problem) = Self.load(files, metadata: metadata)
            return
        }
        let generation = loadGeneration
        Task.detached(priority: .userInitiated) {
            let (loaded, message) = Self.load(files, metadata: metadata)
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                if loaded != self.items { self.items = loaded }
                if self.problem != message { self.problem = message }
            }
        }
    }

    private nonisolated static func load(_ files: [URL], metadata: [String: OrganiserItem]) -> ([WorkspaceItem], String?) {
        var loaded: [WorkspaceItem] = [], failures: [String] = []
        for file in files {
            do { loaded += WorkspaceItem.parse(try String(contentsOf: file, encoding: .utf8), file: file, metadata: metadata) }
            catch { failures.append(file.lastPathComponent + ": " + error.localizedDescription) }
        }
        return (loaded, failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }

    private func watch(_ files: [URL]) {
        let wanted = Set(files)
        for url in watchers.keys where !wanted.contains(url) { watchers.removeValue(forKey: url)?.cancel() }
        for url in wanted where watchers[url] == nil {
            watchers[url] = FileWatcher(url: url) { [weak self] in self?.scheduleRefresh() }
        }
    }

    /// One atomic save can deliver several events; coalesce them into one load.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func recompute() {
        projection = WorkspaceProjection(items: items, destination: destination, project: project,
                                         date: date, mode: calendarMode)
    }

    var projects: [String] { Array(Set(items.flatMap(\.projects))).sorted() }
    func navigate(_ destination: WorkspaceDestination) {
        self.destination = destination; selectedID = nil; refresh()
    }
    func shiftDate(_ direction: Int) {
        let component: Calendar.Component = calendarMode == .month ? .month : .day
        date = Calendar.current.date(byAdding: component, value: direction * (calendarMode == .week ? 7 : 1), to: date) ?? date
    }

    var selectedDay: Date { Calendar.current.startOfDay(for: date) }

    /// All-day events first (they start at midnight), then by start time. The
    /// selected day is always on screen, so the projection already holds it.
    var eventsOnSelectedDay: [WorkspaceItem] { projection.eventsByDay[selectedDay] ?? [] }

    var selectedEvent: WorkspaceItem? {
        selectedEventID.flatMap { id in items.first { $0.id == id } }
    }

    var isShowingToday: Bool { Calendar.current.isDateInToday(date) }

    /// Called whenever Today is shown or the panel regains focus. Returns true
    /// when the day changed underneath it.
    @discardableResult
    func rollToTodayIfNeeded(now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        defer { todayAnchor = today }
        guard today != todayAnchor, selectedDay == todayAnchor else { return false }
        date = now
        return true
    }

    func moveDays(_ offset: Int) {
        date = Calendar.current.date(byAdding: .day, value: offset, to: date) ?? date
    }

    /// Steps the selection through the selected day's events. With nothing
    /// selected, ↓ lands on the first and ↑ on the last; the ends don't wrap.
    func stepEvent(_ offset: Int) {
        let events = eventsOnSelectedDay
        guard !events.isEmpty else { return }
        guard let current = selectedEventID.flatMap({ id in events.firstIndex { $0.id == id } }) else {
            selectedEventID = (offset > 0 ? events.first : events.last)?.id
            return
        }
        selectedEventID = events[min(events.count - 1, max(0, current + offset))].id
    }

    func select(_ item: WorkspaceItem, on day: Date) {
        date = day
        selectedEventID = item.id
    }

    /// New event: the capture box opens with `cal` already in the tag field.
    func prepareNewEvent() { appState.captureTagPrefill = "cal" }

    /// The section's own hue when it has one; otherwise the calendar's teal.
    func hue(for item: WorkspaceItem) -> TagPalette.Entry {
        appState.tagHues.entry(for: item.section) ?? TagPalette.calendar
    }
}

#if DEBUG
extension WorkspaceModel {
    static func preview(destination: WorkspaceDestination, calendarMode: WorkspaceCalendarMode = .month) -> WorkspaceModel {
        let model = WorkspaceModel(appState: AppState())
        model.frozen = true
        model.destination = destination
        model.calendarMode = calendarMode
        let file = URL(fileURLWithPath: "/tmp/preview-inbox.md")
        let today = Calendar.current.startOfDay(for: Date())
        func hours(_ h: Double, from day: Date = today) -> Date { day.addingTimeInterval(h * 3600) }
        func item(_ id: String, _ text: String, section: String, priority: Int = 3, kind: String = "capture",
                  starts: Date? = nil, ends: Date? = nil) -> WorkspaceItem {
            WorkspaceItem(id: id, text: text, section: section, file: file, completed: false, priority: priority,
                          tags: [], kind: kind, starts: starts, ends: ends, url: nil)
        }
        model.items = [
            item("1", "Renew passport", section: "Admin", priority: 0),
            item("2", "Order seeds for the spring beds", section: "Garden", priority: 2),
            item("3", "Reply to the landlord about the boiler", section: "Home"),
            item("4", "Dentist", section: "Calendar", kind: "event", starts: hours(9), ends: hours(10)),
            item("5", "Standup", section: "Calendar", kind: "event", starts: hours(9.5), ends: hours(9.75)),
            item("6", "Seb's birthday", section: "Calendar", kind: "event", starts: hours(24), ends: hours(48)),
            item("7", "Call the council", section: "Calendar", kind: "event", starts: hours(24 * 3 + 14), ends: hours(24 * 3 + 14.5)),
        ]
        return model
    }
}
#endif
