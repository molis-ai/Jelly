import CalendarDomain
import Foundation

struct WeekStreamAnchor: Equatable, Sendable {
    let weekStart: CalendarDate
    let pixelOffset: CGFloat
}

struct WeekStreamModel: Equatable, Sendable {
    private static let initialHalfWindowWeeks = 52
    private static let extensionWeeks = 52
    private static let maximumWindowWeeks = 157

    private(set) var weekStarts: [CalendarDate]
    private(set) var focusWeek: CalendarDate
    private(set) var selectedDate: CalendarDate?
    private var civilDayIntent: Int
    private var logicalMonth: CalendarDate

    init(centeredOn date: CalendarDate) {
        let centerWeek = Self.weekStart(containing: date)
        focusWeek = centerWeek
        selectedDate = nil
        civilDayIntent = date.day
        logicalMonth = Self.monthStart(centerWeek.addingDays(3))
        weekStarts = (-Self.initialHalfWindowWeeks...Self.initialHalfWindowWeeks).map {
            centerWeek.addingDays($0 * 7)
        }
    }

    var monthTitleDate: CalendarDate {
        focusWeek.addingDays(3)
    }

    static func weekStart(containing date: CalendarDate) -> CalendarDate {
        date.addingDays(-(date.weekday.rawValue - 1))
    }

    mutating func updateFocus(toWeekStarting week: CalendarDate) {
        focusWeek = Self.weekStart(containing: week)
        logicalMonth = Self.monthStart(focusWeek.addingDays(3))
    }

    mutating func updateSelection(to date: CalendarDate?) {
        selectedDate = date
    }

    /// True when `date` sits in the calendar month the stream is currently
    /// browsing (the title month). Chevron navigation moves this window while
    /// leaving `selectedDate` untouched, so callers can detect a stale
    /// selection before following it.
    func selectionBelongsToFocusedLogicalMonth(_ date: CalendarDate) -> Bool {
        Self.monthStart(date) == logicalMonth
    }

    mutating func moveFocus(to date: CalendarDate, preservingCivilDayIntent: Bool) {
        if preservingCivilDayIntent {
            logicalMonth = Self.monthStart(date)
            focusWeek = Self.focusWeek(forMonthNavigationTarget: date)
        } else {
            focusWeek = Self.weekStart(containing: date)
            civilDayIntent = date.day
            logicalMonth = Self.monthStart(focusWeek.addingDays(3))
        }
    }

    @discardableResult
    mutating func recenterWindowAroundFocusIfNeeded() -> Bool {
        let requiredFirst = focusWeek.addingDays(-Self.initialHalfWindowWeeks * 7)
        let requiredLast = focusWeek.addingDays(Self.initialHalfWindowWeeks * 7)
        guard weekStarts[0] > requiredFirst || weekStarts[weekStarts.count - 1] < requiredLast else {
            return false
        }
        weekStarts = (-Self.initialHalfWindowWeeks...Self.initialHalfWindowWeeks).map {
            focusWeek.addingDays($0 * 7)
        }
        return true
    }

    func jumpTargetForPreviousMonth() -> CalendarDate {
        monthTarget(offset: -1)
    }

    func jumpTargetForNextMonth() -> CalendarDate {
        monthTarget(offset: 1)
    }

    func todayTarget(_ today: CalendarDate) -> CalendarDate {
        today
    }

    mutating func extendEarlier(
        visibleWeek: CalendarDate,
        pixelOffset: CGFloat
    ) -> WeekStreamAnchor {
        let anchor = WeekStreamAnchor(
            weekStart: Self.weekStart(containing: visibleWeek),
            pixelOffset: pixelOffset
        )
        precondition(
            weekStarts.contains(anchor.weekStart),
            "Visible week anchor must belong to the loaded week stream."
        )
        let first = weekStarts[0]
        let newWeeks = (1...Self.extensionWeeks).reversed().map {
            first.addingDays(-$0 * 7)
        }
        weekStarts.insert(contentsOf: newWeeks, at: 0)
        trimToMaximum(afterExtending: .earlier, preserving: anchor.weekStart)
        return anchor
    }

    mutating func extendLater(
        visibleWeek: CalendarDate,
        pixelOffset: CGFloat
    ) -> WeekStreamAnchor {
        let anchor = WeekStreamAnchor(
            weekStart: Self.weekStart(containing: visibleWeek),
            pixelOffset: pixelOffset
        )
        precondition(
            weekStarts.contains(anchor.weekStart),
            "Visible week anchor must belong to the loaded week stream."
        )
        let last = weekStarts[weekStarts.count - 1]
        weekStarts.append(contentsOf: (1...Self.extensionWeeks).map {
            last.addingDays($0 * 7)
        })
        trimToMaximum(afterExtending: .later, preserving: anchor.weekStart)
        return anchor
    }

