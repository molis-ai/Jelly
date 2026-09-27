import CalendarDomain
import Foundation
import SwiftUI

/// The same civil-day schedule and 15-minute editing semantics as the desktop,
/// with larger hour rows and explicit touch handles. No persistence lives here.
enum MobileTimeGridGeometry {
    static let scale: CGFloat = 1.75
    static let hourHeight = WeekTimeGridMetrics.hourHeight * scale
    static let gridHeight = WeekTimeGridMetrics.gridHeight * scale
    static let snapMinutes = 15

    static func y(_ minute: Int) -> CGFloat { WeekTimeGridMetrics.yOffset(minute: minute) * scale }

    static func minute(at y: CGFloat) -> Int {
        let raw = Int(max(0, y) / hourHeight * 60)
        return min(1_425, max(0, raw / snapMinutes * snapMinutes))
    }

    static func deltaMinutes(for translation: CGFloat) -> Int {
        Int((translation / hourHeight * 60 / CGFloat(snapMinutes)).rounded()) * snapMinutes
    }

    static func create(on date: CalendarDate, minute: Int) throws -> CalendarSchedule {
        let start = min(1_425, max(0, minute / snapMinutes * snapMinutes))
        return try schedule(base: date, start: start, end: min(1_440, start + 60))
    }

    static func selection(on date: CalendarDate, from startY: CGFloat, to endY: CGFloat) throws -> CalendarSchedule {
        func boundary(_ y: CGFloat) -> Int {
            min(1_440, max(0, Int(y / hourHeight * 60) / snapMinutes * snapMinutes))
        }
        let a = boundary(startY), b = boundary(endY)
        let lower = min(1_425, min(a, b))
        return try schedule(base: date, start: lower, end: max(lower + snapMinutes, max(a, b)))
    }

    static func reschedule(
        _ original: CalendarSchedule, dayDelta: Int, minuteDelta: Int, resizeEnd: Bool
    ) throws -> CalendarSchedule {
        guard let start = original.startTime, let end = original.endTime else {
            return try original.shifted(byDays: dayDelta)
        }
        let startMinute = start.value
        let endMinute = original.startDate.days(until: original.endDate) * 1_440 + end.value
        let delta = dayDelta * 1_440 + minuteDelta
        if resizeEnd {
            return try schedule(base: original.startDate, start: startMinute,
                                end: max(startMinute + snapMinutes, endMinute + delta))
        }
        return try schedule(base: original.startDate, start: startMinute + delta, end: endMinute + delta)
    }

    static func band(_ schedule: CalendarSchedule, on day: CalendarDate) -> (start: Int, end: Int)? {
        guard let start = schedule.startTime, let end = schedule.endTime,
              schedule.startDate <= day, schedule.endDate >= day else { return nil }
        let lower = schedule.startDate == day ? start.value : 0
        let upper = schedule.endDate == day ? end.value : 1_440
        return upper > lower ? (lower, upper) : nil
    }

    private static func schedule(base: CalendarDate, start: Int, end: Int) throws -> CalendarSchedule {
        func components(_ value: Int) -> (CalendarDate, MinuteOfDay) {
            let offset = Int(floor(Double(value) / 1_440))
            let minute = value - offset * 1_440
            return (base.addingDays(offset), MinuteOfDay(hour: minute / 60, minute: minute % 60)!)
        }
        let (startDate, startTime) = components(start)
        let (endDate, endTime) = components(end)
        return try CalendarSchedule(startDate: startDate, endDate: endDate, startTime: startTime, endTime: endTime)
    }
}

struct MobileTimedPlacement: Identifiable {
    let block: WeekTimedBlock
    let lane: Int
    let laneCount: Int
    var id: String { block.id }
}

