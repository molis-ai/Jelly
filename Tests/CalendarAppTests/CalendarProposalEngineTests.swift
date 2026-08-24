import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("CalendarProposalEngineTests")
struct CalendarProposalEngineTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let day = CalendarDate(year: 2026, month: 8, day: 3)!
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000503")!
    private let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000500")!
    private let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000504")!

    @Test func proposalUsesEarliestNonOverlappingSlotsInCandidateOrder() throws {
        let proposals = CalendarProposalEngine.propose(
            for: [candidate(30), candidate(45)],
            calendarState: try stateWithTimedItem(9, 0, 9, 30),
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 30))
        #expect(proposals[secondID]?.schedule.startTime == MinuteOfDay(hour: 10, minute: 0))
        #expect(proposals[firstID]?.schedule.endTime == MinuteOfDay(hour: 10, minute: 0))
        #expect(proposals[secondID]?.schedule.endTime == MinuteOfDay(hour: 10, minute: 45))
        #expect(proposals[firstID]?.schedule.startDate == day)
        #expect(proposals[secondID]?.schedule.startDate == day)
        #expect(proposals.count == 2)
    }

    @Test func ninetyMinuteSlotDoesNotStartAtTwentyThirty() throws {
        let proposals = CalendarProposalEngine.propose(
            for: [candidate(90)],
            calendarState: try stateWithTimedItem(9, 0, 20, 30),
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals[firstID]?.schedule.startDate == day.addingDays(1))
        #expect(proposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(proposals[firstID]?.schedule.endTime == MinuteOfDay(hour: 10, minute: 30))
    }

    @Test func lastDayNinetyMinuteOverflowReturnsNoProposal() throws {
        var calendar = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        for offset in 0...6 {
            let itemDay = day.addingDays(offset)
            let item = try makeItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000051\(offset)")!,
                schedule: timedSchedule(day: itemDay, start: (9, 0), end: (20, 30))
            )
            calendar.items[item.id] = item
        }

        let proposals = CalendarProposalEngine.propose(
            for: [candidate(90)],
            calendarState: calendar,
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals[firstID] == nil)
        #expect(proposals.isEmpty)
    }

    @Test func sevenFullDaysReturnNoProposal() throws {
        var calendar = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        for offset in 0...6 {
            let itemDay = day.addingDays(offset)
            let item = try makeItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000052\(offset)")!,
                schedule: timedSchedule(day: itemDay, start: (9, 0), end: (21, 0))
            )
            calendar.items[item.id] = item
        }

        let proposals = CalendarProposalEngine.propose(
            for: [candidate(15)],
            calendarState: calendar,
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals.isEmpty)
    }

    @Test func firstDayStartsAfterCurrentTime() throws {
        let proposals = CalendarProposalEngine.propose(
            for: [candidate(30)],
            calendarState: emptyState(),
            now: localInstant(day, 10, 7),
            timeZone: shanghai
        )
        #expect(proposals[firstID]?.schedule.startDate == day)
        #expect(proposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 10, minute: 15))
        #expect(proposals[firstID]?.schedule.endTime == MinuteOfDay(hour: 10, minute: 45))
    }

    @Test func shanghaiAndLosAngelesUseLocalCivilDays() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-08-02T16:30:00Z")!
        let shanghaiDay = CalendarDate(year: 2026, month: 8, day: 3)!
        let losAngelesDay = CalendarDate(year: 2026, month: 8, day: 2)!

        let shanghaiProposals = CalendarProposalEngine.propose(
            for: [candidate(30)],
            calendarState: emptyState(),
            now: instant,
            timeZone: shanghai
        )
        let losAngelesProposals = CalendarProposalEngine.propose(
            for: [candidate(30)],
            calendarState: emptyState(),
            now: instant,
            timeZone: losAngeles
        )

        #expect(shanghaiProposals[firstID]?.schedule.startDate == shanghaiDay)
        #expect(shanghaiProposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(losAngelesProposals[firstID]?.schedule.startDate == losAngelesDay)
        #expect(losAngelesProposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 30))
    }

    @Test func daylightSavingTransitionKeepsCivilHourGrid() throws {
        let springDay = CalendarDate(year: 2026, month: 3, day: 8)!
        let fallDay = CalendarDate(year: 2026, month: 11, day: 1)!

        let springProposals = CalendarProposalEngine.propose(
            for: [candidate(30)],
            calendarState: emptyState(),
            now: localInstant(springDay, 8, 0, timeZone: losAngeles),
            timeZone: losAngeles
        )
        #expect(springProposals[firstID]?.schedule.startDate == springDay)
        #expect(springProposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(springProposals[firstID]?.schedule.endTime == MinuteOfDay(hour: 9, minute: 30))

        let occupiedSpring = try stateWithTimedItem(
            9, 0, 21, 0,
            on: springDay,
            timeZoneIdentifier: losAngeles.identifier
        )
        let afterOccupiedSpring = CalendarProposalEngine.propose(
            for: [candidate(30)],
            calendarState: occupiedSpring,
            now: localInstant(springDay, 8, 0, timeZone: losAngeles),
            timeZone: losAngeles
        )
        #expect(afterOccupiedSpring[firstID]?.schedule.startDate == springDay.addingDays(1))
        #expect(afterOccupiedSpring[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))

        let fallProposals = CalendarProposalEngine.propose(
            for: [candidate(30)],
            calendarState: emptyState(),
            now: localInstant(fallDay, 9, 7, timeZone: losAngeles),
            timeZone: losAngeles
        )
        #expect(fallProposals[firstID]?.schedule.startDate == fallDay)
        #expect(fallProposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 15))
    }

    @Test func untimedItemDoesNotBlockProposal() throws {
        let untimed = try makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000530")!,
            schedule: CalendarSchedule(
                startDate: day,
                endDate: day,
                startTime: nil,
                endTime: nil
            )
        )
        var calendar = emptyState()
        calendar.items[untimed.id] = untimed

        let proposals = CalendarProposalEngine.propose(
            for: [candidate(30)],
            calendarState: calendar,
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(proposals[firstID]?.schedule.endTime == MinuteOfDay(hour: 9, minute: 30))
    }

    @Test func recurrenceOccurrenceBlocksProposal() throws {
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
            endTime: MinuteOfDay(hour: 9, minute: 30),
            creationTimeZoneIdentifier: shanghai.identifier,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var calendar = emptyState()
        calendar.recurrence.series[series.id] = series

        let proposals = CalendarProposalEngine.propose(
            for: [candidate(30), candidate(45, id: secondID)],
            calendarState: calendar,
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 30))
        #expect(proposals[secondID]?.schedule.startTime == MinuteOfDay(hour: 10, minute: 0))
    }

    @Test func unselectedActionsAreOmittedAndDoNotOccupy() throws {
        let skipped = candidate(
            60,
            id: firstID,
            selectedForCreation: true,
            selectedForCalendar: false
        )
        let uncreated = candidate(
            60,
            id: thirdID,
            selectedForCreation: false,
            selectedForCalendar: true
        )
        let scheduled = candidate(30, id: secondID)

        let proposals = CalendarProposalEngine.propose(
            for: [skipped, uncreated, scheduled],
            calendarState: emptyState(),
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals[firstID] == nil)
        #expect(proposals[thirdID] == nil)
        #expect(proposals[secondID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(Set(proposals.keys) == [secondID])
    }

    @Test func ninetyMinuteSlotFitsWhenEndingAtTwentyOne() throws {
        let proposals = CalendarProposalEngine.propose(
            for: [candidate(90)],
            calendarState: try stateWithTimedItem(9, 0, 19, 30),
            now: localInstant(day, 8, 0),
            timeZone: shanghai
        )
        #expect(proposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 19, minute: 30))
        #expect(proposals[firstID]?.schedule.endTime == MinuteOfDay(hour: 21, minute: 0))
        #expect(proposals[firstID]?.schedule.startDate == day)
    }

    private func candidate(
        _ minutes: Int,
        id: UUID? = nil,
        selectedForCreation: Bool = true,
        selectedForCalendar: Bool = true
    ) -> CandidateAction {
        let duration: CandidateDuration
        switch minutes {
        case 15: duration = .minutes15
        case 30: duration = .minutes30
        case 45: duration = .minutes45
        case 60: duration = .minutes60
        case 90: duration = .minutes90
        default: fatalError("unsupported candidate duration")
        }
        return CandidateAction(
            id: id ?? (minutes == 45 ? secondID : firstID),
            title: "行动",
            completionDescription: "完成这项行动",
            estimatedDuration: duration,
            selectedForCreation: selectedForCreation,
            selectedForCalendar: selectedForCalendar,
            titleLockedByUser: false,
            completionLockedByUser: false,
            sourceCandidateID: nil,
            proposal: nil
        )
    }

    private func stateWithTimedItem(
        _ startHour: Int,
        _ startMinute: Int,
        _ endHour: Int,
        _ endMinute: Int,
        on itemDay: CalendarDate? = nil,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) throws -> CalendarState {
        let schedule = try timedSchedule(
            day: itemDay ?? day,
            start: (startHour, startMinute),
            end: (endHour, endMinute)
        )
        let item = try makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000510")!,
            schedule: schedule,
            timeZoneIdentifier: timeZoneIdentifier
        )
        var calendar = emptyState()
        calendar.items[item.id] = item
        return calendar
    }

    private func emptyState() -> CalendarState {
        CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
    }

    private func makeItem(
        id: UUID,
        schedule: CalendarSchedule,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            kind: .task,
            title: "已有事项",
            categoryID: categoryID,
            schedule: schedule,
            creationTimeZoneIdentifier: timeZoneIdentifier,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func timedSchedule(
        day: CalendarDate,
        start: (Int, Int),
        end: (Int, Int)
    ) throws -> CalendarSchedule {
        try CalendarSchedule(
            startDate: day,
            endDate: day,
            startTime: MinuteOfDay(hour: start.0, minute: start.1),
            endTime: MinuteOfDay(hour: end.0, minute: end.1)
        )
    }

    private func localInstant(
        _ day: CalendarDate,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone? = nil
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? shanghai
        return calendar.date(
            from: DateComponents(
                year: day.year,
                month: day.month,
                day: day.day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
