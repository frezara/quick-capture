import SwiftUI
import AppKit

/// Today: the day's schedule on the left and the editor on its daily note on
/// the right (CONTEXT.md). The editor is the panel's one warm web view, which
/// `MainPanel` moves into `EditorSlot` while Today is on screen.
struct TodayView: View {
    let model: WorkspaceModel
    let onEditorSlot: (NSView?) -> Void
    let onFocusSchedule: () -> Void
    let onDayChange: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        VStack(spacing: 0) {
            header
            t.border.frame(height: 1)
            HStack(spacing: 0) {
                TodaySchedule(events: model.eventsOnSelectedDay,
                              hues: model.eventsOnSelectedDay.map(model.hue(for:)),
                              selectedID: model.scheduleFocused ? model.selectedEventID : nil,
                              focused: model.scheduleFocused,
                              showsNow: model.isShowingToday,
                              onSelect: { item in
                                  model.selectedEventID = item.id
                                  onFocusSchedule()
                              })
                    .equatable()
                    .frame(width: 290)
                t.border.frame(width: 1)
                EditorSlot(onAttach: onEditorSlot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.selectedDay) { onDayChange() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(Self.dayTitle(model.date))
                .font(TypeScale.title).tracking(Tracking.title)
                .foregroundStyle(t.ink)
            if model.isShowingToday {
                Text("Today")
                    .font(Typeface.ui(12, .bold)).foregroundStyle(t.inkOnNow)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(t.now, in: RoundedRectangle(cornerRadius: Metrics.radiusKey))
                    .padding(.top, 6)
            }
            Spacer()
            HStack(spacing: 4) {
                Button("‹") { model.moveDays(-1) }
                    .help("Previous day  [").accessibilityLabel("Previous day")
                Button("Today") { model.date = Date() }
                    .help("Back to today  T")
                Button("›") { model.moveDays(1) }
                    .help("Next day  ]").accessibilityLabel("Next day")
            }
            .buttonStyle(GhostButtonStyle(t: t))
        }
        .padding(.leading, 26).padding(.trailing, 20).padding(.top, 24).padding(.bottom, 16)
    }

    private static let titleFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    static func dayTitle(_ date: Date) -> String { titleFormat.string(from: date) }
}

/// The left panel. Plain values in, so typing in the editor next to it never
/// re-renders it.
private struct TodaySchedule: View, Equatable {
    let events: [WorkspaceItem]
    let hues: [TagPalette.Entry]
    let selectedID: String?
    let focused: Bool
    let showsNow: Bool
    let onSelect: (WorkspaceItem) -> Void
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var dark: Bool { scheme == .dark }

    static func == (a: Self, b: Self) -> Bool {
        a.events == b.events && a.hues == b.hues && a.selectedID == b.selectedID
            && a.focused == b.focused && a.showsNow == b.showsNow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Schedule").font(Typeface.ui(12, .semibold))
                if focused { Circle().fill(t.accent).frame(width: 6, height: 6) }
            }
            .foregroundStyle(focused ? t.accent : t.inkSecondary)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)

            ForEach(Array(events.enumerated()), id: \.element.id) { index, item in
                if CalendarLayout.isAllDay(item) {
                    allDay(item, hue: hues[index])
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                timed(now: context.date)
            }
            if events.isEmpty {
                Text("Nothing scheduled.").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
            }
            Spacer(minLength: 0)
            hint
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(t.sunken)
    }

    private func timed(now: Date) -> some View {
        let timed = events.enumerated().filter { !CalendarLayout.isAllDay($0.element) }
        let nowIndex = showsNow ? (timed.firstIndex { ($0.element.starts ?? now) > now } ?? timed.count) : nil
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timed.enumerated()), id: \.element.element.id) { position, pair in
                if position == nowIndex { nowLine(now) }
                row(pair.element, hue: hues[pair.offset], past: showsNow && (pair.element.ends ?? pair.element.starts ?? now) <= now)
            }
            if nowIndex == timed.count { nowLine(now) }
        }
    }

    private func allDay(_ item: WorkspaceItem, hue: TagPalette.Entry) -> some View {
        Text(item.title)
            .font(Typeface.ui(12.5, .semibold)).foregroundStyle(hue.label(dark: dark))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(hue.tint(dark: dark), in: RoundedRectangle(cornerRadius: Metrics.radiusKey))
            .overlay(selectedRing(item))
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(item) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title), all day")
            .accessibilityAddTraits(item.id == selectedID ? [.isButton, .isSelected] : .isButton)
    }

    private func row(_ item: WorkspaceItem, hue: TagPalette.Entry, past: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.starts.map(NativeCalendarView.time) ?? "")
                .font(Typeface.mono(12)).foregroundStyle(t.inkSecondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Typeface.ui(13.5, .semibold))
                    .foregroundStyle(hue.label(dark: dark)).lineLimit(2)
                if let ends = item.ends, let starts = item.starts, ends > starts {
                    Text("to \(NativeCalendarView.time(ends))")
                        .font(Typeface.mono(12)).foregroundStyle(t.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(item.id == selectedID ? hue.tint(dark: dark) : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.radiusField))
        .overlay(selectedRing(item))
        .padding(.horizontal, -10)
        .opacity(past && item.id != selectedID ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.title, NativeCalendarView.timeRange(item)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(item.id == selectedID ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private func selectedRing(_ item: WorkspaceItem) -> some View {
        if item.id == selectedID {
            RoundedRectangle(cornerRadius: Metrics.radiusField).strokeBorder(t.accent, lineWidth: 2)
        }
    }

    private func nowLine(_ now: Date) -> some View {
        HStack(spacing: 10) {
            Text(NativeCalendarView.time(now))
                .font(Typeface.mono(11, .bold)).foregroundStyle(t.inkOnNow)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(t.now, in: RoundedRectangle(cornerRadius: Metrics.radiusKey))
                .frame(width: 44, alignment: .leading)
            t.nowLine.frame(height: 2)
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Now, \(NativeCalendarView.time(now))")
    }

    private var hint: some View {
        HStack(spacing: 4) {
            if focused {
                Keycap(text: "↑", t: t); Keycap(text: "↓", t: t); Text("events").padding(.trailing, 4)
                Keycap(text: "↵", t: t); Text("open").padding(.trailing, 4)
                Keycap(text: "[", t: t); Keycap(text: "]", t: t); Text("day")
            } else {
                Keycap(text: ShortcutAction.toggleTodayFocus.chord.displayGlyphs, t: t)
                Text("to move here")
            }
        }
        .font(TypeScale.meta).foregroundStyle(t.inkSecondary)
    }
}

/// An empty AppKit view the panel reparents the editor web view into.
private struct EditorSlot: NSViewRepresentable {
    let onAttach: (NSView?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAttach: onAttach) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Attach after SwiftUI has put the slot in the window, so the web view
        // lands in a view with a real frame.
        DispatchQueue.main.async { context.coordinator.onAttach(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.onAttach(nil)
    }

    final class Coordinator {
        let onAttach: (NSView?) -> Void
        init(onAttach: @escaping (NSView?) -> Void) { self.onAttach = onAttach }
    }
}
