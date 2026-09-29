import Foundation

/// What “明天下午 3 点开会” means: a title plus an optional day and time.
public struct QuickAddParse: Equatable, Sendable {
    public var title: String
    public var date: CalendarDate?
    public var startTime: MinuteOfDay?
    public var endTime: MinuteOfDay?
    /// “提醒我…” was written in the text.
    public var wantsReminder: Bool

    public init(
        title: String,
        date: CalendarDate? = nil,
        startTime: MinuteOfDay? = nil,
        endTime: MinuteOfDay? = nil,
        wantsReminder: Bool = false
    ) {
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.wantsReminder = wantsReminder
    }

    public var recognizedSchedule: Bool { date != nil || startTime != nil }

    /// A timed parse lasts an hour unless an end was given; an end at or
    /// before the start runs past midnight.
    public func schedule(defaultDate: CalendarDate) throws -> CalendarSchedule {
        let day = date ?? defaultDate
        guard let start = startTime else {
            return try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil)
        }
        let end = endTime ?? MinuteOfDay(hour: min(23, start.value / 60 + 1), minute: start.value / 60 >= 23 ? 59 : start.value % 60)!
        let endDay = end <= start ? day.addingDays(1) : day
        return try CalendarSchedule(startDate: day, endDate: endDay, startTime: start, endTime: end)
    }

    public var reminder: ItemReminder? {
        guard wantsReminder else { return nil }
        return startTime == nil ? .onStartDay(at: ItemReminder.defaultAllDayTime) : .beforeStart(minutes: 0)
    }
}

public enum QuickAddParser {
    public static func parse(_ text: String, today: CalendarDate) -> QuickAddParse {
        var scanner = Scanner(text: text, today: today)
        scanner.run()
        return scanner.result(original: text)
    }

    // MARK: - Implementation