/// Connected overlapping intervals share columns; adjacent intervals reuse a
/// column. This keeps every simultaneous item reachable instead of covering it.
enum MobileTimedLayout {
    static func placements(_ blocks: [WeekTimedBlock]) -> [MobileTimedPlacement] {
        let sorted = blocks.sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            if $0.endMinute != $1.endMinute { return $0.endMinute > $1.endMinute }
            return $0.id < $1.id
        }
        var result: [MobileTimedPlacement] = []
        var group: [WeekTimedBlock] = []
        var groupEnd = -1
        func flush() {
            var laneEnds: [Int] = []
            var assigned: [(WeekTimedBlock, Int)] = []
            for block in group {
                let lane = laneEnds.firstIndex(where: { $0 <= block.startMinute }) ?? laneEnds.count
                if lane == laneEnds.count { laneEnds.append(block.endMinute) }
                else { laneEnds[lane] = block.endMinute }
                assigned.append((block, lane))
            }
            result.append(contentsOf: assigned.map { MobileTimedPlacement(block: $0.0, lane: $0.1, laneCount: laneEnds.count) })
            group = []
        }
        for block in sorted {
            if !group.isEmpty && block.startMinute >= groupEnd { flush(); groupEnd = -1 }
            group.append(block)
            groupEnd = max(groupEnd, block.endMinute)
        }
        flush()
        return result
    }
}

struct MobileTimeGrid: View {
    let state: CalendarState
    @Binding var selectedDay: CalendarDate
    let singleDay: Bool
    let hiddenCategoryIDs: Set<UUID>
    let isEditable: Bool
    let onOpen: (ProjectedEntry) -> Void
    let onComplete: (ProjectedEntry) -> Void
    let onCreate: (CalendarSchedule) -> Void
    let onReschedule: (ProjectedEntry, CalendarSchedule) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var gesturePreview: Preview?
    @State private var didAutoScroll = false
    @GestureState private var gestureActive = false
    private let coordinateSpace = "jelly-mobile-time-grid"

    private struct Preview {
        let entry: ProjectedEntry?
        let schedule: CalendarSchedule
        let title: String
    }

    private var theme: CalendarSemanticAppearance { CalendarTheme.appearance(for: colorScheme) }
    private var weekStart: CalendarDate { WeekStreamModel.weekStart(containing: selectedDay) }
    private var dates: [CalendarDate] { singleDay ? [selectedDay] : (0..<7).map { weekStart.addingDays($0) } }
    private var entries: [ProjectedEntry] {
        TimelineProjection.make(in: .init(start: dates[0], end: dates[dates.count - 1]), state: state,
                                hiddenCategoryIDs: hiddenCategoryIDs).entries
    }
    private var blocks: [WeekTimedBlock] { WeekViewModel.timedBlocks(entries: entries, weekStart: weekStart) }

