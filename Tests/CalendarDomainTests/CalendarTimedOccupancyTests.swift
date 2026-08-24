import Foundation
import Testing
@testable import CalendarDomain

@Suite("CalendarTimedOccupancyTests")
struct CalendarTimedOccupancyTests {
    private let day = CalendarDate(year: 2026, month: 8, day: 3)!
    private let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
    private let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000404")!

    @Test func touchingTimedRangesDoNotOverlap() throws {
        let first = try schedule(day: day, start: (9, 0), end: (9, 30))
        let second = try schedule(day: day, start: (9, 30), end: (10, 0))
        #expect(CalendarTimedOccupancy.overlaps(first, second) == false)
        #expect(CalendarTimedOccupancy.overlaps(second, first) == false)
    }

    @Test func containedAndIdenticalTimedRangesOverlap() throws {
        let outer = try schedule(day: day, start: (9, 0), end: (10, 0))
        let inner = try schedule(day: day, start: (9, 15), end: (9, 45))
        let same = try schedule(day: day, start: (9, 0), end: (10, 0))
        let adjacentBefore = try schedule(day: day, start: (8, 0), end: (9, 0))
        let overlappingBefore = try schedule(day: day, start: (8, 0), end: (9, 1))

        #expect(CalendarTimedOccupancy.overlaps(outer, inner))
        #expect(CalendarTimedOccupancy.overlaps(inner, outer))
        #expect(CalendarTimedOccupancy.overlaps(outer, same))
        #expect(CalendarTimedOccupancy.overlaps(outer, adjacentBefore) == false)
        #expect(CalendarTimedOccupancy.overlaps(outer, overlappingBefore))
    }

