import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DecompositionWorkspaceStoreTests")
@MainActor
struct DecompositionWorkspaceStoreTests {
    @Test func oneUndoRemovesOnlyObjectsCreatedByPlan() async throws {
        let fixture = try StorePlanFixture.make()
        let repository = WorkspaceStoreTestRepository(initial: fixture.workspace)
        let store = WorkspaceStore(initialState: fixture.workspace, repository: repository)
        await store.load()
        let original = store.state
        let payload = try fixture.validPayload()

        let outcome = try await store.sendWorkspace(
            .applyDecompositionPlan(payload), undoLabel: "拆开并安排"
        )
        guard case .committed = outcome else {
            Issue.record("plan must commit before undo is exercised")
            return
        }
        #expect(store.latestUndoLabel == "拆开并安排")
        #expect(store.state.calendar.items[StorePlanFixture.itemID] != nil)
        #expect(planObjectsArePresent(store.state))

        let unrelated = try StorePlanFixture.untimedItem(
            id: StorePlanFixture.unrelatedItemID,
            title: "无关事项"
        )
        _ = try await store.sendCalendar(.createItem(unrelated), undoLabel: "无关事项")
        _ = try await store.undo()
        #expect(store.calendarState.items[unrelated.id] == nil)
        #expect(planObjectsArePresent(store.state))
        _ = try await store.undo()
        #expect(planObjectsAreAbsent(store.state))
        #expect(originalObjectsAreUnchanged(store.state, original: original))
    }

    @Test func planReverseRecordDoesNotRollBackALaterUnrelatedNoteEdit() async throws {
        let fixture = try StorePlanFixture.make()
        let repository = WorkspaceStoreTestRepository(initial: fixture.workspace)
        let store = WorkspaceStore(initialState: fixture.workspace, repository: repository)
        await store.load()
        let beforePlan = store.state
        let payload = try fixture.validPayload()

        guard case .committed = try await store.sendWorkspace(
            .applyDecompositionPlan(payload), undoLabel: "拆开并安排"
        ) else {
            Issue.record("plan must commit before reverse is exercised")
            return
        }
        let afterPlan = store.state
        let planRecord = try #require(WorkspaceUndoReducer.record(
            before: beforePlan,
            after: afterPlan,
            label: "拆开并安排"
        ))

        let other = try #require(store.state.notes[StorePlanFixture.otherNoteID])
        var submitted = other
        submitted.title = "后来改的无关笔记"
        let submission = NoteDraftSubmission(
            noteID: other.id,
            editSessionID: StorePlanFixture.editSessionID,
            baseNoteRevision: other.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(other),
            baseSnapshot: other,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: 1,
            snapshot: submitted,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submitted),
            modifiedFields: [.title],
            linkedBlockDeletionDispositions: [:]
        )
        guard case .committed = try await store.sendWorkspace(
            .updateNote(submission), undoLabel: "改无关笔记"
        ) else {
            Issue.record("unrelated note edit must commit")
            return
        }

        let application = try WorkspaceUndoReducer.apply(
            planRecord,
            direction: .undo,
            to: store.state,
            noteRevisionHighWatermarks: [StorePlanFixture.otherNoteID: store.state.notes[StorePlanFixture.otherNoteID]!.revision]
        )
        #expect(application.candidate.notes[StorePlanFixture.otherNoteID]?.title == "后来改的无关笔记")
        #expect(planObjectsAreAbsent(application.candidate))
        #expect(application.candidate.notes[StorePlanFixture.noteID]?.document.blocks.map(\.id)
            == beforePlan.notes[StorePlanFixture.noteID]?.document.blocks.map(\.id))
    }

    @Test func persistenceFailureDoesNotPublishAPartialPlan() async throws {
        let fixture = try StorePlanFixture.make()
        let repository = WorkspaceStoreTestRepository(initial: fixture.workspace)
        let store = WorkspaceStore(initialState: fixture.workspace, repository: repository)
        await store.load()
        let original = store.state
        await repository.failNextSave()
        let payload = try fixture.validPayload()

        let outcome = try await store.sendWorkspace(
            .applyDecompositionPlan(payload),
            undoLabel: "拆开并安排"
        )
        guard case let .notCommitted(_, journal, artifacts) = outcome else {
            Issue.record("persistence failure must return a non-committed outcome")
            return
        }
        #expect(journal == .clean)
        #expect(artifacts == .init())
        #expect(store.state == original)
        #expect(planObjectsAreAbsent(store.state))
        #expect(store.canUndo == false)
        #expect(await repository.saveCount == 0)
        #expect(store.state.revision == original.revision)

        let retry = try await store.sendWorkspace(
            .applyDecompositionPlan(payload),
            undoLabel: "拆开并安排"
        )
        guard case .committed = retry else {
            Issue.record("the same payload must commit after a failed save")
            return
        }
        #expect(planObjectsArePresent(store.state))
        let tasks = store.state.notes[StorePlanFixture.noteID]?.document.blocks.filter { $0.kind == .task } ?? []
        #expect(tasks.map(\.id) == [StorePlanFixture.firstTaskID, StorePlanFixture.secondTaskID])
        #expect(store.state.calendar.items.keys.sorted(by: { $0.uuidString < $1.uuidString })
            == [StorePlanFixture.itemID])
        #expect(store.state.taskBlockLinks.map(\.calendarItemID) == [StorePlanFixture.itemID])
        #expect(store.state.revision == original.revision + 1)
        #expect(await repository.saveCount == 1)
        #expect(store.canUndo)
    }
}

