import AppKit
import ImageIO
import SwiftUI

struct CaptureView: View {
    @ObservedObject var appState: AppState
    let onSubmit: (String, String?, URL?) -> Void
    let onClose: () -> Void
    let onToggleEditor: () -> Void
    let onEscape: () -> Void
    let onContentSizeChange: (CGSize) -> Void

    @State private var todoText = ""
    @State private var tagText = ""
    @State private var shakeTrigger = 0
    @State private var isShaking = false
    /// Decoded chip thumbnail. Loaded off the main thread (a 6K Retina PNG
    /// decoded inline would jank the summon); the chip frame shows immediately
    /// and the image fills in.
    @State private var chipThumbnail: NSImage?
    /// Sticky tag-suggestions visibility. Driven off `focused` transitions
    /// rather than read live, so a *transient* `focused == nil` (which AppKit
    /// briefly produces while the panel resizes) doesn't collapse the footer
    /// and start a resize⇄focus oscillation. Only an explicit move to the todo
    /// field hides it.
    @State private var tagFieldActive = false
    @FocusState private var focused: Field?

    enum Field: Hashable { case todo, tag }

    // "Misted Steel" palette resolved from system appearance (see DesignSystem).
    // The panel follows the system colour scheme — dark mode renders Theme.dark.
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { colorScheme == .dark ? .dark : .light }