    private enum ExtensionDirection {
        case earlier
        case later
    }

    private mutating func trimToMaximum(
        afterExtending direction: ExtensionDirection,
        preserving anchorWeek: CalendarDate
    ) {
        guard weekStarts.count > Self.maximumWindowWeeks else { return }

        let focusIsInExpandedWindow = contains(focusWeek, from: weekStarts[0], through: weekStarts[weekStarts.count - 1])
        let afterTrimmingEarlierStart = weekStarts[Self.extensionWeeks]
        let afterTrimmingLaterEnd = weekStarts[weekStarts.count - Self.extensionWeeks - 1]
        let canTrimEarlier = contains(
            anchorWeek,
            from: afterTrimmingEarlierStart,
            through: weekStarts[weekStarts.count - 1]
        ) && (!focusIsInExpandedWindow || contains(
            focusWeek,
            from: afterTrimmingEarlierStart,
            through: weekStarts[weekStarts.count - 1]
        ))
        let canTrimLater = contains(
            anchorWeek,
            from: weekStarts[0],
            through: afterTrimmingLaterEnd
        ) && (!focusIsInExpandedWindow || contains(
            focusWeek,
            from: weekStarts[0],
            through: afterTrimmingLaterEnd
        ))
        precondition(
            canTrimEarlier || canTrimLater,
            "No bounded week window can preserve both focus and visible anchor."
        )

        let firstDistance = abs(focusWeek.days(until: weekStarts[0]))
        let lastDistance = abs(focusWeek.days(until: weekStarts[weekStarts.count - 1]))
        let shouldTrimEarlier: Bool
        if canTrimEarlier != canTrimLater {
            shouldTrimEarlier = canTrimEarlier
        } else if firstDistance == lastDistance {
            // A tie has no farther side. Preserve the edge that triggered loading.
            shouldTrimEarlier = direction == .later
        } else {
            shouldTrimEarlier = firstDistance > lastDistance
        }

        if shouldTrimEarlier {
            weekStarts.removeFirst(Self.extensionWeeks)
        } else {
            weekStarts.removeLast(Self.extensionWeeks)
        }
        precondition(weekStarts.contains(anchorWeek), "Week-stream trim removed its visible anchor.")
        if focusIsInExpandedWindow {
            precondition(weekStarts.contains(focusWeek), "Week-stream trim removed its focus week.")
        }
    }

    private func contains(
        _ date: CalendarDate,
        from start: CalendarDate,
        through end: CalendarDate
    ) -> Bool {
        start <= date && date <= end
    }

    private func monthTarget(offset: Int) -> CalendarDate {
        let targetMonth = Self.offsetMonth(
            year: logicalMonth.year,
            month: logicalMonth.month,
            by: offset
        )
        let lastDay = Self.lastDay(ofYear: targetMonth.year, month: targetMonth.month)
        return CalendarDate(
            year: targetMonth.year,
            month: targetMonth.month,
            day: min(civilDayIntent, lastDay)
        )!
    }

    private static func offsetMonth(year: Int, month: Int, by offset: Int) -> (year: Int, month: Int) {
        let zeroBasedMonth = year * 12 + month - 1 + offset
        return (zeroBasedMonth / 12, zeroBasedMonth % 12 + 1)
    }

    private static func lastDay(ofYear year: Int, month: Int) -> Int {
        let nextMonth = offsetMonth(year: year, month: month, by: 1)
        return CalendarDate(year: nextMonth.year, month: nextMonth.month, day: 1)!
            .previousDay
            .day
    }

    private static func focusWeek(forMonthNavigationTarget target: CalendarDate) -> CalendarDate {
        let targetMonth = monthStart(target)
        let naturalFocusWeek = weekStart(containing: target)
        let naturalTitleDate = naturalFocusWeek.addingDays(3)
        guard naturalTitleDate.year != targetMonth.year
                || naturalTitleDate.month != targetMonth.month
        else {
            return naturalFocusWeek
        }
        return naturalTitleDate < targetMonth
            ? naturalFocusWeek.addingDays(7)
            : naturalFocusWeek.addingDays(-7)
    }

    private static func monthStart(_ date: CalendarDate) -> CalendarDate {
        CalendarDate(year: date.year, month: date.month, day: 1)!
    }
}
