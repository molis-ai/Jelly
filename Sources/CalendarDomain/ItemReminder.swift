import Foundation

/// When a single calendar item should ring. Jelly only computes the fire date;
/// the platform layer hands it to Reminders (Mac) or local notifications (iOS).
public enum ItemReminder: Codable, Hashable, Sendable {
    /// Timed items: minutes before the start time. `0` rings at the start.
    case beforeStart(minutes: Int)
    /// Any item: a clock time on the item's start day, typically for 全天 items.
    case onStartDay(at: MinuteOfDay)

    public static let allowedLeadMinutes = [0, 5, 10, 15, 30, 60, 120, 1440]
    public static let defaultAllDayTime = MinuteOfDay(hour: 9, minute: 0)!

    public var isValidLeadTime: Bool {
        guard case let .beforeStart(minutes) = self else { return true }
        return (0...10_080).contains(minutes)
    }

    /// Keeps a reminder meaningful after the schedule changes between 全天 and 定时.
    public func adapted(to schedule: CalendarSchedule) -> ItemReminder {
        switch self {
        case .beforeStart where schedule.startTime == nil:
            return .onStartDay(at: Self.defaultAllDayTime)
        default:
            return self
        }
    }

    public func fireDate(for schedule: CalendarSchedule, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = schedule.startDate
        switch self {
        case let .beforeStart(minutes):
            guard isValidLeadTime, let start = schedule.startTime else { return nil }
            let startDate = calendar.date(from: DateComponents(
                year: day.year, month: day.month, day: day.day,
                hour: start.value / 60, minute: start.value % 60
            ))
            return startDate.map { $0.addingTimeInterval(TimeInterval(-minutes * 60)) }
        case let .onStartDay(time):
            return calendar.date(from: DateComponents(
                year: day.year, month: day.month, day: day.day,
                hour: time.value / 60, minute: time.value % 60
            ))
        }
    }

    public var title: String {
        switch self {
        case let .beforeStart(minutes):
            switch minutes {
            case 0: return "开始时"
            case 1440: return "提前 1 天"
            case let value where value % 60 == 0: return "提前 \(value / 60) 小时"
            default: return "提前 \(minutes) 分钟"
            }
        case let .onStartDay(time):
            return String(format: "当天 %02d:%02d", time.value / 60, time.value % 60)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case minutes
        case minuteOfDay
    }

    private enum Kind: String, Codable {
        case beforeStart
        case onStartDay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .beforeStart:
            let minutes = try container.decode(Int.self, forKey: .minutes)
            self = .beforeStart(minutes: minutes)
            guard isValidLeadTime else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minutes,
                    in: container,
                    debugDescription: "Reminder lead time is out of range."
                )
            }
        case .onStartDay:
            self = .onStartDay(at: try container.decode(MinuteOfDay.self, forKey: .minuteOfDay))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .beforeStart(minutes):
            try container.encode(Kind.beforeStart, forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        case let .onStartDay(time):
            try container.encode(Kind.onStartDay, forKey: .kind)
            try container.encode(time, forKey: .minuteOfDay)
        }
    }
}
