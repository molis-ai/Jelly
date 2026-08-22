import CalendarDomain
import Foundation

public enum DecompositionInsertionAnchor: Equatable, Sendable {
    case after(BlockID)
    case end
}

public struct ApplyDecompositionPlanPayload: Equatable, Sendable {
    public let noteID: NoteID
    public let expectedNoteRevision: Int64
    public let expectedWorkspaceRevision: Int64
    public let insertionAnchor: DecompositionInsertionAnchor
    public let taskBlocks: [DocumentBlock]
    public let calendarItems: [CalendarItem]
    public let links: [TaskBlockCalendarLink]

    public init(
        noteID: NoteID,
        expectedNoteRevision: Int64,
        expectedWorkspaceRevision: Int64,
        insertionAnchor: DecompositionInsertionAnchor,
        taskBlocks: [DocumentBlock],
        calendarItems: [CalendarItem],
        links: [TaskBlockCalendarLink]
    ) {
        self.noteID = noteID
        self.expectedNoteRevision = expectedNoteRevision
        self.expectedWorkspaceRevision = expectedWorkspaceRevision
        self.insertionAnchor = insertionAnchor
        self.taskBlocks = taskBlocks
        self.calendarItems = calendarItems
        self.links = links
    }
}

public enum DecompositionWorkspaceConflict: Equatable, Sendable {
    case noteMissing
    case noteChanged(currentRevision: Int64)
    case anchorMissing(BlockID)
    case calendarChanged(CalendarTimedConflict)
}
