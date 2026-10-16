import SwiftUI

struct NativeCalendarView: View {
    @Bindable var model: WorkspaceModel
    let onCapture: () -> Void
    @State private var selectedEvent: WorkspaceItem?
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
            Divider()
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(8)
            }
            if model.calendarMode == .month { month }
            else { timeline }
            Divider()
            HStack {
                Text("D Day   W Week   M Month").font(.caption)
                Spacer()
                Text(TimeZone.current.identifier).font(.caption)
            }.foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Opens the event's detail anchored to the event itself; one `selectedEvent`
    /// still guarantees only one popover is up at a time.
    private func eventButton<Label: View>(_ item: WorkspaceItem, @ViewBuilder label: () -> Label) -> some View {
        Button { selectedEvent = item } label: { label() }
            .buttonStyle(.plain)
            .help(item.title)
            .popover(isPresented: Binding(get: { selectedEvent?.id == item.id },
                                          set: { if !$0, selectedEvent?.id == item.id { selectedEvent = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    if let starts = item.starts { Text(starts.formatted(date: .complete, time: .shortened)) }
                    if let ends = item.ends { Text("Ends " + ends.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                    Text(item.section).font(.caption).foregroundStyle(.secondary)
                    if item.text != item.title { Text(item.text).textSelection(.enabled) }
                    Button("Done") { selectedEvent = nil }
                }.padding(22).frame(width: 320)
            }
    }

    private var toolbar: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: onCapture) { Image(systemName: "plus") }.help("Capture a new event with #cal")
                Spacer()
                Picker("Calendar view", selection: $model.calendarMode) {
                    ForEach(WorkspaceCalendarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                Spacer()
                HStack(spacing: 3) {
                    Button { model.shiftDate(-1) } label: { Image(systemName: "chevron.left") }.help("Previous · ⌘←")
                    Button("Today") { model.date = Date() }.help("Today · ⌘T")
                    Button { model.shiftDate(1) } label: { Image(systemName: "chevron.right") }.help("Next · ⌘→")
                }
            }.controlSize(.small)
            HStack {
                Text(title).font(.system(size: 27, weight: .regular))
                Spacer()
            }
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
            .background(.bar)
    }

    private var month: some View {
        GeometryReader { geometry in
            let rowHeight = max(88, (geometry.size.height - 28) / CGFloat(model.days.count / 7))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(model.days.prefix(7)), id: \.self) { day in
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        Text(item.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if let starts = item.starts, !CalendarLayout.isAllDay(item), calendar.isDate(starts, inSameDayAs: day) {
                            Text(starts.formatted(.dateTime.hour().minute())).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(CalendarLayout.isAllDay(item) ? Color.accentColor.opacity(0.12) : .clear)
                }
            }
            if dayEvents.count > limit {
                Button("\(dayEvents.count - limit) more…") { model.date = day; model.calendarMode = .day }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary).padding(.leading, 7)
            }
            Spacer(minLength: 0)
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(inMonth ? Color.clear : Color.secondary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5) }
    }

    private func dateNumber(_ day: Date) -> some View {
        Text(day.formatted(.dateTime.day()))
            .font(.system(size: 13, weight: calendar.isDateInToday(day) ? .semibold : .regular))
            .foregroundStyle(calendar.isDateInToday(day) ? Color.white : .primary)
            .frame(width: 25, height: 25)
            .background(calendar.isDateInToday(day) ? Color.red : .clear, in: Circle())
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: timeWidth, height: 41)
                ForEach(model.days, id: \.self) { day in
                    HStack(spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        dateNumber(day)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }.fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: timeWidth, alignment: .trailing).padding(.top, 6)
                ForEach(model.days, id: \.self) { day in
                    VStack(spacing: 3) {
                        ForEach(events(on: day).filter { CalendarLayout.isAllDay($0) }) { item in
                            eventButton(item) {
                                Text(item.title).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(4).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }.padding(4).frame(maxWidth: .infinity, minHeight: 30)
                }
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in
                                Text(String(format: "%02d:00", hour)).font(.system(size: 10)).foregroundStyle(.secondary)
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
                    Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 0.5).offset(y: CGFloat(hour) * hourHeight)
                    Rectangle().fill(Color.secondary.opacity(0.07)).frame(height: 0.5).offset(y: (CGFloat(hour) + 0.5) * hourHeight)
                }
                ForEach(CalendarLayout.segments(items: dayEvents, day: day)) { segment in
                    if let item = byID[segment.id] {
                        let width = max(1, (geometry.size.width - 4) / CGFloat(segment.columnCount))
                        eventButton(item) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                if segment.endMinute - segment.startMinute >= 40, let starts = item.starts {
                                    Text(starts.formatted(date: .omitted, time: .shortened)).font(.system(size: 10))
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 5).padding(.vertical, 3)
                                .frame(width: max(1, width - 2), height: max(18, CGFloat(segment.endMinute - segment.startMinute) / 60 * hourHeight - 1), alignment: .topLeading)
                                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 3) }
                                .clipped()
                        }
                            .offset(x: CGFloat(segment.column) * width + 2, y: CGFloat(segment.startMinute) / 60 * hourHeight)
                    }
                }
                if calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let parts = calendar.dateComponents([.hour, .minute], from: context.date)
                        let y = CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 60 * hourHeight
                        Rectangle().fill(.red).frame(height: 1).overlay(alignment: .leading) {
                            Circle().fill(.red).frame(width: 5, height: 5)
                        }.offset(y: y)
                    }.allowsHitTesting(false)
                }
            }
        }.frame(maxWidth: .infinity).frame(height: hourHeight * 24)
            .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5) }
    }
}
