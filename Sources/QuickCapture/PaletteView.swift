import AppKit
import SwiftUI

/// The command-palette surface (epic #82): one search field over a sectioned
/// result list. U3 ships the shell — search field, sections, highlight + key
/// handling — over **stub** rows; U5 wires `CaptureItemParser` output in.
///
/// Like `TagDropdownContent`, this lives inside its own borderless child panel
/// and so can't read the SwiftUI environment colour scheme — `isDark` is passed
/// in from `PalettePanel`, which resolves it from the panel's effective
/// appearance. The opaque-surface treatment (no behind-window frost) mirrors the
/// floating dropdown lesson (56b274f): a key palette over arbitrary content
/// reads cleaner as a solid card.

/// One selectable result row. A section's rows plus its title make a
/// `PaletteSection`; the whole list flattens to `[PaletteRow]` so a single
/// highlight index walks across section boundaries (U3 stub model — U5 will
/// grow these with real capture/tag/command payloads).
struct PaletteRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A capture item — carries a priority bucket so the row can draw its
        /// dot, and the item's 0-based file `line` so U6 can reveal it in the
        /// editor. The line is the unambiguous navigation target for a capture.
        case capture(priority: Int, line: Int)
        /// A jump-to-tag row — carries the `## section` name it navigates to
        /// (U6 reveals that section). Distinct from a capture row precisely so
        /// activation is unambiguous: a tag navigates by name, never by line.
        case tag(name: String)
        /// A global command (U7) — carries the `PaletteCommand` it runs so
        /// `MainPanel` can dispatch to the right existing entry point. The id is
        /// the stable navigation target, the same way a capture carries its line.
        case command(PaletteCommand)
    }

    let id = UUID()
    let title: String
    let kind: Kind
    /// Trailing tag label (capture rows) or count (tag rows); nil hides it.
    var detail: String? = nil

    static func == (lhs: PaletteRow, rhs: PaletteRow) -> Bool { lhs.id == rhs.id }
}

struct PaletteSection: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let rows: [PaletteRow]

    static func == (lhs: PaletteSection, rhs: PaletteSection) -> Bool { lhs.id == rhs.id }
}

/// A per-item action invoked from the `⌘K` actions menu (epic #82, U12 / R12).
/// Carries the item's file `line`, its `displayText` (so the disk side can
/// verify the line hasn't drifted since the palette parsed the file, and so
/// Copy has the exact text), and the row's title for the menu's heading. Each
/// case routes to an existing flow in `MainPanel.perform(itemAction:)`.
struct PaletteItemAction: Equatable {
    enum Kind: Equatable {
        /// Flip `[ ]`↔`[x]` on the item's line. The label reflects the current
        /// state so the menu reads "Mark done" on an open item, "Mark undone"
        /// on a checked one.
        case toggleDone
        case delete
        case refile
        case copy
    }
    let kind: Kind
    let line: Int
    let displayText: String
}

/// Pure list helpers — the only logic in this surface that carries a decision,
/// so it's factored out of the view and unit-tested (`PaletteViewTests`).
enum PaletteList {
    /// Flatten sections to the selectable rows in display order. The highlight
    /// index addresses this list, so it can move across section boundaries while
    /// section headers (non-selectable) are skipped implicitly.
    static func flatten(_ sections: [PaletteSection]) -> [PaletteRow] {
        sections.flatMap(\.rows)
    }

    /// Clamp/move the highlight by `delta`, staying within `[0, count)`. Empty
    /// lists pin to 0. No wrap-around — a launcher list stops at the ends
    /// (matches the capture box's tag dropdown, which also hard-stops).
    static func moveHighlight(_ current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, current + delta))
    }
}

