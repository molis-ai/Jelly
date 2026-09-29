import CalendarDomain
import Foundation

enum ItemRecurrenceMode: Equatable, Hashable, CaseIterable, Sendable {
    case none
    case daily
    case weekly

    var title: String {
        switch self {
        case .none: "不重复"
        case .daily: "每天"
        case .weekly: "每周"
        }
    }
}

struct ItemDraft: Equatable {
    var kind: ItemKind
    var title: String
    var categoryID: UUID
    var startDate: CalendarDate
    var endDate: CalendarDate
    var usesTime: Bool
    var startTime: MinuteOfDay
    var endTime: MinuteOfDay
    var repeatsWeekly: Bool
    var weekdays: Set<Weekday>
    var recurrenceEndDate: CalendarDate?
    var priority: ItemPriority
    /// Retained for schema/domain compatibility; product UI no longer exposes pin.
    var isPinned: Bool
    /// Markdown 随记 (style-only checklists, lists, emphasis).
    var notes: String = ""
    /// One-off item's reminder, or the series' reminder when editing a series.
    var reminder: ItemReminder? = nil
}

extension ItemDraft {
    init(item: CalendarItem) {
        self.init(
            kind: item.kind,
            title: item.title,
            categoryID: item.categoryID,
            startDate: item.schedule.startDate,
            endDate: item.schedule.endDate,
            usesTime: item.schedule.startTime != nil,
            startTime: item.schedule.startTime ?? MinuteOfDay(hour: 9, minute: 0)!,
            endTime: item.schedule.endTime ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: false,
            weekdays: [],
            recurrenceEndDate: nil,
            priority: item.priority,
            isPinned: item.isPinned,
            notes: item.notes,
            reminder: item.reminder
        )
    }

    init(series: WeeklySeries, date: CalendarDate) {
        self.init(
            kind: series.kind,
            title: series.title,
            categoryID: series.categoryID,
            startDate: date,
            endDate: date.addingDays(series.durationDays - 1),
            usesTime: series.startTime != nil,
            startTime: series.startTime ?? MinuteOfDay(hour: 9, minute: 0)!,
            endTime: series.endTime ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true,
            weekdays: series.weekdays,
            recurrenceEndDate: series.recurrenceEndDate,
            priority: series.priority,
            isPinned: series.isPinned,
            notes: series.notes,
            reminder: series.reminder
        )
    }

    init(occurrence: CalendarOccurrence, series: WeeklySeries) {
        self.init(
            kind: occurrence.kind,
            title: occurrence.title,
            categoryID: occurrence.categoryID,
            startDate: occurrence.schedule.startDate,
            endDate: occurrence.schedule.endDate,
            usesTime: occurrence.schedule.startTime != nil,
            startTime: occurrence.schedule.startTime ?? MinuteOfDay(hour: 9, minute: 0)!,
            endTime: occurrence.schedule.endTime ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true,
            weekdays: series.weekdays,
            recurrenceEndDate: series.recurrenceEndDate,
            priority: occurrence.priority,
            isPinned: occurrence.isPinned,
            notes: occurrence.notes,
            reminder: series.reminder
        )
    }

    static func newItem(
        from startDate: CalendarDate,
        through endDate: CalendarDate,
        categoryID: UUID,
        startTime: MinuteOfDay? = nil,
        endTime: MinuteOfDay? = nil
    ) -> ItemDraft {
        let usesTime = startTime != nil
        return ItemDraft(
            kind: .task,
            title: "",
            categoryID: categoryID,
            startDate: startDate,
            endDate: endDate,
            usesTime: usesTime,
            startTime: startTime ?? MinuteOfDay(hour: 9, minute: 0)!,
            endTime: endTime ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: false,
            weekdays: [startDate.weekday],
            recurrenceEndDate: nil,
            priority: .none,
            isPinned: false,
            notes: ""
        )
    }

    static var allWeekdays: Set<Weekday> { Set(Weekday.allCases) }

    var recurrenceMode: ItemRecurrenceMode {
        get {
            guard repeatsWeekly else { return .none }
            return weekdays == Self.allWeekdays ? .daily : .weekly
        }
        set {
            switch newValue {
            case .none:
                repeatsWeekly = false
            case .daily:
                repeatsWeekly = true
                weekdays = Self.allWeekdays
            case .weekly:
                repeatsWeekly = true
                if weekdays == Self.allWeekdays || weekdays.isEmpty {
                    weekdays = [startDate.weekday]
                }
            }
        }
    }
}

extension CalendarDate {
    var editorDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    static func editorDate(containing date: Date) -> CalendarDate {
        CalendarDate.localDay(containing: date, in: .current)
    }
}

extension MinuteOfDay {
    var editorDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: 2001,
            month: 1,
            day: 1,
            hour: value / 60,
            minute: value % 60
        ))!
    }

    static func editorMinute(containing date: Date) -> MinuteOfDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return MinuteOfDay(hour: components.hour ?? 9, minute: components.minute ?? 0)!
    }
}
