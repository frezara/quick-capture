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

    /// Reads existing Markdown without enrolling old items in sync or changing it.
    static func parse(_ text: String, file: URL, metadata: [String: OrganiserItem]) -> [WorkspaceItem] {
        let lines = text.components(separatedBy: "\n")
        var section = "Quick capture", result: [WorkspaceItem] = []
        var inFence = false
        let tagPattern = try! NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\p{N}_/-]+)"#)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
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

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var destination: WorkspaceDestination = .todos
    @Published var calendarMode: WorkspaceCalendarMode = .month
    @Published var date = Date()
    @Published var project: String?
    @Published var selectedID: String?
    @Published private(set) var items: [WorkspaceItem] = []
    @Published private(set) var problem: String?
    var captureFile: URL { appState.captureFileURL }
    private let appState: AppState
    init(appState: AppState) { self.appState = appState }

    func refresh() {
        let controller = OrganiserController.shared
        var metadata: [String: OrganiserItem] = [:]
        for record in controller.records {
            if record.state == "pending", let operation = try? controller.outbox.operation(record) { metadata[record.id] = operation.item }
            else { metadata[record.id] = record.baseline?.item }
        }
        let files = [appState.captureFileURL] + appState.effectiveRefileTargets.map { $0.folderURL.appendingPathComponent("inbox.md") }
        var loaded: [WorkspaceItem] = [], failures: [String] = []
        for file in files {
            do { loaded += WorkspaceItem.parse(try String(contentsOf: file, encoding: .utf8), file: file, metadata: metadata) }
            catch { failures.append(file.lastPathComponent + ": " + error.localizedDescription) }
        }
        if loaded != items { items = loaded }
        let message = failures.isEmpty ? nil : failures.joined(separator: "\n")
        if problem != message { problem = message }
    }
    var projects: [String] { Array(Set(items.flatMap(\.projects))).sorted() }
    var visible: [WorkspaceItem] {
        items.filter { item in
            let matches: Bool
            switch destination {
            case .todos: matches = item.isTodo && !item.completed
            case .notes: matches = item.kind == "note"
            case .links: matches = item.kind == "bookmark" || item.url != nil
            case .projects: matches = project.map { item.projects.contains($0) } ?? !item.projects.isEmpty
            case .calendar: matches = item.starts != nil && !item.completed
            }
            return matches
        }.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
    }
    func navigate(_ destination: WorkspaceDestination) {
        self.destination = destination; selectedID = nil; refresh()
    }
    func shiftDate(_ direction: Int) {
        let component: Calendar.Component = calendarMode == .month ? .month : .day
        date = Calendar.current.date(byAdding: component, value: direction * (calendarMode == .week ? 7 : 1), to: date) ?? date
    }
    var days: [Date] {
        var calendar = Calendar.current; calendar.firstWeekday = 2
        let start: Date, count: Int
        switch calendarMode {
        case .day: start = calendar.startOfDay(for: date); count = 1
        case .week: start = calendar.dateInterval(of: .weekOfYear, for: date)!.start; count = 7
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!.start
            start = calendar.dateInterval(of: .weekOfYear, for: month)!.start
            let end = calendar.date(byAdding: .month, value: 1, to: month)!
            let days = calendar.dateComponents([.day], from: start, to: end).day!
            count = ((days + 6) / 7) * 7
        }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
