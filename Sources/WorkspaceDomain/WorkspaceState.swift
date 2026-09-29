import CalendarDomain
import Foundation

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var revision: Int64
    public var calendar: CalendarState
    public var notes: [NoteID: Note]
    public var inspirations: [InspirationID: Inspiration]
    public var calendarNoteRelations: CalendarNoteRelationGraph
    public var taskBlockLinks: Set<TaskBlockCalendarLink>
    public var inspirationNoteLinks: Set<InspirationNoteLink>
    public var materialDigests: [InspirationID: MaterialDigest]
    /// To-dos without a day ("以后再说").
    public var undatedItems: [UUID: UndatedItem]

    public init(
        revision: Int64,
        calendar: CalendarState,
        notes: [NoteID: Note],
        inspirations: [InspirationID: Inspiration],
        calendarNoteRelations: CalendarNoteRelationGraph,
        taskBlockLinks: Set<TaskBlockCalendarLink>,
        inspirationNoteLinks: Set<InspirationNoteLink>,
        materialDigests: [InspirationID: MaterialDigest],
        undatedItems: [UUID: UndatedItem] = [:]
    ) {
        self.revision = revision
        self.calendar = calendar
        self.notes = notes
        self.inspirations = inspirations
        self.calendarNoteRelations = calendarNoteRelations
        self.taskBlockLinks = taskBlockLinks
        self.inspirationNoteLinks = inspirationNoteLinks
        self.materialDigests = materialDigests
        self.undatedItems = undatedItems
    }

    public static func empty(calendar: CalendarState) -> WorkspaceState {
        WorkspaceState(
            revision: 0,
            calendar: calendar,
            notes: [:],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [],
            materialDigests: [:]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case calendar
        case notes
        case inspirations
        case calendarNoteRelations
        case taskBlockLinks
        case inspirationNoteLinks
        case materialDigests
        case undatedItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int64.self, forKey: .revision)
        calendar = try container.decode(CalendarState.self, forKey: .calendar)
        notes = try container.decode([NoteID: Note].self, forKey: .notes)
        inspirations = try container.decode([InspirationID: Inspiration].self, forKey: .inspirations)
        calendarNoteRelations = try container.decode(CalendarNoteRelationGraph.self, forKey: .calendarNoteRelations)
        taskBlockLinks = try container.decode(Set<TaskBlockCalendarLink>.self, forKey: .taskBlockLinks)
        inspirationNoteLinks = try container.decode(Set<InspirationNoteLink>.self, forKey: .inspirationNoteLinks)
        materialDigests = try container.decodeIfPresent(
            [InspirationID: MaterialDigest].self,
            forKey: .materialDigests
        ) ?? [:]
        undatedItems = try container.decodeIfPresent([UUID: UndatedItem].self, forKey: .undatedItems) ?? [:]
    }
}