struct PaletteView: View {
    /// Parsed capture items + tag counts (read from the capture file when the
    /// palette opens). `PaletteViewModel` turns these plus the live `query` into
    /// the rendered sections, so filtering/sorting stays in the pure view-model.
    let items: [CaptureItem]
    let tagSummary: [CaptureTagSummary]
    let isDark: Bool
    /// Fired when a row is activated (Return or click). U3 just dismisses; U5/U6
    /// route to navigation/commands.
    let onActivate: (PaletteRow) -> Void
    /// Fired when a per-item action is chosen from the `⌘K` menu (U8). Copy is
    /// handled in-view (pasteboard); the rest route to `MainPanel`.
    let onItemAction: (PaletteItemAction) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlight = 0
    /// When non-nil, the `⌘K` actions menu is open over the highlighted capture
    /// row; the value is that row's identity so the menu can act on it (line,
    /// display text) and label the done/undone action from its current state.
    @State private var actionsTarget: ActionsTarget? = nil
    @State private var actionHighlight = 0
    @FocusState private var fieldFocused: Bool

    /// The capture the `⌘K` menu is scoped to. `isDone` drives the toggle label
    /// (a checked item offers "Mark undone").
    private struct ActionsTarget: Equatable {
        let title: String
        let line: Int
        let isDone: Bool
    }

    private var theme: Theme { isDark ? .dark : .light }
    /// Sections recomputed from the parsed data + live query via the pure
    /// view-model. Empty query → Recent + Jump to tag; a query substring-filters.
    private var sections: [PaletteSection] {
        PaletteViewModel.sections(items: items, tagSummary: tagSummary, query: query)
    }
    private var rows: [PaletteRow] { PaletteList.flatten(sections) }

