import Foundation

/// Wall-clock positions for the native 24-hour calendar. Events crossing midnight
/// are clipped to each day; concurrent events share columns instead of obscuring one another.
enum CalendarLayout {
    struct Segment: Identifiable, Equatable {
        let id: String
        let startMinute: Double
        let endMinute: Double
        var column = 0
        var columnCount = 1
    }

    static func isAllDay(_ item: WorkspaceItem, calendar: Calendar = .current) -> Bool {
        guard let start = item.starts, let end = item.ends, end > start else { return false }
        return start == calendar.startOfDay(for: start) && end == calendar.startOfDay(for: end)
    }

    static func segments(items: [WorkspaceItem], day: Date, calendar: Calendar = .current) -> [Segment] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        func minute(_ date: Date) -> Double {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        }
        var segments = items.compactMap { item -> Segment? in
            guard item.occurs(on: day, calendar: calendar), !isAllDay(item, calendar: calendar), let start = item.starts else { return nil }
            let end = max(item.ends ?? start, start)
            let from = start <= interval.start ? 0 : minute(start)
            let to = end >= interval.end ? 1440 : minute(end)
            return Segment(id: item.id, startMinute: from, endMinute: min(1440, max(from + 20, to)))
        }.sorted { $0.startMinute == $1.startMinute ? $0.id < $1.id : $0.startMinute < $1.startMinute }
        // Each connected overlap group shares a width, including chained overlaps.
        var groupStart = 0
        while groupStart < segments.count {
            var groupEnd = groupStart + 1
            var until = segments[groupStart].endMinute
            while groupEnd < segments.count && segments[groupEnd].startMinute < until {
                until = max(until, segments[groupEnd].endMinute)
                groupEnd += 1
            }
            var columnEnds: [Double] = []
            for index in groupStart..<groupEnd {
                let column = columnEnds.firstIndex(where: { $0 <= segments[index].startMinute }) ?? columnEnds.count
                if column == columnEnds.count { columnEnds.append(segments[index].endMinute) }
                else { columnEnds[column] = segments[index].endMinute }
                segments[index].column = column
            }
            for index in groupStart..<groupEnd { segments[index].columnCount = columnEnds.count }
            groupStart = groupEnd
        }
        return segments
    }

    static func mode(for key: String, hasModifiers: Bool, editingText: Bool) -> WorkspaceCalendarMode? {
        guard !hasModifiers, !editingText else { return nil }
        switch key.lowercased() {
        case "d": return .day
        case "w": return .week
        case "m": return .month
        default: return nil
        }
    }
}
