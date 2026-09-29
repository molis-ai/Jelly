import Foundation

public enum TaskBlockCalendarTitle {
    public static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TaskBlockCalendarLink: Hashable, Codable, Sendable {
    public let noteID: NoteID
    public let blockID: BlockID
    public let calendarItemID: UUID

    public init(noteID: NoteID, blockID: BlockID, calendarItemID: UUID) {
        self.noteID = noteID
        self.blockID = blockID
        self.calendarItemID = calendarItemID
    }
}
