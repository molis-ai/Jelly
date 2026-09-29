import CalendarDomain
import Foundation
import WorkspaceDomain

enum ItemEditorConfiguration: Identifiable {
    case oneOff(item: CalendarItem)
    case occurrence(series: WeeklySeries, occurrence: CalendarOccurrence, scope: SeriesScope)

    var id: String {
        switch self {
        case let .oneOff(item): "item-\(item.id.uuidString)"
        case let .occurrence(_, occurrence, scope): "occurrence-\(occurrence.id.seriesID.uuidString)-\(scope)"
        }
    }

    var mode: ItemEditorMode {
        switch self {
        case let .oneOff(item): .editItem(item)
        case let .occurrence(series, occurrence, scope):
            .editOccurrence(series: series, key: occurrence.key, scope: scope)
        }
    }

    var draft: ItemDraft {
        switch self {
        case let .oneOff(item): ItemDraft(item: item)
        case let .occurrence(series, occurrence, _): ItemDraft(occurrence: occurrence, series: series)
        }
    }

    var canEditRule: Bool {
        if case let .occurrence(_, _, scope) = self {
            return scope == .thisAndFuture
        }
        return false
    }

    var calendarTarget: CalendarTargetID {
        switch self {
        case let .oneOff(item):
            .item(item.id)
        case let .occurrence(series, occurrence, scope):
            scope == .thisAndFuture ? .series(series.id) : .occurrence(occurrence.key)
        }
    }

    var projectedItem: ProjectedItem {
        switch self {
        case let .oneOff(item):
            .item(item)
        case let .occurrence(_, occurrence, _):
            .occurrence(occurrence)
        }
    }
}
