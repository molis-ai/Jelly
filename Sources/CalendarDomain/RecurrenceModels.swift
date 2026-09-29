import Foundation

public struct WeeklySeries: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    public var title: String
    public var categoryID: UUID
    public var ruleStartDate: CalendarDate
    public var recurrenceEndDate: CalendarDate?
    public var weekdays: Set<Weekday>
    public var durationDays: Int
    public var startTime: MinuteOfDay?
    public var endTime: MinuteOfDay?
    public var priority: ItemPriority
    public var isPinned: Bool
    /// Markdown notes / 随记 shared by series instances unless overridden.
    public var notes: String
    /// Rings for every occurrence; single-occurrence edits keep the series'.
    public var reminder: ItemReminder?
    public var creationTimeZoneIdentifier: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        categoryID: UUID,
        ruleStartDate: CalendarDate,
        recurrenceEndDate: CalendarDate?,
        weekdays: Set<Weekday>,
        durationDays: Int,
        startTime: MinuteOfDay?,
        endTime: MinuteOfDay?,
        priority: ItemPriority = .none,
        isPinned: Bool = false,
        notes: String = "",
        reminder: ItemReminder? = nil,
        creationTimeZoneIdentifier: String = TimeZone.current.identifier,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw DomainValidationError.emptyTitle
        }
        guard !weekdays.isEmpty else {
            throw DomainValidationError.emptyWeekdaySet
        }
        guard durationDays >= 1 else {
            throw DomainValidationError.invalidDateRange
        }
        guard TimeZone(identifier: creationTimeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidTimeZoneIdentifier
        }
        if let recurrenceEndDate {
            guard recurrenceEndDate >= ruleStartDate else {
                throw DomainValidationError.invalidRecurrenceEnd
            }
            guard Self.hasMatchingWeekday(
                between: ruleStartDate,
                and: recurrenceEndDate,
                weekdays: weekdays
            ) else {
                throw DomainValidationError.noOccurrenceInRange
            }
        }
        _ = try CalendarSchedule(
            startDate: ruleStartDate,
            endDate: ruleStartDate.addingDays(durationDays - 1),
            startTime: startTime,
            endTime: endTime
        )

        self.id = id
        self.kind = kind
        self.title = trimmedTitle
        self.categoryID = categoryID
        self.ruleStartDate = ruleStartDate
        self.recurrenceEndDate = recurrenceEndDate
        self.weekdays = weekdays
        self.durationDays = durationDays
        self.startTime = startTime
        self.endTime = endTime
        self.priority = isPinned && priority == .none ? .p0 : priority
        self.isPinned = isPinned
        self.notes = notes
        self.reminder = reminder
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decode(ItemKind.self, forKey: .kind)
        let title = try container.decode(String.self, forKey: .title)
        let categoryID = try container.decode(UUID.self, forKey: .categoryID)
        guard ![CodingKeys.startDate, .endDate, .timeRange].contains(where: container.contains) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ruleStartDate,
                in: container,
                debugDescription: "WeeklySeries schema 2 cannot contain schema 1 schedule fields."
            )
        }
        let ruleStartDate = try container.decode(CalendarDate.self, forKey: .ruleStartDate)
        let recurrenceEndDate = try container.decodeIfPresent(CalendarDate.self, forKey: .recurrenceEndDate)
        let durationDays = try container.decode(Int.self, forKey: .durationDays)
        let startTime = try container.decodeIfPresent(MinuteOfDay.self, forKey: .startTime)
        let endTime = try container.decodeIfPresent(MinuteOfDay.self, forKey: .endTime)
        let weekdays = try container.decode(Set<Weekday>.self, forKey: .weekdays)
        let priority = try container.decodeIfPresent(ItemPriority.self, forKey: .priority) ?? .none
        let isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        let notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        let reminder = try container.decodeIfPresent(ItemReminder.self, forKey: .reminder)
        let creationTimeZoneIdentifier = try container.decode(String.self, forKey: .creationTimeZoneIdentifier)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        do {
            try self.init(
                id: id,
                kind: kind,
                title: title,
                categoryID: categoryID,
                ruleStartDate: ruleStartDate,
                recurrenceEndDate: recurrenceEndDate,
                weekdays: weekdays,
                durationDays: durationDays,
                startTime: startTime,
                endTime: endTime,
                priority: priority,
                isPinned: isPinned,
                notes: notes,
                reminder: reminder,
                creationTimeZoneIdentifier: creationTimeZoneIdentifier,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "WeeklySeries violates its persisted-domain invariants."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(ruleStartDate, forKey: .ruleStartDate)
        try container.encodeIfPresent(recurrenceEndDate, forKey: .recurrenceEndDate)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encode(durationDays, forKey: .durationDays)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encode(priority, forKey: .priority)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(reminder, forKey: .reminder)
        try container.encode(creationTimeZoneIdentifier, forKey: .creationTimeZoneIdentifier)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func hasMatchingWeekday(
        between startDate: CalendarDate,
        and endDate: CalendarDate,
        weekdays: Set<Weekday>
    ) -> Bool {
        var date = startDate
        while date <= endDate {
            if weekdays.contains(date.weekday) {
                return true
            }
            date = date.addingDays(1)
        }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case categoryID
        case ruleStartDate
        case recurrenceEndDate
        case weekdays
        case durationDays
        case startTime
        case endTime
        case priority
        case isPinned
        case notes
        case reminder
        case creationTimeZoneIdentifier
        case createdAt
        case updatedAt
        case startDate
        case endDate
        case timeRange
    }
}

public struct OccurrenceKey: Codable, Hashable, Sendable {
    public let seriesID: UUID
    public let originalDate: CalendarDate

    public init(seriesID: UUID, originalDate: CalendarDate) {
        self.seriesID = seriesID
        self.originalDate = originalDate
    }
}

public enum OccurrenceExceptionKind: Codable, Equatable, Sendable {
    case skipped
    case modified(OccurrenceOverride)
}

public struct OccurrenceOverride: Codable, Equatable, Sendable {
    public var displayedSchedule: CalendarSchedule
    public var title: String
    public var kind: ItemKind
    public var categoryID: UUID
    public var priority: ItemPriority
    public var isPinned: Bool
    public var notes: String

    public init(
        displayedSchedule: CalendarSchedule,
        title: String,
        kind: ItemKind,
        categoryID: UUID,
        priority: ItemPriority = .none,
        isPinned: Bool = false,
        notes: String = ""
    ) {
        self.displayedSchedule = displayedSchedule
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
        self.priority = isPinned && priority == .none ? .p0 : priority
        self.isPinned = isPinned
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let kind = try container.decode(ItemKind.self, forKey: .kind)
        let categoryID = try container.decode(UUID.self, forKey: .categoryID)
        guard ![CodingKeys.displayedDate, .timeRange].contains(where: container.contains) else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayedSchedule,
                in: container,
                debugDescription: "OccurrenceOverride schema 2 cannot contain schema 1 schedule fields."
            )
        }
        let displayedSchedule = try container.decode(CalendarSchedule.self, forKey: .displayedSchedule)
        let priority = try container.decodeIfPresent(ItemPriority.self, forKey: .priority) ?? .none
        let isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        let notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.init(
            displayedSchedule: displayedSchedule,
            title: title,
            kind: kind,
            categoryID: categoryID,
            priority: priority,
            isPinned: isPinned,
            notes: notes
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayedSchedule, forKey: .displayedSchedule)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(priority, forKey: .priority)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(notes, forKey: .notes)
    }

    private enum CodingKeys: String, CodingKey {
        case displayedSchedule
        case title
        case kind
        case categoryID
        case priority
        case isPinned
        case notes
        case displayedDate
        case timeRange
    }
}

public struct OccurrenceCompletion: Codable, Equatable, Sendable {
    public let key: OccurrenceKey
    public var completedAt: Date

    public init(key: OccurrenceKey, completedAt: Date) {
        self.key = key
        self.completedAt = completedAt
    }
}

public struct CalendarOccurrence: Identifiable, Equatable, Sendable {
    public let key: OccurrenceKey
    public let schedule: CalendarSchedule
    public let title: String
    public let kind: ItemKind
    public let categoryID: UUID
    public let priority: ItemPriority
    public let isPinned: Bool
    public let notes: String
    public let creationTimeZoneIdentifier: String
    public let completedAt: Date?
    public let createdAt: Date

    public var id: OccurrenceKey { key }

    public init(
        key: OccurrenceKey,
        schedule: CalendarSchedule,
        title: String,
        kind: ItemKind,
        categoryID: UUID,
        priority: ItemPriority = .none,
        isPinned: Bool = false,
        notes: String = "",
        creationTimeZoneIdentifier: String,
        completedAt: Date?,
        createdAt: Date
    ) {
        self.key = key
        self.schedule = schedule
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
        self.priority = isPinned && priority == .none ? .p0 : priority
        self.isPinned = isPinned
        self.notes = notes
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

}
