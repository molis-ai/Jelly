import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("SeriesReminderTests")
@MainActor
struct SeriesReminderTests {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    /// Monday 2026-10-05.
    private let monday = CalendarDate(year: 2026, month: 10, day: 5)!

    private func weekly(reminder: ItemReminder?) throws -> WeeklySeries {
        try WeeklySeries(
            id: UUID(),
            kind: .task,
            title: "周会",
            categoryID: makeEmptyState().uncategorizedID,
            ruleStartDate: monday,
            recurrenceEndDate: nil,
            weekdays: [.monday],
            durationDays: 1,
            startTime: MinuteOfDay(hour: 10, minute: 0),
            endTime: MinuteOfDay(hour: 11, minute: 0),
            reminder: reminder,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func date(_ day: CalendarDate, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    @Test func everyUpcomingOccurrenceRingsExceptSkippedAndCompletedOnes() throws {
        let series = try weekly(reminder: .beforeStart(minutes: 15))
        var state = WorkspaceState.empty(calendar: makeEmptyState())
        state.calendar.recurrence.series[series.id] = series
        let skipped = OccurrenceKey(seriesID: series.id, originalDate: monday.addingDays(7))
        let done = OccurrenceKey(seriesID: series.id, originalDate: monday.addingDays(14))
        state.calendar.recurrence.exceptions[skipped] = .skipped
        state.calendar.recurrence.completions[done] = OccurrenceCompletion(key: done, completedAt: .distantPast)

        let now = date(monday, 8)
        let requests = ReminderPlanner.requests(in: state, now: now, timeZone: zone, horizonDays: 29)
        #expect(requests.map(\.dueDay) == [monday, monday.addingDays(21), monday.addingDays(28)])
        #expect(requests.first?.fireDate == date(monday, 9, 45))
        #expect(requests.first?.key == ReminderPlanner.occurrenceKey(OccurrenceKey(seriesID: series.id, originalDate: monday)))
        #expect(requests.allSatisfy { $0.title == "周会" })
    }

    @Test func creatingARepeatingItemKeepsItsReminder() throws {
        var draft = ItemDraft.newItem(from: monday, through: monday, categoryID: makeEmptyState().uncategorizedID)
        draft.title = "晨跑"
        draft.repeatsWeekly = true
        draft.weekdays = [.monday, .wednesday]
        draft.reminder = .onStartDay(at: MinuteOfDay(hour: 7, minute: 0)!)
        let command = try ItemEditorViewModel(mode: .create, draft: draft).makeCommand(
            now: .now, newItemID: UUID(), newSeriesID: UUID(), timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case let .createSeries(series) = command else {
            Issue.record("expected a series")
            return
        }
        #expect(series.reminder == .onStartDay(at: MinuteOfDay(hour: 7, minute: 0)!))
    }

    @Test func thisAndFutureChangesTheSeriesReminderButOnlyThisCannot() throws {
        let series = try weekly(reminder: .beforeStart(minutes: 10))
        let key = OccurrenceKey(seriesID: series.id, originalDate: monday.addingDays(7))
        let occurrence = try #require(RecurrenceEngine.occurrences(
            of: series,
            in: CalendarDateRange(start: key.originalDate, end: key.originalDate),
            exceptions: [:],
            completions: [:]
        ).first)
        var draft = ItemDraft(occurrence: occurrence, series: series)
        #expect(draft.reminder == .beforeStart(minutes: 10))
        draft.reminder = .beforeStart(minutes: 30)

        let future = ItemEditorViewModel(mode: .editOccurrence(series: series, key: key, scope: .thisAndFuture), draft: ItemDraft(occurrence: occurrence, series: series))
        future.draft = draft
        guard case let .mutateSeries(_, .thisAndFuture, .patch(patch), newID) = try future.makeCommand(
            now: .now, newItemID: UUID(), newSeriesID: UUID(), timeZoneIdentifier: "Asia/Shanghai"
        ) else {
            Issue.record("expected a series patch")
            return
        }
        guard case .set(.beforeStart(minutes: 30)) = patch.reminder else {
            Issue.record("reminder should travel with this-and-future")
            return
        }
        let graph = RecurrenceGraph(series: [series.id: series], exceptions: [:], completions: [:])
        let result = try SeriesMutationEngine.apply(edit: .patch(patch), to: key, scope: .thisAndFuture, in: graph, newSeriesID: newID, now: .now)
        #expect(result.series[newID]?.reminder == .beforeStart(minutes: 30))
        #expect(result.series[series.id]?.reminder == .beforeStart(minutes: 10))

        let onlyThis = ItemEditorViewModel(mode: .editOccurrence(series: series, key: key, scope: .onlyThis), draft: ItemDraft(occurrence: occurrence, series: series))
        onlyThis.draft = draft
        guard case let .mutateSeries(_, .onlyThis, .patch(thisPatch), _) = try onlyThis.makeCommand(
            now: .now, newItemID: UUID(), newSeriesID: UUID(), timeZoneIdentifier: "Asia/Shanghai"
        ), case .unchanged = thisPatch.reminder else {
            Issue.record("only-this must not touch the series reminder")
            return
        }
        #expect(throws: SeriesMutationError.invalidOnlyThisRulePatch) {
            try SeriesMutationEngine.apply(
                edit: .patch(SeriesPatch(reminder: .clear)),
                to: key, scope: .onlyThis, in: graph, newSeriesID: UUID(), now: .now
            )
        }
    }

    @Test func seriesReminderSurvivesEncodingAndUndo() throws {
        let series = try weekly(reminder: .beforeStart(minutes: 5))
        let decoded = try JSONDecoder().decode(WeeklySeries.self, from: JSONEncoder().encode(series))
        #expect(decoded.reminder == .beforeStart(minutes: 5))

        var before = WorkspaceState.empty(calendar: makeEmptyState())
        before.calendar.recurrence.series[series.id] = series
        var after = before
        after.calendar.recurrence.series[series.id]?.reminder = nil
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: after, label: "去掉提醒"))
        let undone = try WorkspaceUndoReducer.apply(record, direction: .undo, to: after, noteRevisionHighWatermarks: [:]).candidate
        #expect(undone.calendar.recurrence.series[series.id]?.reminder == .beforeStart(minutes: 5))
    }
}
