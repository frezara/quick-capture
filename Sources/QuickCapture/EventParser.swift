import Foundation

struct CalendarEvent: Equatable {
    var title: String
    var start: Date
    var duration: TimeInterval
}

enum EventParser {
    enum ParseError: LocalizedError, Equatable {
        case noDateFound
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .noDateFound: return "Couldn't find a date or time in the input."
            case .emptyTitle:  return "Couldn't find an event title in the input."
            }
        }
    }

    /// Default when the input has a time but no explicit duration. Matches
    /// Calendar.app's "Quick Event" default.
    static let defaultDuration: TimeInterval = 30 * 60

    static func parse(_ input: String, now: Date = Date()) -> Result<CalendarEvent, ParseError> {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return .failure(.emptyTitle) }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return .failure(.noDateFound)
        }

        let range = NSRange(trimmedInput.startIndex..., in: trimmedInput)
        let matches = detector.matches(in: trimmedInput, range: range)
        guard let match = matches.first, let date = match.date else {
            return .failure(.noDateFound)
        }

        // NSDataDetector returns a baseline of "now" — adjust relative to the
        // injected `now` so tests are deterministic. Detector uses Date() under
        // the hood, so the offset between its baseline and ours is the delta.
        let detectorBaseline = Date()
        let adjustedStart = date.addingTimeInterval(now.timeIntervalSince(detectorBaseline))

        let duration = match.duration > 0 ? match.duration : defaultDuration

        // Strip the matched date span from the input to recover the title.
        var titleNS = trimmedInput as NSString
        titleNS = titleNS.replacingCharacters(in: match.range, with: "") as NSString
        let title = (titleNS as String)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",;:-")))

        guard !title.isEmpty else { return .failure(.emptyTitle) }

        return .success(CalendarEvent(title: title, start: adjustedStart, duration: duration))
    }
}
