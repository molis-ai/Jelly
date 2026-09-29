import CalendarDomain
import Foundation
import Testing

@Suite("QuickAddParserTests")
struct QuickAddParserTests {
    /// Monday 2026-09-28.
    private let today = CalendarDate(year: 2026, month: 9, day: 28)!

    private func time(_ hour: Int, _ minute: Int = 0) -> MinuteOfDay { MinuteOfDay(hour: hour, minute: minute)! }
    private func day(_ month: Int, _ value: Int, year: Int = 2026) -> CalendarDate { CalendarDate(year: year, month: month, day: value)! }

    @Test func tomorrowAfternoonMeeting() throws {
        let parse = QuickAddParser.parse("明天下午 3 点开会", today: today)
        #expect(parse.title == "开会")
        #expect(parse.date == day(9, 29))
        #expect(parse.startTime == time(15))
        let schedule = try parse.schedule(defaultDate: today)
        #expect(schedule.endTime == time(16))
    }

    @Test func chineseNumeralsHalfHoursAndRanges() {
        let a = QuickAddParser.parse("后天上午十点半 牙医", today: today)
        #expect(a.date == day(9, 30))
        #expect(a.startTime == time(10, 30))
        #expect(a.title == "牙医")

        let b = QuickAddParser.parse("下午3点到4点半评审", today: today)
        #expect(b.date == nil)
        #expect(b.startTime == time(15))
        #expect(b.endTime == time(16, 30))
        #expect(b.title == "评审")

        let c = QuickAddParser.parse("周五 15:00-16:30 1:1", today: today)
        #expect(c.date == day(10, 2))
        #expect(c.startTime == time(15))
        #expect(c.endTime == time(16, 30))
        #expect(c.title == "1:1")

        let d = QuickAddParser.parse("3-5点 写周报", today: today)
        #expect(d.startTime == time(15))
        #expect(d.endTime == time(17))
    }

    @Test func weekdaysAndWeeks() {
        #expect(QuickAddParser.parse("周一交房租", today: today).date == today)
        #expect(QuickAddParser.parse("周三交房租", today: today).date == day(9, 30))
        #expect(QuickAddParser.parse("下周三交房租", today: today).date == day(10, 7))
        #expect(QuickAddParser.parse("下下周一 复盘", today: today).date == day(10, 12))
        #expect(QuickAddParser.parse("星期天 爬山", today: today).date == day(10, 4))
        #expect(QuickAddParser.parse("这周末 爬山", today: today).date == day(10, 3))
        #expect(QuickAddParser.parse("下周末 爬山", today: today).date == day(10, 10))
    }

    @Test func explicitDatesRollForwardToTheNextOccurrence() {
        #expect(QuickAddParser.parse("10月1日 放假", today: today).date == day(10, 1))
        #expect(QuickAddParser.parse("3月8号 聚餐", today: today).date == day(3, 8, year: 2027))
        #expect(QuickAddParser.parse("15号 还信用卡", today: today).date == day(10, 15))
        #expect(QuickAddParser.parse("30号 还信用卡", today: today).date == day(9, 30))
        #expect(QuickAddParser.parse("2026-12-24 平安夜", today: today).date == day(12, 24))
        #expect(QuickAddParser.parse("12/24 平安夜", today: today).date == day(12, 24))
        #expect(QuickAddParser.parse("3天后 取快递", today: today).date == day(10, 1))
        #expect(QuickAddParser.parse("下个月5号 体检", today: today).date == day(10, 5))
    }

    @Test func eveningWordsAndReminders() {
        let a = QuickAddParser.parse("今晚8点提醒我给妈妈打电话", today: today)
        #expect(a.date == today)
        #expect(a.startTime == time(20))
        #expect(a.wantsReminder)
        #expect(a.reminder == .beforeStart(minutes: 0))
        #expect(a.title == "给妈妈打电话")

        let b = QuickAddParser.parse("明天提醒我交水费", today: today)
        #expect(b.reminder == .onStartDay(at: ItemReminder.defaultAllDayTime))
        #expect(b.startTime == nil)

        let c = QuickAddParser.parse("晚上11点到1点 看球", today: today)
        #expect(c.startTime == time(23))
        #expect(c.endTime == time(1))
    }

    @Test func plainTitlesStayUntouched() throws {
        let parse = QuickAddParser.parse("把报告发给老王", today: today)
        #expect(!parse.recognizedSchedule)
        #expect(parse.title == "把报告发给老王")
        let overnight = QuickAddParser.parse("晚上11点到1点 看球", today: today)
        let schedule = try overnight.schedule(defaultDate: today)
        #expect(schedule.endDate == today.addingDays(1))
        #expect(QuickAddParser.parse("晚上跑步", today: today).title == "晚上跑步")
    }
}
