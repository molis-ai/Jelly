import CalendarDomain
import Foundation
import WorkspaceDomain

// MARK: - Argument structs (snake_case wire keys, one per tool)

struct ListItemsArgs: Codable {
    let date: String
    let span: String?
}

struct GetItemArgs: Codable {
    let id: String
}

struct SearchArgs: Codable {
    let query: String
    let kind: String?
    let includeArchived: Bool?

    enum CodingKeys: String, CodingKey {
        case query
        case kind
        case includeArchived = "include_archived"
    }
}

struct CreateItemArgs: Codable {
    let title: String
    let date: String
    let endDate: String?
    let startTime: String?
    let endTime: String?
    let categoryId: String?
    let priority: String?
    let pinned: Bool?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title
        case date
        case endDate = "end_date"
        case startTime = "start_time"
        case endTime = "end_time"
        case categoryId = "category_id"
        case priority
        case pinned
        case notes
    }
}

struct UpdateItemArgs: Codable {
    let id: String
    let title: String?
    let notes: String?
    let startTime: String?
    let endTime: String?
    let clearTimes: Bool?
    let categoryId: String?
    let priority: String?
    let pinned: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case startTime = "start_time"
        case endTime = "end_time"
        case clearTimes = "clear_times"
        case categoryId = "category_id"
        case priority
        case pinned
    }
}

struct MoveItemsArgs: Codable {
    let itemIds: [String]
    let date: String

    enum CodingKeys: String, CodingKey {
        case itemIds = "item_ids"
        case date
    }
}

struct SetTaskCompletedArgs: Codable {
    let itemId: String?
    let seriesId: String?
    let date: String?
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case seriesId = "series_id"
        case date
        case completed
    }
}

struct DeleteItemArgs: Codable {
    let id: String
}

struct ReorderUntimedArgs: Codable {
    let date: String
    let orderedIds: [String]

    enum CodingKeys: String, CodingKey {
        case date
        case orderedIds = "ordered_ids"
    }
}

struct CreateSeriesArgs: Codable {
    let title: String
    let weekdays: [Int]
    let startDate: String
    let recurrenceEndDate: String?
    let durationDays: Int?
    let startTime: String?
    let endTime: String?
    let categoryId: String?
    let priority: String?
    let pinned: Bool?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title
        case weekdays
        case startDate = "start_date"
        case recurrenceEndDate = "recurrence_end_date"
        case durationDays = "duration_days"
        case startTime = "start_time"
        case endTime = "end_time"
        case categoryId = "category_id"
        case priority
        case pinned
        case notes
    }
}

struct ModifySeriesArgs: Codable {
    let seriesId: String
    let date: String
    let scope: String
    let action: String
    let title: String?
    let weekdays: [Int]?
    let categoryId: String?
    let priority: String?
    let pinned: Bool?
    let notes: String?
    let recurrenceEndDate: String?
    let clearRecurrenceEndDate: Bool?
    let startDate: String?
    let durationDays: Int?
    let startTime: String?
    let endTime: String?
    let clearTimes: Bool?

    enum CodingKeys: String, CodingKey {
        case seriesId = "series_id"
        case date
        case scope
        case action
        case title
        case weekdays
        case categoryId = "category_id"
        case priority
        case pinned
        case notes
        case recurrenceEndDate = "recurrence_end_date"
        case clearRecurrenceEndDate = "clear_recurrence_end_date"
        case startDate = "start_date"
        case durationDays = "duration_days"
        case startTime = "start_time"
        case endTime = "end_time"
        case clearTimes = "clear_times"
    }
}

struct EmptyArgs: Codable {}

// MARK: - Parsing helpers

enum MCPArgParsing {
    enum ListSpan: String {
        case day, week, month
    }

    static func invalidParams(_ message: String) -> MCPGatewayError {
        MCPGatewayError(code: "invalid_params", message: message)
    }

    static func calendarDate(_ raw: String, field: String) throws -> CalendarDate {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = CalendarDate(year: year, month: month, day: day) else {
            throw invalidParams("\(field) 需要是 YYYY-MM-DD 格式的有效日期，收到：\(raw)")
        }
        return date
    }

    static func minuteOfDay(_ raw: String, field: String) throws -> MinuteOfDay {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              let time = MinuteOfDay(hour: hour, minute: minute) else {
            throw invalidParams("\(field) 需要是 24 小时制 HH:mm 格式，收到：\(raw)")
        }
        return time
    }

