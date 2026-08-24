import CalendarDomain
import Combine
import Foundation

struct WeekTimedBlock: Identifiable, Equatable, Sendable {
    let id: String
    let entry: ProjectedEntry
    /// 0...6 within the focused week (Monday = 0).
    let dayIndex: Int
    /// Minutes from local midnight on that day column, inclusive start.
    let startMinute: Int
    /// Minutes from local midnight on that day column, exclusive end (0...1440).
    let endMinute: Int

    var durationMinutes: Int { max(0, endMinute - startMinute) }
}

struct WeekAllDayItem: Identifiable, Equatable, Sendable {
    let id: String
    let entry: ProjectedEntry
    let dayIndex: Int
}

@MainActor
final class WeekViewModel: ObservableObject {
    @Published private(set) var weekStart: CalendarDate
    @Published private(set) var today: CalendarDate
    @Published private(set) var state: CalendarState
    @Published private(set) var hiddenCategoryIDs: Set<UUID>

    private var timeline = TimelineProjection(entries: [])
    private var hasConsumedInitialAutoScroll = false

    init(
        weekStart: CalendarDate,
        today: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>
    ) {
        self.weekStart = WeekStreamModel.weekStart(containing: weekStart)
        self.today = today
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        rebuild()
    }

    var dayStarts: [CalendarDate] {
        (0..<7).map { weekStart.addingDays($0) }
    }

    var weekEnd: CalendarDate {
        weekStart.addingDays(6)
    }

    var title: String {
        let end = weekEnd
        if weekStart.year == end.year, weekStart.month == end.month {
            return "\(weekStart.year)年\(weekStart.month)月\(weekStart.day)日 – \(end.day)日"
        }
        if weekStart.year == end.year {
            return "\(weekStart.year)年\(weekStart.month)月\(weekStart.day)日 – \(end.month)月\(end.day)日"
        }
        return "\(weekStart.year)年\(weekStart.month)月\(weekStart.day)日 – \(end.year)年\(end.month)月\(end.day)日"
    }

    var projectedEntries: [ProjectedEntry] {
        timeline.entries
    }

    func update(
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    ) {
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.today = today
        rebuild()
    }

    func goToPreviousWeek() {
        weekStart = weekStart.addingDays(-7)
        rebuild()
    }

    func goToNextWeek() {
        weekStart = weekStart.addingDays(7)
        rebuild()
    }

    func goToToday() {
        weekStart = WeekStreamModel.weekStart(containing: today)
        rebuild()
    }

    func focus(on date: CalendarDate) {
        let next = WeekStreamModel.weekStart(containing: date)
        guard next != weekStart else { return }
        weekStart = next
        rebuild()
    }

    nonisolated static func currentMinuteOfDay(
        from date: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// Hour target for the first week-grid appearance, or nil once consumed.
    /// The flag lives on the view-model (which survives month↔week teardown),
    /// so a later mode switch never yanks the grid away from user scrolling.
    func takeInitialAutoScrollHour(nowMinuteOfDay: Int) -> Int? {
        guard !hasConsumedInitialAutoScroll else { return nil }
        hasConsumedInitialAutoScroll = true
        return WeekTimeGridMetrics.initialAutoScrollHour(forNowMinuteOfDay: nowMinuteOfDay)
    }

    func allDayItems(on dayIndex: Int) -> [WeekAllDayItem] {
        guard dayStarts.indices.contains(dayIndex) else { return [] }
        let day = dayStarts[dayIndex]
        return projectedEntries.compactMap { entry in
            let schedule = entry.schedule
            guard schedule.startTime == nil else { return nil }
            guard schedule.startDate <= day, schedule.endDate >= day else { return nil }
            let projected = ProjectedItem(entry: entry)
            return WeekAllDayItem(
                id: "allday:\(projected.id)-\(dayIndex)",
                entry: entry,
                dayIndex: dayIndex
            )
        }
    }

    func timedBlocks() -> [WeekTimedBlock] {
        Self.timedBlocks(entries: projectedEntries, weekStart: weekStart)
    }

    nonisolated static func timedBlocks(
        entries: [ProjectedEntry],
        weekStart: CalendarDate
    ) -> [WeekTimedBlock] {
        let weekEnd = weekStart.addingDays(6)
        var blocks: [WeekTimedBlock] = []
        for entry in entries {
            let schedule = entry.schedule
            guard let startTime = schedule.startTime, let endTime = schedule.endTime else {
                continue
            }
            var day = max(schedule.startDate, weekStart)
            let last = min(schedule.endDate, weekEnd)
            while day <= last {
                let dayIndex = weekStart.days(until: day)
                let startMinute: Int
                let endMinute: Int
                if schedule.startDate == schedule.endDate {
                    startMinute = startTime.value
                    // Minimum 15 minutes visual height for short events.
                    endMinute = max(endTime.value, startTime.value + 15)
                } else if day == schedule.startDate {
                    startMinute = startTime.value
                    endMinute = 24 * 60
                } else if day == schedule.endDate {
                    startMinute = 0
                    // endTime 00:00 on the end day means the block ended at midnight.
                    endMinute = endTime.value
                } else {
                    startMinute = 0
                    endMinute = 24 * 60
                }
                if endMinute > startMinute {
                    let projected = ProjectedItem(entry: entry)
                    blocks.append(WeekTimedBlock(
                        id: "timed:\(projected.id)-\(dayIndex)-\(startMinute)-\(endMinute)",
                        entry: entry,
                        dayIndex: dayIndex,
                        startMinute: startMinute,
                        endMinute: min(endMinute, 24 * 60)
                    ))
                }
                day = day.addingDays(1)
            }
        }
        return blocks
    }

    private func rebuild() {
        let range = CalendarDateRange(start: weekStart, end: weekEnd)
        timeline = TimelineProjection.make(
            in: range,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        )
        objectWillChange.send()
    }
}

extension ProjectedItem {
    init(entry: ProjectedEntry) {
        switch entry {
        case let .item(item):
            self = .item(item)
        case let .occurrence(occurrence):
            self = .occurrence(occurrence)
        }
    }
}
