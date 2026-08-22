import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("DecompositionWorkspaceCommandTests")
struct DecompositionWorkspaceCommandTests {
    @Test func applyPlanInsertsOrderedTasksItemsAndLinksInOneRevision() throws {
        let workspace = try Task4Fixture.workspace()
        let note = try #require(workspace.notes[Task4Fixture.noteID])
        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .applyDecompositionPlan(try validPayload(after: Task4Fixture.paragraphBlockID)),
            now: Task4Fixture.later
        )
        let changed = try #require(result.change)
        #expect(changed.state.revision == workspace.revision + 1)
        #expect(changed.state.notes[Task4Fixture.noteID]?.revision == note.revision + 1)
        #expect(insertedTitles(changed.state) == ["打电话", "记录时间"])
        #expect(changed.state.calendar.items.count == workspace.calendar.items.count + 1)
        #expect(changed.state.taskBlockLinks.count == workspace.taskBlockLinks.count + 1)
        #expect(changed.changedNoteIDs == [Task4Fixture.noteID])
        #expect(changed.state.notes[Task4Fixture.noteID]?.updatedAt == Task4Fixture.later)
        #expect(
            changed.state.calendarNoteRelations.baselines[.item(DecompositionPlanIDs.itemID)]?.primaryNoteID
                == Task4Fixture.noteID
        )
        #expect(
            changed.state.calendarNoteRelations.baselines[.item(DecompositionPlanIDs.itemID)]?.referenceNoteIDs
                == []
        )
        #expect(changed.state.taskBlockLinks == [
            TaskBlockCalendarLink(
                noteID: Task4Fixture.noteID,
                blockID: DecompositionPlanIDs.secondTaskID,
                calendarItemID: DecompositionPlanIDs.itemID
            )
        ])
        #expect(changed.state.notes[Task4Fixture.otherNoteID] == workspace.notes[Task4Fixture.otherNoteID])
        #expect(changed.state.calendar.items[Task4Fixture.itemID] == workspace.calendar.items[Task4Fixture.itemID])
    }

    @Test func applyPlanAppendsAtEndAndLeavesUnscheduledTasksUnlinked() throws {
        let workspace = try Task4Fixture.workspace()
        var payload = try validPayload(after: Task4Fixture.paragraphBlockID)
        payload = ApplyDecompositionPlanPayload(
            noteID: payload.noteID,
            expectedNoteRevision: payload.expectedNoteRevision,
            expectedWorkspaceRevision: payload.expectedWorkspaceRevision,
            insertionAnchor: .end,
            taskBlocks: payload.taskBlocks,
            calendarItems: [],
            links: []
        )

        let changed = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .applyDecompositionPlan(payload),
            now: Task4Fixture.later
        ).change)
        let titles = try #require(changed.state.notes[Task4Fixture.noteID]).document.blocks.map {
            $0.inlineContent.spans.map(\.text).joined()
        }
        #expect(titles == ["正文", "打电话", "记录时间"])
        #expect(changed.state.calendar.items.count == workspace.calendar.items.count)
        #expect(changed.state.taskBlockLinks == workspace.taskBlockLinks)
        #expect(changed.state.calendarNoteRelations == workspace.calendarNoteRelations)
    }

    @Test func noteMissingReturnsTypedConflictWithoutMutation() throws {
        var workspace = try Task4Fixture.workspace()
        workspace.notes.removeValue(forKey: Task4Fixture.noteID)
        try expectConflict(.noteMissing, workspace: workspace, original: workspace)
    }

    @Test func staleNoteRevisionReturnsTypedConflictWithoutMutation() throws {
        let workspace = try Task4Fixture.workspace()
        var payload = try validPayload(after: Task4Fixture.paragraphBlockID)
        payload = payload.with(expectedNoteRevision: payload.expectedNoteRevision - 1)
        try expectConflict(
            .noteChanged(currentRevision: Task4Fixture.note(id: Task4Fixture.noteID, title: "笔记", revision: 3).revision),
            workspace: workspace,
            original: workspace,
            payload: payload
        )
    }

    @Test func missingAnchorReturnsTypedConflictWithoutMutation() throws {
        let workspace = try Task4Fixture.workspace()
        try expectConflict(
            .anchorMissing(DecompositionPlanIDs.missingAnchorID),
            workspace: workspace,
            original: workspace,
            payload: try validPayload(after: DecompositionPlanIDs.missingAnchorID)
        )
    }

    @Test func workspaceRevisionMismatchSucceedsWhenCalendarHasNoTimedConflict() throws {
        var workspace = try Task4Fixture.workspace()
        workspace.revision += 1
        workspace.calendar.items[DecompositionPlanIDs.unrelatedItemID] = try timedItem(
            id: DecompositionPlanIDs.unrelatedItemID,
            title: "无关事项",
            start: (11, 0),
            end: (12, 0)
        )
        let payload = try validPayload(after: Task4Fixture.paragraphBlockID)
        #expect(payload.expectedWorkspaceRevision != workspace.revision)

        let changed = try #require(try WorkspaceReducer.reduce(
            workspace,
            command: .applyDecompositionPlan(payload),
            now: Task4Fixture.later
        ).change)
        #expect(changed.state.revision == workspace.revision + 1)
        #expect(changed.state.calendar.items[DecompositionPlanIDs.itemID] != nil)
        #expect(changed.state.calendar.items[DecompositionPlanIDs.unrelatedItemID] != nil)
    }

    @Test func workspaceRevisionMismatchFailsOnlyOnRealCalendarConflict() throws {
        var workspace = try Task4Fixture.workspace()
        workspace.revision += 1
        workspace.calendar.items[DecompositionPlanIDs.unrelatedItemID] = try timedItem(
            id: DecompositionPlanIDs.unrelatedItemID,
            title: "已占用",
            start: (9, 0),
            end: (10, 0)
        )
        try expectConflict(
            .calendarChanged(.item(DecompositionPlanIDs.unrelatedItemID)),
            workspace: workspace,
            original: workspace
        )
    }

    @Test func existingTimedItemConflictDoesNotMutateWorkspace() throws {
        var workspace = try Task4Fixture.workspace()
        workspace.calendar.items[DecompositionPlanIDs.blockingItemID] = try timedItem(
            id: DecompositionPlanIDs.blockingItemID,
            title: "已有会议",
            start: (9, 15),
            end: (9, 45)
        )
        try expectConflict(
            .calendarChanged(.item(DecompositionPlanIDs.blockingItemID)),
            workspace: workspace,
            original: workspace
        )
    }

    @Test func recurrenceOccurrenceConflictDoesNotMutateWorkspace() throws {
        var workspace = try Task4Fixture.workspace()
        let series = try WeeklySeries(
            id: DecompositionPlanIDs.seriesID,
            kind: .task,
            title: "周会",
            categoryID: Task4Fixture.uncategorizedID,
            ruleStartDate: Task4Fixture.day,
            recurrenceEndDate: nil,
            weekdays: [Task4Fixture.day.weekday],
            durationDays: 1,
            startTime: MinuteOfDay(hour: 9, minute: 0),
            endTime: MinuteOfDay(hour: 10, minute: 0),
            creationTimeZoneIdentifier: "UTC",
            createdAt: Task4Fixture.now,
            updatedAt: Task4Fixture.now
        )
        workspace.calendar.recurrence.series[series.id] = series
        try expectConflict(
            .calendarChanged(.occurrence(OccurrenceKey(
                seriesID: series.id,
                originalDate: Task4Fixture.day
            ))),
            workspace: workspace,
            original: workspace
        )
    }

    @Test func proposedSelfConflictDoesNotMutateWorkspace() throws {
        let workspace = try Task4Fixture.workspace()
        var payload = try validPayload(after: Task4Fixture.paragraphBlockID)
        let overlapping = try timedItem(
            id: DecompositionPlanIDs.secondItemID,
            title: "打电话",
            start: (9, 15),
            end: (9, 45)
        )
        payload = ApplyDecompositionPlanPayload(
            noteID: payload.noteID,
            expectedNoteRevision: payload.expectedNoteRevision,
            expectedWorkspaceRevision: payload.expectedWorkspaceRevision,
            insertionAnchor: payload.insertionAnchor,
            taskBlocks: payload.taskBlocks,
            calendarItems: [overlapping, payload.calendarItems[0]],
            links: [
                TaskBlockCalendarLink(
                    noteID: Task4Fixture.noteID,
                    blockID: DecompositionPlanIDs.firstTaskID,
                    calendarItemID: overlapping.id
                ),
                payload.links[0]
            ]
        )
        try expectConflict(
            .calendarChanged(.proposed(overlapping.id, DecompositionPlanIDs.itemID)),
            workspace: workspace,
            original: workspace,
            payload: payload
        )
    }

    @Test(arguments: StructuralForgery.allCases)
    func structuralForgeryThrowsWithoutMutation(_ forgery: StructuralForgery) throws {
        let workspace = try Task4Fixture.workspace()
        let original = workspace
        let payload = try forgery.payload(from: validPayload(after: Task4Fixture.paragraphBlockID))
        #expect(throws: WorkspaceReducerError.invalidDecompositionPlan) {
            _ = try WorkspaceReducer.reduce(
                workspace,
                command: .applyDecompositionPlan(payload),
                now: Task4Fixture.later
            )
        }
        #expect(workspace == original)
        #expect(workspace.revision == original.revision)
        #expect(workspace.notes == original.notes)
        #expect(workspace.calendar.items == original.calendar.items)
        #expect(workspace.taskBlockLinks == original.taskBlockLinks)
        #expect(workspace.calendarNoteRelations == original.calendarNoteRelations)
    }
}