    /// The tag field switches to its accent treatment once it's focused or holds
    /// text — the "active" state from the mockup.
    private var tagActive: Bool { focused == .tag || !tagText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            inputsRow
            if shouldShowExtras {
                // Symmetric: gap above the rule (from the inputs) and below it
                // (to the chips), so the separator doesn't get squashed against
                // the input row.
                VStack(spacing: 0) {
                    Rectangle().fill(theme.border).frame(height: 1)
                        .padding(.top, Metrics.s3)
                    Group {
                        if isCalendarMode {
                            calendarPreview
                        } else {
                            footer
                        }
                    }
                    .padding(.top, Metrics.s3)
                }
                .transition(.opacity)
            }
        }
        .padding(Metrics.s3)
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
                    .onChange(of: proxy.size) { onContentSizeChange(proxy.size) }
            }
        )
        .background(panelSurface)
        // The capture box is always a self-contained rounded, bordered panel —
        // capture mode and editor mode are mutually exclusive (ADR-0004), so it
        // never has to fuse with the editor.
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusWindow, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusWindow, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.async { focused = .todo }
        }
        // Keep the sticky footer flag in step with real focus moves. A move to
        // .tag opens it; a move to .todo closes it. A transient nil (produced
        // by AppKit while the panel resizes) is ignored so the footer doesn't
        // flicker and drive a resize loop.
        .onChange(of: focused) { _, newValue in
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
            appState.pendingAttachment = nil
            appState.recentScreenshotExists = false
            appState.attachFeedback = nil
            chipThumbnail = nil
        }
        .onChange(of: appState.pendingAttachment) { _, newValue in
            loadChipThumbnail(for: newValue)
        }
        .onChange(of: appState.attachFeedback) { _, newValue in
            guard newValue != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                appState.attachFeedback = nil
            }
        }
    }

    // MARK: - Panel surface

    /// `surface` fill with the brushed top-edge `highlight` (bright in the top
    /// ~12%, fading out) from the mockup.
    private var panelSurface: some View {
        theme.surface.overlay(
            LinearGradient(
                stops: [
                    .init(color: theme.highlight.opacity(0.6), location: 0),
                    .init(color: .clear, location: 0.12),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    // MARK: - Inputs row (todo + tag inline, trailing "open" glyph)

    private var inputsRow: some View {
        HStack(alignment: .top, spacing: Metrics.s2) {
            todoField
            tagField
        }
    }

    private var todoField: some View {
        let focusedNow = focused == .todo
        return ZStack(alignment: .topLeading) {
            if todoText.isEmpty {
                Text("What needs doing?")
                    .font(.system(size: 17, design: appState.captureFontDesign.design))
                    .foregroundStyle(theme.inkTertiary)
                    .allowsHitTesting(false)
            }
            TodoTextEditor(
                text: $todoText,
                font: appState.captureFontDesign.nsFont(size: 17),
                textColor: NSColor(theme.ink),
                maxLines: 4,
                isFocused: Binding(
                    get: { focused == .todo },
                    set: { if $0 { focused = .todo } }
                ),
                onSubmit: { submit() },
                onTab: { focused = .tag },
                onEmptyDelete: { detachChipIfPresent() }
            )
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .fill(theme.surfaceField)
        )
        // Focus → accent border; submit-on-empty → a red border flash.
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .strokeBorder(isShaking ? Color.red.opacity(0.75)
                                        : (focusedNow ? theme.accent : .clear),
                              lineWidth: 1)
                .animation(.easeOut(duration: 0.2), value: isShaking)
        )
        // 3px accent-soft focus ring sitting just outside the field edge
        // (the mockup's `box-shadow:0 0 0 3px`).
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusField + 1, style: .continuous)
                .strokeBorder(theme.accentSoft, lineWidth: 3)
                .padding(-2)
                .opacity(focusedNow && !isShaking ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: focusedNow)
        )
        .frame(maxWidth: .infinity)
        // Shakes when the user tries to submit with no text — signals
        // that the todo field is required.
        .phaseAnimator([0.0, -7, 7, -5, 5, -3, 3, 0], trigger: shakeTrigger) { content, phase in
            content.offset(x: phase)
        } animation: { _ in
            .easeInOut(duration: 0.04)
        }
    }

    private var tagField: some View {
        HStack(spacing: Metrics.s1) {
            Text("#")
                .font(TypeScale.tag)
                .foregroundStyle(tagActive ? theme.accent : theme.inkTertiary)
            TextField("", text: $tagText, prompt: Text("tag").foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(TypeScale.tag)
                .foregroundStyle(tagActive ? theme.accentInk : theme.ink)
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
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .fill(tagActive ? theme.accentSoft : theme.surfaceField)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .strokeBorder(tagActive ? theme.accent.opacity(0.38) : .clear, lineWidth: 1)
        )
        // Fixed width — wide enough for common tags like "quick-capture" so the
        // field never resizes as you type (longer tags scroll within it). The
        // todo field (maxWidth: .infinity) absorbs the remaining space.
        .frame(width: 180)
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

    /// The accessory section below the inputs is always present (tag chips, or
    /// the calendar preview in `#cal` mode). Keeping it shown in both modes
    /// means the capture strip is a fixed height — no jarring grow/shrink on the
    /// floating HUD, and no squash when collapsing back from the editor (the
    /// strip's measured height matches in both modes).
    private var shouldShowExtras: Bool { true }

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
        HStack(spacing: Metrics.s2) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            if let event = parsedCalendarEvent {
                Text(formatCalendarPreview(event))
                    .font(TypeScale.code)
                    .foregroundStyle(theme.accentInk)
            } else {
                Text(todoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Type the event, e.g. \"call Seb tomorrow at 2pm\""
                     : "No date found — add a time like \"tomorrow at 2pm\"")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
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

    // MARK: - Footer (attachment chip, tag pills, screenshot hint)

    private var footer: some View {
        HStack(spacing: Metrics.s2) {
            if appState.pendingAttachment != nil {
                attachmentChip
            }
            tagChipsScroll
            if appState.pendingAttachment == nil,
               let hint = attachHintText {
                Text(hint)
                    .font(TypeScale.chip)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.attachFeedback)
    }

    private var tagChipsScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.s1) {
                ForEach(displayedTags, id: \.self) { tag in
                    chip(tag, isMatch: tag.lowercased() == matchedTag?.lowercased())
                        .onTapGesture { chipTapped(tag) }
                }
            }
            .padding(.vertical, 1)   // breathing room so chip borders don't clip
        }
        // Fade chips into the panel surface at the right edge, hinting that more
        // content scrolls beyond. allowsHitTesting(false) keeps chips under the
        // gradient still tappable.
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [.clear, theme.surface],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 32)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Attachment chip

    /// Pull-in feedback wins over the standing hint; the hint only shows when
    /// a screenshot actually exists to pull in, so the footer stays quiet on
    /// summons with nothing to offer.
    private var attachHintText: String? {
        if let feedback = appState.attachFeedback { return feedback }
        if appState.recentScreenshotExists { return "⌘⇧S to attach screenshot" }
        return nil
    }

    /// Thumbnail chip for the attached screenshot. In `#cal` mode the chip is
    /// disabled — a calendar capture never writes markdown, so the attachment
    /// isn't kept, and the chip says so rather than silently dropping it.
    private var attachmentChip: some View {
        HStack(spacing: Metrics.s1) {
            Group {
                if let thumb = chipThumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.inkTertiary)
                }
            }
            .frame(width: 28, height: 19)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            Text(isCalendarMode ? "Not used for calendar captures" : "Screenshot")
                .font(TypeScale.chip)
                .foregroundStyle(isCalendarMode ? theme.inkTertiary : theme.inkSecondary)
                .lineLimit(1)

            if !isCalendarMode {
                Button {
                    detachChipIfPresent()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove screenshot (⌫ on empty input)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(theme.surfaceField)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .opacity(isCalendarMode ? 0.55 : 1)
        .onAppear { loadChipThumbnail(for: appState.pendingAttachment) }
    }

    /// Detach is sticky for the capture session — nothing re-attaches until a
    /// fresh summon or an explicit ⌘⇧S.
    @discardableResult
    private func detachChipIfPresent() -> Bool {
        guard appState.pendingAttachment != nil else { return false }
        appState.pendingAttachment = nil
        chipThumbnail = nil
        return true
    }

    private func loadChipThumbnail(for url: URL?) {
        chipThumbnail = nil
        guard let url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 120,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return }
            let image = NSImage(cgImage: cg, size: .zero)
            DispatchQueue.main.async {
                if appState.pendingAttachment == url { chipThumbnail = image }
            }
        }
    }

    /// One steel chip treatment for every tag (no per-tag colour). The
    /// prefix-matched tag carries the `accentSoft` / `accentInk` fill.
    /// The `cal` chip swaps the `#` for a calendar icon to signal it's special.
    private func chip(_ name: String, isMatch: Bool) -> some View {
        let isCal = name.lowercased() == "cal"
        return HStack(spacing: 4) {
            if isCal {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isMatch ? theme.accent : theme.inkTertiary)
            } else {
                Text("#").foregroundStyle(isMatch ? theme.accent : theme.inkTertiary)
            }
            Text(name).foregroundStyle(isMatch ? theme.accentInk : theme.inkSecondary)
        }
        .font(TypeScale.chip)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(isMatch ? theme.accentSoft : theme.surfaceField)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .strokeBorder(isMatch ? theme.accent.opacity(0.42) : theme.border, lineWidth: 1)
        )
        .help(isCal ? "Creates a calendar event — type naturally, e.g. \"call Seb tomorrow at 2pm\"" : "")
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
        // Calendar captures never write markdown, so the attachment has
        // nowhere to go — the chip is visibly disabled in that mode (R21).
        let attachment = isCalendarMode ? nil : appState.pendingAttachment
        onSubmit(trimmedText, tag, attachment)
        todoText = ""
        tagText = ""
        appState.pendingAttachment = nil
        chipThumbnail = nil
    }

    private func chipTapped(_ tag: String) {
        // Clicking a suggestion chip is the commit action — one tag, one save.
        tagText = tag
        submit()
    }

}

