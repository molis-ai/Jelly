import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DecompositionDraftTests")
struct DecompositionDraftTests {
    private let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
    private let neighborID = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
    private let extraID = UUID(uuidString: "00000000-0000-0000-0000-000000000305")!

    @Test func refreshPreservesEachUserLockedFieldAndSelection() throws {
        let original = CandidateAction(
            id: originalID,
            title: "我改的标题",
            completionDescription: "旧说明",
            estimatedDuration: .minutes30,
            selectedForCreation: false,
            selectedForCalendar: false,
            titleLockedByUser: true,
            completionLockedByUser: false,
            sourceCandidateID: nil,
            proposal: nil
        )
        let merged = try DecompositionDraftReducer.mergeRefresh(
            [PlannerCandidate(existingID: original.id, title: "模型标题",
                              completionDescription: "新说明", estimatedMinutes: 30)],
            into: [original]
        )
        #expect(merged[0].title == "我改的标题")
        #expect(merged[0].completionDescription == "新说明")
        #expect(merged[0].selectedForCreation == false)
        #expect(merged[0].id == originalID)
        #expect(merged[0].titleLockedByUser)
        #expect(!merged[0].completionLockedByUser)
        #expect(merged[0].selectedForCalendar == false)
        #expect(merged[0].estimatedDuration == .minutes30)
    }

    @Test func refreshUpdatesUnlockedTitleAndPreservesLockedCompletion() throws {
        let original = candidate(
            id: originalID,
            title: "旧标题",
            completion: "我改的说明",
            titleLocked: false,
            completionLocked: true,
            selectedForCreation: true,
            selectedForCalendar: true
        )
        let merged = try DecompositionDraftReducer.mergeRefresh(
            [PlannerCandidate(
                existingID: original.id,
                title: "模型标题",
                completionDescription: "模型说明",
                estimatedMinutes: 45
            )],
            into: [original]
        )
        #expect(merged[0].title == "模型标题")
        #expect(merged[0].completionDescription == "我改的说明")
        #expect(merged[0].estimatedDuration == .minutes45)
        #expect(merged[0].selectedForCreation)
        #expect(merged[0].selectedForCalendar)
    }

    @Test func refreshPreservesCurrentOrderWhenModelReturnsDifferentOrder() throws {
        let first = candidate(id: originalID, title: "第一项")
        let second = candidate(id: neighborID, title: "第二项")
        let merged = try DecompositionDraftReducer.mergeRefresh(
            [
                PlannerCandidate(
                    existingID: neighborID,
                    title: "后改前",
                    completionDescription: "完成第二项",
                    estimatedMinutes: 15
                ),
                PlannerCandidate(
                    existingID: originalID,
                    title: "前改后",
                    completionDescription: "完成第一项",
                    estimatedMinutes: 60
                )
            ],
            into: [first, second]
        )
        #expect(merged.map(\.id) == [originalID, neighborID])
        #expect(merged[0].title == "前改后")
        #expect(merged[1].title == "后改前")
        #expect(merged[0].estimatedDuration == .minutes60)
        #expect(merged[1].estimatedDuration == .minutes15)
    }

