import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DecompositionPlanBuilderTests")
struct DecompositionPlanBuilderTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let now = Date(timeIntervalSince1970: 1_787_356_800)
    private let day = CalendarDate(year: 2026, month: 8, day: 22)!
    private let firstBlockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000901")!)
    private let secondBlockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000902")!)
    private let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000903")!
    private let extraItemID = UUID(uuidString: "00000000-0000-0000-0000-000000000904")!

    @Test func builderCreatesAllSelectedTasksButOnlyScheduledItems() throws {
        let snapshot = try selectionSnapshot()
        let payload = try DecompositionPlanBuilder.makePayload(
            snapshot: snapshot,
            candidates: [selectedScheduled, selectedUnscheduled, deselected],
            note: try sourceNote(revision: 3),
            workspaceRevision: 9,
            now: now,
            ids: DecompositionPlanIDs(
                blockIDs: [firstBlockID, secondBlockID],
                calendarItemIDs: [itemID]
            ),
            timeZone: shanghai
        )
        #expect(payload.taskBlocks.count == 2)
        #expect(payload.calendarItems.count == 1)
        #expect(payload.links.count == 1)
        #expect(payload.calendarItems[0].title
            == payload.taskBlocks[0].inlineContent.spans.map(\.text).joined())
        #expect(payload.taskBlocks.map(\.id) == [firstBlockID, secondBlockID])
        #expect(payload.calendarItems.map(\.id) == [itemID])
        #expect(payload.links == [
            TaskBlockCalendarLink(
                noteID: FixtureIDs.noteID,
                blockID: firstBlockID,
                calendarItemID: itemID
            )
        ])
        #expect(payload.noteID == FixtureIDs.noteID)
        #expect(payload.expectedNoteRevision == 3)
        #expect(payload.expectedWorkspaceRevision == 9)
        #expect(payload.calendarItems[0].createdAt == now)
        #expect(payload.calendarItems[0].updatedAt == now)
    }

    @Test func selectionSnapshotInsertsAfterTheSourceBlock() throws {
        let payload = try DecompositionPlanBuilder.makePayload(
            snapshot: try selectionSnapshot(),
            candidates: [selectedUnscheduled],
            note: try sourceNote(revision: 3),
            workspaceRevision: 4,
            now: now,
            ids: DecompositionPlanIDs(blockIDs: [firstBlockID], calendarItemIDs: []),
            timeZone: shanghai
        )
        #expect(payload.insertionAnchor == .after(FixtureIDs.sourceBlockID))
    }

    @Test func wholeNoteSnapshotAppendsAtEnd() throws {
        let payload = try DecompositionPlanBuilder.makePayload(
            snapshot: try wholeNoteSnapshot(),
            candidates: [selectedUnscheduled],
            note: try sourceNote(revision: 3),
            workspaceRevision: 4,
            now: now,
            ids: DecompositionPlanIDs(blockIDs: [firstBlockID], calendarItemIDs: []),
            timeZone: shanghai
        )
        #expect(payload.insertionAnchor == .end)
        #expect(payload.taskBlocks.count == 1)
        #expect(payload.calendarItems.isEmpty)
        #expect(payload.links.isEmpty)
    }

    @Test func emptyCreationSelectionIsRejected() throws {
        #expect(throws: DecompositionPlanBuilderError.noSelectedTasks) {
            try DecompositionPlanBuilder.makePayload(
                snapshot: try selectionSnapshot(),
                candidates: [deselected],
                note: try sourceNote(revision: 3),
                workspaceRevision: 4,
                now: now,
                ids: DecompositionPlanIDs(blockIDs: [], calendarItemIDs: []),
                timeZone: shanghai
            )
        }
    }

    @Test func calendarSelectionWithoutProposalIsRejected() throws {
        var missing = selectedScheduled
        missing.proposal = nil
        #expect(throws: DecompositionPlanBuilderError.missingCalendarProposal(missing.id)) {
            try DecompositionPlanBuilder.makePayload(
                snapshot: try selectionSnapshot(),
                candidates: [missing],
                note: try sourceNote(revision: 3),
                workspaceRevision: 4,
                now: now,
                ids: DecompositionPlanIDs(blockIDs: [firstBlockID], calendarItemIDs: [itemID]),
                timeZone: shanghai
            )
        }
    }

    @Test func completionDescriptionWritesToTaskStateNotCalendarTitle() throws {
        let payload = try DecompositionPlanBuilder.makePayload(
            snapshot: try selectionSnapshot(),
            candidates: [selectedScheduled],
            note: try sourceNote(revision: 3),
            workspaceRevision: 4,
            now: now,
            ids: DecompositionPlanIDs(blockIDs: [firstBlockID], calendarItemIDs: [itemID]),
            timeZone: shanghai
        )
        #expect(payload.taskBlocks[0].taskState?.completionDescription == "拿到明确上门时间")
        #expect(payload.calendarItems[0].title == "给物业打电话")
        #expect(payload.calendarItems[0].notes.isEmpty)
        #expect(!payload.calendarItems[0].title.contains("上门"))
    }

    @Test func idCountsMustMatchCreatedTasksAndScheduledItemsExactly() throws {
        #expect(throws: DecompositionPlanBuilderError.idCountMismatch) {
            try DecompositionPlanBuilder.makePayload(
                snapshot: try selectionSnapshot(),
                candidates: [selectedScheduled, selectedUnscheduled],
                note: try sourceNote(revision: 3),
                workspaceRevision: 4,
                now: now,
                ids: DecompositionPlanIDs(
                    blockIDs: [firstBlockID],
                    calendarItemIDs: [itemID]
                ),
                timeZone: shanghai
            )
        }
        #expect(throws: DecompositionPlanBuilderError.idCountMismatch) {
            try DecompositionPlanBuilder.makePayload(
                snapshot: try selectionSnapshot(),
                candidates: [selectedScheduled],
                note: try sourceNote(revision: 3),
                workspaceRevision: 4,
                now: now,
                ids: DecompositionPlanIDs(
                    blockIDs: [firstBlockID],
                    calendarItemIDs: [itemID, extraItemID]
                ),
                timeZone: shanghai
            )
        }
        let exact = try DecompositionPlanBuilder.makePayload(
            snapshot: try selectionSnapshot(),
            candidates: [selectedScheduled, selectedUnscheduled],
            note: try sourceNote(revision: 3),
            workspaceRevision: 4,
            now: now,
            ids: DecompositionPlanIDs(
                blockIDs: [firstBlockID, secondBlockID],
                calendarItemIDs: [itemID]
            ),
            timeZone: shanghai
        )
        #expect(exact.taskBlocks.map(\.id) == [firstBlockID, secondBlockID])
        #expect(exact.calendarItems.map(\.id) == [itemID])
        #expect(exact.links.count == 1)
    }

    private var selectedScheduled: CandidateAction {
        candidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000911")!,
            title: "给物业打电话",
            completion: "拿到明确上门时间",
            selectedForCreation: true,
            selectedForCalendar: true,
            proposal: try! CalendarProposal(
                schedule: CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: MinuteOfDay(hour: 9, minute: 0),
                    endTime: MinuteOfDay(hour: 9, minute: 30)
                )
            )
        )
    }

    private var selectedUnscheduled: CandidateAction {
        candidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000912")!,
            title: "记录上门时间",
            completion: "写进笔记",
            selectedForCreation: true,
            selectedForCalendar: false
        )
    }

    private var deselected: CandidateAction {
        candidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000913")!,
            title: "不要创建这项",
            completion: "被取消的行动",
            selectedForCreation: false,
            selectedForCalendar: true,
            proposal: try! CalendarProposal(
                schedule: CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: MinuteOfDay(hour: 10, minute: 0),
                    endTime: MinuteOfDay(hour: 10, minute: 30)
                )
            )
        )
    }

    private func candidate(
        id: UUID,
        title: String,
        completion: String,
        selectedForCreation: Bool,
        selectedForCalendar: Bool,
        proposal: CalendarProposal? = nil
    ) -> CandidateAction {
        CandidateAction(
            id: id,
            title: title,
            completionDescription: completion,
            estimatedDuration: .minutes30,
            selectedForCreation: selectedForCreation,
            selectedForCalendar: selectedForCalendar,
            titleLockedByUser: false,
            completionLockedByUser: false,
            sourceCandidateID: nil,
            proposal: proposal
        )
    }

    private func sourceNote(revision: Int64) throws -> Note {
        Note(
            id: FixtureIDs.noteID,
            title: "来源笔记",
            document: .init(blocks: [
                .init(
                    id: FixtureIDs.sourceBlockID,
                    kind: .paragraph,
                    inlineContent: .plain("预约牙医"),
                    taskState: nil,
                    indentLevel: 0
                )
            ]),
            categoryID: FixtureIDs.categoryID,
            archivedAt: nil,
            revision: revision,
            createdAt: now,
            updatedAt: now
        )
    }

    private func selectionSnapshot() throws -> DecompositionSourceSnapshot {
        try DecompositionSourceCapture.capture(
            note: try sourceNote(revision: 3),
            workspaceRevision: 9,
            selection: .text(
                anchor: .init(blockID: FixtureIDs.sourceBlockID, graphemeOffset: 2),
                focus: .init(blockID: FixtureIDs.sourceBlockID, graphemeOffset: 4),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
    }

    private func wholeNoteSnapshot() throws -> DecompositionSourceSnapshot {
        try DecompositionSourceCapture.capture(
            note: try sourceNote(revision: 3),
            workspaceRevision: 9,
            selection: .text(
                anchor: .init(blockID: FixtureIDs.sourceBlockID, graphemeOffset: 0),
                focus: .init(blockID: FixtureIDs.sourceBlockID, graphemeOffset: 0),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
    }
}

private enum FixtureIDs {
    static let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000900")!)
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000905")!
    static let sourceBlockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000906")!)
}
