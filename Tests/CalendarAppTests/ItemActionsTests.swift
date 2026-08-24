import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("ItemActionsTests")
@MainActor
struct ItemActionsTests {
    @Test func copyToDayCreatesIndependentOneOffOnToday() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000903")!
        let today = CalendarDate(year: 2026, month: 8, day: 24)!
        let now = Date(timeIntervalSince1970: 1_756_000_300)
        let source = try CalendarItem(
            id: sourceID,
            kind: .task,
            title: "周复盘",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 10)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 10)!,
                startTime: MinuteOfDay(hour: 18, minute: 0)!,
                endTime: MinuteOfDay(hour: 19, minute: 0)!
            ),
            priority: .p0,
            isPinned: true,
            notes: "看指标",
            completedAt: now,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let command = try ItemActions.copyToDay(
            .item(source),
            day: today,
            id: copyID,
            now: now
        )
        guard case let .createItem(copy) = command else {
            Issue.record("Expected createItem for a same-day copy")
            return
        }
        #expect(copy.id == copyID)
        #expect(copy.id != sourceID)
        #expect(copy.title == "周复盘")
        #expect(copy.schedule.startDate == today)
        #expect(copy.schedule.startTime == MinuteOfDay(hour: 18, minute: 0)!)
        #expect(copy.completedAt == nil)
        #expect(copy.isPinned == false)
        #expect(copy.priority == .p0)
        #expect(copy.notes == "看指标")
    }

    @Test func copyToDayTurnsOccurrenceIntoOneOffInsteadOfSeriesEdit() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000904")!
        let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000905")!
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000906")!
        let originalDate = CalendarDate(year: 2026, month: 8, day: 3)!
        let today = CalendarDate(year: 2026, month: 8, day: 24)!
        let now = Date(timeIntervalSince1970: 1_756_000_400)
        let occurrence = CalendarOccurrence(
            key: OccurrenceKey(seriesID: seriesID, originalDate: originalDate),
            schedule: try CalendarSchedule(
                startDate: originalDate,
                endDate: originalDate,
                startTime: nil,
                endTime: nil
            ),
            title: "每周站会",
            kind: .task,
            categoryID: categoryID,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: .distantPast
        )

        let command = try ItemActions.copyToDay(
            .occurrence(occurrence),
            day: today,
            id: copyID,
            now: now
        )
        guard case let .createItem(copy) = command else {
            Issue.record("Occurrence copy must be a one-off createItem, not mutateSeries")
            return
        }
        #expect(copy.id == copyID)
        #expect(copy.schedule.startDate == today)
        #expect(copy.title == "每周站会")
        #expect(copy.kind == .task)
    }
}