    var body: some View {
        GeometryReader { geometry in
            let gutter = WeekTimeGridMetrics.gutterWidth
            let columnWidth = singleDay ? max(1, geometry.size.width - gutter) : max(180, (geometry.size.width - gutter) / 7)
            let totalWidth = gutter + columnWidth * CGFloat(dates.count)
            ScrollViewReader { horizontal in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        headers(columnWidth: columnWidth)
                        allDayStrip(columnWidth: columnWidth)
                        ScrollViewReader { vertical in
                            ScrollView(.vertical) {
                                ZStack(alignment: .topLeading) {
                                    hourLabels
                                    HStack(spacing: 0) {
                                        Color.clear.frame(width: gutter)
                                        ForEach(dates, id: \.self) { date in
                                            dayColumn(date, width: columnWidth)
                                        }
                                    }
                                    if let gesturePreview { preview(gesturePreview, columnWidth: columnWidth) }
                                }
                                .frame(width: totalWidth, height: MobileTimeGridGeometry.gridHeight)
                                .coordinateSpace(name: coordinateSpace)
                            }
                            .scrollDisabled(gestureActive)
                            .onAppear {
                                guard !didAutoScroll else { return }
                                didAutoScroll = true
                                let hour = WeekTimeGridMetrics.initialAutoScrollHour(forNowMinuteOfDay: WeekViewModel.currentMinuteOfDay())
                                vertical.scrollTo("time-\(hour)", anchor: .top)
                            }
                        }
                    }.frame(width: totalWidth, height: geometry.size.height)
                }
                .scrollDisabled(gestureActive)
                .onAppear { horizontal.scrollTo(selectedDay, anchor: .leading) }
                .onChange(of: selectedDay) { _, value in
                    gesturePreview = nil
                    horizontal.scrollTo(value, anchor: .leading)
                }
                .onChange(of: gestureActive) { _, active in if !active { gesturePreview = nil } }
            }
        }
        .accessibilityHint("左右滚动查看其他日期，上下滚动查看时间。长按空白新增，长按事项移动，拖动底部手柄调整结束时间。")
    }

    private func headers(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("时间").font(.caption).foregroundStyle(theme.secondaryText).frame(width: WeekTimeGridMetrics.gutterWidth)
            ForEach(dates, id: \.self) { date in
                Button { selectedDay = date } label: {
                    HStack(spacing: 5) {
                        Text("\(date.month)/\(date.day)").fontWeight(date == selectedDay ? .bold : .regular)
                        Text(["一", "二", "三", "四", "五", "六", "日"][date.weekday.rawValue - 1]).font(.caption)
                    }.frame(width: columnWidth, height: 44)
                        .background(date == selectedDay ? theme.selectionFill : theme.canvas)
                }.buttonStyle(.plain).id(date)
            }
        }.background(theme.canvas)
    }

    private func allDayStrip(columnWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("全天").font(.caption).foregroundStyle(theme.secondaryText)
                .frame(width: WeekTimeGridMetrics.gutterWidth, height: 44)
            ForEach(dates, id: \.self) { date in
                let values = entries.filter { $0.schedule.startTime == nil && $0.schedule.startDate <= date && $0.schedule.endDate >= date }
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(values) { entry in
                            Button { onOpen(entry) } label: {
                                Text(entry.title).font(.caption).lineLimit(2).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                    .padding(.horizontal, 8).background(accent(entry).opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                        Button { if let schedule = try? CalendarSchedule(startDate: date, endDate: date, startTime: nil, endTime: nil) { onCreate(schedule) } } label: {
                            Label(values.isEmpty ? "全天事项" : "添加", systemImage: "plus").font(.caption).frame(minHeight: 44)
                        }.disabled(!isEditable)
                    }.padding(4)
                }.frame(width: columnWidth, height: 92)
            }
        }.background(theme.elevatedSurface)
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).font(.caption2.monospacedDigit()).foregroundStyle(theme.secondaryText)
                    .frame(width: WeekTimeGridMetrics.gutterWidth, height: MobileTimeGridGeometry.hourHeight, alignment: .top)
                    .id("time-\(hour)")
            }
        }
    }

    private func dayColumn(_ date: CalendarDate, width: CGFloat) -> some View {
        let dayIndex = weekStart.days(until: date)
        let placements = MobileTimedLayout.placements(blocks.filter { $0.dayIndex == dayIndex })
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle().fill(theme.canvas).overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
                        .frame(height: MobileTimeGridGeometry.hourHeight)
                        .accessibilityLabel("\(date.month)月\(date.day)日 \(hour)点，新增事项")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            if isEditable, let schedule = try? MobileTimeGridGeometry.create(on: date, minute: hour * 60) { onCreate(schedule) }
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(createGesture(on: date))
            ForEach(placements) { placement in
                item(placement, on: date, columnWidth: width)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if date == CalendarDate.localDay(containing: context.date, in: .current) {
                    Rectangle().fill(theme.controlAccent).frame(height: 1.5)
                        .offset(y: MobileTimeGridGeometry.y(WeekViewModel.currentMinuteOfDay(from: context.date)))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .frame(width: width, height: MobileTimeGridGeometry.gridHeight)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.separator.opacity(0.6)).frame(width: 0.5) }
    }

    private func item(_ placement: MobileTimedPlacement, on date: CalendarDate, columnWidth: CGFloat) -> some View {
        let entry = placement.block.entry
        let band = MobileTimeGridGeometry.band(entry.schedule, on: date) ?? (placement.block.startMinute, placement.block.endMinute)
        let height = max(22, MobileTimeGridGeometry.y(band.end - band.start))
        let laneWidth = (columnWidth - 6) / CGFloat(placement.laneCount)
        let isLast = entry.schedule.endDate == date || (entry.schedule.endTime?.value == 0 && entry.schedule.endDate == date.addingDays(1))
        return VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(.caption.weight(.semibold)).lineLimit(max(1, Int(height / 26)))
            if height >= 44 { Text(timeLabel(entry.schedule)).font(.caption2.monospacedDigit()).lineLimit(1) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(width: max(1, laneWidth - 3), height: height, alignment: .topLeading)
        .foregroundStyle(accent(entry))
        .background(accent(entry).opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(accent(entry)).frame(width: 3) }
        .contentShape(Rectangle())
        .onTapGesture { onOpen(entry) }
        .gesture(editGesture(entry, on: date, columnWidth: columnWidth, resizeEnd: false))
        // The resize overlay is outside the move recognizer's view subtree.
        // A touch on the handle must not issue a second move command.
        .overlay(alignment: .bottomTrailing) {
            if isLast && isEditable {
                Image(systemName: "equal").font(.caption.bold()).foregroundStyle(accent(entry))
                    .frame(width: min(44, max(20, laneWidth - 3)), height: 24)
                    .contentShape(Rectangle())
                    .highPriorityGesture(editGesture(entry, on: date, columnWidth: columnWidth, resizeEnd: true))
                    .accessibilityLabel("调整\(entry.title)的结束时间")
                    .accessibilityAction(named: Text("延长15分钟")) { nudge(entry, minutes: 15, resizeEnd: true) }
                    .accessibilityAction(named: Text("缩短15分钟")) { nudge(entry, minutes: -15, resizeEnd: true) }
            }
        }
        .opacity(gesturePreview?.entry?.id == entry.id ? 0.4 : entry.completedAt == nil ? 1 : 0.55)
        .accessibilityLabel("\(entry.title)，\(timeLabel(entry.schedule))")
        .accessibilityAction { onOpen(entry) }
        .accessibilityAction(named: Text(entry.completedAt == nil ? "标记完成" : "重新打开")) {
            if isEditable { onComplete(entry) }
        }
        .accessibilityAction(named: Text("提前15分钟")) { if isEditable { nudge(entry, minutes: -15) } }
        .accessibilityAction(named: Text("推迟15分钟")) { if isEditable { nudge(entry, minutes: 15) } }
        .accessibilityAction(named: Text("移到前一天")) { if isEditable { nudge(entry, days: -1) } }
        .accessibilityAction(named: Text("移到后一天")) { if isEditable { nudge(entry, days: 1) } }
        .offset(x: 3 + CGFloat(placement.lane) * laneWidth, y: MobileTimeGridGeometry.y(band.start))
    }

    private func createGesture(on date: CalendarDate) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace)))
            .updating($gestureActive) { value, active, _ in if case .second(true, _) = value { active = true } }
            .onChanged { value in
                guard isEditable, case let .second(true, drag?) = value,
                      let schedule = try? MobileTimeGridGeometry.selection(on: date, from: drag.startLocation.y, to: drag.location.y) else { return }
                gesturePreview = .init(entry: nil, schedule: schedule, title: "新事项")
            }
            .onEnded { value in
                defer { gesturePreview = nil }
                guard isEditable, case let .second(true, drag?) = value,
                      let schedule = try? MobileTimeGridGeometry.selection(on: date, from: drag.startLocation.y, to: drag.location.y) else { return }
                onCreate(schedule)
            }
    }

    private func editGesture(_ entry: ProjectedEntry, on date: CalendarDate, columnWidth: CGFloat, resizeEnd: Bool) -> some Gesture {
        LongPressGesture(minimumDuration: resizeEnd ? 0.25 : 0.45).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace)))
            .updating($gestureActive) { value, active, _ in if case .second(true, _) = value { active = true } }
            .onChanged { value in
                guard isEditable, case let .second(true, drag?) = value,
                      let schedule = proposed(entry, on: date, translation: drag.translation, columnWidth: columnWidth, resizeEnd: resizeEnd) else { return }
                gesturePreview = .init(entry: entry, schedule: schedule, title: entry.title)
            }
            .onEnded { value in
                defer { gesturePreview = nil }
                guard isEditable, case let .second(true, drag?) = value,
                      let schedule = proposed(entry, on: date, translation: drag.translation, columnWidth: columnWidth, resizeEnd: resizeEnd),
                      schedule != entry.schedule else { return }
                onReschedule(entry, schedule)
            }
    }

    private func proposed(_ entry: ProjectedEntry, on date: CalendarDate, translation: CGSize, columnWidth: CGFloat, resizeEnd: Bool) -> CalendarSchedule? {
        let currentIndex = dates.firstIndex(of: date) ?? 0
        let rawDelta = singleDay ? 0 : Int((translation.width / columnWidth).rounded())
        let dayDelta = min(dates.count - 1, max(0, currentIndex + rawDelta)) - currentIndex
        return try? MobileTimeGridGeometry.reschedule(entry.schedule, dayDelta: dayDelta,
                                                     minuteDelta: MobileTimeGridGeometry.deltaMinutes(for: translation.height), resizeEnd: resizeEnd)
    }

    private func preview(_ value: Preview, columnWidth: CGFloat) -> some View {
        ForEach(Array(dates.enumerated()), id: \.element) { index, date in
            if let band = MobileTimeGridGeometry.band(value.schedule, on: date) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.title).font(.caption.bold()).lineLimit(1)
                    Text(timeLabel(value.schedule)).font(.caption2.monospacedDigit()).lineLimit(1)
                }.padding(6)
                    .frame(width: columnWidth - 8, height: max(24, MobileTimeGridGeometry.y(band.end - band.start)), alignment: .topLeading)
                    .background(theme.dragPreviewFill, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(theme.dragPreviewOutline, lineWidth: 2) }
                    .offset(x: WeekTimeGridMetrics.gutterWidth + CGFloat(index) * columnWidth + 4, y: MobileTimeGridGeometry.y(band.start))
                    .allowsHitTesting(false)
            }
        }
    }

    private func nudge(_ entry: ProjectedEntry, days: Int = 0, minutes: Int = 0, resizeEnd: Bool = false) {
        guard isEditable, let schedule = try? MobileTimeGridGeometry.reschedule(entry.schedule, dayDelta: days, minuteDelta: minutes, resizeEnd: resizeEnd), schedule != entry.schedule else { return }
        onReschedule(entry, schedule)
    }

    private func accent(_ entry: ProjectedEntry) -> Color {
        CalendarTheme.categoryAccent(state.categories[entry.categoryID]?.colorHex ?? "#8C8F96", appearance: colorScheme == .dark ? .dark : .light)
    }

    private func timeLabel(_ schedule: CalendarSchedule) -> String {
        guard let start = schedule.startTime, let end = schedule.endTime else { return "全天" }
        let suffix = schedule.endDate > schedule.startDate ? " +\(schedule.startDate.days(until: schedule.endDate))天" : ""
        return String(format: "%02d:%02d–%02d:%02d", start.value / 60, start.value % 60, end.value / 60, end.value % 60) + suffix
    }
}
