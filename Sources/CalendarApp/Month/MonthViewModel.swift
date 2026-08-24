import CalendarDomain
import Combine
import Foundation

enum WeekStreamFocusDestination: Equatable, Sendable {
    case previousLogicalMonth
    case nextLogicalMonth
    case today(CalendarDate)
}

@MainActor
final class MonthViewModel: ObservableObject {
    @Published private(set) var state: CalendarState
    @Published private(set) var hiddenCategoryIDs: Set<UUID>
    @Published private(set) var today: CalendarDate

    private(set) var weekStream: WeekStreamModel
    private(set) var loadedRange: CalendarDateRange

    private var timelineProjection = TimelineProjection(entries: [])
    private var itemLookup: [String: ProjectedItem] = [:]

    var selectedDate: CalendarDate? {
        get { weekStream.selectedDate }
        set {
            objectWillChange.send()
            weekStream.updateSelection(to: newValue)
        }
    }

    init(
        centeredOn date: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    ) {
        let stream = WeekStreamModel(centeredOn: date)
        weekStream = stream
        loadedRange = Self.range(for: stream.weekStarts)
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.today = today
        rebuildProjection()
    }

    var weekStarts: [CalendarDate] {
        weekStream.weekStarts
    }

    var focusWeek: CalendarDate {
        weekStream.focusWeek
    }

    var monthTitleDate: CalendarDate {
        weekStream.monthTitleDate
    }

    var projectedEntries: [ProjectedEntry] {
        timelineProjection.entries
    }

    func projectedItem(withID id: String) -> ProjectedItem? {
        itemLookup[id]
    }

    func weekLayouts(laneCapacity: Int) -> [WeekLayout] {
        WeekSegmentLayout.make(
            entries: projectedEntries,
            weekStarts: weekStarts,
            laneCapacity: laneCapacity
        )
    }

    func update(
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    ) {
        objectWillChange.send()
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.today = today
        rebuildProjection()
    }

    func updateFocus(toWeekStarting week: CalendarDate) {
        objectWillChange.send()
        weekStream.updateFocus(toWeekStarting: week)
        rebuildItemLookup()
    }

    /// Bring a week from another calendar mode back into the month stream.
    /// Viewport teardown can leave `focusWeek` on `weekStarts[0]` (about a year
    /// earlier); this recenters the loaded window on the week the user still has.
    func reveal(weekContaining date: CalendarDate) {
        moveFocus(to: date, preservingCivilDayIntent: false)
    }

    /// Landing date for a month→week switch. A tap-selected day still wins,
    /// but chevron flips move the browsed month without clearing the old
    /// selection — following it would open the week grid on a month the user
    /// has already navigated away from, so fall back to the focus week.
    func monthToWeekAnchorDate() -> CalendarDate {
        guard let selectedDate,
              weekStream.selectionBelongsToFocusedLogicalMonth(selectedDate)
        else { return focusWeek }
        return selectedDate
    }

    func extendEarlier(visibleWeek: CalendarDate, pixelOffset: CGFloat) -> WeekStreamAnchor {
        objectWillChange.send()
        let anchor = weekStream.extendEarlier(
            visibleWeek: visibleWeek,
            pixelOffset: pixelOffset
        )
        rebuildProjection()
        return anchor
    }

    func extendLater(visibleWeek: CalendarDate, pixelOffset: CGFloat) -> WeekStreamAnchor {
        objectWillChange.send()
        let anchor = weekStream.extendLater(
            visibleWeek: visibleWeek,
            pixelOffset: pixelOffset
        )
        rebuildProjection()
        return anchor
    }

    func moveWeekStreamFocus(to destination: WeekStreamFocusDestination) {
        switch destination {
        case .previousLogicalMonth:
            moveFocus(to: weekStream.jumpTargetForPreviousMonth(), preservingCivilDayIntent: true)
        case .nextLogicalMonth:
            moveFocus(to: weekStream.jumpTargetForNextMonth(), preservingCivilDayIntent: true)
        case let .today(today):
            self.today = today
            selectedDate = today
            moveFocus(
                to: weekStream.todayTarget(today),
                preservingCivilDayIntent: false
            )
        }
    }

    private func moveFocus(to date: CalendarDate, preservingCivilDayIntent: Bool) {
        objectWillChange.send()
        weekStream.moveFocus(to: date, preservingCivilDayIntent: preservingCivilDayIntent)
        if !weekStream.recenterWindowAroundFocusIfNeeded() {
            ensureWeekIsLoaded(weekStream.focusWeek)
        }
        rebuildProjection()
    }

    private func ensureWeekIsLoaded(_ weekStart: CalendarDate) {
        while weekStart < weekStarts[0] {
            let previousFirst = weekStarts[0]
            _ = weekStream.extendEarlier(visibleWeek: previousFirst, pixelOffset: 0)
            precondition(
                weekStarts[0] < previousFirst,
                "Earlier week-stream extension did not advance toward the target."
            )
        }
        while weekStart > weekStarts[weekStarts.count - 1] {
            let previousLast = weekStarts[weekStarts.count - 1]
            _ = weekStream.extendLater(visibleWeek: previousLast, pixelOffset: 0)
            precondition(
                weekStarts[weekStarts.count - 1] > previousLast,
                "Later week-stream extension did not advance toward the target."
            )
        }
    }

    private func rebuildProjection() {
        let range = Self.range(for: weekStarts)
        let projection = TimelineProjection.make(
            in: range,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        )
        loadedRange = range
        timelineProjection = projection
        rebuildItemLookup()
    }

    private func rebuildItemLookup() {
        itemLookup = Dictionary(
            uniqueKeysWithValues: timelineProjection.entries.map {
                let item = ProjectedItem(entry: $0)
                return (item.id, item)
            }
        )
    }

    private static func range(for weekStarts: [CalendarDate]) -> CalendarDateRange {
        CalendarDateRange(
            start: weekStarts[0],
            end: weekStarts[weekStarts.count - 1].addingDays(6)
        )
    }
}