private enum DecompositionPlanIDs {
    static let firstTaskID = BlockID(Task4Fixture.uuid(501))
    static let secondTaskID = BlockID(Task4Fixture.uuid(502))
    static let missingAnchorID = BlockID(Task4Fixture.uuid(503))
    static let itemID = Task4Fixture.uuid(510)
    static let secondItemID = Task4Fixture.uuid(511)
    static let unrelatedItemID = Task4Fixture.uuid(512)
    static let blockingItemID = Task4Fixture.uuid(513)
    static let seriesID = Task4Fixture.uuid(520)
}

enum StructuralForgery: String, CaseIterable, Sendable {
    case emptyTasks
    case nonTaskBlock
    case emptyTitle
    case emptyCompletion
    case duplicateBlockID
    case existingBlockID
    case duplicateCalendarID
    case existingCalendarID
    case linkCountMismatch
    case linkEndpointMismatch
    case itemTitleMismatch
    case completionMismatch
    case unknownCategory
}

private extension StructuralForgery {
    func payload(from valid: ApplyDecompositionPlanPayload) throws -> ApplyDecompositionPlanPayload {
        switch self {
        case .emptyTasks:
            return valid.replacing(taskBlocks: [], calendarItems: [], links: [])
        case .nonTaskBlock:
            var blocks = valid.taskBlocks
            blocks[0] = DocumentBlock(
                id: blocks[0].id,
                kind: .paragraph,
                inlineContent: blocks[0].inlineContent,
                taskState: nil,
                indentLevel: 0
            )
            return valid.replacing(taskBlocks: blocks)
        case .emptyTitle:
            var blocks = valid.taskBlocks
            blocks[0] = try DocumentBlock.task(
                id: blocks[0].id,
                text: "   ",
                completionDescription: blocks[0].taskState?.completionDescription
            )
            return valid.replacing(taskBlocks: blocks)
        case .emptyCompletion:
            var blocks = valid.taskBlocks
            blocks[0] = try DocumentBlock.task(
                id: blocks[0].id,
                text: blocks[0].inlineContent.spans.map { $0.text }.joined(),
                completionDescription: nil
            )
            return valid.replacing(taskBlocks: blocks)
        case .duplicateBlockID:
            var blocks = valid.taskBlocks
            blocks[1] = try DocumentBlock.task(
                id: blocks[0].id,
                text: "记录时间",
                completionDescription: blocks[1].taskState?.completionDescription
            )
            return valid.replacing(taskBlocks: blocks, calendarItems: [], links: [])
        case .existingBlockID:
            var blocks = valid.taskBlocks
            blocks[0] = try DocumentBlock.task(
                id: Task4Fixture.paragraphBlockID,
                text: "打电话",
                completionDescription: blocks[0].taskState?.completionDescription
            )
            return valid.replacing(taskBlocks: blocks, calendarItems: [], links: [])
        case .duplicateCalendarID:
            let duplicate = try timedItem(
                id: valid.calendarItems[0].id,
                title: "打电话",
                start: (10, 0),
                end: (10, 30)
            )
            return valid.replacing(
                calendarItems: valid.calendarItems + [duplicate],
                links: valid.links + [
                    TaskBlockCalendarLink(
                        noteID: Task4Fixture.noteID,
                        blockID: DecompositionPlanIDs.firstTaskID,
                        calendarItemID: duplicate.id
                    )
                ]
            )
        case .existingCalendarID:
            let colliding = try timedItem(
                id: Task4Fixture.itemID,
                title: "记录时间",
                start: (9, 30),
                end: (10, 0)
            )
            return valid.replacing(
                calendarItems: [colliding],
                links: [
                    TaskBlockCalendarLink(
                        noteID: Task4Fixture.noteID,
                        blockID: DecompositionPlanIDs.secondTaskID,
                        calendarItemID: Task4Fixture.itemID
                    )
                ]
            )
        case .linkCountMismatch:
            return valid.replacing(links: [])
        case .linkEndpointMismatch:
            return valid.replacing(links: [
                TaskBlockCalendarLink(
                    noteID: Task4Fixture.otherNoteID,
                    blockID: DecompositionPlanIDs.secondTaskID,
                    calendarItemID: DecompositionPlanIDs.itemID
                )
            ])
        case .itemTitleMismatch:
            var items = valid.calendarItems
            items[0] = try timedItem(
                id: items[0].id,
                title: "不是任务标题",
                start: (9, 30),
                end: (10, 0)
            )
            return valid.replacing(calendarItems: items)
        case .completionMismatch:
            var items = valid.calendarItems
            items[0] = try CalendarItem(
                id: items[0].id,
                kind: .task,
                title: items[0].title,
                categoryID: items[0].categoryID,
                schedule: items[0].schedule,
                creationTimeZoneIdentifier: items[0].creationTimeZoneIdentifier,
                completedAt: Task4Fixture.completedAt,
                createdAt: items[0].createdAt,
                updatedAt: items[0].updatedAt
            )
            return valid.replacing(calendarItems: items)
        case .unknownCategory:
            var items = valid.calendarItems
            items[0] = try CalendarItem(
                id: items[0].id,
                kind: .task,
                title: items[0].title,
                categoryID: Task4Fixture.missingCategoryID,
                schedule: items[0].schedule,
                creationTimeZoneIdentifier: items[0].creationTimeZoneIdentifier,
                completedAt: items[0].completedAt,
                createdAt: items[0].createdAt,
                updatedAt: items[0].updatedAt
            )
            return valid.replacing(calendarItems: items)
        }
    }
}

