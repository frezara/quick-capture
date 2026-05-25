import AppKit
import SwiftUI

struct CaptureView: View {
    @ObservedObject var appState: AppState
    let onSubmit: (String, String?) -> Void
    let onDismiss: () -> Void
    let onContentSizeChange: (CGSize) -> Void

    @State private var todoText = ""
    @State private var tagText = ""
    @FocusState private var focused: Field?

    enum Field: Hashable { case todo, tag }

    // Paper palette
    private let surface         = Color.white
    private let borderColor     = Color(hex: 0xF0F0F3)
    private let primaryText     = Color(hex: 0x1F1F24)
    private let secondaryText   = Color(hex: 0x6E6E72)
    private let tertiaryText    = Color(hex: 0x8A8A8E)
    private let inputBackground = Color(hex: 0xF4F4F7)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(borderColor)
            inputsRow
            if shouldShowExtras {
                Divider().background(borderColor)
                Group {
                    if isCalendarMode {
                        calendarPreview
                    } else {
                        footer
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shouldShowExtras)
        .animation(.easeInOut(duration: 0.18), value: isCalendarMode)
        // Report intrinsic content size up to CapturePanel so it can resize
        // the window to fit. background+GeometryReader is the standard SwiftUI
        // recipe for measuring without affecting layout.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ContentSizeKey.self) { size in
            onContentSizeChange(size)
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.async { focused = .todo }
        }
        .onExitCommand { onDismiss() }
        // Global Enter handler — guarantees that pressing Enter saves the todo
        // no matter where focus is (chip, suggestion area, transient nil).
        // Children's own Enter handlers (TextField.onSubmit, chip onKeyPress)
        // fire first and return .handled, so this only runs as a fallback.
        .onKeyPress(.return) {
            submit()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .capturePanelDidHide)) { _ in
            todoText = ""
            tagText = ""
            focused = .todo
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            AppIconBadge(size: 18)
            Text("QUICK CAPTURE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(hex: 0x4A4A52))
            Spacer()
            Button(action: openCaptureFile) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("Open capture file (⌘F)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Opens the capture file and dismisses the panel — the user is moving to
    /// the editor, so leaving the panel floating would be in the way. Prefers
    /// Obsidian (via the `obsidian://open?path=…` URL scheme) since the file
    /// typically lives in an Obsidian vault; falls back to the system default
    /// handler if Obsidian isn't installed. Shows an alert when the file is
    /// missing rather than silently creating it — the path may be a typo and
    /// we don't want to scatter empty files.
    private func openCaptureFile() {
        let url = appState.captureFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "Capture file not found"
            alert.informativeText = """
            \(url.path)

            Check the path in Settings, or capture something first to create the file.
            """
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        if !openInObsidian(fileURL: url) {
            NSWorkspace.shared.open(url)
        }
        onDismiss()
    }

    /// Returns true when Obsidian is installed AND handed off the URL
    /// successfully. The bundle-id check avoids `open`'s "no handler"
    /// dialog when Obsidian isn't installed.
    private func openInObsidian(fileURL: URL) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil else {
            return false
        }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]
        guard let obsidianURL = components.url else { return false }
        return NSWorkspace.shared.open(obsidianURL)
    }

    // MARK: - Inputs row (todo + tag inline)

    private var inputsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("What needs doing?", text: $todoText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17, design: appState.captureFontDesign.design))
                .foregroundStyle(primaryText)
                .focused($focused, equals: .todo)
                .lineLimit(1...4)
                .onSubmit { submit() }
                .onKeyPress(.tab) {
                    focused = .tag
                    return .handled
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(inputBackground)
                )