    private static let cnDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9
    ]

    /// Arabic digits or Chinese numerals up to 99 (十一, 二十三, 两).
    static func number(_ raw: Substring) -> Int? {
        if let value = Int(raw) { return value }
        let chars = Array(raw)
        guard !chars.isEmpty, chars.allSatisfy({ cnDigits[$0] != nil || $0 == "十" }) else { return nil }
        if let tenIndex = chars.firstIndex(of: "十") {
            let tens = tenIndex == 0 ? 1 : cnDigits[chars[0]] ?? 0
            let ones = tenIndex + 1 < chars.count ? cnDigits[chars[tenIndex + 1]] ?? 0 : 0
            guard chars.count <= 3 else { return nil }
            return tens * 10 + ones
        }
        guard chars.count == 1 else { return nil }
        return cnDigits[chars[0]]
    }

    private static let numberPattern = "(\\d{1,2}|[零〇一二两三四五六七八九十]{1,3})"
    private static let weekdayPattern = "([一二三四五六日天1-7])"

    private static func weekday(_ raw: Substring) -> Weekday? {
        switch raw {
        case "一", "1": .monday
        case "二", "2": .tuesday
        case "三", "3": .wednesday
        case "四", "4": .thursday
        case "五", "5": .friday
        case "六", "6": .saturday
        case "日", "天", "7": .sunday
        default: nil
        }
    }

    private enum Period {
        case earlyMorning, morning, noon, afternoon, evening

        init?(_ word: Substring) {
            switch word {
            case "凌晨": self = .earlyMorning
            case "早上", "早晨", "上午", "早", "今早", "明早": self = .morning
            case "中午": self = .noon
            case "下午": self = .afternoon
            case "傍晚", "晚上", "今晚", "明晚", "夜里", "晚": self = .evening
            default: return nil
            }
        }

        func hour24(_ hour: Int) -> Int {
            switch self {
            case .earlyMorning: return hour == 12 ? 0 : hour
            case .morning: return hour
            case .noon: return hour <= 3 ? hour + 12 : hour
            case .afternoon, .evening: return hour < 12 ? hour + 12 : hour
            }
        }
    }

    private struct Scanner {
        let text: String
        let today: CalendarDate
        var consumed: [NSRange] = []
        var date: CalendarDate?
        var period: Period?
        var start: (hour: Int, minute: Int, explicitPeriod: Bool)?
        var end: (hour: Int, minute: Int, period: Period?)?
        var wantsReminder = false

        init(text: String, today: CalendarDate) {
            self.text = text
            self.today = today
        }

        mutating func run() {
            scanReminder()
            scanExplicitDates()
            scanRelativeDates()
            scanWeekdays()
            scanTimeRanges()
            scanTimes()
            scanPeriodsAlone()
        }

        // MARK: helpers

        /// Already-recognized pieces are blanked out (same UTF-16 length) so a
        /// later pattern can neither overlap them nor be blocked by them.
        private var masked: String {
            let copy = NSMutableString(string: text)
            for range in consumed {
                copy.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
            }
            return copy as String
        }

        private func matches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let source = masked
            return regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        }

        private func group(_ match: NSTextCheckingResult, _ index: Int) -> Substring? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return text[swiftRange]
        }

        private mutating func consume(_ match: NSTextCheckingResult) {
            consumed.append(match.range)
        }

        // MARK: scanners

        private mutating func scanReminder() {
            for match in matches("提醒我|提醒一下|提醒") {
                wantsReminder = true
                consume(match)
            }
        }

        private mutating func scanExplicitDates() {
            guard date == nil else { return }
            if let match = matches("(\\d{4})[-/.年](\\d{1,2})[-/.月](\\d{1,2})[日号]?").first,
               let year = group(match, 1).flatMap({ Int($0) }),
               let month = group(match, 2).flatMap({ Int($0) }),
               let day = group(match, 3).flatMap({ Int($0) }),
               let value = CalendarDate(year: year, month: month, day: day) {
                date = value
                consume(match)
                return
            }
            if let match = matches(numberPattern + "月" + numberPattern + "[日号]?").first,
               let month = group(match, 1).flatMap(QuickAddParser.number),
               let day = group(match, 2).flatMap(QuickAddParser.number),
               let value = upcoming(month: month, day: day) {
                date = value
                consume(match)
                return
            }
            if let match = matches("下个?月" + numberPattern + "[日号]").first,
               let day = group(match, 1).flatMap(QuickAddParser.number) {
                let (year, month) = today.month == 12 ? (today.year + 1, 1) : (today.year, today.month + 1)
                if let value = CalendarDate(year: year, month: month, day: day) {
                    date = value
                    consume(match)
                    return
                }
            }
            if let match = matches("(?<![\\d/])(\\d{1,2})/(\\d{1,2})(?![\\d/])").first,
               let month = group(match, 1).flatMap({ Int($0) }),
               let day = group(match, 2).flatMap({ Int($0) }),
               let value = upcoming(month: month, day: day) {
                date = value
                consume(match)
                return
            }
            if let match = matches("(?<![月\\d])" + numberPattern + "[号日](?![子])").first,
               let day = group(match, 1).flatMap(QuickAddParser.number),
               (1...31).contains(day) {
                var candidate = CalendarDate(year: today.year, month: today.month, day: day)
                if candidate == nil || candidate! < today {
                    let (year, month) = today.month == 12 ? (today.year + 1, 1) : (today.year, today.month + 1)
                    candidate = CalendarDate(year: year, month: month, day: day)
                }
                if let candidate {
                    date = candidate
                    consume(match)
                }
            }
        }

        private func upcoming(month: Int, day: Int) -> CalendarDate? {
            guard let thisYear = CalendarDate(year: today.year, month: month, day: day) else { return nil }
            return thisYear < today ? CalendarDate(year: today.year + 1, month: month, day: day) : thisYear
        }

        private mutating func scanRelativeDates() {
            if date == nil, let match = matches(QuickAddParser.numberPattern + "天(?:后|以后|之后)").first,
               let count = group(match, 1).flatMap(QuickAddParser.number) {
                date = today.addingDays(count)
                consume(match)
            }
            let words: [(String, Int, Period?)] = [
                ("大后天", 3, nil), ("后天", 2, nil), ("明天", 1, nil), ("明日", 1, nil),
                ("明早", 1, .morning), ("明晚", 1, .evening),
                ("今天", 0, nil), ("今日", 0, nil), ("今早", 0, .morning), ("今晚", 0, .evening)
            ]
            for (word, offset, wordPeriod) in words {
                guard let match = matches(word).first else { continue }
                if date == nil { date = today.addingDays(offset) }
                if let wordPeriod, period == nil { period = wordPeriod }
                consume(match)
            }
        }

        private mutating func scanWeekdays() {
            guard date == nil else {
                return
            }
            let todayIndex = today.weekday.rawValue
            if let match = matches("(下下|下|这|本)?(?:个)?(?:周|星期|礼拜)" + QuickAddParser.weekdayPattern).first,
               let target = group(match, 2).flatMap(QuickAddParser.weekday) {
                let prefix = group(match, 1)
                let mondayOfThisWeek = today.addingDays(1 - todayIndex)
                let offsetInWeek = target.rawValue - 1
                switch prefix {
                case "下下": date = mondayOfThisWeek.addingDays(14 + offsetInWeek)
                case "下": date = mondayOfThisWeek.addingDays(7 + offsetInWeek)
                case "这", "本": date = mondayOfThisWeek.addingDays(offsetInWeek)
                default:
                    let delta = (target.rawValue - todayIndex + 7) % 7
                    date = today.addingDays(delta)
                }
                consume(match)
                return
            }
            if let match = matches("(下|这|本)?(?:个)?周末").first {
                let mondayOfThisWeek = today.addingDays(1 - todayIndex)
                if group(match, 1) == "下" {
                    date = mondayOfThisWeek.addingDays(12)
                } else {
                    // This weekend; on Sunday that is today.
                    date = todayIndex == Weekday.sunday.rawValue ? today : mondayOfThisWeek.addingDays(5)
                }
                consume(match)
            }
        }

        private static let periodPattern = "(凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|早|晚)?\\s*"

        private mutating func scanTimeRanges() {
            let clock = "(\\d{1,2})[:：](\\d{2})"
            // 15:00-16:30
            if let match = matches(Self.periodPattern + clock + "\\s*(?:-|~|到|至|—)\\s*" + Self.periodPattern + clock).first,
               let h1 = group(match, 2).flatMap({ Int($0) }), let m1 = group(match, 3).flatMap({ Int($0) }),
               let h2 = group(match, 5).flatMap({ Int($0) }), let m2 = group(match, 6).flatMap({ Int($0) }) {
                setPeriod(group(match, 1))
                start = (h1, m1, group(match, 1) != nil)
                end = (h2, m2, group(match, 4).flatMap(Period.init))
                consume(match)
                return
            }
            // 下午3点到4点半 / 3-5点 / 三点至五点
            let point = QuickAddParser.numberPattern + "\\s*(?:点|时)?(半|一刻|三刻|" + QuickAddParser.numberPattern + "分?)?"
            if let match = matches(Self.periodPattern + point + "\\s*(?:-|~|到|至|—)\\s*" + Self.periodPattern + QuickAddParser.numberPattern + "\\s*(?:点|时)(半|一刻|三刻|" + QuickAddParser.numberPattern + "分?)?").first,
               let h1 = group(match, 2).flatMap(QuickAddParser.number),
               let h2 = group(match, 6).flatMap(QuickAddParser.number) {
                setPeriod(group(match, 1))
                start = (h1, minutes(group(match, 3), group(match, 4)), group(match, 1) != nil)
                end = (h2, minutes(group(match, 7), group(match, 8)), group(match, 5).flatMap(Period.init))
                consume(match)
            }
        }

        private mutating func scanTimes() {
            guard start == nil else { return }
            if let match = matches(Self.periodPattern + "(\\d{1,2})[:：](\\d{2})").first,
               let hour = group(match, 2).flatMap({ Int($0) }),
               let minute = group(match, 3).flatMap({ Int($0) }) {
                setPeriod(group(match, 1))
                start = (hour, minute, group(match, 1) != nil)
                consume(match)
                return
            }
            if let match = matches("(?i)(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)").first,
               let hour = group(match, 1).flatMap({ Int($0) }) {
                let minute = group(match, 2).flatMap { Int($0) } ?? 0
                let isPM = group(match, 3)?.lowercased() == "pm"
                start = (isPM && hour < 12 ? hour + 12 : (!isPM && hour == 12 ? 0 : hour), minute, true)
                consume(match)
                return
            }
            let pattern = Self.periodPattern + QuickAddParser.numberPattern + "\\s*(?:点|时)(半|一刻|三刻|" + QuickAddParser.numberPattern + "分?)?"
            if let match = matches(pattern).first,
               let hour = group(match, 2).flatMap(QuickAddParser.number) {
                setPeriod(group(match, 1))
                start = (hour, minutes(group(match, 3), group(match, 4)), group(match, 1) != nil)
                consume(match)
            }
        }

        private mutating func scanPeriodsAlone() {
            // “晚上跑步” without a clock time keeps the item all-day; the word
            // is still removed from the title only when a time was found.
            guard start != nil, let match = matches("(凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里)").first else { return }
            setPeriod(group(match, 1))
            consume(match)
        }

        private mutating func setPeriod(_ word: Substring?) {
            guard let word, let value = Period(word) else { return }
            period = value
        }

        private func minutes(_ fraction: Substring?, _ digits: Substring?) -> Int {
            switch fraction {
            case "半": return 30
            case "一刻": return 15
            case "三刻": return 45
            default: return digits.flatMap(QuickAddParser.number) ?? 0
            }
        }

        private func resolve(_ hour: Int, _ minute: Int, explicit: Bool) -> MinuteOfDay? {
            var value = hour
            if let period {
                value = period.hour24(hour)
            } else if !explicit, (1...6).contains(hour) {
                // “3 点开会”: bare small hours are almost always afternoon.
                value = hour + 12
            }
            if value == 24 { value = 0 }
            return MinuteOfDay(hour: value, minute: minute)
        }

        func result(original: String) -> QuickAddParse {
            var title = original
            for range in consumed.sorted(by: { $0.location > $1.location }) {
                guard let swiftRange = Range(range, in: title) else { continue }
                title.replaceSubrange(swiftRange, with: " ")
            }
            let trimSet = CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "，,。.、:：;；-—~"))
            var cleaned = title
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: trimSet)
            if cleaned.isEmpty { cleaned = original.trimmingCharacters(in: .whitespacesAndNewlines) }
            var startTime: MinuteOfDay?
            var endTime: MinuteOfDay?
            if let start {
                startTime = resolve(start.hour, start.minute, explicit: start.explicitPeriod)
                if let end, let s = startTime {
                    if let endPeriod = end.period {
                        endTime = MinuteOfDay(hour: endPeriod.hour24(end.hour) % 24, minute: end.minute)
                    } else {
                        // “下午3点到5点” → 17:00; “晚上11点到1点” → 01:00 next day.
                        let candidates = [end.hour, end.hour < 12 ? end.hour + 12 : nil]
                            .compactMap { $0 }
                            .compactMap { MinuteOfDay(hour: $0 % 24, minute: end.minute) }
                        endTime = candidates.filter { $0 > s }.min() ?? candidates.first
                    }
                }
            }
            return QuickAddParse(
                title: cleaned,
                date: date,
                startTime: startTime,
                endTime: startTime == nil ? nil : endTime,
                wantsReminder: wantsReminder
            )
        }
    }
}