private extension ApplyDecompositionPlanPayload {
    func replacing(
        taskBlocks: [DocumentBlock]? = nil,
        calendarItems: [CalendarItem]? = nil,
        links: [TaskBlockCalendarLink]? = nil
    ) -> ApplyDecompositionPlanPayload {
        ApplyDecompositionPlanPayload(
            noteID: noteID,
            expectedNoteRevision: expectedNoteRevision,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            insertionAnchor: insertionAnchor,
            taskBlocks: taskBlocks ?? self.taskBlocks,
            calendarItems: calendarItems ?? self.calendarItems,
            links: links ?? self.links
        )
    }

    func with(expectedNoteRevision: Int64) -> ApplyDecompositionPlanPayload {
        ApplyDecompositionPlanPayload(
            noteID: noteID,
            expectedNoteRevision: expectedNoteRevision,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            insertionAnchor: insertionAnchor,
            taskBlocks: taskBlocks,
            calendarItems: calendarItems,
            links: links
        )
    }
}

private func validPayload(after blockID: BlockID) throws -> ApplyDecompositionPlanPayload {
    let workspace = try Task4Fixture.workspace()
    let note = try #require(workspace.notes[Task4Fixture.noteID])
    let first = try DocumentBlock.task(
        id: DecompositionPlanIDs.firstTaskID,
        text: "打电话",
        completionDescription: "拿到明确上门时间"
    )
    let second = try DocumentBlock.task(
        id: DecompositionPlanIDs.secondTaskID,
        text: "记录时间",
        completionDescription: "写进日历备注"
    )
    let item = try timedItem(
        id: DecompositionPlanIDs.itemID,
        title: "记录时间",
        start: (9, 30),
        end: (10, 0)
    )
    return ApplyDecompositionPlanPayload(
        noteID: note.id,
        expectedNoteRevision: note.revision,
        expectedWorkspaceRevision: workspace.revision,
        insertionAnchor: .after(blockID),
        taskBlocks: [first, second],
        calendarItems: [item],
        links: [
            TaskBlockCalendarLink(
                noteID: note.id,
                blockID: second.id,
                calendarItemID: item.id
            )
        ]
    )
}

