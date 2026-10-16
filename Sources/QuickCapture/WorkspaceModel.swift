import Foundation
import SwiftUI

/// Native destinations share one panel. Saved filters are deferred.
enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case todos, calendar, projects, notes, links
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todos: return "Todos"
        case .calendar: return "Calendar"
        case .projects: return "Projects"
        case .notes: return "Notes"
        case .links: return "Saved links"
        }
    }
    var symbol: String {
        switch self {
        case .todos: return "checklist"
        case .calendar: return "calendar"
        case .projects: return "folder"
        case .notes: return "note.text"
        case .links: return "bookmark"
        }
    }
    var action: ShortcutAction {
        switch self {
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
            result.append(WorkspaceItem(id: sourceID ?? "\(file.path):\(index)", text: body, section: section, file: file,
                completed: line.range(of: #"^\s*[-*+] \[[xX]\]"#, options: .regularExpression) != nil,
                priority: FileWriter.priorityBucket(for: first), tags: tags, kind: kind,
                starts: date(meta?.starts_at), ends: date(meta?.ends_at), url: link))
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
            case .calendar: return item.starts != nil && !item.completed
            }
        }.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
        days = Self.days(around: date, mode: mode, calendar: calendar)
        guard destination == .calendar else { eventsByDay = [:]; return }
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

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var destination: WorkspaceDestination = .todos { didSet { recompute() } }
    @Published var calendarMode: WorkspaceCalendarMode = .month { didSet { recompute() } }
    @Published var date = Date() { didSet { recompute() } }
    @Published var project: String? { didSet { recompute() } }
    @Published var selectedID: String?
    @Published private(set) var items: [WorkspaceItem] = [] { didSet { recompute() } }
    @Published private(set) var problem: String?
    @Published private(set) var projection = WorkspaceProjection.empty
    var visible: [WorkspaceItem] { projection.visible }
    var days: [Date] { projection.days }
    var captureFile: URL { appState.captureFileURL }
    private let appState: AppState
    /// Inboxes are watched rather than polled; a watcher event or an explicit
    /// refresh starts a load, and a newer load supersedes an older one.
    private var watchers: [URL: FileWatcher] = [:]
    private var loadGeneration = 0
    private var pendingRefresh: Task<Void, Never>?
    init(appState: AppState) {
        self.appState = appState
        recompute()
    }

    func refresh() {
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
}
