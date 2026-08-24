import Foundation
import Testing
@testable import CalendarDomain

@Suite("CalendarItemCopyTests")
struct CalendarItemCopyTests {
    @Test func copyShiftsTimedItemToTodayAndLeavesSourceUnchanged() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000803")!
        let sourceDate = CalendarDate(year: 2026, month: 8, day: 3)!
        let today = CalendarDate(year: 2026, month: 8, day: 24)!
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let source = try CalendarItem(
            id: sourceID,
            kind: .task,
            title: "产品同步",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: sourceDate,
                endDate: sourceDate,
                startTime: MinuteOfDay(hour: 9, minute: 30)!,
                endTime: MinuteOfDay(hour: 10, minute: 15)!
            ),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            priority: .p1,
            isPinned: true,
            notes: "带上纪要",
            completedAt: now,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var state = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        state.items[source.id] = source

        let copy = try CalendarItemCopy.oneOff(from: source, to: today, id: copyID, now: now)
        let afterCopy = try CalendarReducer.reduce(
            state,
            command: .createItem(copy),
            now: now
        )

        #expect(afterCopy.items[sourceID] == source)
        let stored = try #require(afterCopy.items[copyID])
        #expect(stored.title == "产品同步")
        #expect(stored.categoryID == categoryID)
        #expect(stored.kind == .task)
        #expect(stored.priority == .p1)
        #expect(stored.isPinned == false)
        #expect(stored.notes == "带上纪要")
        #expect(stored.completedAt == nil)
        #expect(stored.creationTimeZoneIdentifier == "Asia/Shanghai")
        #expect(stored.schedule.startDate == today)
        #expect(stored.schedule.endDate == today)
        #expect(stored.schedule.startTime == MinuteOfDay(hour: 9, minute: 30)!)
        #expect(stored.schedule.endTime == MinuteOfDay(hour: 10, minute: 15)!)
        #expect(stored.createdAt == now)
        #expect(stored.updatedAt == now)
    }

    @Test func copyPreservesMultiDayDurationThenMoveIsIndependent() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000804")!
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000805")!
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000806")!
        let today = CalendarDate(year: 2026, month: 8, day: 24)!
        let destination = CalendarDate(year: 2026, month: 8, day: 27)!
        let now = Date(timeIntervalSince1970: 1_756_000_100)
        let source = try CalendarItem(
            id: sourceID,
            kind: .task,
            title: "出差",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 6)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 8)!,
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var state = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        state.items[source.id] = source

        let copy = try CalendarItemCopy.oneOff(from: source, to: today, id: copyID, now: now)
        let afterCopy = try CalendarReducer.reduce(state, command: .createItem(copy), now: now)
        #expect(afterCopy.items[copyID]?.schedule.startDate == today)
        #expect(afterCopy.items[copyID]?.schedule.endDate == CalendarDate(year: 2026, month: 8, day: 26)!)

        let afterMove = try CalendarReducer.reduce(
            afterCopy,
            command: .moveItem(copyID, to: destination),
            now: now
        )
        #expect(afterMove.items[sourceID]?.schedule == source.schedule)
        #expect(afterMove.items[copyID]?.schedule.startDate == destination)
        #expect(afterMove.items[copyID]?.schedule.endDate == CalendarDate(year: 2026, month: 8, day: 29)!)
        #expect(afterMove.items[copyID]?.schedule.startTime == MinuteOfDay(hour: 23, minute: 0)!)
        #expect(afterMove.items[copyID]?.schedule.endTime == MinuteOfDay(hour: 1, minute: 0)!)
    }

    @Test func copyFromOccurrenceCreatesOneOffUsingDisplayedSchedule() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000807")!
        let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000808")!
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000809")!
        let originalDate = CalendarDate(year: 2026, month: 8, day: 3)!
        let displayedDate = CalendarDate(year: 2026, month: 8, day: 5)!
        let today = CalendarDate(year: 2026, month: 8, day: 24)!
        let now = Date(timeIntervalSince1970: 1_756_000_200)
        let occurrence = CalendarOccurrence(
            key: OccurrenceKey(seriesID: seriesID, originalDate: originalDate),
            schedule: try CalendarSchedule(
                startDate: displayedDate,
                endDate: displayedDate,
                startTime: MinuteOfDay(hour: 14, minute: 0)!,
                endTime: MinuteOfDay(hour: 15, minute: 0)!
            ),
            title: "改期周会",
            kind: .event,
            categoryID: categoryID,
            priority: .p2,
            isPinned: true,
            notes: "会议室 B",
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: now,
            createdAt: .distantPast
        )

        let copy = try CalendarItemCopy.oneOff(
            from: ProjectedItem.occurrence(occurrence),
            to: today,
            id: copyID,
            now: now
        )
        #expect(copy.id == copyID)
        #expect(copy.kind == .task)
        #expect(copy.title == "改期周会")
        #expect(copy.priority == .p2)
        #expect(copy.isPinned == false)
        #expect(copy.completedAt == nil)
        #expect(copy.notes == "会议室 B")
        #expect(copy.schedule.startDate == today)
        #expect(copy.schedule.startTime == MinuteOfDay(hour: 14, minute: 0)!)
        #expect(copy.schedule.endTime == MinuteOfDay(hour: 15, minute: 0)!)
    }
}
