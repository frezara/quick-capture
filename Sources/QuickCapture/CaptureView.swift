import AppKit
import SwiftUI

struct CaptureView: View {
    @ObservedObject var appState: AppState
    let onSubmit: (String, String?) -> Void
    let onClose: () -> Void
    let onToggleEditor: () -> Void
    let onEscape: () -> Void
    let onContentSizeChange: (CGSize) -> Void
    /// When true the editor is open beneath this strip — the header shows the
    /// filename + close, and the toggle collapses rather than opens.
    var editorOpen: Bool = false
    var filename: String = ""

    @State private var todoText = ""
    @State private var tagText = ""
    @State private var shakeTrigger = 0
    @State private var isShaking = false
    /// Sticky tag-suggestions visibility. Driven off `focused` transitions
    /// rather than read live, so a *transient* `focused == nil` (which AppKit
    /// briefly produces while the panel resizes) doesn't collapse the footer
    /// and start a resize⇄focus oscillation. Only an explicit move to the todo
    /// field hides it.
    @State private var tagFieldActive = false
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
        // Animate the footer in/out. MainPanel tracks this animated height
        // per frame (top-anchored) so the window grows/shrinks in lockstep —
        // smooth and symmetric both ways.
        .animation(.easeInOut(duration: 0.18), value: shouldShowExtras)
        .animation(.easeInOut(duration: 0.18), value: isCalendarMode)
        // Pin the root to its intrinsic height — otherwise NSHostingView's fixed
        // frame can squash the VStack when the todo field grows mid-resize,
        // clipping the header.
        .fixedSize(horizontal: false, vertical: true)
        // Report intrinsic content size up to MainPanel so it can resize the
        // window to fit. We call back directly from the GeometryReader's
        // onAppear/onChange rather than via a PreferenceKey: on macOS 14 the
        // `.onPreferenceChange` path only ever delivered the default value and
        // never the real measured size, so the window never grew with content.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onContentSizeChange(proxy.size) }
                    .onChange(of: proxy.size) { onContentSizeChange($0) }
            }
        )
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.async { focused = .todo }
        }
        // Keep the sticky footer flag in step with real focus moves. A move to
        // .tag opens it; a move to .todo closes it. A transient nil (produced
        // by AppKit while the panel resizes) is ignored so the footer doesn't
        // flicker and drive a resize loop.
        .onChange(of: focused) { newValue in
            if newValue == .tag {
                tagFieldActive = true
            } else {
                // Collapse the footer when the tag field is no longer focused —
                // but defer the check so the *transient* focus drop AppKit emits
                // while the panel resizes (the footer appearing changes the
                // height) doesn't collapse it and start a resize⇄focus
                // oscillation. If focus has genuinely moved on by then, hide it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if focused != .tag { tagFieldActive = false }
                }
            }
        }
        .onExitCommand { onEscape() }
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
            tagFieldActive = false
            focused = .todo
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            AppIconBadge(size: 18)
            if editorOpen {
                // Split mode: the filename takes the title slot; the chrome
                // (collapse + close) folds into this row (no separate bar).
                Text(filename)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0x4A4A52))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                headerButton("chevron.up", help: "Collapse editor (⌘F)", action: onToggleEditor)
                headerButton("xmark", help: "Close", action: onClose)
            } else {
                Text("QUICK CAPTURE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color(hex: 0x4A4A52))
                Spacer()
                headerButton("doc.text", help: "Open editor (⌘F)", action: onToggleEditor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func headerButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Inputs row (todo + tag inline)

    private var inputsRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if todoText.isEmpty {
                    Text("What needs doing?")
                        .font(.system(size: 17, design: appState.captureFontDesign.design))
                        .foregroundStyle(tertiaryText)
                        .allowsHitTesting(false)
                }
                TodoTextEditor(
                    text: $todoText,
                    font: appState.captureFontDesign.nsFont(size: 17),
                    textColor: NSColor(primaryText),
                    maxLines: 4,
                    isFocused: Binding(
                        get: { focused == .todo },
                        set: { if $0 { focused = .todo } }
                    ),
                    onSubmit: { submit() },
                    onTab: { focused = .tag }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isShaking ? Color.red.opacity(0.75) : Color.clear,
                                  lineWidth: 1)
                    .animation(.easeOut(duration: 0.2), value: isShaking)
            )
            // Shakes when the user tries to submit with no text — signals
            // that the todo field is required.
            .phaseAnimator([0.0, -7, 7, -5, 5, -3, 3, 0], trigger: shakeTrigger) { content, phase in
                content.offset(x: phase)
            } animation: { _ in
                .easeInOut(duration: 0.04)
            }

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
        tagFieldActive || isCalendarMode
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
            // Nothing to save. Bounce focus to the todo input and shake/border-flash
            // it so the user sees that text is required.
            focused = .todo
            shakeTrigger += 1
            isShaking = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                isShaking = false
            }
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

extension CaptureFontDesign {
    func nsFont(size: CGFloat) -> NSFont {
        let design: NSFontDescriptor.SystemDesign
        switch self {
        case .system:     design = .default
        case .rounded:    design = .rounded
        case .serif:      design = .serif
        case .monospaced: design = .monospaced
        }
        let base = NSFont.systemFont(ofSize: size).fontDescriptor
        return base.withDesign(design)
            .flatMap { NSFont(descriptor: $0, size: size) }
            ?? .systemFont(ofSize: size)
    }
}

/// Multi-line input that grows to `maxLines` then scrolls. Drops down to
/// AppKit because SwiftUI's `TextField(axis:.vertical)` doesn't auto-scroll
/// to keep the cursor visible past its line limit.
struct TodoTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    let maxLines: Int
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onTab: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = textColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        // Width tracks the scroll view's clip view — without this the document
        // view stays at its initial (zero) width and text wraps mid-field.
        tv.autoresizingMask = [.width]

        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = true
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true
        sv.contentView.drawsBackground = false
        sv.verticalScrollElasticity = .none
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            tv.scrollRangeToVisible(NSRange(location: text.utf16.count, length: 0))
        }
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = textColor
        if isFocused, tv.window?.firstResponder !== tv {
            DispatchQueue.main.async { [weak tv] in
                tv?.window?.makeFirstResponder(tv)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [.font: font]
        )
        let bounding = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        let used = max(lineH, bounding.height)
        return CGSize(width: width, height: ceil(min(used, lineH * CGFloat(maxLines))))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TodoTextEditor
        init(parent: TodoTextEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            tv.scrollRangeToVisible(tv.selectedRange())
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            tv.scrollRangeToVisible(tv.selectedRange())
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return → newline; bare Return → submit.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab()
                return true
            default:
                return false
            }
        }
    }
}

