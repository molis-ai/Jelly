import CalendarDomain
import Foundation

public enum ExpansionDirectionDecision: String, Codable, Equatable, Sendable {
    case pending
    case adopted
    case ignored
}

public struct ExpansionDirection: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var decision: ExpansionDirectionDecision

    public init(id: UUID = UUID(), text: String, decision: ExpansionDirectionDecision = .pending) {
        self.id = id
        self.text = text
        self.decision = decision
    }
}

/// AI follow-up for a captured thought: one supplementary sentence plus 2–3
/// directions. It never rewrites the raw inspiration; `sourceChecksum` pins
/// the text it was generated from so a later edit makes it visibly stale.
public struct InspirationExpansion: Codable, Equatable, Sendable {
    public static let supplementLimit = 160
    public static let directionLimit = 80
    public static let directionCountRange = 2...3

    public var supplement: String
    public var directions: [ExpansionDirection]
    public var sourceChecksum: String
    public var modelIdentifier: String
    public var createdAt: Date

    public init(
        supplement: String,
        directions: [ExpansionDirection],
        sourceChecksum: String,
        modelIdentifier: String,
        createdAt: Date
    ) {
        self.supplement = supplement
        self.directions = directions
        self.sourceChecksum = sourceChecksum
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
    }

    public var isValid: Bool {
        let trimmed = supplement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= Self.supplementLimit
            && Self.directionCountRange.contains(directions.count)
            && Set(directions.map(\.id)).count == directions.count
            && directions.allSatisfy {
                let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && text.count <= Self.directionLimit
            }
    }

    public var adoptedDirections: [ExpansionDirection] {
        directions.filter { $0.decision == .adopted }
    }
}

/// "What do you think?" layer on top of a material digest. Questions come from
/// the model; the answer is always the user's own words.
public struct InspirationPerspective: Codable, Equatable, Sendable {
    public static let questionLimit = 3
    public static let answerLimit = 4_000

    public var questions: [String]
    public var answer: String
    public var updatedAt: Date

    public init(questions: [String], answer: String, updatedAt: Date) {
        self.questions = questions
        self.answer = answer
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        questions.count <= Self.questionLimit
            && questions.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && answer.count <= Self.answerLimit
    }

    public var hasAnswer: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A to-do without a day yet — "以后再说". Scheduling turns it into a normal
/// calendar item and removes it from the list.
public struct UndatedItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var notes: String
    public var categoryID: UUID
    public var priority: ItemPriority
    public var sourceInspirationID: InspirationID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        categoryID: UUID,
        priority: ItemPriority = .none,
        sourceInspirationID: InspirationID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes
        self.categoryID = categoryID
        self.priority = priority
        self.sourceInspirationID = sourceInspirationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Where a captured thought goes when it becomes something to do.
public enum InspirationActionTarget: Equatable, Sendable {
    case calendar(CalendarItem)
    case undated(UndatedItem)
}

public struct ScheduleInspirationPayload: Equatable, Sendable {
    public let inspirationID: InspirationID
    public let target: InspirationActionTarget

    public init(inspirationID: InspirationID, target: InspirationActionTarget) {
        self.inspirationID = inspirationID
        self.target = target
    }
}

public struct ReviewSchedule: Equatable, Sendable {
    /// Inspirations younger than this are not yet "old"; they stay in the inbox.
    public var minimumAge: TimeInterval
    /// A kept inspiration comes back after this interval.
    public var keepInterval: TimeInterval

    public init(minimumAge: TimeInterval, keepInterval: TimeInterval) {
        self.minimumAge = minimumAge
        self.keepInterval = keepInterval
    }

    public static let `default` = ReviewSchedule(minimumAge: 20 * 3_600, keepInterval: 7 * 86_400)
}

public enum InspirationReviewQueue {
    /// Active inspirations that have not turned into anything yet: no note,
    /// no calendar item, no undated to-do, and not reviewed recently.
    public static func due(
        in state: WorkspaceState,
        now: Date,
        schedule: ReviewSchedule = .default
    ) -> [Inspiration] {
        let converted = Set(state.inspirationNoteLinks.compactMap { link -> InspirationID? in
            if case let .live(id) = link.source { return id }
            return nil
        })
        let listed = Set(state.undatedItems.values.compactMap(\.sourceInspirationID))
        return state.inspirations.values
            .filter { inspiration in
                guard inspiration.lifecycle == .active,
                      !converted.contains(inspiration.id),
                      !listed.contains(inspiration.id),
                      !inspiration.scheduledItemIDs.contains(where: { state.calendar.items[$0] != nil }),
                      now.timeIntervalSince(inspiration.createdAt) >= schedule.minimumAge
                else { return false }
                guard let reviewed = inspiration.lastReviewedAt else { return true }
                return now.timeIntervalSince(reviewed) >= schedule.keepInterval
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
    }
}
