import Foundation

/// Builds a new one-off item from an existing item or occurrence, shifted so
/// its start falls on `startDate`. The source is left unchanged; the copy is
/// always an independent completable TODO (never a series).
public enum CalendarItemCopy {
    public static func oneOff(
        from item: ProjectedItem,
        to startDate: CalendarDate,
        id: UUID,
        now: Date
    ) throws -> CalendarItem {
        switch item {
        case let .item(calendarItem):
            return try oneOff(from: calendarItem, to: startDate, id: id, now: now)
        case let .occurrence(occurrence):
            return try oneOff(from: occurrence, to: startDate, id: id, now: now)
        }
    }

    public static func oneOff(
        from item: CalendarItem,
        to startDate: CalendarDate,
        id: UUID,
        now: Date
    ) throws -> CalendarItem {
        try makeCopy(
            title: item.title,
            categoryID: item.categoryID,
            schedule: item.schedule,
            creationTimeZoneIdentifier: item.creationTimeZoneIdentifier,
            priority: item.priority,
            notes: item.notes,
            to: startDate,
            id: id,
            now: now
        )
    }

    public static func oneOff(
        from occurrence: CalendarOccurrence,
        to startDate: CalendarDate,
        id: UUID,
        now: Date
    ) throws -> CalendarItem {
        try makeCopy(
            title: occurrence.title,
            categoryID: occurrence.categoryID,
            schedule: occurrence.schedule,
            creationTimeZoneIdentifier: occurrence.creationTimeZoneIdentifier,
            priority: occurrence.priority,
            notes: occurrence.notes,
            to: startDate,
            id: id,
            now: now
        )
    }

    private static func makeCopy(
        title: String,
        categoryID: UUID,
        schedule: CalendarSchedule,
        creationTimeZoneIdentifier: String,
        priority: ItemPriority,
        notes: String,
        to startDate: CalendarDate,
        id: UUID,
        now: Date
    ) throws -> CalendarItem {
        let shifted = try schedule.shifted(byDays: schedule.startDate.days(until: startDate))
        return try CalendarItem(
            id: id,
            kind: .unifiedTODO,
            title: title,
            categoryID: categoryID,
            schedule: shifted,
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            priority: priority,
            isPinned: false,
            notes: notes,
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}
