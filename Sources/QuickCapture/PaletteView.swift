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
        /// A capture item — carries a priority bucket so the row can draw its dot.
        case capture(priority: Int)
        case tag
        case command
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
    /// The sections to render. U3 injects stubs; U5 will compute these from the
    /// parsed capture file + command list as the query changes.
    let sections: [PaletteSection]
    let isDark: Bool
    /// Fired when a row is activated (Return or click). U3 just dismisses; U5/U6
    /// route to navigation/commands.
    let onActivate: (PaletteRow) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    private var theme: Theme { isDark ? .dark : .light }
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
            resultsList
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
        // Esc closes the palette; arrows move the highlight; Return activates the
        // highlighted row. Handled at the root (like CaptureView's picker keys) so
        // events land even when the TextField holds focus.
        .onExitCommand { onDismiss() }
        .onKeyPress(.upArrow) {
            highlight = PaletteList.moveHighlight(highlightClamped, by: -1, count: rows.count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlight = PaletteList.moveHighlight(highlightClamped, by: 1, count: rows.count)
            return .handled
        }
        .onKeyPress(.return) {
            guard rows.indices.contains(highlightClamped) else { return .ignored }
            onActivate(rows[highlightClamped])
            return .handled
        }
        // A query change re-narrows the list (U5); reset the highlight to the top
        // so it never points past a shorter result set.
        .onChange(of: query) { _, _ in highlight = 0 }
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
        case .capture(let priority):
            Circle()
                .fill(priorityColor(priority))
                .frame(width: 7, height: 7)
                .frame(width: 16)
        case .tag:
            Image(systemName: "number")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 16)
        case .command:
            Image(systemName: "command")
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
    PaletteView(sections: PaletteView.stubSections, isDark: false,
                onActivate: { _ in }, onDismiss: {})
        .padding(40)
        .background(Color(0xECEDF0))
}

#Preview("Palette · dark") {
    PaletteView(sections: PaletteView.stubSections, isDark: true,
                onActivate: { _ in }, onDismiss: {})
        .padding(40)
        .background(Color(0x141417))
        .preferredColorScheme(.dark)
}

extension PaletteView {
    /// Placeholder content for U3 — the shell renders these until U5 swaps in
    /// `CaptureItemParser` output. Kept on the view (not the panel) so previews
    /// and the panel share one source.
    static var stubSections: [PaletteSection] {
        [
            PaletteSection(title: "Recent captures", rows: [
                PaletteRow(title: "Buy milk", kind: .capture(priority: 3), detail: "quick-capture"),
                PaletteRow(title: "Draft the launch email", kind: .capture(priority: 1), detail: "work"),
                PaletteRow(title: "Renew passport", kind: .capture(priority: 2), detail: "errands"),
            ]),
            PaletteSection(title: "Jump to tag", rows: [
                PaletteRow(title: "work", kind: .tag, detail: "12"),
                PaletteRow(title: "errands", kind: .tag, detail: "4"),
            ]),
            PaletteSection(title: "Commands", rows: [
                PaletteRow(title: "Open Editor", kind: .command),
                PaletteRow(title: "Archive completed", kind: .command),
                PaletteRow(title: "Settings", kind: .command),
            ]),
        ]
    }
}
