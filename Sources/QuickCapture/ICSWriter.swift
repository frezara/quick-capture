import Foundation

enum ICSWriter {
    enum WriteError: LocalizedError {
        case encodingFailed
        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Failed to encode the calendar event as UTF-8."
            }
        }
    }

    /// Build a minimal valid VCALENDAR string for `event`. `METHOD:REQUEST`
    /// makes Calendar.app show its "add to calendar" confirmation sheet on open.
    static func makeICS(for event: CalendarEvent, uid: String = UUID().uuidString, now: Date = Date()) -> String {
        let end = event.start.addingTimeInterval(event.duration)
        let summary = escape(event.title)

        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Quick Capture//EN",
            "METHOD:REQUEST",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(format(now))",
            "DTSTART:\(format(event.start))",
            "DTEND:\(format(end))",
            "SUMMARY:\(summary)",
            "END:VEVENT",
            "END:VCALENDAR",
            ""
        ].joined(separator: "\r\n")
    }

    /// Write the ICS to a temp file and return the URL.
    static func writeTempFile(for event: CalendarEvent) throws -> URL {
        let body = makeICS(for: event)
        guard let data = body.data(using: .utf8) else { throw WriteError.encodingFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcapture-\(UUID().uuidString).ics")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `YYYYMMDDTHHMMSSZ` in UTC — the iCalendar `DATE-TIME` form.
    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// iCalendar TEXT escape: backslash, comma, semicolon, newline.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: ",",  with: "\\,")
         .replacingOccurrences(of: ";",  with: "\\;")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}
