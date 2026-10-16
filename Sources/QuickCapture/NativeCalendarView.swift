import SwiftUI

struct NativeCalendarView: View {
    @Bindable var model: WorkspaceModel
    let onCapture: () -> Void
    @State private var selectedEvent: WorkspaceItem?
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }
    /// One device pixel. Grid columns sit at fractional x, where a 0.5pt line
    /// drops out entirely on a 1x display.
    @Environment(\.displayScale) private var displayScale
    private var hairline: CGFloat { 1 / displayScale }
    private let hourHeight: CGFloat = 60
    private let timeWidth: CGFloat = 54
    private var calendar: Calendar { .current }
    private func events(on day: Date) -> [WorkspaceItem] { model.projection.eventsByDay[day] ?? [] }
    private var title: String {
        model.calendarMode == .day
            ? model.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            : model.date.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            t.border.frame(height: hairline)
            if let problem = model.problem {
                WarningBanner(text: problem, t: t).padding(Metrics.s2)
            }
            if model.calendarMode == .month { month }
            else { timeline }
            t.border.frame(height: hairline)
            HStack(spacing: Metrics.s1) {
                Keycap(text: "D", t: t); hint("Day")
                Keycap(text: "W", t: t); hint("Week")
                Keycap(text: "M", t: t); hint("Month")
                Spacer()
                hint(TimeZone.current.identifier)
            }.padding(.horizontal, Metrics.s3).padding(.vertical, Metrics.s1 + 2)
            .background(t.surfaceRail)
        }
        .background(t.surface)
        .tint(t.accent)
    }

    /// Opens the event's detail anchored to the event itself; one `selectedEvent`
    /// still guarantees only one popover is up at a time.
    private func eventButton<Label: View>(_ item: WorkspaceItem, @ViewBuilder label: () -> Label) -> some View {
        Button { selectedEvent = item } label: { label() }
            .buttonStyle(.plain)
            .help(item.title)
            .popover(isPresented: Binding(get: { selectedEvent?.id == item.id },
                                          set: { if !$0, selectedEvent?.id == item.id { selectedEvent = nil } })) {
                VStack(alignment: .leading, spacing: Metrics.s2) {
                    Text(item.section.uppercased())
                        .font(TypeScale.caption).tracking(Tracking.caption).foregroundStyle(t.inkSecondary)
                    Text(item.title).font(Typeface.ui(16, .semibold)).foregroundStyle(t.ink)
                    if let starts = item.starts {
                        Text(starts.formatted(date: .complete, time: .shortened)).font(Typeface.ui(12)).foregroundStyle(t.ink)
                    }
                    if let ends = item.ends {
                        Text("Ends " + ends.formatted(date: .abbreviated, time: .shortened)).font(Typeface.ui(12)).foregroundStyle(t.inkSecondary)
                    }
                    if item.text != item.title {
                        Text(item.text).font(Typeface.ui(12)).foregroundStyle(t.ink).textSelection(.enabled)
                    }
                    HStack { Spacer(); Button("Done") { selectedEvent = nil }.buttonStyle(GhostButtonStyle(t: t)) }
                }.padding(Metrics.s4).frame(width: 320).background(t.surface)
            }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(TypeScale.caption).foregroundStyle(t.inkSecondary).padding(.trailing, Metrics.s1)
    }

    private var toolbar: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: onCapture) { Image(systemName: "plus") }
                    .buttonStyle(GhostButtonStyle(t: t))
                    .help("Capture a new event with #cal")
                Spacer()
                Picker("Calendar view", selection: $model.calendarMode) {
                    ForEach(WorkspaceCalendarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                Spacer()
                HStack(spacing: 3) {
                    Button { model.shiftDate(-1) } label: { Image(systemName: "chevron.left") }.help("Previous · ⌘←")
                    Button("Today") { model.date = Date() }.help("Today · ⌘T")
                    Button { model.shiftDate(1) } label: { Image(systemName: "chevron.right") }.help("Next · ⌘→")
                }.buttonStyle(GhostButtonStyle(t: t))
            }.controlSize(.small)
            HStack {
                Text(title).font(TypeScale.h1).tracking(Tracking.h1).foregroundStyle(t.ink)
                Spacer()
            }
        }.padding(.horizontal, Metrics.s4).padding(.top, Metrics.s3).padding(.bottom, Metrics.s3)
            .background(t.surfaceRail)
    }

    private var month: some View {
        GeometryReader { geometry in
            let rowHeight = max(88, (geometry.size.height - 28) / CGFloat(model.days.count / 7))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(model.days.prefix(7)), id: \.self) { day in
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(TypeScale.caption).tracking(Tracking.caption).foregroundStyle(t.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 12)
                    }
                }.frame(height: 28)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                        ForEach(model.days, id: \.self) { day in
                            monthDay(day, height: rowHeight)
                        }
                    }
                }
            }
        }
    }

    private func monthDay(_ day: Date, height: CGFloat) -> some View {
        let dayEvents = events(on: day)
        let limit = max(1, Int((height - 38) / 21))
        let inMonth = calendar.isDate(day, equalTo: model.date, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Spacer()
                Button {
                    model.date = day; model.calendarMode = .day
                } label: { dateNumber(day) }.buttonStyle(.plain).help("Open " + day.formatted(date: .complete, time: .omitted))
            }.padding(.horizontal, 7).padding(.top, 5)
            ForEach(Array(dayEvents.prefix(limit))) { item in
                eventButton(item) {
                    HStack(spacing: 4) {
                        Circle().fill(t.accent).frame(width: 5, height: 5)
                        Text(item.title).foregroundStyle(CalendarLayout.isAllDay(item) ? t.accentInk : t.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        if let starts = item.starts, !CalendarLayout.isAllDay(item), calendar.isDate(starts, inSameDayAs: day) {
                            Text(starts.formatted(.dateTime.hour().minute())).foregroundStyle(t.inkSecondary).lineLimit(1)
                        }
                    }.font(Typeface.ui(11)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(CalendarLayout.isAllDay(item) ? t.accentSoft : .clear,
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            if dayEvents.count > limit {
                Button("\(dayEvents.count - limit) more…") { model.date = day; model.calendarMode = .day }
                    .buttonStyle(.plain).font(TypeScale.caption).foregroundStyle(t.inkSecondary).padding(.leading, 7)
            }
            Spacer(minLength: 0)
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(inMonth ? Color.clear : t.surfaceRail)
        .overlay(alignment: .top) { t.border.frame(height: hairline) }
        .overlay(alignment: .trailing) { t.border.frame(width: hairline) }
    }

    /// Today keeps the calendar convention of a red disc, drawn in the
    /// palette's own red so it sits with the rest of the tokens.
    private func dateNumber(_ day: Date) -> some View {
        let today = calendar.isDateInToday(day)
        return Text(day.formatted(.dateTime.day()))
            .font(Typeface.ui(13, today ? .semibold : .regular))
            .foregroundStyle(today ? t.surface : t.ink)
            .frame(width: 25, height: 25)
            .background(today ? t.priHigh : .clear, in: Circle())
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: timeWidth, height: 41)
                ForEach(model.days, id: \.self) { day in
                    HStack(spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(TypeScale.caption).tracking(Tracking.caption).foregroundStyle(t.inkSecondary)
                        dateNumber(day)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }.fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(Typeface.ui(10)).foregroundStyle(t.inkSecondary)
                    .frame(width: timeWidth, alignment: .trailing).padding(.top, 6)
                ForEach(model.days, id: \.self) { day in
                    VStack(spacing: 3) {
                        ForEach(events(on: day).filter { CalendarLayout.isAllDay($0) }) { item in
                            eventButton(item) {
                                Text(item.title).font(Typeface.ui(11)).foregroundStyle(t.accentInk)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(4).background(t.accentSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                    }.padding(4).frame(maxWidth: .infinity, minHeight: 30)
                }
            }.fixedSize(horizontal: false, vertical: true)
            t.border.frame(height: hairline)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in
                                Text(String(format: "%02d:00", hour)).font(Typeface.mono(10)).foregroundStyle(t.inkSecondary)
                                    .frame(width: timeWidth - 8, height: hourHeight, alignment: .topTrailing).padding(.trailing, 8)
                                    .id(hour)
                            }
                        }
                        ForEach(model.days, id: \.self) { day in
                            timelineDay(day)
                        }
                    }.padding(.top, 6)
                }
                .onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
    }

    private func timelineDay(_ day: Date) -> some View {
        let dayEvents = events(on: day)
        let byID = Dictionary(dayEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0..<24) { hour in
                    t.border.frame(height: hairline).offset(y: CGFloat(hour) * hourHeight)
                    t.border.opacity(0.4).frame(height: hairline).offset(y: (CGFloat(hour) + 0.5) * hourHeight)
                }
                ForEach(CalendarLayout.segments(items: dayEvents, day: day)) { segment in
                    if let item = byID[segment.id] {
                        let width = max(1, (geometry.size.width - 4) / CGFloat(segment.columnCount))
                        eventButton(item) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(Typeface.ui(11, .medium)).foregroundStyle(t.accentInk).lineLimit(2)
                                if segment.endMinute - segment.startMinute >= 40, let starts = item.starts {
                                    Text(starts.formatted(date: .omitted, time: .shortened)).font(Typeface.ui(10)).foregroundStyle(t.accentInk)
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 5).padding(.vertical, 3)
                                .frame(width: max(1, width - 2), height: max(18, CGFloat(segment.endMinute - segment.startMinute) / 60 * hourHeight - 1), alignment: .topLeading)
                                .background(t.accentSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(t.accent).frame(width: 3) }
                                .clipped()
                        }
                            .offset(x: CGFloat(segment.column) * width + 2, y: CGFloat(segment.startMinute) / 60 * hourHeight)
                    }
                }
                if calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let parts = calendar.dateComponents([.hour, .minute], from: context.date)
                        let y = CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 60 * hourHeight
                        Rectangle().fill(t.priHigh).frame(height: 1).overlay(alignment: .leading) {
                            Circle().fill(t.priHigh).frame(width: 5, height: 5)
                        }.offset(y: y)
                    }.allowsHitTesting(false)
                }
            }
        }.frame(maxWidth: .infinity).frame(height: hourHeight * 24)
            .overlay(alignment: .leading) { t.border.frame(width: hairline) }
    }
}

#if DEBUG
#Preview("Calendar · month") {
    NativeCalendarView(model: .preview(destination: .calendar), onCapture: {})
        .frame(width: 900, height: 640)
}

#Preview("Calendar · week · dark") {
    NativeCalendarView(model: .preview(destination: .calendar, calendarMode: .week), onCapture: {})
        .frame(width: 900, height: 640)
        .preferredColorScheme(.dark)
}
#endif
