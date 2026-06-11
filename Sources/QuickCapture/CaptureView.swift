import AppKit
import SwiftUI

struct CaptureView: View {
    @ObservedObject var appState: AppState
    let onSubmit: (String, String?, [URL]) -> Bool
    let onClose: () -> Void
    let onToggleEditor: () -> Void
    let onEscape: () -> Void
    let onContentSizeChange: (CGSize) -> Void
    /// Attach the chosen screenshots and dismiss the picker surface (MainPanel
    /// shrinks the window back to the capture box).
    var onPickerAttach: ([URL]) -> Void = { _ in }
    /// Dismiss the picker surface without attaching.
    var onPickerCancel: () -> Void = {}

    @State private var todoText = ""
    @State private var tagText = ""
    @State private var shakeTrigger = 0
    @State private var isShaking = false
    /// Decoded chip thumbnails, keyed by attachment URL. Loaded off the main
    /// thread (a 6K Retina PNG decoded inline would jank the summon); each chip
    /// frame shows immediately and its image fills in.
    @State private var chipThumbnails: [URL: NSImage] = [:]
    /// Sticky tag-suggestions visibility. Driven off `focused` transitions
    /// rather than read live, so a *transient* `focused == nil` (which AppKit
    /// briefly produces while the panel resizes) doesn't collapse the footer
    /// and start a resize⇄focus oscillation. Only an explicit move to the todo
    /// field hides it.
    @State private var tagFieldActive = false

    /// Highlighted row in the tag dropdown (clamped to the filtered list at
    /// use sites, since the list shrinks as the user types).
    @State private var tagHighlight = 0
    /// Esc closes the dropdown without leaving the tag field; typing reopens.
    @State private var tagDropdownDismissed = false
    /// Highlighted row in the ⌘⇧S screenshot picker (0 = newest). Moves with
    /// ↑/↓ independently of what's toggled for selection.
    @State private var pickerIndex = 0
    /// Screenshots toggled (Space/click) in the ⌘⇧S picker. Enter attaches all
    /// of these; empty falls back to the highlighted row (the one-press flow).
    /// Keyed by URL so it survives a re-query that reshuffles indices.
    @State private var pickerSelection: Set<URL> = []
    /// Decoded previews for the picker, keyed by screenshot URL. Loaded off the
    /// main thread like the chip thumbnail.
    @State private var pickerPreviews: [URL: NSImage] = [:]
    @FocusState private var focused: Field?

    enum Field: Hashable { case todo, tag, picker }

    // "Misted Steel" palette resolved from system appearance (see DesignSystem).
    // The panel follows the system colour scheme — dark mode renders Theme.dark.
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { colorScheme == .dark ? .dark : .light }

    /// The tag field switches to its accent treatment once it's focused or holds
    /// text — the "active" state from the mockup.
    private var tagActive: Bool { focused == .tag || !tagText.isEmpty }

