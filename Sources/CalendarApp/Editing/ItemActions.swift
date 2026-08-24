import CalendarDomain
import Foundation

enum ItemActions {
    static func setPriority(_ priority: ItemPriority, on item: ProjectedItem) -> CalendarCommand {
        switch item {
        case let .item(calendarItem):
            return .setItemPriority(calendarItem.id, priority)
        case let .occurrence(occurrence):
            return .mutateSeries(
                occurrence.key,
                scope: .onlyThis,
                edit: .patch(.init(priority: priority)),
                newSeriesID: UUID()
            )
        }
    }

    /// Pin sets isPinned and forces P0; unpin clears pin only.
    static func setPinned(_ isPinned: Bool, on item: ProjectedItem) -> CalendarCommand {
        switch item {
        case let .item(calendarItem):
            return .setItemPinned(calendarItem.id, isPinned)
        case let .occurrence(occurrence):
            return .mutateSeries(
                occurrence.key,
                scope: .onlyThis,
                edit: .patch(.init(
                    priority: isPinned ? .p0 : nil,
                    isPinned: isPinned
                )),
                newSeriesID: UUID()
            )
        }
    }

    static func deleteCommand(for item: ProjectedItem) -> CalendarCommand {
        switch item {
        case let .item(calendarItem):
            return .deleteItem(calendarItem.id)
        case let .occurrence(occurrence):
            return .mutateSeries(
                occurrence.key,
                scope: .onlyThis,
                edit: .delete,
                newSeriesID: UUID()
            )
        }
    }

    /// Independent one-off copy whose start falls on `day`. The source stays
    /// put; the copy can later be dragged with the existing move path.
    static func copyToDay(
        _ item: ProjectedItem,
        day: CalendarDate,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> CalendarCommand {
        .createItem(try CalendarItemCopy.oneOff(from: item, to: day, id: id, now: now))
    }

    static func editorConfiguration(
        for item: ProjectedItem,
        seriesLookup: (UUID) -> WeeklySeries?,
        scope: SeriesScope
    ) -> ItemEditorConfiguration? {
        switch item {
        case let .item(calendarItem):
            return .oneOff(item: calendarItem)
        case let .occurrence(occurrence):
            guard let series = seriesLookup(occurrence.key.seriesID) else {
                return nil
            }
            return .occurrence(series: series, occurrence: occurrence, scope: scope)
        }
    }
}