private func timedItem(
    id: UUID,
    title: String,
    start: (Int, Int),
    end: (Int, Int)
) throws -> CalendarItem {
    try CalendarItem(
        id: id,
        kind: .task,
        title: title,
        categoryID: Task4Fixture.uncategorizedID,
        schedule: CalendarSchedule(
            startDate: Task4Fixture.day,
            endDate: Task4Fixture.day,
            startTime: MinuteOfDay(hour: start.0, minute: start.1),
            endTime: MinuteOfDay(hour: end.0, minute: end.1)
        ),
        creationTimeZoneIdentifier: "UTC",
        completedAt: nil,
        createdAt: Task4Fixture.now,
        updatedAt: Task4Fixture.now
    )
}

private func insertedTitles(_ state: WorkspaceState) -> [String] {
    guard let note = state.notes[Task4Fixture.noteID],
          let sourceIndex = note.document.blocks.firstIndex(where: {
              $0.id == Task4Fixture.paragraphBlockID
          })
    else {
        return []
    }
    return note.document.blocks.suffix(from: sourceIndex + 1).map {
        $0.inlineContent.spans.map(\.text).joined()
    }
}

private func expectConflict(
    _ conflict: DecompositionWorkspaceConflict,
    workspace: WorkspaceState,
    original: WorkspaceState,
    payload: ApplyDecompositionPlanPayload? = nil
) throws {
    let payload = try payload ?? validPayload(after: Task4Fixture.paragraphBlockID)
    let result = try WorkspaceReducer.reduce(
        workspace,
        command: .applyDecompositionPlan(payload),
        now: Task4Fixture.later
    )
    #expect(result == .conflict(.decomposition(conflict)))
    #expect(workspace == original)
}