    var body: some View {
        Group {
            if let items = appState.screenshotPickerItems {
                // ⌘⇧S takeover: a large centered panel (same window, like the
                // editor) that fills the surface while you pick.
                screenshotPickerSurface(items)
            } else {
                captureColumn
            }
        }
        .padding(Metrics.s3)
        // Animate the footer in/out. MainPanel tracks this animated height
        // per frame (top-anchored) so the window grows/shrinks in lockstep —
        // smooth and symmetric both ways.
        .animation(.easeInOut(duration: 0.18), value: shouldShowExtras)
        .animation(.easeInOut(duration: 0.18), value: isCalendarMode)
        .animation(.easeInOut(duration: 0.18), value: pickerOpen)
        // Pin the root to its intrinsic height — otherwise NSHostingView's fixed
        // frame can squash the VStack when the todo field grows mid-resize,
        // clipping the header. The picker surface, by contrast, fills the large
        // window (MainPanel owns that fixed frame), so it must NOT be height-pinned.
        .fixedSize(horizontal: false, vertical: !pickerOpen)
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
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.borderStrong, lineWidth: 0.5)
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
                // A fresh entry into the field reopens a previously
                // Esc-dismissed dropdown and starts at the top row.
                tagDropdownDismissed = false
                tagHighlight = 0
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
        // Esc closes transient surfaces first (picker, then the tag dropdown,
        // without clearing typed text); only a plain Esc dismisses the panel.
        .onExitCommand {
            if pickerOpen {
                onPickerCancel()
            } else if tagDropdownVisible {
                tagDropdownDismissed = true
            } else {
                onEscape()
            }
        }
        // Global Enter handler — guarantees that pressing Enter saves the todo
        // no matter where focus is (chip, suggestion area, transient nil).
        // Children's own Enter handlers (TextField.onSubmit) fire first and
        // return .handled, so this only runs as a fallback. While the picker is
        // open it owns Enter (attach) and the arrows (navigate): a plain
        // `.focusable()` view doesn't reliably receive `.onKeyPress(.return)`
        // (Return is reserved for default-button activation), so the picker's
        // keys are handled here at the root where the events actually land.
        .onKeyPress(.return) {
            if pickerOpen { attachPicked(); return .handled }
            submit()
            return .handled
        }
        .onKeyPress(.upArrow)    { pickerOpen ? { movePicker(-1); return .handled }() : .ignored }
        .onKeyPress(.downArrow)  { pickerOpen ? { movePicker(1);  return .handled }() : .ignored }
        .onKeyPress(.leftArrow)  { pickerOpen ? { movePicker(-1); return .handled }() : .ignored }
        .onKeyPress(.rightArrow) { pickerOpen ? { movePicker(1);  return .handled }() : .ignored }
        // Space toggles the highlighted row's selection — multi-attach (#45).
        .onKeyPress(.space)      { pickerOpen ? { toggleHighlighted(); return .handled }() : .ignored }
        .onChange(of: tagText) { _, _ in
            // Typing reopens an Esc-dismissed dropdown and resets the
            // highlight — the filtered list under the cursor just changed.
            tagDropdownDismissed = false
            tagHighlight = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .capturePanelDidHide)) { _ in
            todoText = ""
            tagText = ""
            tagFieldActive = false
            tagDropdownDismissed = false
            tagHighlight = 0
            focused = .todo
            appState.pendingAttachments = []
            appState.recentScreenshotExists = false
            appState.attachFeedback = nil
            appState.screenshotPickerItems = nil
            chipThumbnails = [:]
            pickerSelection = []
            pickerPreviews = [:]
        }
        .onChange(of: appState.pendingAttachments) { _, newValue in
            loadChipThumbnails(for: newValue)
        }
        // The picker's item set changing (open, or ⌘⇧S re-query) resets the
        // highlight to the newest and (re)loads previews; opening also moves
        // keyboard focus onto the picker so arrows/Enter reach it, and closing
        // hands focus back to the todo field.
        .onChange(of: pickerItemsKey) { _, _ in
            guard let items = appState.screenshotPickerItems else {
                if focused == .picker { focused = .todo }
                return
            }
            pickerIndex = 0
            pickerSelection = []   // a fresh picker starts with nothing toggled
            loadPickerPreviews(items)
            // Defer focus a runloop — the focusable picker view is installed in
            // this same render pass, and focusing it synchronously can miss.
            DispatchQueue.main.async { focused = .picker }
        }
        .onChange(of: appState.attachFeedback) { _, newValue in
            guard newValue != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                appState.attachFeedback = nil
            }
        }
    }

    /// The capture box layout (inputs + tag chips / calendar preview). Shown
    /// whenever the picker surface isn't taking over the window.
    private var captureColumn: some View {
        VStack(spacing: 0) {
            inputsRow
            if shouldShowExtras {
                // Symmetric: gap above the rule (from the inputs) and below it
                // (to the chips), so the separator doesn't get squashed against
                // the input row.
                VStack(spacing: 0) {
                    Rectangle().fill(theme.border).frame(height: 0.5)
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
    }

    // MARK: - Panel surface

    /// Frosted material: behind-window blur under a translucent `panel` wash,
    /// with the inset top-edge light from the mockup.
    private var panelSurface: some View {
        VisualEffectBlur()
            .overlay(theme.panel)
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: theme.highlight, location: 0),
                        .init(color: .clear, location: 0.12),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
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
                    .font(.system(size: 16, design: appState.captureFontDesign.design))
                    .foregroundStyle(theme.inkTertiary)
                    .allowsHitTesting(false)
            }
            TodoTextEditor(
                text: $todoText,
                font: appState.captureFontDesign.nsFont(size: 16),
                textColor: NSColor(theme.ink),
                maxLines: 4,
                isFocused: Binding(
                    get: { focused == .todo },
                    set: { if $0 { focused = .todo } }
                ),
                onSubmit: { submit() },
                onTab: { focused = .tag },
                onEmptyDelete: { detachMostRecent() }
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
                .strokeBorder(isShaking ? theme.priHigh.opacity(0.75)
                                        : (focusedNow ? theme.accent : .clear),
                              lineWidth: 1)
                .animation(.easeOut(duration: 0.2), value: isShaking)
        )
        // 3px accent focus halo sitting just outside the field edge
        // (the mockup's `box-shadow: 0 0 0 3px accentRing`).
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusField + 1, style: .continuous)
                .strokeBorder(theme.accentRing, lineWidth: 3)
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
                .onKeyPress(.return) {
                    // Enter accepts the highlighted suggestion when it differs
                    // from the typed text; otherwise falls through (.ignored)
                    // to onSubmit, which saves the capture.
                    guard tagDropdownVisible else { return .ignored }
                    let pick = filteredTags[tagHighlightClamped]
                    let query = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard pick.lowercased() != query.lowercased() else { return .ignored }
                    acceptTag(pick)
                    return .handled
                }
                .onKeyPress(.tab) {
                    // Tab accepts the highlighted suggestion. With the
                    // dropdown closed, fall back to first-prefix-match
                    // autocomplete (no Tab cycle anywhere).
                    if tagDropdownVisible {
                        acceptTag(filteredTags[tagHighlightClamped])
                        return .handled
                    }
                    let query = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return .handled }
                    if let match = matchedTag,
                       match.lowercased() != query.lowercased() {
                        tagText = match
                    }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard tagDropdownVisible else { return .ignored }
                    tagHighlight = max(0, tagHighlightClamped - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard tagDropdownVisible else { return .ignored }
                    tagHighlight = min(filteredTags.count - 1, tagHighlightClamped + 1)
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
        // The Obsidian-style suggest dropdown floats in a borderless child
        // window anchored to this field (#70) — the capture window is
        // content-sized, so an in-layout dropdown would resize the whole
        // panel and an overlay would be clipped at its bottom edge.
        .background(
            TagDropdownAnchor(
                tags: filteredTags,
                highlight: tagHighlightClamped,
                visible: tagDropdownVisible,
                isDark: colorScheme == .dark,
                onPick: { acceptTag($0) }
            )
        )
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

    // MARK: - Tag dropdown (Obsidian-style suggest)

    /// Prefix-filtered suggestions: the full known list while the field is
    /// empty (Obsidian shows everything on focus), narrowing as you type.
    private var filteredTags: [String] {
        let query = tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = query.isEmpty
            ? allKnownTags
            : allKnownTags.filter { $0.lowercased().hasPrefix(query) }
        return Array(matches.prefix(6))
    }

    /// Visibility keys off `tagFieldActive` (the debounced focus flag), not
    /// `focused` directly — AppKit emits transient focus drops whenever the
    /// panel resizes (e.g. the todo field growing a line), which would
    /// flicker the dropdown. Hidden once the field holds exactly the only
    /// match (accepting a tag closes the dropdown without extra state).
    private var tagDropdownVisible: Bool {
        guard tagFieldActive, !tagDropdownDismissed, !filteredTags.isEmpty else { return false }
        let query = tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if filteredTags.count == 1 && filteredTags[0].lowercased() == query { return false }
        return true
    }

    /// The highlighted row, clamped — the filtered list shrinks as you type.
    private var tagHighlightClamped: Int {
        min(tagHighlight, max(0, filteredTags.count - 1))
    }

    /// Put the chosen tag in the field and close the dropdown (the exact-match
    /// rule in `tagDropdownVisible` does the closing). Enter then submits.
    private func acceptTag(_ tag: String) {
        tagText = tag
        tagHighlight = 0
        focused = .tag
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
            if !appState.pendingAttachments.isEmpty {
                attachmentChips
            }
            if let hint = attachHintText {
                Text(hint)
                    .font(TypeScale.chip)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize()
                    .transition(.opacity)
            } else if appState.pendingAttachments.isEmpty {
                // The tag chips moved into the dropdown under the tag field;
                // keep a quiet hint here so the footer row (and with it the
                // strip's fixed height) never collapses to empty.
                Text("Tab to tag · ⌘⇧S to attach")
                    .font(TypeScale.chip)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.15), value: appState.attachFeedback)
    }

    // MARK: - Attachment chip

    /// Pull-in feedback wins over the standing hint; the hint only shows when
    /// a screenshot actually exists to pull in and no chip is attached, so the
    /// footer stays quiet on summons with nothing to offer.
    private var attachHintText: String? {
        guard appState.pendingAttachments.isEmpty else { return nil }
        if let feedback = appState.attachFeedback { return feedback }
        if appState.recentScreenshotExists { return "⌘⇧S to attach screenshot" }
        return nil
    }

    /// Newest-first count cap before chips collapse to a single summary chip, so
    /// a many-screenshot capture doesn't push the tag chips off the strip.
    private static let maxInlineChips = 3

    /// One thumbnail chip per attachment, or a single "N screenshots" summary
    /// once there are more than `maxInlineChips`. In `#cal` mode every chip is
    /// disabled — a calendar capture never writes markdown, so the attachments
    /// aren't kept, and the strip says so rather than silently dropping them.
    @ViewBuilder
    private var attachmentChips: some View {
        let urls = appState.pendingAttachments
        if isCalendarMode {
            disabledAttachmentChip(count: urls.count)
        } else if urls.count > Self.maxInlineChips {
            summaryAttachmentChip(count: urls.count, newest: urls.last)
        } else {
            HStack(spacing: Metrics.s1) {
                ForEach(urls, id: \.self) { url in
                    attachmentChip(for: url)
                }
            }
        }
    }

    /// A single attachment chip: its thumbnail + an xmark that detaches just
    /// that screenshot.
    private func attachmentChip(for url: URL) -> some View {
        chipShell {
            thumbOrPlaceholder(chipThumbnails[url])
            Button {
                detach(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove screenshot (⌫ on empty input removes the most recent)")
        }
    }

    /// Collapsed chip for >3 attachments: newest thumbnail + an "N screenshots"
    /// count, with an xmark that detaches the most recent.
    private func summaryAttachmentChip(count: Int, newest: URL?) -> some View {
        chipShell {
            thumbOrPlaceholder(newest.flatMap { chipThumbnails[$0] })
            Text("\(count) screenshots")
                .font(TypeScale.chip)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(1)
            Button {
                detachMostRecent()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove the most recent screenshot (⌫ on empty input)")
        }
    }

    /// Disabled summary shown in `#cal` mode where attachments are dropped.
    private func disabledAttachmentChip(count: Int) -> some View {
        chipShell {
            Image(systemName: "photo")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 28, height: 19)
            Text(count == 1 ? "Not used for calendar captures"
                            : "\(count) screenshots — not used for calendar captures")
                .font(TypeScale.chip)
                .foregroundStyle(theme.inkTertiary)
                .lineLimit(1)
        }
        .opacity(0.55)
    }

    /// The 28×19 thumbnail frame shared by every attachment chip.
    private func thumbOrPlaceholder(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
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
    }

    /// Shared chip chrome (rounded, bordered) wrapping arbitrary contents.
    private func chipShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Metrics.s1) { content() }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(theme.chip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 0.5)
            )
    }

    /// Detach one screenshot. Detach is sticky for the capture session —
    /// nothing re-attaches until a fresh summon or an explicit ⌘⇧S.
    private func detach(_ url: URL) {
        appState.pendingAttachments.removeAll { $0 == url }
        chipThumbnails[url] = nil
    }

    /// ⌫ on the empty input removes the most-recently-attached screenshot.
    @discardableResult
    private func detachMostRecent() -> Bool {
        guard let last = appState.pendingAttachments.last else { return false }
        detach(last)
        return true
    }

    private func loadChipThumbnails(for urls: [URL]) {
        // Drop thumbnails for URLs no longer attached.
        chipThumbnails = chipThumbnails.filter { urls.contains($0.key) }
        for url in urls where chipThumbnails[url] == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cg = AttachmentStore.thumbnail(at: url, maxPixelSize: 120) else { return }
                let image = NSImage(cgImage: cg, size: .zero)
                DispatchQueue.main.async {
                    if appState.pendingAttachments.contains(url) { chipThumbnails[url] = image }
                }
            }
        }
    }

    // MARK: - Screenshot picker (⌘⇧S)

    private var pickerOpen: Bool { appState.screenshotPickerItems != nil }

    /// Stable identity for the current picker item set. Drives the focus /
    /// highlight / preview resets when the picker opens, closes, or is
    /// re-queried by a second ⌘⇧S.
    private var pickerItemsKey: String {
        (appState.screenshotPickerItems ?? []).map(\.url.path).joined(separator: "|")
    }

    /// The ⌘⇧S takeover surface: a large centered panel (like the editor) with a
    /// scrollable vertical list of recent screenshots on the left and a big live
    /// preview of the highlighted one on the right. It's `.focusable()` and grabs
    /// focus while open, so arrows / Enter reach the root key handlers instead of
    /// the todo field; Esc is routed to `onPickerCancel()` from the root.
    private func screenshotPickerSurface(_ items: [ScreenshotLocator.Screenshot]) -> some View {
        let selected = items.indices.contains(pickerIndex) ? items[pickerIndex] : items.first
        return VStack(alignment: .leading, spacing: Metrics.s3) {
            HStack(spacing: Metrics.s2) {
                Text("Recent screenshots")
                    .font(Typeface.ui(15, .semibold))
                    .foregroundStyle(theme.ink)
                if !pickerSelection.isEmpty {
                    Text("\(pickerSelection.count) selected")
                        .font(TypeScale.chip)
                        .foregroundStyle(theme.accentInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(theme.accentSoft)
                        )
                }
                Spacer(minLength: 0)
                HStack(spacing: Metrics.s1) {
                    keycap("↑↓");  hintLabel("navigate")
                    keycap("space"); hintLabel("select")
                    keycap("⏎");   hintLabel("attach")
                    keycap("esc");  hintLabel("cancel")
                }
            }

            HStack(alignment: .top, spacing: Metrics.s3) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.element.url) { idx, shot in
                                pickerRow(shot,
                                          isHighlighted: idx == pickerIndex,
                                          isSelected: pickerSelection.contains(shot.url))
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Click highlights and toggles selection
                                        // (#45); Enter attaches the selected set.
                                        pickerIndex = idx
                                        toggleHighlighted()
                                    }
                            }
                        }
                    }
                    .onChange(of: pickerIndex) { _, idx in
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
                .frame(width: 240)

                pickerPreview(selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Anchors keyboard focus inside the panel while the picker is open so
        // the root key handlers (arrows / Enter) receive events; the actual
        // handling lives at the root (see body) because a focusable view
        // doesn't reliably get `.onKeyPress(.return)`. The focus ring is dropped
        // — the row highlight already shows selection.
        .focusable()
        .focused($focused, equals: .picker)
        .focusEffectDisabled()
    }

    /// Small bordered key chip for the picker's keyboard hints (mono, per the
    /// mockup's keycap treatment).
    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(Typeface.mono(10, .medium))
            .foregroundStyle(theme.inkSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.chip)
            )
    }

    private func hintLabel(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.chip)
            .foregroundStyle(theme.inkTertiary)
            .padding(.trailing, 2)
    }

    /// A picker row. `isHighlighted` is the ↑↓ cursor (accent wash + border);
    /// `isSelected` is the toggled-for-attach state (a checkmark badge). The two
    /// are independent — you can move the highlight without changing selection.
    private func pickerRow(_ shot: ScreenshotLocator.Screenshot,
                           isHighlighted: Bool,
                           isSelected: Bool) -> some View {
        HStack(spacing: Metrics.s2) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let thumb = pickerPreviews[shot.url] {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
                .frame(width: 52, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .background(Circle().fill(.white).padding(1.5))
                        .padding(2)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(screenshotTime(shot))
                    .font(TypeScale.chip)
                    .foregroundStyle(isHighlighted ? theme.accentInk : theme.inkSecondary)
                    .lineLimit(1)
                Text(screenshotDay(shot))
                    .font(TypeScale.caption)
                    .foregroundStyle(theme.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(isHighlighted ? theme.accentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .strokeBorder(isHighlighted ? theme.accent.opacity(0.42) : .clear, lineWidth: 1)
        )
    }

    private func pickerPreview(_ shot: ScreenshotLocator.Screenshot?) -> some View {
        Group {
            if let shot, let img = pickerPreviews[shot.url] {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Metrics.s2)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(theme.inkTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .fill(theme.surfaceField)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 0.5)
        )
    }

    /// Wrap-around so ↑ from the newest lands on the oldest and vice versa —
    /// friendlier than a hard stop on a five-item list.
    private func movePicker(_ delta: Int) {
        guard let count = appState.screenshotPickerItems?.count, count > 0 else { return }
        pickerIndex = (pickerIndex + delta + count) % count
    }

    /// Space (or click) toggles the highlighted row in/out of the selection.
    private func toggleHighlighted() {
        guard let items = appState.screenshotPickerItems,
              items.indices.contains(pickerIndex) else { return }
        let url = items[pickerIndex].url
        if pickerSelection.contains(url) { pickerSelection.remove(url) }
        else { pickerSelection.insert(url) }
    }

    /// Attach the chosen screenshots and close the surface. All toggled rows
    /// attach in newest-first list order; with nothing toggled it falls back to
    /// the highlighted row — preserving the original one-press flow. MainPanel
    /// (via `onPickerAttach`) sets `pendingAttachments`; `onChange` decodes the
    /// chips.
    private func attachPicked() {
        guard let items = appState.screenshotPickerItems,
              items.indices.contains(pickerIndex) else { onPickerCancel(); return }
        let urls: [URL]
        if pickerSelection.isEmpty {
            urls = [items[pickerIndex].url]
        } else {
            // Preserve the picker's display order (newest first) and dedup.
            urls = items.map(\.url).filter { pickerSelection.contains($0) }
        }
        onPickerAttach(urls)
    }

    private func loadPickerPreviews(_ items: [ScreenshotLocator.Screenshot]) {
        for url in items.map(\.url) where pickerPreviews[url] == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cg = AttachmentStore.thumbnail(at: url, maxPixelSize: 1000) else { return }
                let image = NSImage(cgImage: cg, size: .zero)
                DispatchQueue.main.async { pickerPreviews[url] = image }
            }
        }
    }

    private func screenshotTime(_ shot: ScreenshotLocator.Screenshot) -> String {
        posixFormatted(shot.createdAt, "h:mm a")
    }

    private func screenshotDay(_ shot: ScreenshotLocator.Screenshot) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(shot.createdAt) { return "Today" }
        if cal.isDateInYesterday(shot.createdAt) { return "Yesterday" }
        return posixFormatted(shot.createdAt, "EEE, MMM d")
    }

    /// Finder-tag-style chips: each tag carries its 7px hue dot; the
    /// prefix-matched tag tints with its OWN hue (not the accent). The `cal`
    /// chip is a command, not a tag — calendar glyph, no dot, neutral always.
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
        // Calendar captures never write markdown, so attachments have nowhere
        // to go — the chips are visibly disabled in that mode (R21).
        let attachments = isCalendarMode ? [] : appState.pendingAttachments
        let saved = onSubmit(trimmedText, tag, attachments)
        // On a failed or user-declined save, leave the typed text and chips
        // intact so the user can retry without retyping.
        guard saved else { return }
        todoText = ""
        tagText = ""
        appState.pendingAttachments = []
        chipThumbnails = [:]
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
        onSubmit: { _, _, _ in true }, onClose: {}, onToggleEditor: {},
        onEscape: {}, onContentSizeChange: { _ in }
    )
    .frame(width: 600)
    .padding(40)
    .background(Color(0xECEDF0))
}

#Preview("Capture · dark") {
    CaptureView(
        appState: .previewSeeded(),
        onSubmit: { _, _, _ in true }, onClose: {}, onToggleEditor: {},
        onEscape: {}, onContentSizeChange: { _ in }
    )
    .frame(width: 600)
    .padding(40)
    .background(Color(0x141417))
    .preferredColorScheme(.dark)
}
