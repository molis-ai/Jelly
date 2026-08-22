import CalendarDomain
import Foundation
import WorkspaceDomain

struct DecompositionSourceSnapshot: Equatable, Sendable {
    struct TextRange: Equatable, Sendable {
        let blockID: BlockID
        let lowerGraphemeOffset: Int
        let upperGraphemeOffset: Int
    }

    let noteID: NoteID
    let noteRevision: Int64
    let workspaceRevision: Int64
    let sourceBlockID: BlockID?
    let selectedRange: TextRange?
    let normalizedText: String
    let noteChecksum: String
    let sourceChecksum: String
}

enum CandidateDuration: Int, CaseIterable, Equatable, Sendable {
    case minutes15 = 15
    case minutes30 = 30
    case minutes45 = 45
    case minutes60 = 60
    case minutes90 = 90
}

struct CalendarProposal: Equatable, Sendable {
    let schedule: CalendarSchedule
}

enum DecompositionStage: Int, CaseIterable, Equatable, Sendable {
    case understand
    case split
    case schedule
}

enum ManualDecompositionReason: Equatable, Sendable {
    case systemVersionUnsupported
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case localeUnsupported
    case timedOut
    case repeatedInvalidOutput
    case modelFailure
}

enum DecompositionMode: Equatable, Sendable {
    case intelligent
    case manual(reason: ManualDecompositionReason)
}

struct DecompositionQuestion: Equatable, Sendable {
    let text: String
    let quickAnswers: [String]
}

enum DecompositionRecoverableError: Equatable, Sendable {
    case requestCancelled
    case planningFailed
    case sourceChanged
    case calendarConflict
    case persistenceFailed
}

struct CandidateAction: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var completionDescription: String
    var estimatedDuration: CandidateDuration
    var selectedForCreation: Bool
    var selectedForCalendar: Bool
    var titleLockedByUser: Bool
    var completionLockedByUser: Bool
    var sourceCandidateID: UUID?
    var proposal: CalendarProposal?
}

enum ClarificationDecision: Equatable, Sendable {
    case ask(question: String, quickAnswers: [String])
    case notNeeded
}

struct PlannerCandidate: Equatable, Sendable {
    let existingID: UUID?
    let title: String
    let completionDescription: String
    let estimatedMinutes: Int
}

enum DecompositionPlannerAvailability: Equatable, Sendable {
    case available
    case unavailable(ManualDecompositionReason)
}

struct ClarificationRequest: Equatable, Sendable {
    let source: DecompositionSourceSnapshot
}

struct PlannerCandidateContext: Equatable, Sendable {
    let id: UUID
    let title: String
    let completionDescription: String
    let estimatedMinutes: Int
    let titleLockedByUser: Bool
    let completionLockedByUser: Bool
}

struct CandidateRequest: Equatable, Sendable {
    let source: DecompositionSourceSnapshot
    let answer: String?
    let existingCandidates: [PlannerCandidateContext]
    let validationFeedback: DecompositionOutputError?
}

struct SplitCandidateRequest: Equatable, Sendable {
    let source: DecompositionSourceSnapshot
    let answer: String?
    let target: PlannerCandidateContext
    let validationFeedback: DecompositionOutputError?
}

enum DecompositionOutputError: Error, Equatable, Sendable {
    case invalidCount(Int)
    case emptyTitle(index: Int)
    case emptyCompletion(index: Int)
    case invalidDuration(index: Int, minutes: Int)
    case duplicateExistingID(UUID)
    case unexpectedExistingIDs
}

struct DecompositionDraft: Equatable, Sendable {
    var source: DecompositionSourceSnapshot
    var stage: DecompositionStage
    var question: DecompositionQuestion?
    var answer: String
    var candidates: [CandidateAction]
    var mode: DecompositionMode
    var lastRecoverableError: DecompositionRecoverableError?
}
