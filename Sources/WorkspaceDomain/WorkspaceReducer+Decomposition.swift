import CalendarDomain
import Foundation

extension WorkspaceReducer {
    static func applyDecompositionPlan(
        _ payload: ApplyDecompositionPlanPayload,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws -> WorkspaceCommandControl {
        guard let note = candidate.notes[payload.noteID] else {
            return .result(.conflict(.decomposition(.noteMissing)))
        }
        guard note.revision == payload.expectedNoteRevision else {
            return .result(.conflict(.decomposition(.noteChanged(currentRevision: note.revision))))
        }
        switch payload.insertionAnchor {
        case let .after(blockID):
            guard note.document.blocks.contains(where: { $0.id == blockID }) else {
                return .result(.conflict(.decomposition(.anchorMissing(blockID))))
            }
        case .end:
            break
        }

        try validateDecompositionStructure(payload, note: note, in: candidate)

        // expectedWorkspaceRevision is not a staleness gate. A later unrelated
        // workspace write is allowed; only a real timed overlap fails.
        if let conflict = firstCalendarConflict(for: payload.calendarItems, in: candidate.calendar) {
            return .result(.conflict(.decomposition(.calendarChanged(conflict))))
        }

        var updatedNote = note
        switch payload.insertionAnchor {
        case let .after(blockID):
            guard let index = updatedNote.document.blocks.firstIndex(where: { $0.id == blockID }) else {
                return .result(.conflict(.decomposition(.anchorMissing(blockID))))
            }
            updatedNote.document.blocks.insert(contentsOf: payload.taskBlocks, at: index + 1)
        case .end:
            updatedNote.document.blocks.append(contentsOf: payload.taskBlocks)
        }
        updatedNote.updatedAt = now
        do {
            try validateProposedNote(updatedNote, in: candidate)
        } catch {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }
        candidate.notes[updatedNote.id] = updatedNote

        for item in payload.calendarItems {
            try applyCalendar(.createItem(item), to: &candidate, now: now, metadata: &metadata)
            let owner = CalendarNoteOwnerID.item(item.id)
            if let existing = candidate.calendarNoteRelations.baselines[owner],
               existing.primaryNoteID != nil || !existing.referenceNoteIDs.isEmpty {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            candidate.calendarNoteRelations.baselines[owner] = .init(
                primaryNoteID: payload.noteID,
                referenceNoteIDs: []
            )
        }
        for link in payload.links {
            guard candidate.taskBlockLinks.insert(link).inserted else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
        }
        return .proceed
    }

    private static func validateDecompositionStructure(
        _ payload: ApplyDecompositionPlanPayload,
        note: Note,
        in state: WorkspaceState
    ) throws {
        guard payload.expectedWorkspaceRevision >= 0 else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }
        guard !payload.taskBlocks.isEmpty else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }

        let payloadBlockIDs = payload.taskBlocks.map(\.id)
        guard Set(payloadBlockIDs).count == payloadBlockIDs.count else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }
        let existingBlockIDs = Set(state.notes.values.flatMap { $0.document.blocks.map(\.id) })
        guard existingBlockIDs.isDisjoint(with: payloadBlockIDs) else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }

        for block in payload.taskBlocks {
            guard block.kind == .task else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            do {
                try BlockDocumentValidator.validateBlockLocal(block)
            } catch {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            let title = TaskBlockCalendarTitle.normalized(
                block.inlineContent.spans.map(\.text).joined()
            )
            guard !title.isEmpty else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            guard block.taskState?.completionDescription != nil else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
        }

        let payloadItemIDs = payload.calendarItems.map(\.id)
        guard Set(payloadItemIDs).count == payloadItemIDs.count else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }
        guard payloadItemIDs.allSatisfy({ state.calendar.items[$0] == nil }) else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }
        guard payload.links.count == payload.calendarItems.count else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }
        let linkItemIDs = payload.links.map(\.calendarItemID)
        let linkBlockIDs = payload.links.map(\.blockID)
        guard Set(linkItemIDs) == Set(payloadItemIDs),
              Set(linkBlockIDs).count == linkBlockIDs.count
        else {
            throw WorkspaceReducerError.invalidDecompositionPlan
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: payload.taskBlocks.map { ($0.id, $0) })
        let itemsByID = Dictionary(uniqueKeysWithValues: payload.calendarItems.map { ($0.id, $0) })
        for link in payload.links {
            guard link.noteID == payload.noteID,
                  let task = tasksByID[link.blockID],
                  let item = itemsByID[link.calendarItemID]
            else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            guard item.kind == .task else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            guard state.calendar.categories[item.categoryID] != nil,
                  item.categoryID == note.categoryID
            else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            let expectedTitle = TaskBlockCalendarTitle.normalized(
                task.inlineContent.spans.map(\.text).joined()
            )
            guard item.title == expectedTitle else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
            guard item.completedAt == task.taskState?.completedAt else {
                throw WorkspaceReducerError.invalidDecompositionPlan
            }
        }
    }

    private static func firstCalendarConflict(
        for items: [CalendarItem],
        in calendar: CalendarState
    ) -> CalendarTimedConflict? {
        guard !items.isEmpty else { return nil }
        let dates = items.flatMap { [$0.schedule.startDate, $0.schedule.endDate] }
        guard let start = dates.min(), let end = dates.max() else { return nil }
        let range = CalendarDateRange(start: start.addingDays(-1), end: end.addingDays(1))
        return CalendarTimedOccupancy.firstConflict(proposed: items, in: calendar, range: range)
    }
}
