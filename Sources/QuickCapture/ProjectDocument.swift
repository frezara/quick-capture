import Foundation

enum ProjectTaskStatus: String, CaseIterable, Identifiable {
    case inbox = "Inbox", backlog = "Backlog", next = "Next", doing = "Doing", blocked = "Blocked", done = "Done"
    var id: String { rawValue }
}

struct ProjectTask: Identifiable {
    let line: Int
    let title: String
    let status: ProjectTaskStatus
    let range: Range<Int>
    var id: Int { line }
}

/// Management views are projections of a single readable Markdown document.
/// Parsed once at init: views read `tasks`, `status` and `goal` many times per
/// render, and re-scanning the whole inbox on each read made typing lag.
struct ProjectDocument {
    let text: String
    let lines: [String]
    let overview: [String: String]
    let tasks: [ProjectTask]
    init(text: String) {
        self.text = text
        lines = text.components(separatedBy: "\n")
        overview = Self.parseOverview(lines)
        tasks = Self.parseTasks(lines)
    }
    private static func outsideFences(_ lines: [String]) -> Set<Int> {
        var fence: String?, visible = Set<Int>()
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
            } else if fence == nil { visible.insert(index) }
        }
        return visible
    }
    private static func parseOverview(_ lines: [String]) -> [String: String] {
        var active = false, values: [String: String] = [:]
        let visible = outsideFences(lines)
        for (index, line) in lines.enumerated() where visible.contains(index) {
            if line.hasPrefix("## ") { active = line == "## Project"; continue }
            guard active, let colon = line.firstIndex(of: ":") else { continue }
            values[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
    var status: String { overview["Status"] ?? "Active" }
    var goal: String { overview["Goal"] ?? "" }
    private static func parseTasks(_ lines: [String]) -> [ProjectTask] {
        var section = "Inbox", fence: String?, result: [ProjectTask] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil else { continue }
            if line.hasPrefix("## ") { section = String(line.dropFirst(3)); continue }
            guard line.range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) != nil else { continue }
            var end = index + 1
            while end < lines.count && (lines[end].hasPrefix("  ") || lines[end].hasPrefix("\t")) { end += 1 }
            let completed = line.range(of: #"^[-*+] \[[xX]\]"#, options: .regularExpression) != nil
            let state = completed ? ProjectTaskStatus.done : ProjectTaskStatus.allCases.first { $0.rawValue.lowercased() == section.lowercased() && $0 != .done } ?? .inbox
            result.append(ProjectTask(line: index, title: String(line.dropFirst(6)), status: state, range: index..<end))
        }
        return result
    }
    func settingOverview(status: String, goal: String) -> String {
        var lines = lines
        for (key, value) in [("Status", status), ("Goal", goal.replacingOccurrences(of: "\n", with: " "))] {
            let visible = Self.outsideFences(lines)
            if let start = lines.indices.first(where: { visible.contains($0) && lines[$0] == "## Project" }) {
                let end = lines.indices.first(where: { $0 > start && visible.contains($0) && lines[$0].hasPrefix("## ") }) ?? lines.count
                if let index = (start + 1..<end).first(where: { visible.contains($0) && lines[$0].hasPrefix(key + ":") }) { lines[index] = key + ": " + value }
                else { lines.insert(key + ": " + value, at: start + 1) }
            } else {
                lines += ["", "## Project", key + ": " + value, ""]
            }
        }
        return lines.joined(separator: "\n")
    }
    func moving(_ task: ProjectTask, to status: ProjectTaskStatus) -> String {
        var lines = lines
        var block = Array(lines[task.range])
        block[0] = block[0].replacingOccurrences(of: #"^([-*+] )\[[ xX]\]"#, with: "$1[\(status == .done ? "x" : " ")]", options: .regularExpression)
        lines.removeSubrange(task.range)
        return Self.appending(block.joined(separator: "\n"), section: status.rawValue, to: lines.joined(separator: "\n"))
    }
    static func appending(_ block: String, section: String, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let visible = Self.outsideFences(lines)
        if let heading = lines.indices.first(where: { visible.contains($0) && lines[$0] == "## " + section }) {
            let end = lines.indices.first(where: { $0 > heading && visible.contains($0) && lines[$0].hasPrefix("## ") }) ?? lines.count
            lines.insert(contentsOf: [block, ""], at: end)
        } else { lines += ["", "## " + section, block, ""] }
        return lines.joined(separator: "\n")
    }
    static func template(name: String) -> String {
        "# Inbox\n\n## Project\nName: \(name)\nStatus: Active\nGoal: \n\n## Inbox\n\n## Backlog\n\n## Next\n\n## Doing\n\n## Blocked\n\n## Done\n\n## Notes\n"
    }
}

/// What a sidebar row shows for one project, built when its inbox is read
/// rather than in the row's `body`.
struct ProjectSummary: Equatable {
    let line: String
    let nextAction: String?
    var open = 0
    init(text: String?) {
        guard let text else { line = "Inbox unavailable"; nextAction = nil; return }
        let document = ProjectDocument(text: text)
        open = document.tasks.filter { $0.status != .done }.count
        line = "\(document.status) · \(open) open"
        nextAction = document.tasks.first { $0.status == .next || $0.status == .doing }?.title
    }
}

struct DiskProject: Codable, Identifiable, Equatable {
    let id: String
    let folder: String
    var endpoint: String?
    var baseline: OrganiserSnapshot?
    var pending: OrganiserOperation?
    var conflict: OrganiserSnapshot?
    var problem: String?
    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    var file: URL { folderURL.appendingPathComponent("inbox.md") }
    var name: String { folderURL.lastPathComponent }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.folder == rhs.folder && lhs.problem == rhs.problem && lhs.pending?.operation_id == rhs.pending?.operation_id
            && lhs.baseline?.revision == rhs.baseline?.revision && lhs.conflict?.revision == rhs.conflict?.revision
    }
}

/// Only reads the registered root inbox. Never enumerates or uploads the folder.
enum ProjectFiles {
    static func read(_ project: DiskProject) throws -> String {
        let values = try project.file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1024 * 1024 else {
            throw HandoffError.invalid("The project inbox must be a regular UTF-8 file, at most 1 MiB, in the project root.")
        }
        return try String(contentsOf: project.file, encoding: .utf8)
    }
    static func write(_ text: String, project: DiskProject, expected: String) throws {
        guard text.utf8.count <= 1024 * 1024 else { throw HandoffError.invalid("Project inbox exceeds 1 MiB.") }
        _ = try read(project)
        try FileWriter.write(Data(text.utf8), to: project.file, ifStillMatching: expected)
    }
}