    @Test func initialCountMustBeBetweenTwoAndFive() {
        #expect(throws: DecompositionOutputError.invalidCount(1)) {
            try DecompositionOutputValidator.validateInitial([validPlanner(title: "仅一项")])
        }
        #expect(throws: DecompositionOutputError.invalidCount(6)) {
            try DecompositionOutputValidator.validateInitial((1...6).map { validPlanner(title: "第\($0)项") })
        }
        let accepted = try? DecompositionOutputValidator.validateInitial(
            (1...2).map { validPlanner(title: "第\($0)项") }
        )
        #expect(accepted?.count == 2)
        let five = try? DecompositionOutputValidator.validateInitial(
            (1...5).map { validPlanner(title: "第\($0)项") }
        )
        #expect(five?.count == 5)
    }

    @Test func validatorRejectsEmptyTitleCompletionInvalidDurationAndDuplicateIDs() {
        #expect(throws: DecompositionOutputError.emptyTitle(index: 1)) {
            try DecompositionOutputValidator.validateInitial([
                validPlanner(title: "打电话"),
                validPlanner(title: "  \n")
            ])
        }
        #expect(throws: DecompositionOutputError.emptyCompletion(index: 0)) {
            try DecompositionOutputValidator.validateInitial([
                PlannerCandidate(
                    existingID: nil,
                    title: "打电话",
                    completionDescription: "   ",
                    estimatedMinutes: 15
                ),
                validPlanner(title: "记录时间")
            ])
        }
        #expect(throws: DecompositionOutputError.invalidDuration(index: 1, minutes: 20)) {
            try DecompositionOutputValidator.validateInitial([
                validPlanner(title: "打电话"),
                PlannerCandidate(
                    existingID: nil,
                    title: "记录时间",
                    completionDescription: "写下上门时段",
                    estimatedMinutes: 20
                )
            ])
        }
        #expect(throws: DecompositionOutputError.duplicateExistingID(originalID)) {
            try DecompositionOutputValidator.validateRefresh(
                [
                    PlannerCandidate(
                        existingID: originalID,
                        title: "打电话",
                        completionDescription: "打通并确认",
                        estimatedMinutes: 15
                    ),
                    PlannerCandidate(
                        existingID: originalID,
                        title: "记录时间",
                        completionDescription: "写下上门时段",
                        estimatedMinutes: 30
                    )
                ],
                expectedIDs: [originalID, neighborID]
            )
        }
    }

    @Test func refreshRequiresExactExistingIDSet() {
        #expect(throws: DecompositionOutputError.unexpectedExistingIDs) {
            try DecompositionOutputValidator.validateRefresh(
                [
                    PlannerCandidate(
                        existingID: originalID,
                        title: "打电话",
                        completionDescription: "打通并确认",
                        estimatedMinutes: 15
                    ),
                    PlannerCandidate(
                        existingID: extraID,
                        title: "记录时间",
                        completionDescription: "写下上门时段",
                        estimatedMinutes: 30
                    )
                ],
                expectedIDs: [originalID, neighborID]
            )
        }
        #expect(throws: DecompositionOutputError.unexpectedExistingIDs) {
            try DecompositionDraftReducer.mergeRefresh(
                [PlannerCandidate(
                    existingID: extraID,
                    title: "模型标题",
                    completionDescription: "新说明",
                    estimatedMinutes: 30
                )],
                into: [candidate(id: originalID, title: "旧标题")]
            )
        }
    }

    @Test func splitReplacesOnlyTheTargetAtItsOriginalPosition() throws {
        let day = CalendarDate(year: 2026, month: 8, day: 22)!
        let proposal = CalendarProposal(
            schedule: try CalendarSchedule(
                startDate: day,
                endDate: day,
                startTime: MinuteOfDay(hour: 9, minute: 0),
                endTime: MinuteOfDay(hour: 9, minute: 30)
            )
        )
        let first = candidate(
            id: originalID,
            title: "保留项",
            completion: "原说明",
            selectedForCreation: false,
            selectedForCalendar: true,
            proposal: proposal
        )
        var firstLocked = first
        firstLocked.titleLockedByUser = true
        let target = candidate(
            id: neighborID,
            title: "继续拆这一项",
            completion: "目标说明",
            selectedForCreation: true,
            selectedForCalendar: false
        )
        let last = candidate(id: extraID, title: "末项")
        let originalNeighbors = [firstLocked, last]

        let replaced = try DecompositionDraftReducer.replaceCandidate(
            id: neighborID,
            with: [
                PlannerCandidate(
                    existingID: nil,
                    title: "拆出甲",
                    completionDescription: "完成甲",
                    estimatedMinutes: 15
                ),
                PlannerCandidate(
                    existingID: nil,
                    title: "拆出乙",
                    completionDescription: "完成乙",
                    estimatedMinutes: 45
                )
            ],
            in: [firstLocked, target, last]
        )

        #expect(replaced.count == 4)
        #expect(replaced[0] == firstLocked)
        #expect(replaced[3] == last)
        #expect(replaced[1].title == "拆出甲")
        #expect(replaced[2].title == "拆出乙")
        #expect(replaced[1].completionDescription == "完成甲")
        #expect(replaced[2].completionDescription == "完成乙")
        #expect(replaced[1].estimatedDuration == .minutes15)
        #expect(replaced[2].estimatedDuration == .minutes45)
        #expect(replaced[1].sourceCandidateID == neighborID)
        #expect(replaced[2].sourceCandidateID == neighborID)
        #expect(replaced[1].selectedForCreation)
        #expect(replaced[2].selectedForCreation)
        #expect(!replaced[1].selectedForCalendar)
        #expect(!replaced[2].selectedForCalendar)
        #expect(!replaced[1].titleLockedByUser)
        #expect(!replaced[1].completionLockedByUser)
        #expect(replaced[1].proposal == nil)
        #expect(Set(replaced.map(\.id)).count == 4)
        #expect(!replaced.map(\.id).contains(neighborID))
        #expect(originalNeighbors == [replaced[0], replaced[3]])
    }

    @Test func splitRequiresTwoToFiveNewIDs() {
        let current = [candidate(id: originalID, title: "目标")]
        #expect(throws: DecompositionOutputError.invalidCount(1)) {
            try DecompositionDraftReducer.replaceCandidate(
                id: originalID,
                with: [validPlanner(title: "只有一项")],
                in: current
            )
        }
        #expect(throws: DecompositionOutputError.invalidCount(6)) {
            try DecompositionDraftReducer.replaceCandidate(
                id: originalID,
                with: (1...6).map { validPlanner(title: "第\($0)项") },
                in: current
            )
        }
        #expect(throws: DecompositionOutputError.unexpectedExistingIDs) {
            try DecompositionOutputValidator.validateSplit([
                PlannerCandidate(
                    existingID: originalID,
                    title: "拆出甲",
                    completionDescription: "完成甲",
                    estimatedMinutes: 15
                ),
                validPlanner(title: "拆出乙")
            ])
        }
        #expect(throws: DecompositionOutputError.unexpectedExistingIDs) {
            try DecompositionDraftReducer.replaceCandidate(
                id: extraID,
                with: [validPlanner(title: "拆出甲"), validPlanner(title: "拆出乙")],
                in: current
            )
        }
    }

    @Test func draftHoldsStageAnswerCandidatesDurationAndProposal() throws {
        let source = try DecompositionSourceCapture.capture(
            note: makeNote(),
            workspaceRevision: 4,
            selection: .text(
                anchor: .init(blockID: blockID, graphemeOffset: 0),
                focus: .init(blockID: blockID, graphemeOffset: 4),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
        let day = CalendarDate(year: 2026, month: 8, day: 22)!
        let proposal = CalendarProposal(
            schedule: try CalendarSchedule(
                startDate: day,
                endDate: day,
                startTime: MinuteOfDay(hour: 10, minute: 0),
                endTime: MinuteOfDay(hour: 10, minute: 45)
            )
        )
        let draft = DecompositionDraft(
            source: source,
            stage: .split,
            question: DecompositionQuestion(text: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"]),
            answer: "拿到确认",
            candidates: [
                candidate(
                    id: originalID,
                    title: "给物业打电话",
                    completion: "拿到明确上门时间",
                    proposal: proposal
                )
            ],
            mode: .manual(reason: .timedOut),
            lastRecoverableError: .planningFailed
        )
        #expect(draft.stage == .split)
        #expect(draft.question?.text == "完成后最重要的结果是什么？")
        #expect(draft.answer == "拿到确认")
        #expect(draft.candidates[0].proposal == proposal)
        #expect(draft.mode == .manual(reason: .timedOut))
        #expect(draft.lastRecoverableError == .planningFailed)
        #expect(CandidateDuration.allCases.map(\.rawValue) == [15, 30, 45, 60, 90])
        #expect(DecompositionStage.allCases == [.understand, .split, .schedule])
    }
}

private let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)

private func makeNote() -> Note {
    var note = Note.empty(
        id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000300")!),
        categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
        now: .distantPast
    )
    note.document = .init(blocks: [
        .init(id: blockID, kind: .paragraph, inlineContent: .plain("预约牙医"), taskState: nil, indentLevel: 0)
    ])
    return note
}

private func validPlanner(title: String) -> PlannerCandidate {
    PlannerCandidate(
        existingID: nil,
        title: title,
        completionDescription: "完成\(title)",
        estimatedMinutes: 30
    )
}

private func candidate(
    id: UUID,
    title: String,
    completion: String = "可观察的完成说明",
    titleLocked: Bool = false,
    completionLocked: Bool = false,
    selectedForCreation: Bool = true,
    selectedForCalendar: Bool = false,
    proposal: CalendarProposal? = nil
) -> CandidateAction {
    CandidateAction(
        id: id,
        title: title,
        completionDescription: completion,
        estimatedDuration: .minutes30,
        selectedForCreation: selectedForCreation,
        selectedForCalendar: selectedForCalendar,
        titleLockedByUser: titleLocked,
        completionLockedByUser: completionLocked,
        sourceCandidateID: nil,
        proposal: proposal
    )
}