private struct StorePlanFixture {
    static let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
    static let sourceBlockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000702")!)
    static let firstTaskID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000703")!)
    static let secondTaskID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000704")!)
    static let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000705")!
    static let unrelatedItemID = UUID(uuidString: "00000000-0000-0000-0000-000000000706")!
    static let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000707")!)
    static let otherNoteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000708")!)
    static let editSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000709")!
    static let day = CalendarDate(year: 2026, month: 8, day: 10)!
    static let now = Date(timeIntervalSince1970: 1_786_220_000)

    let workspace: WorkspaceState

    static func make() throws -> StorePlanFixture {
        let calendar = CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        let source = Note(
            id: noteID,
            title: "来源笔记",
            document: .init(blocks: [
                .init(
                    id: sourceBlockID,
                    kind: .paragraph,
                    inlineContent: .plain("预约牙医"),
                    taskState: nil,
                    indentLevel: 0
                )
            ]),
            categoryID: uncategorizedID,
            archivedAt: nil,
            revision: 3,
            createdAt: now,
            updatedAt: now
        )
        let other = Note(
            id: otherNoteID,
            title: "另一篇",
            document: .empty(),
            categoryID: uncategorizedID,
            archivedAt: nil,
            revision: 1,
            createdAt: now,
            updatedAt: now
        )
        let workspace = WorkspaceState(
            revision: 5,
            calendar: calendar,
            notes: [source.id: source, other.id: other],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [],
            materialDigests: [:]
        )
        return .init(workspace: workspace)
    }

    func validPayload() throws -> ApplyDecompositionPlanPayload {
        let first = try DocumentBlock.task(
            id: Self.firstTaskID,
            text: "打电话",
            completionDescription: "拿到明确上门时间"
        )
        let second = try DocumentBlock.task(
            id: Self.secondTaskID,
            text: "记录时间",
            completionDescription: "写进日历备注"
        )
        let item = try CalendarItem(
            id: Self.itemID,
            kind: .task,
            title: "记录时间",
            categoryID: Self.uncategorizedID,
            schedule: CalendarSchedule(
                startDate: Self.day,
                endDate: Self.day,
                startTime: MinuteOfDay(hour: 9, minute: 30),
                endTime: MinuteOfDay(hour: 10, minute: 0)
            ),
            creationTimeZoneIdentifier: "UTC",
            completedAt: nil,
            createdAt: Self.now,
            updatedAt: Self.now
        )
        return ApplyDecompositionPlanPayload(
            noteID: Self.noteID,
            expectedNoteRevision: 3,
            expectedWorkspaceRevision: workspace.revision,
            insertionAnchor: .after(Self.sourceBlockID),
            taskBlocks: [first, second],
            calendarItems: [item],
            links: [
                TaskBlockCalendarLink(
                    noteID: Self.noteID,
                    blockID: Self.secondTaskID,
                    calendarItemID: Self.itemID
                )
            ]
        )
    }

    static func untimedItem(id: UUID, title: String) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            kind: .task,
            title: title,
            categoryID: uncategorizedID,
            schedule: CalendarSchedule(
                startDate: day,
                endDate: day,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}

private func planObjectsArePresent(_ state: WorkspaceState) -> Bool {
    state.notes[StorePlanFixture.noteID]?.document.blocks.contains(where: {
        $0.id == StorePlanFixture.firstTaskID
    }) == true
        && state.notes[StorePlanFixture.noteID]?.document.blocks.contains(where: {
            $0.id == StorePlanFixture.secondTaskID
        }) == true
        && state.calendar.items[StorePlanFixture.itemID] != nil
        && state.taskBlockLinks.contains(TaskBlockCalendarLink(
            noteID: StorePlanFixture.noteID,
            blockID: StorePlanFixture.secondTaskID,
            calendarItemID: StorePlanFixture.itemID
        ))
        && state.calendarNoteRelations.baselines[.item(StorePlanFixture.itemID)]?.primaryNoteID
            == StorePlanFixture.noteID
}

private func planObjectsAreAbsent(_ state: WorkspaceState) -> Bool {
    state.notes[StorePlanFixture.noteID]?.document.blocks.contains(where: {
        $0.id == StorePlanFixture.firstTaskID || $0.id == StorePlanFixture.secondTaskID
    }) != true
        && state.calendar.items[StorePlanFixture.itemID] == nil
        && !state.taskBlockLinks.contains(where: { $0.calendarItemID == StorePlanFixture.itemID })
        && state.calendarNoteRelations.baselines[.item(StorePlanFixture.itemID)] == nil
}

private func originalObjectsAreUnchanged(_ state: WorkspaceState, original: WorkspaceState) -> Bool {
    state.notes[StorePlanFixture.noteID]?.document.blocks.map(\.id)
        == original.notes[StorePlanFixture.noteID]?.document.blocks.map(\.id)
        && state.notes[StorePlanFixture.otherNoteID]?.title
            == original.notes[StorePlanFixture.otherNoteID]?.title
        && state.calendar.items[StorePlanFixture.itemID] == nil
}
