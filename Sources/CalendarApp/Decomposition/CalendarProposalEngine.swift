import CalendarDomain
import Foundation

enum CalendarProposalEngine {
    private static let windowDays = 7
    private static let dayStartMinutes = 9 * 60
    private static let dayEndMinutes = 21 * 60
    private static let gridMinutes = 15

    static func propose(
        for actions: [CandidateAction],
        calendarState: CalendarState,
        now: Date,
        timeZone: TimeZone
    ) -> [UUID: CalendarProposal] {
        let today = CalendarDate.localDay(containing: now, in: timeZone)
        let range = CalendarDateRange(
            start: today,
            end: today.addingDays(windowDays - 1)
        )
        let projection = TimelineProjection.make(
            in: range,
            state: calendarState,
            hiddenCategoryIDs: []
        )
        var occupied = projection.entries.map(\.schedule)
        let firstDayEarliest = max(dayStartMinutes, ceiledMinuteOfDay(now, in: timeZone))

        var proposals: [UUID: CalendarProposal] = [:]
        for action in actions {
            guard action.selectedForCreation, action.selectedForCalendar else { continue }
            guard let schedule = firstAvailableSchedule(
                durationMinutes: action.estimatedDuration.rawValue,
                today: today,
                firstDayEarliest: firstDayEarliest,
                occupied: occupied
            ) else {
                continue
            }
            occupied.append(schedule)
            proposals[action.id] = CalendarProposal(schedule: schedule)
        }
        return proposals
    }

    private static func firstAvailableSchedule(
        durationMinutes: Int,
        today: CalendarDate,
        firstDayEarliest: Int,
        occupied: [CalendarSchedule]
    ) -> CalendarSchedule? {
        for offset in 0..<windowDays {
            let day = today.addingDays(offset)
            var cursor = offset == 0 ? firstDayEarliest : dayStartMinutes
            while cursor + durationMinutes <= dayEndMinutes {
                let schedule = try! CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: minuteOfDay(cursor),
                    endTime: minuteOfDay(cursor + durationMinutes)
                )
                if occupied.allSatisfy({ !CalendarTimedOccupancy.overlaps($0, schedule) }) {
                    return schedule
                }
                cursor += gridMinutes
            }
        }
        return nil
    }

    private static func ceiledMinuteOfDay(_ now: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: now
        )
        var totalSeconds =
            (components.hour ?? 0) * 3600
            + (components.minute ?? 0) * 60
            + (components.second ?? 0)
        if (components.nanosecond ?? 0) > 0 {
            totalSeconds += 1
        }
        let gridSeconds = gridMinutes * 60
        return ((totalSeconds + gridSeconds - 1) / gridSeconds) * gridSeconds / 60
    }

    private static func minuteOfDay(_ minutes: Int) -> MinuteOfDay {
        MinuteOfDay(hour: minutes / 60, minute: minutes % 60)!
    }
}
