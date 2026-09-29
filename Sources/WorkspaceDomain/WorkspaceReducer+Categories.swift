import CalendarDomain
import Foundation

extension WorkspaceReducer {
    static func applyCategory(
        _ command: CalendarCommand,
        to candidate: inout WorkspaceState,
        now: Date
    ) throws {
        do {
            candidate.calendar = try CalendarReducer.reduce(candidate.calendar, command: command, now: now)
        } catch let error as ReducerError {
            throw WorkspaceReducerError.calendarFailure(error)
        }
    }

    static func deleteCategory(
        _ id: UUID,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws {
        let fallback = candidate.calendar.uncategorizedID
        try applyCategory(.deleteCategory(id, migrateTo: fallback), to: &candidate, now: now)
        for noteID in candidate.notes.keys where candidate.notes[noteID]?.categoryID == id {
            candidate.notes[noteID]?.categoryID = fallback
            candidate.notes[noteID]?.updatedAt = now
        }
        for inspirationID in candidate.inspirations.keys
        where candidate.inspirations[inspirationID]?.categoryID == id {
            candidate.inspirations[inspirationID]?.categoryID = fallback
            candidate.inspirations[inspirationID]?.updatedAt = now
        }
        for itemID in candidate.undatedItems.keys where candidate.undatedItems[itemID]?.categoryID == id {
            candidate.undatedItems[itemID]?.categoryID = fallback
            candidate.undatedItems[itemID]?.updatedAt = now
        }
    }
}
