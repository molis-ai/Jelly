import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("UndatedListModelTests")
@MainActor
struct UndatedListModelTests {
    /// Monday 2026-09-28 10:00 in Shanghai.
    private let now = Date(timeIntervalSince1970: 1_790_560_800)
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private var today: CalendarDate { CalendarDate.localDay(containing: now, in: zone) }

    private func model() async throws -> (UndatedListModel, WorkspaceStore) {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let fixed = now
        return (UndatedListModel(store: store, clock: { fixed }, timeZone: zone), store)
    }

    @Test func plainTextGoesToTheListAndCanBeScheduledLater() async throws {
        let (list, store) = try await model()
        list.draft = "学一下尤克里里"
        #expect(list.draftRecognition == nil)
        #expect(await list.add() == .listed)
        #expect(list.draft.isEmpty)
        let item = try #require(list.items.first)
        #expect(item.title == "学一下尤克里里")

        #expect(await list.schedule(item.id, choice: .tomorrow))
        #expect(store.state.undatedItems.isEmpty)
        let scheduled = try #require(store.state.calendar.items.values.first)
        #expect(scheduled.title == "学一下尤克里里")
        #expect(scheduled.schedule.startDate == today.addingDays(1))
        #expect(scheduled.schedule.startTime == nil)
    }

    @Test func textWithADateSkipsTheListAndKeepsTheReminder() async throws {
        let (list, store) = try await model()
        list.draft = "明天下午3点提醒我开会"
        #expect(list.draftRecognition?.contains("15:00–16:00") == true)
        #expect(await list.add() == .scheduled(today.addingDays(1)))
        #expect(store.state.undatedItems.isEmpty)
        let item = try #require(store.state.calendar.items.values.first)
        #expect(item.title == "开会")
        #expect(item.schedule.startTime == MinuteOfDay(hour: 15, minute: 0))
        #expect(item.reminder == .beforeStart(minutes: 0))
    }

    @Test func renameAndDeleteAreUndoable() async throws {
        let (list, store) = try await model()
        list.draft = "整理照片"
        await list.add()
        let id = try #require(list.items.first?.id)
        #expect(await list.rename(id, to: "整理 2025 年的照片"))
        #expect(store.state.undatedItems[id]?.title == "整理 2025 年的照片")
        #expect(await list.delete(id))
        #expect(store.state.undatedItems.isEmpty)
        _ = try await store.undo()
        #expect(store.state.undatedItems[id]?.title == "整理 2025 年的照片")
    }

    @Test func draftApplyingMovesDateOutOfTheTitle() throws {
        let draft = ItemDraft.newItem(from: today, through: today, categoryID: UUID())
        let parse = QuickAddParser.parse("周五晚上7点 聚餐 提醒我", today: today)
        let applied = try draft.applying(parse)
        #expect(applied.title == "聚餐")
        #expect(applied.startDate == today.addingDays(4))
        #expect(applied.usesTime)
        #expect(applied.startTime == MinuteOfDay(hour: 19, minute: 0))
        #expect(applied.reminder == .beforeStart(minutes: 0))
        #expect(QuickAddPresentation.summary(parse, defaultDate: today) == "10月2日 周五 19:00–20:00 · 提醒")
    }
}
