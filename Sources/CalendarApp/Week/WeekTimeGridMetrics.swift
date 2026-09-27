import CoreGraphics

enum WeekTimeGridMetrics {
    static let hourHeight: CGFloat = 48
    static let hourCount = 24
    static let gutterWidth: CGFloat = 48
    /// Compact all-day strip height (single row of chips).
    static let allDayChipHeight: CGFloat = 22
    static let allDayChipSpacing: CGFloat = 3
    static let allDayVerticalPadding: CGFloat = 6
    static let allDayMinHeight: CGFloat = 34
    /// Viewport shows this many chips; overflow scrolls (no +N truncate).
    static let allDayVisibleRows = 3
    /// Expanded viewport cap; beyond this the per-column scroll still applies.
    static let allDayExpandedRowLimit = 8
    static let dayHeaderHeight: CGFloat = 44
    static let gridCoordinateSpace = "week-timed-grid"

    static var gridHeight: CGFloat {
        CGFloat(hourCount) * hourHeight
    }

    /// First-appearance scroll target: one hour above "now", clamped, so the
    /// current time band sits just below the top edge instead of a fixed 08:00.
    static func initialAutoScrollHour(forNowMinuteOfDay minuteOfDay: Int) -> Int {
        let nowHour = min(max(minuteOfDay / 60, 0), hourCount - 1)
        return max(0, nowHour - 1)
    }

    static func yOffset(minute: Int) -> CGFloat {
        CGFloat(minute) / 60 * hourHeight
    }

    static func blockHeight(startMinute: Int, endMinute: Int) -> CGFloat {
        max(hourHeight * 0.35, yOffset(minute: endMinute - startMinute))
    }

    /// Fixed viewport for the given chip row count (scroll inside for more).
    static func allDaySectionHeight(rowCount: Int) -> CGFloat {
        let rows = max(1, rowCount)
        let content = CGFloat(rows) * allDayChipHeight + CGFloat(rows - 1) * allDayChipSpacing
        return max(allDayMinHeight, content + allDayVerticalPadding * 2)
    }

    /// Collapsed viewport height (`allDayVisibleRows`).
    static var allDaySectionHeight: CGFloat {
        allDaySectionHeight(rowCount: allDayVisibleRows)
    }
}