    /// Timed or untimed is all-or-nothing: both times, or neither.
    static func timePair(start: String?, end: String?) throws -> (start: MinuteOfDay?, end: MinuteOfDay?) {
        switch (start, end) {
        case (nil, nil):
            return (nil, nil)
        case let (start?, end?):
            return (try minuteOfDay(start, field: "start_time"), try minuteOfDay(end, field: "end_time"))
        case let (start?, nil):
            throw invalidParams("提供了 start_time（\(start)）就必须同时提供 end_time；要表示全天/无时间，请两者都不提供。")
        case let (nil, end?):
            throw invalidParams("提供了 end_time（\(end)）就必须同时提供 start_time；要表示全天/无时间，请两者都不提供。")
        }
    }

    static func priority(_ raw: String?) throws -> ItemPriority? {
        guard let raw else { return nil }
        guard let priority = ItemPriority(rawValue: raw.lowercased()) else {
            throw invalidParams("priority 只接受 p0 / p1 / p2 / none，收到：\(raw)")
        }
        return priority
    }

    static func weekdays(_ raw: [Int]?) throws -> Set<Weekday>? {
        guard let raw else { return nil }
        guard !raw.isEmpty else {
            throw invalidParams("weekdays 至少要包含一个星期（1=周一 … 7=周日）。")
        }
        var mapped = Set<Weekday>()
        for value in raw {
            guard let weekday = Weekday(rawValue: value) else {
                throw invalidParams("weekdays 的取值是 1（周一）到 7（周日），收到：\(value)")
            }
            mapped.insert(weekday)
        }
        return mapped
    }

    static func uuid(_ raw: String, field: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else {
            throw invalidParams("\(field) 需要是 UUID，收到：\(raw)")
        }
        return id
    }

    static func objectKind(_ raw: String?) throws -> WorkspaceObjectKind? {
        guard let raw else { return nil }
        guard let kind = WorkspaceObjectKind(rawValue: raw) else {
            throw invalidParams("kind 只接受 calendarItem / note / inspiration，收到：\(raw)")
        }
        return kind
    }

    static func listSpan(_ raw: String?) -> ListSpan {
        guard let raw, let span = ListSpan(rawValue: raw) else { return .day }
        return span
    }

    /// Week starts on Monday (the app's convention); month covers the civil month.
    static func dateRange(for date: CalendarDate, span: ListSpan) -> CalendarDateRange {
        switch span {
        case .day:
            return CalendarDateRange(start: date, end: date)
        case .week:
            let monday = date.addingDays(-(date.weekday.rawValue - 1))
            return CalendarDateRange(start: monday, end: monday.addingDays(6))
        case .month:
            let first = CalendarDate(year: date.year, month: date.month, day: 1)!
            let nextMonth: CalendarDate
            if date.month == 12 {
                nextMonth = CalendarDate(year: date.year + 1, month: 1, day: 1)!
            } else {
                nextMonth = CalendarDate(year: date.year, month: date.month + 1, day: 1)!
            }
            return CalendarDateRange(start: first, end: nextMonth.addingDays(-1))
        }
    }
}

// MARK: - Formatting helpers

enum MCPFormatting {
    private static let weekdayNames = [
        Weekday.monday: "周一",
        .tuesday: "周二",
        .wednesday: "周三",
        .thursday: "周四",
        .friday: "周五",
        .saturday: "周六",
        .sunday: "周日"
    ]

    static func date(_ date: CalendarDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    static func time(_ time: MinuteOfDay) -> String {
        String(format: "%02d:%02d", time.value / 60, time.value % 60)
    }

    static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func weekdayName(_ weekday: Weekday) -> String {
        weekdayNames[weekday] ?? String(weekday.rawValue)
    }

    static func optionalTime(_ time: MinuteOfDay?) -> MCPJSON {
        guard let time else { return .null }
        return .string(MCPFormatting.time(time))
    }

    static func optionalDate(_ date: CalendarDate?) -> MCPJSON {
        guard let date else { return .null }
        return .string(MCPFormatting.date(date))
    }

    static func optionalInstant(_ date: Date?) -> MCPJSON {
        guard let date else { return .null }
        return .string(MCPFormatting.instant(date))
    }

    static func priority(_ priority: ItemPriority) -> MCPJSON {
        .string(priority.rawValue)
    }
}
