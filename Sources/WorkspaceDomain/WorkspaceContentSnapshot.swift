import CalendarDomain
import Foundation

public struct WorkspaceNoteContent: Codable, Equatable, Sendable {
    public let id: NoteID
    public var title: String
    public var document: BlockDocument
    public var categoryID: UUID
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(note: Note) {
        id = note.id
        title = note.title
        document = note.document
        categoryID = note.categoryID
        archivedAt = note.archivedAt
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }

    func note(revision: Int64) -> Note {
        Note(
            id: id,
            title: title,
            document: document,
            categoryID: categoryID,
            archivedAt: archivedAt,
            revision: revision,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct WorkspaceContentSnapshot: Codable, Equatable, Sendable {
    public var calendar: CalendarState
    public var notes: [NoteID: WorkspaceNoteContent]
    public var inspirations: [InspirationID: Inspiration]
    public var calendarNoteRelations: CalendarNoteRelationGraph
    public var taskBlockLinks: Set<TaskBlockCalendarLink>
    public var inspirationNoteLinks: Set<InspirationNoteLink>
    public var materialDigests: [InspirationID: MaterialDigest]
    public var undatedItems: [UUID: UndatedItem]

    public init(state: WorkspaceState) {
        calendar = state.calendar
        notes = state.notes.mapValues(WorkspaceNoteContent.init)
        inspirations = state.inspirations
        calendarNoteRelations = state.calendarNoteRelations
        taskBlockLinks = state.taskBlockLinks
        inspirationNoteLinks = state.inspirationNoteLinks
        materialDigests = state.materialDigests
        undatedItems = state.undatedItems
    }

    private enum CodingKeys: String, CodingKey {
        case calendar
        case notes
        case inspirations
        case calendarNoteRelations
        case taskBlockLinks
        case inspirationNoteLinks
        case materialDigests
        case undatedItems
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calendar = try container.decode(CalendarState.self, forKey: .calendar)
        notes = try container.decode([NoteID: WorkspaceNoteContent].self, forKey: .notes)
        inspirations = try container.decode([InspirationID: Inspiration].self, forKey: .inspirations)
        calendarNoteRelations = try container.decode(CalendarNoteRelationGraph.self, forKey: .calendarNoteRelations)
        taskBlockLinks = try container.decode(Set<TaskBlockCalendarLink>.self, forKey: .taskBlockLinks)
        inspirationNoteLinks = try container.decode(Set<InspirationNoteLink>.self, forKey: .inspirationNoteLinks)
        materialDigests = try container.decode([InspirationID: MaterialDigest].self, forKey: .materialDigests)
        undatedItems = try container.decodeIfPresent([UUID: UndatedItem].self, forKey: .undatedItems) ?? [:]
    }

    func materialized(revisions: [NoteID: Int64], workspaceRevision: Int64) -> WorkspaceState {
        WorkspaceState(
            revision: workspaceRevision,
            calendar: calendar,
            notes: notes.mapValues { content in content.note(revision: revisions[content.id] ?? 0) },
            inspirations: inspirations,
            calendarNoteRelations: calendarNoteRelations,
            taskBlockLinks: taskBlockLinks,
            inspirationNoteLinks: inspirationNoteLinks,
            materialDigests: materialDigests,
            undatedItems: undatedItems
        )
    }
}