// MARK: - Reusable subviews

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
    /// ⌫ with the field already empty. Returns true when consumed (e.g. the
    /// attachment chip was detached) so the delete doesn't also beep.
    var onEmptyDelete: () -> Bool = { false }

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
            case #selector(NSResponder.deleteBackward(_:)):
                guard tv.string.isEmpty else { return false }
                return parent.onEmptyDelete()
            default:
                return false
            }
        }
    }
}


// MARK: - Previews

private extension AppState {
    /// Lightweight state for previews — seeds a couple of recent tags so the
    /// suggestion footer has something to show.
    static func previewSeeded() -> AppState {
        let s = AppState()
        s.recentTags = ["quick-capture", "hyper-active"]
        return s
    }
}

#Preview("Capture · standalone") {
    CaptureView(
        appState: .previewSeeded(),
        onSubmit: { _, _, _ in }, onClose: {}, onToggleEditor: {},
        onEscape: {}, onContentSizeChange: { _ in }
    )
    .frame(width: 600)
    .padding(40)
    .background(Color(0xE4EAF0))
}

#Preview("Capture · dark") {
    CaptureView(
        appState: .previewSeeded(),
        onSubmit: { _, _, _ in }, onClose: {}, onToggleEditor: {},
        onEscape: {}, onContentSizeChange: { _ in }
    )
    .frame(width: 600)
    .padding(40)
    .background(Color(0x161B21))
    .preferredColorScheme(.dark)
}
