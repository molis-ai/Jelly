import CalendarDomain
import Foundation
import WorkspaceDomain

struct DecompositionPlanIDs: Equatable, Sendable {
    let blockIDs: [BlockID]
    let calendarItemIDs: [UUID]
}

enum DecompositionPlanBuilderError: Error, Equatable, Sendable {
    case noSelectedTasks
    case emptyTitle
    case emptyCompletion
    case missingCalendarProposal(UUID)
    case idCountMismatch
}

enum DecompositionPlanBuilder {
    static func makePayload(
        snapshot: DecompositionSourceSnapshot,
        candidates: [CandidateAction],
        note: Note,
        workspaceRevision: Int64,
        now: Date,
        ids: DecompositionPlanIDs,
        timeZone: TimeZone = .current
    ) throws -> ApplyDecompositionPlanPayload {
        let selected = candidates.filter(\.selectedForCreation)
        guard !selected.isEmpty else {
            throw DecompositionPlanBuilderError.noSelectedTasks
        }
        for candidate in selected {
            if candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw DecompositionPlanBuilderError.emptyTitle
            }
            if candidate.completionDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw DecompositionPlanBuilderError.emptyCompletion
            }
            if candidate.selectedForCalendar, candidate.proposal == nil {
                throw DecompositionPlanBuilderError.missingCalendarProposal(candidate.id)
            }
        }
        let scheduled = selected.filter { $0.selectedForCalendar && $0.proposal != nil }
        guard ids.blockIDs.count == selected.count,
              ids.calendarItemIDs.count == scheduled.count
        else {
            throw DecompositionPlanBuilderError.idCountMismatch
        }

        var taskBlocks: [DocumentBlock] = []
        var calendarItems: [CalendarItem] = []
        var links: [TaskBlockCalendarLink] = []
        var calendarIndex = 0
        for (blockID, candidate) in zip(ids.blockIDs, selected) {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let completion = candidate.completionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let block = try DocumentBlock.task(
                id: blockID,
                text: title,
                completionDescription: completion
            )
            taskBlocks.append(block)
            if candidate.selectedForCalendar, let proposal = candidate.proposal {
                let itemID = ids.calendarItemIDs[calendarIndex]
                calendarIndex += 1
                let item = try CalendarItem(
                    id: itemID,
                    kind: .task,
                    title: title,
                    categoryID: note.categoryID,
                    schedule: proposal.schedule,
                    creationTimeZoneIdentifier: timeZone.identifier,
                    completedAt: block.taskState?.completedAt,
                    createdAt: now,
                    updatedAt: now
                )
                calendarItems.append(item)
                links.append(
                    TaskBlockCalendarLink(
                        noteID: snapshot.noteID,
                        blockID: blockID,
                        calendarItemID: itemID
                    )
                )
            }
        }

        return ApplyDecompositionPlanPayload(
            noteID: snapshot.noteID,
            expectedNoteRevision: snapshot.noteRevision,
            expectedWorkspaceRevision: workspaceRevision,
            insertionAnchor: insertionAnchor(for: snapshot),
            taskBlocks: taskBlocks,
            calendarItems: calendarItems,
            links: links
        )
    }

    private static func insertionAnchor(
        for snapshot: DecompositionSourceSnapshot
    ) -> DecompositionInsertionAnchor {
        if let blockID = snapshot.sourceBlockID, snapshot.selectedRange != nil {
            return .after(blockID)
        }
        return .end
    }
}