    /// Highlight clamped to the live row count — the flattened list shrinks as
    /// the (future) filter narrows, so the stored index can outrun it.
    private var highlightClamped: Int {
        PaletteList.moveHighlight(highlight, by: 0, count: rows.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(theme.border).frame(height: 0.5)
            if let target = actionsTarget {
                actionsMenu(target)
            } else {
                resultsList
            }
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.borderStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        // Esc closes the palette (or backs the ⌘K menu out to the search first);
        // arrows move the highlight; Return activates the highlighted row. Handled
        // at the root (like CaptureView's picker keys) so events land even when
        // the TextField holds focus.
        .onExitCommand {
            // In the ⌘K actions menu, Esc backs out to the search rather than
            // closing the whole palette — one step at a time.
            if actionsTarget != nil { actionsTarget = nil } else { onDismiss() }
        }
        .onKeyPress(.upArrow) {
            if actionsTarget != nil {
                actionHighlight = PaletteList.moveHighlight(actionHighlight, by: -1, count: actionKinds.count)
            } else {
                highlight = PaletteList.moveHighlight(highlightClamped, by: -1, count: rows.count)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if actionsTarget != nil {
                actionHighlight = PaletteList.moveHighlight(actionHighlight, by: 1, count: actionKinds.count)
            } else {
                highlight = PaletteList.moveHighlight(highlightClamped, by: 1, count: rows.count)
            }
            return .handled
        }
        .onKeyPress(.return) {
            if let target = actionsTarget {
                guard actionKinds.indices.contains(actionHighlight) else { return .ignored }
                runAction(actionKinds[actionHighlight], on: target)
                return .handled
            }
            guard rows.indices.contains(highlightClamped) else { return .ignored }
            onActivate(rows[highlightClamped])
            return .handled
        }
        // ⌘K opens the per-item actions menu over the highlighted capture row
        // (R12). Only capture rows have item actions — a tag/command row ignores
        // it. Re-pressing ⌘K (or Esc) backs out.
        .onKeyPress(keys: ["k"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if actionsTarget != nil { actionsTarget = nil; return .handled }
            openActionsMenu()
            return .handled
        }
        // A query change re-narrows the list (U5); reset the highlight to the top
        // so it never points past a shorter result set. Leaving the ⌘K menu open
        // over a now-stale row would be wrong, so close it back to the search.
        .onChange(of: query) { _, _ in highlight = 0; actionsTarget = nil }
    }

    // MARK: - Per-item actions (⌘K)

    /// The action order the `⌘K` menu renders in: toggle, delete, refile, copy.
    private var actionKinds: [PaletteItemAction.Kind] { [.toggleDone, .delete, .refile, .copy] }

    /// Open the actions menu over the currently highlighted row, but only when
    /// it's a capture (tag/command rows have no per-item actions). Captures the
    /// row's line + display text + done-state so the menu can act and label.
    private func openActionsMenu() {
        guard rows.indices.contains(highlightClamped) else { return }
        let row = rows[highlightClamped]
        guard case .capture(let priority, let line) = row.kind else { return }
        actionsTarget = ActionsTarget(title: row.title, line: line, isDone: priority == 4)
        actionHighlight = 0
    }

    /// Run one action on the menu's target. Copy stays in-view (it just needs the
    /// display text, already on the row); the rest carry line + text out to
    /// `MainPanel` for the disk/editor flows. The menu closes after either way.
    private func runAction(_ kind: PaletteItemAction.Kind, on target: ActionsTarget) {
        onItemAction(PaletteItemAction(kind: kind, line: target.line, displayText: target.title))
        actionsTarget = nil
    }

    private func actionsMenu(_ target: ActionsTarget) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(target.title)
                .font(TypeScale.caption)
                .tracking(Tracking.caption)
                .foregroundStyle(theme.inkTertiary)
                .lineLimit(1)
                .padding(.horizontal, Metrics.s3)
                .padding(.top, Metrics.s2)
                .padding(.bottom, 2)
            ForEach(Array(actionKinds.enumerated()), id: \.offset) { idx, kind in
                actionRow(kind, target: target, highlighted: idx == actionHighlight)
                    .contentShape(Rectangle())
                    .onTapGesture { runAction(kind, on: target) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.s2)
    }

    private func actionRow(_ kind: PaletteItemAction.Kind, target: ActionsTarget, highlighted: Bool) -> some View {
        HStack(spacing: Metrics.s2) {
            Image(systemName: actionGlyph(kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlighted ? theme.accentInk : theme.inkTertiary)
                .frame(width: 16)
            Text(actionLabel(kind, isDone: target.isDone))
                .font(TypeScale.body)
                .foregroundStyle(highlighted ? theme.accentInk : theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: Metrics.s2)
        }
        .padding(.horizontal, Metrics.s2)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(highlighted ? AnyShapeStyle(theme.accentSoft) : AnyShapeStyle(.clear))
        )
        .padding(.horizontal, Metrics.s2)
    }

    private func actionLabel(_ kind: PaletteItemAction.Kind, isDone: Bool) -> String {
        switch kind {
        case .toggleDone: return isDone ? "Mark undone" : "Mark done"
        case .delete:     return "Delete"
        case .refile:     return "Refile…"
        case .copy:       return "Copy text"
        }
    }

    private func actionGlyph(_ kind: PaletteItemAction.Kind) -> String {
        switch kind {
        case .toggleDone: return "checkmark.circle"
        case .delete:     return "trash"
        case .refile:     return "tray.and.arrow.down"
        case .copy:       return "doc.on.doc"
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: Metrics.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.inkTertiary)
            TextField("", text: $query,
                      prompt: Text("Search captures and commands")
                        .foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(TypeScale.captureLg)
                .foregroundStyle(theme.ink)
                .focused($fieldFocused)
                // Let the root key handlers own these — without this the field
                // swallows arrows/Return for caret motion / default-button.
                .onKeyPress(.upArrow) { .ignored }
                .onKeyPress(.downArrow) { .ignored }
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, Metrics.s2 + 4)
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Metrics.s2) {
                    ForEach(sections) { section in
                        if !section.rows.isEmpty {
                            sectionView(section)
                        }
                    }
                }
                .padding(.vertical, Metrics.s2)
            }
            .frame(maxHeight: 360)
            .onChange(of: highlightClamped) { _, idx in
                guard rows.indices.contains(idx) else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(rows[idx].id, anchor: .center)
                }
            }
        }
    }

    private func sectionView(_ section: PaletteSection) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(section.title.uppercased())
                .font(TypeScale.caption)
                .tracking(Tracking.caption)
                .foregroundStyle(theme.inkTertiary)
                .padding(.horizontal, Metrics.s3)
                .padding(.bottom, 2)
            ForEach(section.rows) { row in
                rowView(row, highlighted: rowIsHighlighted(row))
                    .id(row.id)
                    .contentShape(Rectangle())
                    .onTapGesture { onActivate(row) }
            }
        }
    }

    private func rowIsHighlighted(_ row: PaletteRow) -> Bool {
        rows.indices.contains(highlightClamped) && rows[highlightClamped].id == row.id
    }

    private func rowView(_ row: PaletteRow, highlighted: Bool) -> some View {
        HStack(spacing: Metrics.s2) {
            leadingGlyph(row)
            Text(row.title)
                .font(TypeScale.body)
                .foregroundStyle(highlighted ? theme.accentInk : theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: Metrics.s2)
            if let detail = row.detail {
                Text(detail)
                    .font(TypeScale.chip)
                    .foregroundStyle(theme.inkTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Metrics.s2)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(highlighted ? AnyShapeStyle(theme.accentSoft) : AnyShapeStyle(.clear))
        )
        .padding(.horizontal, Metrics.s2)
    }

    /// Capture rows lead with a priority orb (matching the editor's hues); tag
    /// rows with a hash glyph; command rows with a generic command glyph.
    @ViewBuilder
    private func leadingGlyph(_ row: PaletteRow) -> some View {
        switch row.kind {
        case .capture(let priority, _):
            Circle()
                .fill(priorityColor(priority))
                .frame(width: 7, height: 7)
                .frame(width: 16)
        case .tag:
            Image(systemName: "number")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 16)
        case .command(let command):
            Image(systemName: command.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 16)
        }
    }

    /// Map a `FileWriter.priorityBucket` value to its orb hue. Buckets 0/1/2 are
    /// the three priority levels; 3 (plain) and 4 (done) read as muted.
    private func priorityColor(_ bucket: Int) -> Color {
        switch bucket {
        case 0, 1: return theme.priHigh
        case 2:    return theme.priMed
        case 4:    return theme.inkTertiary
        default:   return theme.priLow
        }
    }
}