    @Test func crossDayOvernightOccupiesHalfOpenInterval() throws {
        let overnight = try schedule(
            day: day,
            start: (23, 0),
            endDay: day.addingDays(1),
            end: (1, 0)
        )
        let interior = try schedule(day: day.addingDays(1), start: (0, 45), end: (1, 15))
        let touchingEnd = try schedule(day: day.addingDays(1), start: (1, 0), end: (2, 0))
        let previousEvening = try schedule(day: day, start: (22, 0), end: (23, 0))
        let spanning = try schedule(
            day: day,
            start: (9, 0),
            endDay: day.addingDays(2),
            end: (17, 0)
        )
        let middleDay = try schedule(day: day.addingDays(1), start: (10, 0), end: (11, 0))
        let nextDaySeparate = try schedule(day: day.addingDays(1), start: (10, 0), end: (11, 0))
        let sameClockNextDay = try schedule(day: day.addingDays(1), start: (9, 0), end: (10, 0))

        #expect(CalendarTimedOccupancy.overlaps(overnight, interior))
        #expect(CalendarTimedOccupancy.overlaps(overnight, touchingEnd) == false)
        #expect(CalendarTimedOccupancy.overlaps(overnight, previousEvening) == false)
        #expect(CalendarTimedOccupancy.overlaps(spanning, middleDay))
        #expect(CalendarTimedOccupancy.overlaps(
            try schedule(day: day, start: (9, 0), end: (10, 0)),
            nextDaySeparate
        ) == false)
        #expect(CalendarTimedOccupancy.overlaps(
            try schedule(day: day, start: (9, 0), end: (10, 0)),
            sameClockNextDay
        ) == false)
    }

    @Test func untimedSchedulesDoNotOccupyTheClock() throws {
        let timed = try schedule(day: day, start: (9, 0), end: (10, 0))
        let untimed = try CalendarSchedule(
            startDate: day,
            endDate: day,
            startTime: nil,
            endTime: nil
        )
        let untimedSpan = try CalendarSchedule(
            startDate: day,
            endDate: day.addingDays(2),
            startTime: nil,
            endTime: nil
        )

        #expect(CalendarTimedOccupancy.overlaps(timed, untimed) == false)
        #expect(CalendarTimedOccupancy.overlaps(untimed, timed) == false)
        #expect(CalendarTimedOccupancy.overlaps(untimed, untimedSpan) == false)
    }

    @Test func firstConflictReportsExistingTimedItem() throws {
        let existing = try makeItem(
            id: firstID,
            schedule: schedule(day: day, start: (9, 0), end: (10, 0))
        )
        let proposed = try makeItem(
            id: secondID,
            schedule: schedule(day: day, start: (9, 30), end: (10, 30))
        )

        #expect(
            CalendarTimedOccupancy.firstConflict(
                proposed: [proposed],
                in: state(containing: existing),
                range: CalendarDateRange(start: day, end: day.addingDays(6))
            ) == .item(firstID)
        )
    }

    @Test func firstConflictIgnoresUntimedExistingItems() throws {
        let existing = try makeItem(
            id: firstID,
            schedule: CalendarSchedule(
                startDate: day,
                endDate: day,
                startTime: nil,
                endTime: nil
            )
        )
        let proposed = try makeItem(
            id: secondID,
            schedule: schedule(day: day, start: (9, 0), end: (9, 30))
        )

        #expect(
            CalendarTimedOccupancy.firstConflict(
                proposed: [proposed],
                in: state(containing: existing),
                range: CalendarDateRange(start: day, end: day)
            ) == nil
        )
    }

    @Test func firstConflictReportsRecurrenceOccurrence() throws {
        let series = try WeeklySeries(
            id: seriesID,
            kind: .task,
            title: "周会",
            categoryID: categoryID,
            ruleStartDate: day,
            recurrenceEndDate: nil,
            weekdays: [.monday],
            durationDays: 1,
            startTime: MinuteOfDay(hour: 9, minute: 0),
            endTime: MinuteOfDay(hour: 10, minute: 0),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let occurrenceDay = day.addingDays(7)
        let proposed = try makeItem(
            id: firstID,
            schedule: schedule(day: occurrenceDay, start: (9, 30), end: (10, 30))
        )
        var calendar = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        calendar.recurrence.series[series.id] = series

        #expect(
            CalendarTimedOccupancy.firstConflict(
                proposed: [proposed],
                in: calendar,
                range: CalendarDateRange(start: occurrenceDay, end: occurrenceDay.addingDays(6))
            ) == .occurrence(OccurrenceKey(seriesID: seriesID, originalDate: occurrenceDay))
        )
    }

    @Test func firstConflictReportsProposedItemsThatOverlapEachOther() throws {
        let first = try makeItem(
            id: firstID,
            schedule: schedule(day: day, start: (9, 0), end: (10, 0))
        )
        let second = try makeItem(
            id: secondID,
            schedule: schedule(day: day, start: (9, 30), end: (10, 30))
        )
        let touching = try makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000405")!,
            schedule: schedule(day: day, start: (10, 0), end: (11, 0))
        )

        #expect(
            CalendarTimedOccupancy.firstConflict(
                proposed: [first, second],
                in: CalendarState.empty(uncategorizedID: categoryID, now: .distantPast),
                range: CalendarDateRange(start: day, end: day)
            ) == .proposed(firstID, secondID)
        )
        #expect(
            CalendarTimedOccupancy.firstConflict(
                proposed: [first, touching],
                in: CalendarState.empty(uncategorizedID: categoryID, now: .distantPast),
                range: CalendarDateRange(start: day, end: day)
            ) == nil
        )
    }

    @Test func firstConflictPrefersExistingOccupancyOverProposedSelfConflict() throws {
        let existing = try makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000406")!,
            schedule: schedule(day: day, start: (9, 0), end: (9, 30))
        )
        let first = try makeItem(
            id: firstID,
            schedule: schedule(day: day, start: (9, 15), end: (9, 45))
        )
        let second = try makeItem(
            id: secondID,
            schedule: schedule(day: day, start: (9, 30), end: (10, 0))
        )

        #expect(
            CalendarTimedOccupancy.firstConflict(
                proposed: [first, second],
                in: state(containing: existing),
                range: CalendarDateRange(start: day, end: day)
            ) == .item(existing.id)
        )
    }

    private func schedule(
        day: CalendarDate,
        start: (Int, Int),
        endDay: CalendarDate? = nil,
        end: (Int, Int)
    ) throws -> CalendarSchedule {
        try CalendarSchedule(
            startDate: day,
            endDate: endDay ?? day,
            startTime: MinuteOfDay(hour: start.0, minute: start.1),
            endTime: MinuteOfDay(hour: end.0, minute: end.1)
        )
    }

    private func makeItem(id: UUID, schedule: CalendarSchedule) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            kind: .task,
            title: "事项",
            categoryID: categoryID,
            schedule: schedule,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func state(containing item: CalendarItem) -> CalendarState {
        var result = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        result.items[item.id] = item
        return result
    }
}
