import Foundation

/// Ticked parents (CONTEXT.md), for ticks made outside the editor: ticking an
/// item ticks its descendants; unticking a child unticks every ticked
/// ancestor; unticking a parent leaves its children alone; ticking the last
/// child does not tick the parent. Kept in step with
/// `editor-web/src/tick-cascade.ts`.
enum TickCascade {
    struct Tick: Equatable {
        let line: Int
        let checked: Bool
    }

    private static let task = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+\[([\sxX])\]"#)

    /// The line's checkbox state, or nil when it has no checkbox.
    private static func isChecked(_ line: String) -> Bool? {
        guard let match = task.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let box = Range(match.range(at: 1), in: line) else { return nil }
        return line[box] != " "
    }

    private static func endsGroup(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }

    private static func isItem(_ line: String) -> Bool {
        line.range(of: #"^\s*[-*+]\s"#, options: .regularExpression) != nil
    }

    /// Every checkbox that must change, the requested ones included; lines
    /// already in the right state are left out.
    static func changes(_ lines: [String], _ requested: [Tick]) -> [Tick] {
        var target: [Int: Bool] = [:]
        for r in requested { target[r.line] = r.checked }
        for r in requested {
            if r.checked {
                let rootWidth = FileWriter.indentWidth(lines[r.line])
                var i = r.line + 1
                while i < lines.count, !endsGroup(lines[i]), FileWriter.indentWidth(lines[i]) > rootWidth {
                    if isChecked(lines[i]) != nil, target[i] == nil { target[i] = true }
                    i += 1
                }
            } else {
                var childWidth = FileWriter.indentWidth(lines[r.line])
                var i = r.line - 1
                while i >= 0, childWidth > 0, !endsGroup(lines[i]) {
                    if isItem(lines[i]), FileWriter.indentWidth(lines[i]) < childWidth {
                        childWidth = FileWriter.indentWidth(lines[i])
                        if isChecked(lines[i]) == true { target[i] = false }
                    }
                    i -= 1
                }
            }
        }
        return target
            .filter { line, checked in isChecked(lines[line]).map { $0 != checked } ?? false }
            .map { Tick(line: $0.key, checked: $0.value) }
            .sorted { $0.line < $1.line }
    }

    /// `content` with the item on `line` ticked or unticked, cascade applied.
    /// Nil when that line isn't a task.
    static func apply(to content: String, line: Int, checked: Bool) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard line >= 0, line < lines.count, isChecked(lines[line]) != nil else { return nil }
        for tick in changes(lines, [Tick(line: line, checked: checked)]) {
            lines[tick.line] = lines[tick.line].replacingOccurrences(
                of: #"^(\s*[-*+]\s+)\[[\sxX]\]"#, with: tick.checked ? "$1[x]" : "$1[ ]", options: .regularExpression)
        }
        return lines.joined(separator: "\n")
    }
}
