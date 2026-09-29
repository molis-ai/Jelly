import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("ReminderPlanningTests")
struct ReminderPlanningTests {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let day = CalendarDate(year: 2026, month: 10, day: 8)!

    private func date(_ day: CalendarDate, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    private func item(
        _ title: String,
        reminder: ItemReminder?,
        start: MinuteOfDay? = MinuteOfDay(hour: 15, minute: 0),
        completed: Bool = false
    ) throws -> CalendarItem {
        try CalendarItem(
            id: UUID(),
            kind: .task,
            title: title,
            categoryID: Task4Fixture.uncategorizedID,
            schedule: CalendarSchedule(
                startDate: day,
                endDate: day,
                startTime: start,
                endTime: start.flatMap { MinuteOfDay(hour: $0.value / 60 + 1, minute: 0) }
            ),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            notes: "带上合同",
            reminder: reminder,
            completedAt: completed ? Date() : nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @Test func onlyOpenItemsWithRemindersInsideTheWindowAreRequested() throws {
        var state = try Task4Fixture.workspace()
        let meeting = try item("开会", reminder: .beforeStart(minutes: 10))
        let allDay = try item("交房租", reminder: .onStartDay(at: MinuteOfDay(hour: 9, minute: 0)!), start: nil)
        let silent = try item("没提醒", reminder: nil)
        let done = try item("已完成", reminder: .beforeStart(minutes: 0), completed: true)
        for value in [meeting, allDay, silent, done] { state.calendar.items[value.id] = value }

        let now = date(day, 8)
        let requests = ReminderPlanner.requests(in: state, now: now, timeZone: zone)
        #expect(requests.map(\.title) == ["交房租", "开会"])
        #expect(requests[1].fireDate == date(day, 14, 50))
        #expect(requests[1].notes.contains("提前 10 分钟"))
        #expect(requests[1].notes.contains("带上合同"))
        #expect(requests[0].dueTime == nil)

        let muchLater = date(day.addingDays(30), 8)
        #expect(ReminderPlanner.requests(in: state, now: muchLater, timeZone: zone).isEmpty)
        let farBefore = date(day.addingDays(-90), 8)
        #expect(ReminderPlanner.requests(in: state, now: farBefore, timeZone: zone).isEmpty)
    }

    @Test func reviewReminderRollsToTomorrowAfterItsTime() {
        let state = WorkspaceState.empty(calendar: .empty(uncategorizedID: UUID(), now: Date()))
        let config = ReviewReminderConfiguration(time: MinuteOfDay(hour: 21, minute: 0)!, dueCount: 3)
        let morning = ReminderPlanner.requests(in: state, now: date(day, 9), timeZone: zone, review: config)
        #expect(morning.map(\.title) == ["回顾 3 条旧灵感"])
        #expect(morning.first?.fireDate == date(day, 21))
        let night = ReminderPlanner.requests(in: state, now: date(day, 22), timeZone: zone, review: config)
        #expect(night.first?.fireDate == date(day.addingDays(1), 21))
        let nothingDue = ReviewReminderConfiguration(time: config.time, dueCount: 0)
        #expect(ReminderPlanner.requests(in: state, now: date(day, 9), timeZone: zone, review: nothingDue).isEmpty)
    }

    @Test func planDiffsAgainstWhatWasWrittenBefore() throws {
        var state = try Task4Fixture.workspace()
        var meeting = try item("开会", reminder: .beforeStart(minutes: 10))
        let call = try item("回电话", reminder: .beforeStart(minutes: 0))
        state.calendar.items[meeting.id] = meeting
        state.calendar.items[call.id] = call
        let now = date(day, 8)
        let first = ReminderPlanner.requests(in: state, now: now, timeZone: zone)
        let plan = ReminderSyncPlanner.plan(requests: first, mapping: .init())
        #expect(plan.creates.count == 2)

        var mapping = ReminderSyncMapping()
        for request in first {
            mapping.entries[request.key] = .init(identifier: "ek-\(request.title)", fingerprint: request.fingerprint)
        }
        meeting.title = "开会（改到 3 楼）"
        state.calendar.items[meeting.id] = meeting
        state.calendar.items[call.id] = nil
        let second = ReminderSyncPlanner.plan(
            requests: ReminderPlanner.requests(in: state, now: now, timeZone: zone),
            mapping: mapping
        )
        #expect(second.creates.isEmpty)
        #expect(second.updates.map(\.identifier) == ["ek-开会"])
        #expect(second.deletes.map(\.identifier) == ["ek-回电话"])
        #expect(second.unchanged.isEmpty)
    }
}