// MARK: - Previews

#Preview("Palette · light") {
    PaletteView(items: PaletteView.stubItems, tagSummary: PaletteView.stubTags,
                isDark: false, onActivate: { _ in }, onItemAction: { _ in }, onDismiss: {})
        .padding(40)
        .background(Color(0xECEDF0))
}

#Preview("Palette · dark") {
    PaletteView(items: PaletteView.stubItems, tagSummary: PaletteView.stubTags,
                isDark: true, onActivate: { _ in }, onItemAction: { _ in }, onDismiss: {})
        .padding(40)
        .background(Color(0x141417))
        .preferredColorScheme(.dark)
}

extension PaletteView {
    /// Sample parsed items for previews, so the live view-model drives the
    /// preview the same way it drives the running palette.
    static var stubItems: [CaptureItem] {
        [
            CaptureItem(displayText: "Buy milk", priorityBucket: 3, tag: "Quick capture", line: 2, createdAt: Date()),
            CaptureItem(displayText: "Draft the launch email", priorityBucket: 1, tag: "work", line: 5, createdAt: Date().addingTimeInterval(-60)),
            CaptureItem(displayText: "Renew passport", priorityBucket: 2, tag: "errands", line: 8, createdAt: Date().addingTimeInterval(-120)),
        ]
    }

    static var stubTags: [CaptureTagSummary] {
        [
            CaptureTagSummary(tag: "work", count: 12),
            CaptureTagSummary(tag: "errands", count: 4),
        ]
    }
}
