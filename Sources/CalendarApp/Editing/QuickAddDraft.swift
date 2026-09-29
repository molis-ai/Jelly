import CalendarDomain
import Foundation

extension ItemDraft {
    /// Moves a recognized “明天下午 3 点” out of the title and into the schedule.
    func applying(_ parse: QuickAddParse) throws -> ItemDraft {
        var result = self
        let schedule = try parse.schedule(defaultDate: startDate)
        result.title = parse.title
        result.startDate = schedule.startDate
        result.endDate = schedule.endDate
        result.usesTime = schedule.startTime != nil
        if let start = schedule.startTime { result.startTime = start }
        if let end = schedule.endTime { result.endTime = end }
        if result.reminder == nil, let reminder = parse.reminder {
            result.reminder = reminder
        }
        result.reminder = result.reminder?.adapted(to: schedule)
        return result
    }
}

enum QuickAddPresentation {
    static func weekdayName(_ weekday: Weekday) -> String {
        switch weekday {
        case .monday: "周一"
        case .tuesday: "周二"
        case .wednesday: "周三"
        case .thursday: "周四"
        case .friday: "周五"
        case .saturday: "周六"
        case .sunday: "周日"
        }
    }

    static func clock(_ time: MinuteOfDay) -> String {
        String(format: "%02d:%02d", time.value / 60, time.value % 60)
    }

    /// “10月1日 周四 15:00–16:00 · 提醒”
    static func summary(_ parse: QuickAddParse, defaultDate: CalendarDate) -> String? {
        guard parse.recognizedSchedule || parse.wantsReminder,
              let schedule = try? parse.schedule(defaultDate: defaultDate)
        else { return nil }
        let day = schedule.startDate
        var text = "\(day.month)月\(day.day)日 \(weekdayName(day.weekday))"
        if let start = schedule.startTime, let end = schedule.endTime {
            text += " \(clock(start))–\(clock(end))"
            if schedule.endDate != schedule.startDate { text += "（次日）" }
        }
        if parse.wantsReminder { text += " · 提醒" }
        return text
    }
}
