import Foundation

/// Stored kind is retained for schema compatibility.
/// Product model is unified: every item is a completable TODO; timed vs untimed is the only split.
public enum ItemKind: String, Codable, Equatable, Hashable, Sendable {
    case task
    case event

    /// New writes always use `.task`; `.event` is accepted on read for older data.
    public static let unifiedTODO = ItemKind.task
}

/// Explicit priority for ordering and triage. Pinning forces `.p0`.
public enum ItemPriority: String, Codable, Equatable, Hashable, Comparable, Sendable, CaseIterable {
    case p0
    case p1
    case p2
    case none

    public var title: String {
        switch self {
        case .p0: "P0"
        case .p1: "P1"
        case .p2: "P2"
        case .none: "无"
        }
    }

    /// Lower sorts earlier (P0 first).
    public var sortRank: Int {
        switch self {
        case .p0: 0
        case .p1: 1
        case .p2: 2
        case .none: 3
        }
    }

    public static func < (lhs: ItemPriority, rhs: ItemPriority) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}

public enum DomainValidationError: Error, Equatable, Sendable {
    case invalidDateRange
    case invalidTimeRange
    case emptyTitle
    case eventCannotComplete
    case invalidTimeZoneIdentifier
    case emptyWeekdaySet
    case invalidRecurrenceEnd
    case noOccurrenceInRange
}

public struct CalendarCategory: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        name: String,
        colorHex: String,
        sortIndex: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CalendarItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    public var title: String
    public var categoryID: UUID
    public var schedule: CalendarSchedule
    public var creationTimeZoneIdentifier: String
    public var priority: ItemPriority
    public var isPinned: Bool
    /// Markdown notes / 随记. Empty when unused. Older documents omit the key.
    public var notes: String
    /// Manual order among untimed single-day items. Timed items ignore this.
    public var untimedRank: Int
    /// Optional phone/desktop alert. Only one-off items carry one; nil when unused.
    public var reminder: ItemReminder?
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        categoryID: UUID,
        schedule: CalendarSchedule,
        creationTimeZoneIdentifier: String = TimeZone.current.identifier,
        priority: ItemPriority = .none,
        isPinned: Bool = false,
        notes: String = "",
        untimedRank: Int = 0,
        reminder: ItemReminder? = nil,
        completedAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw DomainValidationError.emptyTitle
        }
        guard TimeZone(identifier: creationTimeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidTimeZoneIdentifier
        }

        self.id = id
        self.kind = kind
        self.title = trimmedTitle
        self.categoryID = categoryID
        self.schedule = schedule
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.priority = isPinned && priority == .none ? .p0 : priority
        self.isPinned = isPinned
        self.notes = notes
        self.untimedRank = untimedRank
        self.reminder = reminder
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decode(ItemKind.self, forKey: .kind)
        let title = try container.decode(String.self, forKey: .title)
        let categoryID = try container.decode(UUID.self, forKey: .categoryID)
        guard ![CodingKeys.date, .timeRange].contains(where: container.contains) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schedule,
                in: container,
                debugDescription: "CalendarItem schema 2 cannot contain schema 1 schedule fields."
            )
        }
        let schedule = try container.decode(CalendarSchedule.self, forKey: .schedule)
        let creationTimeZoneIdentifier = try container.decode(String.self, forKey: .creationTimeZoneIdentifier)
        let priority = try container.decodeIfPresent(ItemPriority.self, forKey: .priority) ?? .none
        let isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        let notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        let untimedRank = try container.decodeIfPresent(Int.self, forKey: .untimedRank) ?? 0
        let reminder = try container.decodeIfPresent(ItemReminder.self, forKey: .reminder)
        let completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        do {
            try self.init(
                id: id,
                kind: kind,
                title: title,
                categoryID: categoryID,
                schedule: schedule,
                creationTimeZoneIdentifier: creationTimeZoneIdentifier,
                priority: priority,
                isPinned: isPinned,
                notes: notes,
                untimedRank: untimedRank,
                reminder: reminder,
                completedAt: completedAt,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "CalendarItem violates its persisted-domain invariants."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(creationTimeZoneIdentifier, forKey: .creationTimeZoneIdentifier)
        try container.encode(priority, forKey: .priority)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(notes, forKey: .notes)
        if untimedRank != 0 {
            try container.encode(untimedRank, forKey: .untimedRank)
        }
        try container.encodeIfPresent(reminder, forKey: .reminder)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case categoryID
        case schedule
        case date
        case timeRange
        case creationTimeZoneIdentifier
        case priority
        case isPinned
        case notes
        case untimedRank
        case reminder
        case completedAt
        case createdAt
        case updatedAt
    }
}
