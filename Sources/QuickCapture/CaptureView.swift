import SwiftUI

struct CaptureView: View {
    @ObservedObject var appState: AppState
    let onSubmit: (String, String?) -> Void
    let onDismiss: () -> Void

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
    private let kbdBackground   = Color(hex: 0xF0F0F3)
    private let kbdText         = Color(hex: 0x3A3A3E)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(borderColor)
            inputsRow
            if !displayedTags.isEmpty {
                suggestionsRow
            }
            Divider().background(borderColor)
            footer
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
            Text("saving to \(displayPath)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Inputs row (todo + tag inline)

    private var inputsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("What needs doing?", text: $todoText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
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

    /// First recent tag whose name starts with the current input. Drives the
    /// tag field's tint colors and what Tab autocompletes to.
    private var matchedTag: String? {
        let query = tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        return appState.recentTags.first(where: { $0.lowercased().hasPrefix(query) })
    }

    private var matchedPalette: TagPalette.Entry? {
        matchedTag.map { TagPalette.entry(for: $0) }
    }

    // MARK: - Suggestions

    /// All recent tags stay visible — they don't filter as the user types.
    /// The matched one is signalled via the tag field's tint colors instead.
    private var displayedTags: [String] {
        Array(appState.recentTags.prefix(7))
    }

    private var suggestionsRow: some View {
        HStack(spacing: 6) {
            ForEach(displayedTags, id: \.self) { tag in
                TagChip(tag: tag) { chipTapped(tag) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HintLabel(key: "⏎", text: "save",  bg: kbdBackground, kbdText: kbdText, label: secondaryText)
            HintLabel(key: "⇥", text: "tag",   bg: kbdBackground, kbdText: kbdText, label: secondaryText)
            HintLabel(key: "⎋", text: "close", bg: kbdBackground, kbdText: kbdText, label: secondaryText)
            Spacer()
            Text("\(todoText.count) chars")
                .font(.system(size: 10))
                .foregroundStyle(tertiaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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

    private var displayPath: String {
        appState.captureFileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
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

struct HintLabel: View {
    let key: String
    let text: String
    let bg: Color
    let kbdText: Color
    let label: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(kbdText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(bg)
                .cornerRadius(3)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(label)
        }
    }
}
