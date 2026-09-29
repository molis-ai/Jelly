import CalendarDomain
import SwiftUI

/// Continuous civil-date weeks, using the desktop's bounded window and
/// multi-day lane projection. Selecting a day opens the agenda below it.
struct MobileMonthStream: View {
    let workspace: MobileWorkspace
    @Binding var selectedDay: CalendarDate
    let hiddenCategories: Set<UUID>
    let open: (ProjectedEntry) -> Void
    let create: (CalendarDate) -> Void
    @State private var stream: WeekStreamModel
    @State private var visibleWeek: CalendarDate?
    @State private var selectedInStream = false
    @State private var navigationWeek: CalendarDate?
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var laneHeight = 44.0

    init(workspace: MobileWorkspace, selectedDay: Binding<CalendarDate>,
         hiddenCategories: Set<UUID>, open: @escaping (ProjectedEntry) -> Void,
         create: @escaping (CalendarDate) -> Void) {
        self.workspace = workspace
        _selectedDay = selectedDay
        self.hiddenCategories = hiddenCategories
        self.open = open
        self.create = create
        _stream = State(initialValue: WeekStreamModel(centeredOn: selectedDay.wrappedValue))
    }

    private var theme: CalendarSemanticAppearance { CalendarTheme.appearance(for: colorScheme) }
    private var today: CalendarDate { .localDay(containing: Date(), in: .current) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Button("上个月", systemImage: "chevron.left") { jump(stream.jumpTargetForPreviousMonth(), preservingCivilDayIntent: true, proxy: proxy) }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    Spacer()
                    Text("\(String(stream.monthTitleDate.year))年\(stream.monthTitleDate.month)月").font(.headline)
                    Spacer()
                    Button("今天") { jump(today, preservingCivilDayIntent: false, proxy: proxy) }.frame(minHeight: 44)
                    Button("下个月", systemImage: "chevron.right") { jump(stream.jumpTargetForNextMonth(), preservingCivilDayIntent: true, proxy: proxy) }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                HStack(spacing: 0) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { label in
                        Text(label).font(.caption).foregroundStyle(theme.secondaryText).frame(maxWidth: .infinity)
                    }
                }.frame(height: 24)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(stream.weekStarts, id: \.self) { week in
                            weekRow(week).id(week)
                        }
                    }.scrollTargetLayout()
                }
                .scrollPosition(id: $visibleWeek, anchor: .top)
                .onAppear { proxy.scrollTo(WeekStreamModel.weekStart(containing: selectedDay), anchor: .top) }
                .onChange(of: visibleWeek) { _, week in
                    guard let week, stream.weekStarts.contains(week) else { return }
                    // Month navigation intentionally chooses a focus week that
                    // belongs to the destination month. Do not reinterpret it
                    // as a fresh user scroll and reset the retained day intent.
                    if navigationWeek != week { stream.updateFocus(toWeekStarting: week) }
                    navigationWeek = nil
                    // The same bounded window rule as desktop. Native scroll
                    // positioning preserves the visible week when rows extend.
                    if let first = stream.weekStarts.first, first.days(until: week) <= 14 {
                        _ = stream.extendEarlier(visibleWeek: week, pixelOffset: 0)
                    } else if let last = stream.weekStarts.last, week.days(until: last) <= 14 {
                        _ = stream.extendLater(visibleWeek: week, pixelOffset: 0)
                    }
                }
                .onChange(of: selectedDay) { _, date in
                    if selectedInStream { selectedInStream = false; return }
                    scroll(to: date, proxy: proxy)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: min(480, 68 + 2 * (44 + 2 * laneHeight + 44)))
        .accessibilityIdentifier("continuous-month-calendar")
    }

    private func weekRow(_ week: CalendarDate) -> some View {
        let entries = TimelineProjection.make(in: .init(start: week, end: week.addingDays(6)),
            state: workspace.store.calendarState, hiddenCategoryIDs: hiddenCategories).entries
        let layout = WeekSegmentLayout.make(entries: entries, weekStarts: [week], laneCapacity: 2)[0]
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { column in
                    let date = week.addingDays(column)
                    Button { select(date) } label: {
                        Text(date.day == 1 ? "\(date.month)/1" : "\(date.day)")
                            .font(.subheadline.weight(date == today ? .bold : .regular))
                            .foregroundStyle(date == selectedDay ? theme.canvas : date == today ? theme.controlAccent : theme.primaryText)
                            .frame(width: 36, height: 36)
                            .background(date == selectedDay ? theme.controlAccent : Color.clear, in: Circle())
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(String(date.year))年\(date.month)月\(date.day)日")
                        .accessibilityAddTraits(date == selectedDay ? .isSelected : [])
                        .contextMenu { Button("在这天添加", systemImage: "plus") { create(date) } }
                }
            }
            GeometryReader { geometry in
                let cellWidth = geometry.size.width / 7
                ZStack(alignment: .topLeading) {
                    ForEach(layout.segments) { segment in
                        let entry = segment.entry
                        let color = CalendarTheme.categoryAccent(
                            workspace.store.calendarState.categories[entry.categoryID]?.colorHex ?? "#8C8F96",
                            appearance: colorScheme == .dark ? .dark : .light)
                        Button { open(entry) } label: {
                            HStack(spacing: 3) {
                                if !segment.showsLeadingHandle { Image(systemName: "chevron.left").font(.caption2) }
                                if entry.completedAt != nil { Image(systemName: "checkmark").font(.caption2) }
                                Text(entry.title).font(.caption).lineLimit(1)
                                if !segment.showsTrailingHandle { Image(systemName: "chevron.right").font(.caption2) }
                            }
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: laneHeight - 4, alignment: .leading)
                            .foregroundStyle(theme.primaryText)
                            .background(color.opacity(entry.completedAt == nil ? 0.20 : 0.10), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3) }
                            .frame(height: laneHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(0, cellWidth * CGFloat(segment.endColumn - segment.startColumn + 1) - 4))
                        .offset(x: cellWidth * CGFloat(segment.startColumn) + 2, y: laneHeight * CGFloat(segment.lane))
                        .accessibilityLabel("\(entry.title)，\(entry.schedule.startDate.month)月\(entry.schedule.startDate.day)日至\(entry.schedule.endDate.month)月\(entry.schedule.endDate.day)日")
                    }
                }
            }.frame(height: laneHeight * 2)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { column in
                    let date = week.addingDays(column)
                    let count = layout.overflowByDate[date] ?? 0
                    Button { select(date) } label: {
                        Text(count > 0 ? "+\(count)" : " ").font(.caption).foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("查看\(date.month)月\(date.day)日的全部事项")
                }
            }
            Divider()
        }
    }

    private func select(_ date: CalendarDate) {
        guard date != selectedDay else { return }
        selectedInStream = true
        selectedDay = date
        stream.updateSelection(to: date)
    }

    private func jump(_ date: CalendarDate, preservingCivilDayIntent: Bool, proxy: ScrollViewProxy) {
        if selectedDay != date {
            selectedInStream = true
            selectedDay = date
        }
        scroll(to: date, preservingCivilDayIntent: preservingCivilDayIntent, proxy: proxy)
    }

    private func scroll(to date: CalendarDate, preservingCivilDayIntent: Bool = false, proxy: ScrollViewProxy) {
        stream.moveFocus(to: date, preservingCivilDayIntent: preservingCivilDayIntent)
        stream.recenterWindowAroundFocusIfNeeded()
        navigationWeek = stream.focusWeek
        visibleWeek = stream.focusWeek
        proxy.scrollTo(stream.focusWeek, anchor: .top)
    }
}
