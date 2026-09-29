import CalendarDomain
import Foundation

extension WorkspaceReducer {
    static func reviewInspiration(
        _ id: InspirationID,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard inspiration.lifecycle == .active else {
            throw WorkspaceReducerError.invalidInspiration
        }
        inspiration.lastReviewedAt = now
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func scheduleInspiration(
        _ payload: ScheduleInspirationPayload,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws {
        guard var inspiration = candidate.inspirations[payload.inspirationID] else {
            throw WorkspaceReducerError.missingInspiration(payload.inspirationID)
        }
        guard inspiration.lifecycle == .active else {
            throw WorkspaceReducerError.invalidInspiration
        }
        switch payload.target {
        case let .calendar(item):
            try applyCalendar(.createItem(item), to: &candidate, now: now, metadata: &metadata)
            inspiration.scheduledItemIDs.append(item.id)
        case let .undated(item):
            guard item.sourceInspirationID == payload.inspirationID else {
                throw WorkspaceReducerError.invalidUndatedItem
            }
            try createUndatedItem(item, in: &candidate)
        }
        inspiration.lastReviewedAt = now
        candidate.inspirations[payload.inspirationID] = inspiration
    }

    static func setInspirationExpansion(
        _ id: InspirationID,
        expansion: InspirationExpansion?,
        in candidate: inout WorkspaceState
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        if let expansion {
            guard expansion.isValid else { throw WorkspaceReducerError.invalidInspiration }
            guard expansion.sourceChecksum == WorkspaceChecksum.inspirationSourceChecksum(inspiration) else {
                return .result(.noChange(.staleInspirationExpansion))
            }
        }
        guard inspiration.expansion != expansion else {
            return .result(.noChange(.identical))
        }
        inspiration.expansion = expansion
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func decideExpansionDirection(
        _ id: InspirationID,
        directionID: UUID,
        decision: ExpansionDirectionDecision,
        in candidate: inout WorkspaceState
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id],
              var expansion = inspiration.expansion,
              let index = expansion.directions.firstIndex(where: { $0.id == directionID })
        else {
            throw WorkspaceReducerError.invalidInspiration
        }
        guard expansion.directions[index].decision != decision else {
            return .result(.noChange(.identical))
        }
        expansion.directions[index].decision = decision
        inspiration.expansion = expansion
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func setInspirationPerspective(
        _ id: InspirationID,
        perspective: InspirationPerspective?,
        in candidate: inout WorkspaceState
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        if let perspective, !perspective.isValid {
            throw WorkspaceReducerError.invalidInspiration
        }
        guard inspiration.perspective != perspective else {
            return .result(.noChange(.identical))
        }
        inspiration.perspective = perspective
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func createUndatedItem(_ item: UndatedItem, in candidate: inout WorkspaceState) throws {
        guard candidate.undatedItems[item.id] == nil else {
            throw WorkspaceReducerError.invalidUndatedItem
        }
        try validateUndatedItem(item, in: candidate)
        candidate.undatedItems[item.id] = item
    }

    static func updateUndatedItem(_ item: UndatedItem, in candidate: inout WorkspaceState) throws {
        guard let existing = candidate.undatedItems[item.id] else {
            throw WorkspaceReducerError.missingUndatedItem(item.id)
        }
        guard existing.sourceInspirationID == item.sourceInspirationID else {
            throw WorkspaceReducerError.invalidUndatedItem
        }
        try validateUndatedItem(item, in: candidate)
        candidate.undatedItems[item.id] = item
    }

    static func scheduleUndatedItem(
        _ id: UUID,
        item: CalendarItem,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws {
        guard let undated = candidate.undatedItems.removeValue(forKey: id) else {
            throw WorkspaceReducerError.missingUndatedItem(id)
        }
        try applyCalendar(.createItem(item), to: &candidate, now: now, metadata: &metadata)
        if let source = undated.sourceInspirationID,
           var inspiration = candidate.inspirations[source] {
            inspiration.scheduledItemIDs.append(item.id)
            candidate.inspirations[source] = inspiration
        }
    }

    private static func validateUndatedItem(_ item: UndatedItem, in candidate: WorkspaceState) throws {
        guard item.isValid,
              candidate.calendar.categories[item.categoryID] != nil,
              item.sourceInspirationID.map({ candidate.inspirations[$0] != nil }) ?? true
        else {
            throw WorkspaceReducerError.invalidUndatedItem
        }
    }
}
