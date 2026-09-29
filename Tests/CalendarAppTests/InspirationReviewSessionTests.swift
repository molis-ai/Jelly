import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("InspirationReviewSessionTests")
@MainActor
struct InspirationReviewSessionTests {
    private let captured = Date(timeIntervalSince1970: 1_790_000_000)
    private var reviewTime: Date { captured.addingTimeInterval(2 * 86_400) }

    private func storeWithThoughts(_ texts: [String]) async throws -> (WorkspaceStore, [InspirationID]) {
        var workspace = WorkspaceState.empty(calendar: makeEmptyState())
        var ids: [InspirationID] = []
        for (offset, text) in texts.enumerated() {
            let inspiration = Inspiration.text(
                rawText: text,
                categoryID: workspace.calendar.uncategorizedID,
                now: captured.addingTimeInterval(Double(offset))
            )
            workspace.inspirations[inspiration.id] = inspiration
            ids.append(inspiration.id)
        }
        let store = WorkspaceStore(initialState: workspace, repository: InMemoryWorkspaceRepository(workspace: workspace))
        await store.load()
        return (store, ids)
    }

    @Test func eachDecisionIsPersistedAndTheQueueAdvancesOldestFirst() async throws {
        let (store, ids) = try await storeWithThoughts(["留着的", "变成待办的", "丢掉的", "跳过的"])
        let now = reviewTime
        let session = InspirationReviewSession(store: store, clock: { now })
        #expect(session.queue == ids)
        #expect(session.progressText == "1 / 4")

        await session.keep()
        #expect(store.state.inspirations[ids[0]]?.lastReviewedAt == now)

        await session.schedule(.tomorrow)
        let itemID = try #require(store.state.inspirations[ids[1]]?.scheduledItemIDs.first)
        let item = try #require(store.state.calendar.items[itemID])
        #expect(item.title == "变成待办的")
        #expect(item.schedule.startDate == CalendarDate.today(now: now).addingDays(1))
        #expect(item.notes.contains("变成待办的"))

        await session.discard()
        #expect(store.state.inspirations[ids[2]]?.lifecycle == .archived)

        session.skip()
        #expect(store.state.inspirations[ids[3]]?.lastReviewedAt == nil)
        #expect(session.isFinished)
        #expect(session.tally == .init(kept: 1, scheduled: 1, discarded: 1, skipped: 1))

        let next = InspirationReviewSession(store: store, clock: { now.addingTimeInterval(3_600) })
        #expect(next.queue == [ids[3]])
    }

    @Test func freshThoughtsAreNotPulledIntoReviewYet() async throws {
        let (store, _) = try await storeWithThoughts(["刚记下"])
        let justNow = captured.addingTimeInterval(600)
        #expect(InspirationReviewSession(store: store, clock: { justNow }).queue.isEmpty)
    }

    @Test func undatedChoiceKeepsTheThoughtOutOfTheNextPass() async throws {
        let (store, ids) = try await storeWithThoughts(["以后再说的事"])
        let now = reviewTime
        let session = InspirationReviewSession(store: store, clock: { now })
        await session.schedule(.undated)
        let undated = try #require(store.state.undatedItems.values.first)
        #expect(undated.sourceInspirationID == ids[0])
        #expect(InspirationReviewQueue.due(in: store.state, now: now.addingTimeInterval(30 * 86_400)).isEmpty)
    }

    @Test func nudgeShowsOncePerDayUntilDismissed() throws {
        let suite = "jelly-review-nudge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = reviewTime
        #expect(!InspirationReviewNudge.shouldShow(dueCount: 0, now: now, defaults: defaults))
        #expect(InspirationReviewNudge.shouldShow(dueCount: 2, now: now, defaults: defaults))
        InspirationReviewNudge.dismiss(now: now, defaults: defaults)
        #expect(!InspirationReviewNudge.shouldShow(dueCount: 2, now: now.addingTimeInterval(60), defaults: defaults))
        #expect(InspirationReviewNudge.shouldShow(dueCount: 2, now: now.addingTimeInterval(86_400), defaults: defaults))
    }
}
