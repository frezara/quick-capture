import SwiftUI

/// Month, week and day calendar (design/highlighter, "Calendar, round 2").
/// Highlight marks now (today, the current time); accent marks selection and
/// the primary action; each event wears its section's hue. Keyboard handling
/// lives in `CalendarLayout.command` and is routed by MainPanel.
struct NativeCalendarView: View {
    let model: WorkspaceModel
    let onCapture: () -> Void
    var onEditor: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    private var dark: Bool { scheme == .dark }
    /// One device pixel. Grid columns sit at fractional x, where a 0.5pt line
    /// drops out entirely on a 1x display.
    @Environment(\.displayScale) private var displayScale
    private var hairline: CGFloat { 1 / displayScale }
    private let hourHeight: CGFloat = 50
    private let gutter: CGFloat = 56
    private var calendar: Calendar { .current }
    private func events(on day: Date) -> [WorkspaceItem] { model.projection.eventsByDay[day] ?? [] }
    private func isSelected(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: model.date) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                if let problem = model.problem {
                    WarningBanner(text: problem, t: t).padding(.horizontal, Metrics.s3).padding(.bottom, Metrics.s2)
                }
                switch model.calendarMode {
                case .month: month
                case .week, .day: timeline
                }
            }
            .frame(maxWidth: .infinity)
            switch model.calendarMode {
            case .month: aside(width: 280) { agenda }
            case .day: aside(width: 290) { eventDetail }
            case .week: EmptyView()
            }
        }
        .background(t.surface)
        .tint(t.accent)
    }

    // MARK: - Toolbar

    /// One row when it fits; otherwise the controls sit above the title (the
    /// day view's long date beside its side panel), never wrapping a label.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Metrics.s2) {
                title.fixedSize()
                Spacer(minLength: Metrics.s2)
                controls
            }
            VStack(alignment: .leading, spacing: Metrics.s2) {
                HStack { Spacer(minLength: 0); controls }
                title.fixedSize()
            }
        }
        .padding(.leading, 26).padding(.trailing, 20).padding(.top, 24).padding(.bottom, 14)
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: Metrics.s2) {
            modeSwitcher
            HStack(spacing: 4) {
                Button { model.shiftDate(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous  ⌘←").accessibilityLabel("Previous")
                Button("Today") { model.date = Date() }.help("Today  T")
                Button { model.shiftDate(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next  ⌘→").accessibilityLabel("Next")
            }.buttonStyle(GhostButtonStyle(t: t))
            Button("New event") { model.prepareNewEvent(); onCapture() }
                .buttonStyle(AccentButtonStyle(t: t))
                .help("New event  N")
        }
        .fixedSize()
    }

    @ViewBuilder private var title: some View {
        switch model.calendarMode {
        case .day:
            HStack(alignment: .center, spacing: Metrics.s2) {
                Text(model.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(TypeScale.title).tracking(Tracking.title).foregroundStyle(t.ink)
                if calendar.isDateInToday(model.date) {
                    Text("Today").font(Typeface.ui(12, .bold)).foregroundStyle(t.inkOnNow)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(t.now, in: RoundedRectangle(cornerRadius: Metrics.radiusKey, style: .continuous))
                }
            }
        case .week, .month:
            HStack(alignment: .firstTextBaseline, spacing: Metrics.s2) {
                (Text(model.date.formatted(.dateTime.month(.wide))).foregroundStyle(t.ink)
                 + Text(" " + model.date.formatted(.dateTime.year())).fontWeight(.regular).foregroundStyle(t.inkTertiary))
                    .font(TypeScale.title).tracking(Tracking.title)
                if model.calendarMode == .week, let first = model.days.first, let last = model.days.last {
                    Text(Self.rangeText(first, last)).font(Typeface.ui(13)).foregroundStyle(t.inkSecondary)
                }
            }
        }
    }

    /// "12 to 18 October", or "28 September to 4 October" across months.
    static func rangeText(_ first: Date, _ last: Date, calendar: Calendar = .current) -> String {
        let end = last.formatted(.dateTime.day().month(.wide))
        let start = calendar.isDate(first, equalTo: last, toGranularity: .month)
            ? first.formatted(.dateTime.day()) : first.formatted(.dateTime.day().month(.wide))
        return "\(start) to \(end)"
    }

    /// Day / Week / Month with each one's key shown, so D W M stay discoverable.
    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceCalendarMode.allCases, id: \.self) { mode in
                let on = model.calendarMode == mode
                let key = String(mode.rawValue.prefix(1))
                Button { model.calendarMode = mode } label: {
                    HStack(spacing: 6) {
                        Text(mode.rawValue)
                        Text(key)
                            .font(Typeface.mono(10.5, .medium))
                            .padding(.horizontal, 4)
                            .background(on ? t.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusKey, style: .continuous))
                    }
                    .font(Typeface.ui(12.5, on ? .semibold : .regular))
                    .foregroundStyle(on ? t.accent : t.inkSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                            .fill(on ? (dark ? t.border : t.surface) : .clear)
                            .shadow(color: .black.opacity(on && !dark ? 0.12 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(mode.rawValue) view  \(key)")
                .accessibilityLabel(mode.rawValue)
                .accessibilityHint("Shortcut \(key)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(dark ? t.surfaceField : t.keycap, in: RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous))
    }

    // MARK: - Month

    private var month: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(model.days.prefix(7)), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                }
            }.padding(.bottom, 6)
            GeometryReader { geometry in
                let rows = max(1, model.days.count / 7)
                let height = geometry.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                let index = row * 7 + column
                                if index < model.days.count {
                                    let day = model.days[index]
                                    let dayEvents = events(on: day)
                                    MonthCell(day: day, events: dayEvents, hues: dayEvents.map(model.hue(for:)),
                                              height: height,
                                              inMonth: calendar.isDate(day, equalTo: model.date, toGranularity: .month),
                                              today: calendar.isDateInToday(day), selected: isSelected(day),
                                              chosenEventID: chosen(in: dayEvents),
                                              t: t, dark: dark, hairline: hairline, model: model)
                                        .equatable()
                                }
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .trailing) { t.hairline.frame(width: hairline) }
        }
    }

    /// The selected event, but only for the cells that show it — every other
    /// cell keeps a nil here and so stays equal across an arrow press.
    private func chosen(in dayEvents: [WorkspaceItem]) -> String? {
        guard let id = model.selectedEventID, dayEvents.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    // MARK: - Week and day

    private var timeline: some View {
        let days = model.days
        return VStack(spacing: 0) {
            if model.calendarMode == .week { weekHeader(days) }
            allDayRow(days)
            t.border.frame(height: hairline)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter(days)
                        ForEach(days, id: \.self) { day in
                            let dayEvents = events(on: day)
                            TimelineColumn(day: day, events: dayEvents, hues: dayEvents.map(model.hue(for:)),
                                           today: calendar.isDateInToday(day), week: model.calendarMode == .week,
                                           chosenEventID: chosen(in: dayEvents),
                                           t: t, dark: dark, hairline: hairline, hourHeight: hourHeight, model: model)
                                .equatable()
                        }
                    }
                    .padding(.trailing, model.calendarMode == .week ? 14 : 20)
                    .padding(.vertical, 8)
                }
                // A little below the top, so the first label isn't cut off.
                .onAppear { proxy.scrollTo(Self.firstVisibleHour(days: days), anchor: UnitPoint(x: 0, y: 0.03)) }
            }
        }
    }

    /// Two hours before now when today is on screen, else 08:00.
    static func firstVisibleHour(days: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard days.contains(where: { calendar.isDate($0, inSameDayAs: now) }) else { return 8 }
        return max(0, min(8, calendar.component(.hour, from: now) - 2))
    }

    private func weekHeader(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let selected = isSelected(day)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Typeface.ui(12, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? t.accent : t.inkSecondary)
                    CalendarDayNumber(day: day, size: 16, today: calendar.isDateInToday(day), t: t)
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if selected { t.accent.frame(height: 2).padding(.horizontal, 6) }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.date = day }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { model.date = day }
            }
        }.padding(.trailing, 14)
    }

    private func allDayRow(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("All day").font(Typeface.ui(11)).foregroundStyle(t.inkSecondary)
                .frame(width: gutter - 10, alignment: .trailing).padding(.trailing, 10).padding(.top, 4)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 3) {
                    ForEach(events(on: day).filter { CalendarLayout.isAllDay($0) }) { item in
                        let hue = model.hue(for: item)
                        Text(item.title)
                            .font(Typeface.ui(model.calendarMode == .day ? 12.5 : 11.5, .semibold))
                            .foregroundStyle(hue.label(dark: dark)).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(hue.tint(dark: dark), in: RoundedRectangle(cornerRadius: Metrics.radiusKey, style: .continuous))
                            .overlay {
                                if model.selectedEventID == item.id {
                                    RoundedRectangle(cornerRadius: Metrics.radiusKey).strokeBorder(t.accent, lineWidth: 1.5)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(item, on: day) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.select(item, on: day) }
                    }
                }.padding(.horizontal, 3).padding(.vertical, 4).frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
            }
        }.padding(.trailing, model.calendarMode == .week ? 14 : 20).padding(.bottom, 4)
    }

    private func hourGutter(_ days: [Date]) -> some View {
        let showsNow = days.contains(where: { calendar.isDateInToday($0) })
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            let nowMinute = Double(nowOffset(context.date) / hourHeight * 60)
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(Typeface.mono(11)).foregroundStyle(t.inkSecondary)
                        // The now pill takes this slot while it's within 15 minutes.
                        .opacity(showsNow && abs(nowMinute - Double(hour * 60)) < 15 ? 0 : 1)
                        .frame(width: gutter - 10, height: hourHeight, alignment: .topTrailing)
                        .padding(.trailing, 10)
                        .offset(y: hour == 0 ? 2 : -7)
                        .id(hour)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if showsNow {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.time(context.date))
                        .font(Typeface.mono(11, .bold)).foregroundStyle(t.inkOnNow)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(t.now, in: RoundedRectangle(cornerRadius: Metrics.radiusKey, style: .continuous))
                        .offset(x: 4, y: nowOffset(context.date) - 8)
                }
            }
        }
    }

    private func nowOffset(_ now: Date) -> CGFloat { Self.nowOffset(now, hourHeight: hourHeight) }

    static func nowOffset(_ now: Date, hourHeight: CGFloat, calendar: Calendar = .current) -> CGFloat {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 60 * hourHeight
    }

    // MARK: - Side panels

    private func aside<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
            Spacer(minLength: 0)
            Text("Times in \(TimeZone.current.identifier)").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
        }
        .padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 16)
        .frame(width: width, alignment: .leading).frame(maxHeight: .infinity)
        .background(t.sunken)
        .overlay(alignment: .leading) { t.border.frame(width: hairline) }
    }

    /// Month view: the selected day's events.
    @ViewBuilder private var agenda: some View {
        let day = model.selectedDay
        let dayEvents = model.eventsOnSelectedDay
        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(TypeScale.heading).foregroundStyle(t.ink)
            if calendar.isDateInToday(day) {
                Text("Today").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
            }
        }.padding(.bottom, 4)
        if dayEvents.isEmpty {
            Text("Nothing planned. Press N to add an event.")
                .font(TypeScale.meta).foregroundStyle(t.inkSecondary)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(dayEvents) { item in agendaRow(item, on: day) }
            }
        }
    }

    private func agendaRow(_ item: WorkspaceItem, on day: Date) -> some View {
        let hue = model.hue(for: item)
        let chosen = model.selectedEventID == item.id
        let allDay = CalendarLayout.isAllDay(item)
        return HStack(alignment: .top, spacing: 10) {
            if !allDay { Circle().fill(hue.dot(dark: dark)).frame(width: 8, height: 8).padding(.top, 5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Typeface.ui(13.5, .semibold))
                    .foregroundStyle(allDay ? hue.label(dark: dark) : t.ink)
                Text(allDay ? "All day" : (Self.timeRange(item) ?? ""))
                    .font(allDay ? TypeScale.meta : Typeface.mono(12)).foregroundStyle(t.inkSecondary)
                if chosen, item.text != item.title {
                    Text(item.text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(TypeScale.meta).foregroundStyle(t.ink).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(allDay ? hue.tint(dark: dark) : (chosen ? t.accentSoft : .clear),
                    in: RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous))
        .overlay {
            if chosen { RoundedRectangle(cornerRadius: Metrics.radiusField).strokeBorder(t.accent, lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(item, on: day) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(item, on: day) }
    }

    /// Day view: the selected event's details, or how to pick one.
    @ViewBuilder private var eventDetail: some View {
        if let item = model.selectedEvent {
            let hue = model.hue(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.section).font(Typeface.ui(12, .semibold)).foregroundStyle(hue.label(dark: dark))
                Text(item.title).font(TypeScale.heading).foregroundStyle(t.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("When").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                if let starts = item.starts {
                    Text(starts.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(Typeface.ui(13.5)).foregroundStyle(t.ink)
                }
                Text(CalendarLayout.isAllDay(item) ? "All day" : (Self.timeRange(item) ?? ""))
                    .font(Typeface.mono(13)).foregroundStyle(t.inkSecondary)
            }
            let note = item.text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Note").font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                    Text(note).font(Typeface.ui(13.5)).foregroundStyle(t.ink).textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                if item.file == model.captureFile {
                    Button("Open in editor", action: onEditor).buttonStyle(GhostButtonStyle(t: t)).help("Open in editor  Enter")
                }
                Button("Done") { model.selectedEventID = nil }.buttonStyle(GhostButtonStyle(t: t)).help("Done  Esc")
            }
        } else {
            Text("No event selected").font(TypeScale.heading).foregroundStyle(t.ink)
            Text(model.eventsOnSelectedDay.isEmpty
                 ? "Nothing planned. Press N to add an event."
                 : "Use ↑ and ↓ to step through the day's events, or click one.")
                .font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// "10:30 to 12:00", or just the start for a point-in-time event.
    static func timeRange(_ item: WorkspaceItem) -> String? {
        guard let starts = item.starts else { return nil }
        guard let ends = item.ends, ends > starts else { return time(starts) }
        return "\(time(starts)) to \(time(ends))"
    }
}

/// Today's number sits on the highlighter; other months' days are dimmed.
private struct CalendarDayNumber: View {
    let day: Date
    let size: CGFloat
    let today: Bool
    var dimmed = false
    let t: Theme

    var body: some View {
        Text(day.formatted(.dateTime.day()))
            .font(Typeface.ui(size, dimmed ? .regular : .semibold))
            .foregroundStyle(today ? t.inkOnNow : (dimmed ? t.inkTertiary : t.ink))
            .padding(.horizontal, 5)
            .background(today ? t.now : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusKey, style: .continuous))
    }
}

/// One month-grid day. Plain values in, so an arrow press re-renders only the
/// cells whose selection changed (`.equatable()`); `model` is only the target
/// for taps and is left out of the comparison.
private struct MonthCell: View, Equatable {
    let day: Date
    let events: [WorkspaceItem]
    let hues: [TagPalette.Entry]
    let height: CGFloat
    let inMonth, today, selected: Bool
    let chosenEventID: String?
    let t: Theme
    let dark: Bool
    let hairline: CGFloat
    let model: WorkspaceModel

    static func == (a: Self, b: Self) -> Bool {
        a.day == b.day && a.events == b.events && a.hues == b.hues && a.height == b.height
            && a.inMonth == b.inMonth && a.today == b.today && a.selected == b.selected
            && a.chosenEventID == b.chosenEventID && a.dark == b.dark && a.hairline == b.hairline
    }

    private func open() { model.date = day; model.calendarMode = .day }

    var body: some View {
        let limit = max(0, Int((height - 34) / 18))
        let shown = events.count > limit ? max(0, limit - 1) : events.count
        VStack(alignment: .leading, spacing: 2) {
            CalendarDayNumber(day: day, size: 13, today: today, dimmed: !inMonth, t: t).padding(.bottom, 2)
            ForEach(Array(events.prefix(shown).enumerated()), id: \.element.id) { index, item in
                event(item, hue: hues[index])
            }
            if events.count > shown {
                Text("\(events.count - shown) more").font(Typeface.ui(11.5)).foregroundStyle(t.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .background(selected ? t.accentSoft.opacity(0.5) : .clear)
        .overlay { if selected { Rectangle().strokeBorder(t.accent, lineWidth: 2) } }
        .overlay(alignment: .top) { t.hairline.frame(height: hairline) }
        .overlay(alignment: .leading) { t.hairline.frame(width: hairline) }
        .clipped()
        .contentShape(Rectangle())
        // Select on the first click rather than after the double-click window.
        .onTapGesture(count: 2, perform: open)
        .simultaneousGesture(TapGesture().onEnded { model.date = day })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide))
                            + (events.isEmpty ? ", nothing planned" : ", \(events.count) events"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.date = day }
        .accessibilityAction(named: "Open day", open)
    }

    private func event(_ item: WorkspaceItem, hue: TagPalette.Entry) -> some View {
        let chosen = chosenEventID == item.id
        return Group {
            if CalendarLayout.isAllDay(item) {
                Text(item.title)
                    .font(Typeface.ui(11.5, .semibold)).foregroundStyle(hue.label(dark: dark))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(hue.tint(dark: dark), in: RoundedRectangle(cornerRadius: Metrics.radiusKey, style: .continuous))
            } else {
                HStack(spacing: 5) {
                    Circle().fill(hue.dot(dark: dark)).frame(width: 6, height: 6)
                    if let starts = item.starts, Calendar.current.isDate(starts, inSameDayAs: day) {
                        Text(NativeCalendarView.time(starts)).font(Typeface.mono(11)).foregroundStyle(t.inkSecondary)
                    }
                    Text(item.title).font(Typeface.ui(11.5)).foregroundStyle(t.ink).lineLimit(1)
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay { if chosen { RoundedRectangle(cornerRadius: Metrics.radiusKey).strokeBorder(t.accent, lineWidth: 1.5) } }
        .contentShape(Rectangle())
        .onTapGesture { model.select(item, on: day) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(item, on: day) }
    }
}

/// One day's 24-hour column in the week and day views. Same plain-values
/// contract as `MonthCell`.
private struct TimelineColumn: View, Equatable {
    let day: Date
    let events: [WorkspaceItem]
    let hues: [TagPalette.Entry]
    let today, week: Bool
    let chosenEventID: String?
    let t: Theme
    let dark: Bool
    let hairline: CGFloat
    let hourHeight: CGFloat
    let model: WorkspaceModel

    static func == (a: Self, b: Self) -> Bool {
        a.day == b.day && a.events == b.events && a.hues == b.hues && a.today == b.today && a.week == b.week
            && a.chosenEventID == b.chosenEventID && a.dark == b.dark && a.hairline == b.hairline
            && a.hourHeight == b.hourHeight
    }

    var body: some View {
        let byID = Dictionary(zip(events, hues).map { ($0.0.id, $0) }, uniquingKeysWith: { first, _ in first })
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0..<24, id: \.self) { hour in
                    t.hairline.frame(height: hairline).offset(y: CGFloat(hour) * hourHeight)
                }
                ForEach(CalendarLayout.segments(items: events, day: day)) { segment in
                    if let pair = byID[segment.id] {
                        let (item, hue) = pair
                        let width = max(1, (geometry.size.width - 6) / CGFloat(segment.columnCount))
                        let height = max(18, CGFloat(segment.endMinute - segment.startMinute) / 60 * hourHeight - 2)
                        event(item, hue: hue, width: width - 3, height: height)
                            .offset(x: CGFloat(segment.column) * width + 3,
                                    y: CGFloat(segment.startMinute) / 60 * hourHeight + 1)
                    }
                }
                if today {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        t.nowLine.frame(height: 2)
                            .offset(y: NativeCalendarView.nowOffset(context.date, hourHeight: hourHeight) - 1)
                    }.allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: hourHeight * 24)
        .background(today && week ? t.now.opacity(dark ? 0.04 : 0.07) : .clear)
        .overlay(alignment: .leading) { t.hairline.frame(width: hairline) }
        .contentShape(Rectangle())
        .onTapGesture { model.date = day; model.selectedEventID = nil }
    }

    private func event(_ item: WorkspaceItem, hue: TagPalette.Entry, width: CGFloat, height: CGFloat) -> some View {
        let chosen = chosenEventID == item.id
        let roomy = height >= 40
        return VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(Typeface.ui(week ? 12 : 13, .semibold))
                .foregroundStyle(hue.label(dark: dark))
                .lineLimit(roomy ? 2 : 1)
            if roomy, let range = NativeCalendarView.timeRange(item) {
                Text(range).font(Typeface.mono(11)).foregroundStyle(t.inkSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, roomy ? 4 : 2)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(hue.tint(dark: dark), in: RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous))
        .overlay {
            if chosen { RoundedRectangle(cornerRadius: Metrics.radiusChip).strokeBorder(t.accent, lineWidth: 2) }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { model.select(item, on: day) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(item, on: day) }
    }
}

#if DEBUG
#Preview("Calendar · month") {
    NativeCalendarView(model: .preview(destination: .calendar), onCapture: {})
        .frame(width: 1036, height: 700)
}

#Preview("Calendar · week · dark") {
    NativeCalendarView(model: .preview(destination: .calendar, calendarMode: .week), onCapture: {})
        .frame(width: 1036, height: 700)
        .preferredColorScheme(.dark)
}
#endif
