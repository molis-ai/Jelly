import Foundation

public enum CalendarTimedConflict: Equatable, Sendable {
    case item(UUID)
    case occurrence(OccurrenceKey)
    case proposed(UUID, UUID)
}

public enum CalendarTimedOccupancy {
    public static func overlaps(_ lhs: CalendarSchedule, _ rhs: CalendarSchedule) -> Bool {
        guard lhs.endDate >= rhs.startDate, rhs.endDate >= lhs.startDate else {
            return false
        }
        let origin = min(lhs.startDate, rhs.startDate)
        guard let lhsInterval = absoluteTimedInterval(lhs, origin: origin),
              let rhsInterval = absoluteTimedInterval(rhs, origin: origin)
        else {
            return false
        }
        return lhsInterval.start < rhsInterval.end && rhsInterval.start < lhsInterval.end
    }

    public static func firstConflict(
        proposed: [CalendarItem],
        in state: CalendarState,
        range: CalendarDateRange
    ) -> CalendarTimedConflict? {
        let projection = TimelineProjection.make(
            in: range,
            state: state,
            hiddenCategoryIDs: []
        )

        for item in proposed {
            for entry in projection.entries {
                guard overlaps(item.schedule, entry.schedule) else { continue }
                switch entry {
                case let .item(existing):
                    return .item(existing.id)
                case let .occurrence(occurrence):
                    return .occurrence(occurrence.key)
                }
            }
        }

        for index in proposed.indices {
            for laterIndex in proposed.indices where laterIndex > index {
                if overlaps(proposed[index].schedule, proposed[laterIndex].schedule) {
                    return .proposed(proposed[index].id, proposed[laterIndex].id)
                }
            }
        }

        return nil
    }

    private static func absoluteTimedInterval(
        _ schedule: CalendarSchedule,
        origin: CalendarDate
    ) -> (start: Int, end: Int)? {
        guard let startTime = schedule.startTime, let endTime = schedule.endTime else {
            return nil
        }
        let start = origin.days(until: schedule.startDate) * minutesPerDay + startTime.value
        let end = origin.days(until: schedule.endDate) * minutesPerDay + endTime.value
        return (start, end)
    }

    private static let minutesPerDay = 24 * 60
}