            HStack(spacing: 4) {
                Text("#")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(matchedPalette?.fg ?? tertiaryText)
                TextField("tag", text: $tagText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(matchedPalette?.fg ?? primaryText)
                    .focused($focused, equals: .tag)
                    .onSubmit { submit() }
                    .onKeyPress(.tab) {
                        // Tab → autocomplete to the first prefix-matched tag.
                        // Empty or no match → no-op (no Tab cycle anywhere).
                        let query = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty else { return .handled }
                        if let match = matchedTag,
                           match.lowercased() != query.lowercased() {
                            tagText = match
                        }
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(matchedPalette?.bg ?? inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(matchedPalette?.border ?? Color.clear,
                                  lineWidth: 1)
            )
            .frame(width: 140)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// Tags that are always present in the suggestions and Tab autocomplete,
    /// even before the user has used them. `cal` is the calendar-routing tag —
    /// captures with `#cal` get parsed into a .ics event instead of a todo.
    private static let pinnedTags = ["cal"]

    /// Full searchable tag list: pinned tags first, then anything discovered
    /// in the capture file. Deduped case-insensitively so a pinned tag never
    /// double-renders if it also appears as a `## heading`.
    private var allKnownTags: [String] {
        let recent = appState.recentTags.filter { tag in
            !Self.pinnedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        return Self.pinnedTags + recent
    }

    /// First known tag whose name starts with the current input. Drives the
    /// tag field's tint colors and what Tab autocompletes to.
    private var matchedTag: String? {
        let query = tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        return allKnownTags.first(where: { $0.lowercased().hasPrefix(query) })
    }

    private var matchedPalette: TagPalette.Entry? {
        matchedTag.map { TagPalette.entry(for: $0) }
    }

    // MARK: - Suggestions

    /// All known tags stay visible — they don't filter as the user types.
    /// The matched one is signalled via the tag field's tint colors instead.
    private var displayedTags: [String] {
        Array(allKnownTags.prefix(7))
    }

    // MARK: - Calendar preview

    /// True when the user has committed to the `#cal` tag — drives the calendar
    /// preview chip and routes Enter through `EventParser` instead of FileWriter.
    private var isCalendarMode: Bool {
        tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cal"
    }

    /// The accessory section below the inputs is shown when the user is either
    /// browsing tag suggestions OR composing a calendar event.
    private var shouldShowExtras: Bool {
        focused == .tag || isCalendarMode
    }

    /// Parses the current todo text into a CalendarEvent. Returns nil when the
    /// text is blank or the parser couldn't find a date.
    private var parsedCalendarEvent: CalendarEvent? {
        guard !todoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if case .success(let event) = EventParser.parse(todoText) {
            return event
        }
        return nil
    }

    private var calendarPreview: some View {
        let palette = TagPalette.entry(for: "cal")
        return HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.fg)
            if let event = parsedCalendarEvent {
                Text(formatCalendarPreview(event))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.fg)
            } else {
                Text(todoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Type the event, e.g. \"call Seb tomorrow at 2pm\""
                     : "No date found — add a time like \"tomorrow at 2pm\"")
                    .font(.system(size: 12))
                    .foregroundStyle(tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Human-readable preview: "Today at 14:00 · 30 min" / "Tomorrow at 09:00 · 1 hr".
    private func formatCalendarPreview(_ event: CalendarEvent) -> String {
        let cal = Calendar.current
        let datePart: String
        if cal.isDateInToday(event.start) {
            datePart = "Today"
        } else if cal.isDateInTomorrow(event.start) {
            datePart = "Tomorrow"
        } else if cal.isDate(event.start, equalTo: Date(), toGranularity: .weekOfYear) {
            datePart = posixFormatted(event.start, "EEEE")
        } else {
            datePart = posixFormatted(event.start, "EEE, MMM d")
        }
        let timePart = posixFormatted(event.start, "HH:mm")
        return "\(datePart) at \(timePart) · \(formatDuration(event.duration))"
    }

    private func posixFormatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int(seconds.rounded() / 60))
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60
        let remainder = mins % 60
        if remainder == 0 { return hours == 1 ? "1 hr" : "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }

    // MARK: - Footer (tag pills left, hints right)

    private var footer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(displayedTags, id: \.self) { tag in
                    TagChip(tag: tag) { chipTapped(tag) }
                }
            }
            .padding(.vertical, 1)   // breathing room so chip shadows/borders don't clip
        }
        // Fade chips into the panel background at the right edge, hinting
        // that more content scrolls beyond. allowsHitTesting(false) keeps
        // chips under the gradient still tappable.
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [.clear, surface],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 20)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func submit() {
        let trimmedText = todoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            // No-op: nothing to save. Bounce focus back to the todo input so
            // the user knows it's required (also satisfies the rule that you
            // can't log from the tag field if the todo is empty).
            focused = .todo
            return
        }
        let trimmedTag = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag: String? = trimmedTag.isEmpty ? nil : trimmedTag
        onSubmit(trimmedText, tag)
        todoText = ""
        tagText = ""
    }

    private func chipTapped(_ tag: String) {
        // Clicking a suggestion chip is the commit action — one tag, one save.
        tagText = tag
        submit()
    }

}

// MARK: - Reusable subviews

struct TagChip: View {
    let tag: String
    let onTap: () -> Void

    var body: some View {
        let entry = TagPalette.entry(for: tag)
        Button(action: onTap) {
            Text("#\(tag)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(entry.fg)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(entry.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(entry.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Carries the SwiftUI root's intrinsic size up to `CapturePanel` so the
/// NSPanel can resize its window to match. Last-write-wins is fine — there's
/// only one reporter.
struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

