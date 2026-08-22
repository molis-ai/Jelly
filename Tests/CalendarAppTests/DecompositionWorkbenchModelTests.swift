import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DecompositionWorkbenchModelTests")
@MainActor
struct DecompositionWorkbenchModelTests {
    @Test func startAsksAtMostOneQuestionThenGeneratesCandidates() async throws {
        let planner = ScriptedDecompositionPlanner([
            .clarification(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"])),
            .candidates(validSuggestions(count: 3))
        ])
        let model = try await makeModel(planner: planner)
        await model.start()
        #expect(model.draft.stage == .understand)
        #expect(model.draft.question?.text == "完成后最重要的结果是什么？")
        #expect(model.draft.question?.quickAnswers == ["拿到确认"])
        #expect(model.draft.candidates.isEmpty)
        await model.submitAnswer("拿到确认")
        #expect(model.draft.stage == .split)
        #expect(model.draft.candidates.count == 3)
        #expect(model.draft.answer == "拿到确认")
        #expect(model.requestState == .idle)
    }

    @Test func startSkipsQuestionAndEntersSplitWhenClarificationIsNotNeeded() async throws {
        let planner = ScriptedDecompositionPlanner([
            .clarification(.notNeeded),
            .candidates(validSuggestions(count: 2))
        ])
        let model = try await makeModel(planner: planner)
        await model.start()
        #expect(model.draft.stage == .split)
        #expect(model.draft.question == nil)
        #expect(model.draft.candidates.count == 2)
        #expect(model.draft.candidates.allSatisfy { $0.selectedForCreation })
        #expect(model.draft.candidates.allSatisfy { !$0.selectedForCalendar })
    }

    @Test func emptyAnswerDoesNotSubmit() async throws {
        let planner = ScriptedDecompositionPlanner([
            .clarification(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"])),
            .candidates(validSuggestions(count: 2))
        ])
        let model = try await makeModel(planner: planner)
        await model.start()
        let before = model.draft
        await model.submitAnswer("  \n")
        #expect(model.draft == before)
        #expect(model.draft.stage == .understand)
        #expect(model.requestState == .idle)
        await model.submitAnswer("拿到确认")
        #expect(model.draft.stage == .split)
        #expect(model.draft.candidates.count == 2)
    }

    @Test func returningToPreviousStageKeepsCandidatesAndEnteringScheduleDoesNotWriteStore() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        let generation = fixture.store.statePublicationGeneration
        let saves = await fixture.repository.saveCount
        let candidates = model.draft.candidates
        model.advanceToSchedule()
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.candidates == candidates)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(await fixture.repository.saveCount == saves)
        model.returnToStage(.split)
        #expect(model.draft.stage == .split)
        #expect(model.draft.candidates == candidates)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(await fixture.repository.saveCount == saves)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
    }

    @Test func lateResultFromACancelledRequestIsDiscarded() async throws {
        let planner = DualShotClarificationPlanner()
        let sleeper = ControllableSleeper()
        let model = try await makeModel(planner: planner, sleeper: sleeper)
        let first = Task { await model.start() }
        await planner.waitUntilStarted(count: 1)
        let second = Task { await model.start() }
        await planner.waitUntilStarted(count: 2)
        await planner.resumeOldest(.ask(question: "来自A的迟到问题", quickAnswers: ["A"]))
        await first.value
        #expect(model.draft.question?.text != "来自A的迟到问题")
        await planner.resumeOldest(.ask(question: "来自B的问题", quickAnswers: ["B"]))
        await second.value
        #expect(model.draft.question?.text == "来自B的问题")
        #expect(model.draft.question?.quickAnswers == ["B"])
        #expect(model.requestState == .idle)
    }

    @Test func cancelRequestKeepsUserFieldsAndReturnsToIdle() async throws {
        let planner = DualShotClarificationPlanner()
        let model = try await makeModel(planner: planner)
        model.updateTitle(id: UUID(), value: "不应出现")
        let starting = Task { await model.start() }
        await planner.waitUntilStarted(count: 1)
        #expect({
            if case .running(_, .clarification) = model.requestState { return true }
            return false
        }())
        model.cancelRequest()
        await planner.resumeOldest(.ask(question: "取消后不该写入", quickAnswers: []))
        await starting.value
        #expect(model.requestState == .idle)
        #expect(model.draft.question == nil)
        #expect(model.draft.answer.isEmpty)
        #expect(model.draft.mode == .intelligent)
        #expect(model.draft.lastRecoverableError == nil)
    }

    @Test func timeoutUsesInjectedSleeperAndDoesNotWaitTwentySeconds() async throws {
        let planner = SleepingForeverPlanner()
        let sleeper = ControllableSleeper(policy: .finishImmediately)
        let model = try await makeModel(planner: planner, sleeper: sleeper)
        model.updateAnswer("已输入的回答")
        let started = Date()
        await model.start()
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2)
        #expect(model.draft.mode == .manual(reason: .timedOut))
        #expect(model.draft.answer == "已输入的回答")
        #expect(model.requestState == .idle)
    }

    @Test func invalidOutputRetriesOnceWithFeedbackThenEntersManualAfterExactlyTwoCalls() async throws {
        let invalid = [
            PlannerCandidate(
                existingID: nil,
                title: "只有一项",
                completionDescription: "无法构成合法拆解",
                estimatedMinutes: 30
            )
        ]
        let planner = RecordingDecompositionPlanner(
            clarifications: [.notNeeded],
            candidates: [invalid, invalid]
        )
        let model = try await makeModel(planner: planner)
        await model.start()
        #expect(planner.candidateRequests.count == 2)
        #expect(planner.candidateRequests[0].validationFeedback == nil)
        #expect(planner.candidateRequests[1].validationFeedback == .invalidCount(1))
        #expect(model.draft.mode == .manual(reason: .repeatedInvalidOutput))
        #expect(model.draft.candidates.isEmpty)
        #expect(model.requestState == .idle)
    }

    @Test func availabilityIsRecheckedBeforeEveryPlannerCall() async throws {
        let planner = RecordingDecompositionPlanner(
            clarifications: [.notNeeded],
            candidates: [validSuggestions(count: 2)]
        )
        planner.availabilityFlipAfterClarification = .unavailable(.localeUnsupported)
        let model = try await makeModel(planner: planner)
        await model.start()
        #expect(planner.clarificationCount == 1)
        #expect(planner.candidateRequests.isEmpty)
        #expect(model.draft.mode == .manual(reason: .localeUnsupported))
        #expect(model.draft.candidates.isEmpty)
    }

    @Test func unavailableReasonsMapWithoutCallingThePlanner() async throws {
        let reasons: [ManualDecompositionReason] = [
            .systemVersionUnsupported,
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .localeUnsupported
        ]
        for reason in reasons {
            let planner = RecordingDecompositionPlanner(
                availability: .unavailable(reason),
                clarifications: [.notNeeded],
                candidates: [validSuggestions(count: 2)]
            )
            let model = try await makeModel(planner: planner)
            await model.start()
            #expect(planner.clarificationCount == 0)
            #expect(planner.candidateRequests.isEmpty)
            #expect(model.draft.mode == .manual(reason: reason))
        }
    }

    @Test func modelFailureMapsToManualModeAndKeepsUserContent() async throws {
        let planner = ScriptedDecompositionPlanner([
            .clarification(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"])),
            .failure(.requestedFailure)
        ])
        let model = try await makeModel(planner: planner)
        await model.start()
        await model.submitAnswer("拿到确认")
        #expect(model.draft.mode == .manual(reason: .modelFailure))
        #expect(model.draft.answer == "拿到确认")
        #expect(model.draft.question?.text == "完成后最重要的结果是什么？")
        #expect(model.draft.candidates.isEmpty)
    }

    @Test func switchingToManualDoesNotClearUserEdits() async throws {
        let planner = ScriptedDecompositionPlanner([
            .clarification(.notNeeded),
            .candidates(validSuggestions(count: 2))
        ])
        let model = try await makeModel(planner: planner)
        await model.start()
        let firstID = model.draft.candidates[0].id
        model.updateTitle(id: firstID, value: "我改的标题")
        model.updateCompletion(id: firstID, value: "我改的说明")
        model.enterManualMode(reason: .modelFailure)
        #expect(model.draft.mode == .manual(reason: .modelFailure))
        #expect(model.draft.candidates[0].title == "我改的标题")
        #expect(model.draft.candidates[0].completionDescription == "我改的说明")
        #expect(model.draft.candidates.count == 2)
    }

    @Test func titleAndCompletionLockIndependentlyAcrossRefresh() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000810")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000811")!
        let planner = ScriptedDecompositionPlanner([
            .clarification(.notNeeded),
            .candidates(validSuggestions(count: 2)),
            .candidates([
                PlannerCandidate(
                    existingID: firstID,
                    title: "模型标题",
                    completionDescription: "模型说明一",
                    estimatedMinutes: 45
                ),
                PlannerCandidate(
                    existingID: secondID,
                    title: "模型第二标题",
                    completionDescription: "模型说明二",
                    estimatedMinutes: 15
                )
            ])
        ])
        let model = try await makeModel(
            planner: planner,
            uuid: SequentialUUID([firstID, secondID]).next
        )
        await model.start()
        model.updateTitle(id: firstID, value: "我改的标题")
        #expect(model.draft.candidates[0].titleLockedByUser)
        #expect(!model.draft.candidates[0].completionLockedByUser)
        await model.refreshUnlockedCandidates()
        #expect(model.draft.candidates[0].title == "我改的标题")
        #expect(model.draft.candidates[0].completionDescription == "模型说明一")
        #expect(model.draft.candidates[1].title == "模型第二标题")
        #expect(model.draft.candidates[0].id == firstID)
        #expect(model.draft.candidates[1].id == secondID)
    }

    @Test func emptyFieldsAreAllowedWhileEditingButBlockAdvanceAndCommit() async throws {
        let planner = ScriptedDecompositionPlanner([
            .clarification(.notNeeded),
            .candidates(validSuggestions(count: 2))
        ])
        let fixture = try await WorkbenchFixture.make(planner: planner)
        let model = fixture.model
        await model.start()
        let firstID = model.draft.candidates[0].id
        model.updateTitle(id: firstID, value: "   ")
        #expect(model.draft.candidates[0].title.isEmpty)
        #expect(model.draft.candidates[0].titleLockedByUser)
        model.advanceToSchedule()
        #expect(model.draft.stage == .split)
        model.updateTitle(id: firstID, value: "给物业打电话")
        model.updateCompletion(id: firstID, value: "")
        model.advanceToSchedule()
        #expect(model.draft.stage == .split)
        model.updateCompletion(id: firstID, value: "拿到明确上门时间")
        model.advanceToSchedule()
        #expect(model.draft.stage == .schedule)
        model.updateTitle(id: firstID, value: "")
        let result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(model.draft.stage == .schedule)
        #expect(await fixture.repository.saveCount == 0)
    }

    @Test func addDeleteReorderSelectScheduleAndFailedSplitPreserveNeighbors() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000820")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000821")!
        let manualID = UUID(uuidString: "00000000-0000-0000-0000-000000000822")!
        let planner = RecordingDecompositionPlanner(
            clarifications: [.notNeeded],
            candidates: [validSuggestions(count: 2)],
            splits: [
                [PlannerCandidate(
                    existingID: nil,
                    title: "非法一项",
                    completionDescription: "不够数",
                    estimatedMinutes: 15
                )],
                [PlannerCandidate(
                    existingID: nil,
                    title: "非法一项",
                    completionDescription: "不够数",
                    estimatedMinutes: 15
                )]
            ]
        )
        let model = try await makeModel(
            planner: planner,
            uuid: SequentialUUID([firstID, secondID, manualID]).next
        )
        await model.start()
        model.addManualCandidate()
        #expect(model.draft.candidates.map(\.id) == [firstID, secondID, manualID])
        #expect(model.draft.candidates[2].title.isEmpty)
        model.updateTitle(id: manualID, value: "手工行动")
        model.updateCompletion(id: manualID, value: "手工完成说明")
        model.moveCandidate(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.draft.candidates.map(\.id) == [manualID, firstID, secondID])
        model.setSelectedForCreation(id: firstID, selected: false)
        #expect(!model.draft.candidates[1].selectedForCreation)
        #expect(!model.draft.candidates[1].selectedForCalendar)
        model.setSelectedForCalendar(id: secondID, selected: true)
        #expect(model.draft.candidates[2].selectedForCalendar)
        model.refreshCalendarProposals()
        #expect(model.draft.candidates[2].proposal != nil)
        let beforeSplit = model.draft.candidates
        await model.split(secondID)
        #expect(planner.splitRequests.count == 2)
        #expect(planner.splitRequests[0].validationFeedback == nil)
        #expect(planner.splitRequests[1].validationFeedback == .invalidCount(1))
        #expect(model.draft.candidates == beforeSplit)
        #expect(model.draft.mode == .manual(reason: .repeatedInvalidOutput))
        model.deleteCandidate(id: firstID)
        #expect(model.draft.candidates.map(\.id) == [manualID, secondID])
        #expect(model.draft.candidates[1].proposal != nil)
    }

    @Test func successfulSplitReplacesOnlyTheTargetAndRefreshProposalsUseCurrentSelection() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000830")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000831")!
        let planner = ScriptedDecompositionPlanner([
            .clarification(.notNeeded),
            .candidates(validSuggestions(count: 2)),
            .candidates([
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
            ])
        ])
        let model = try await makeModel(
            planner: planner,
            uuid: SequentialUUID([firstID, secondID]).next
        )
        await model.start()
        let originalFirst = model.draft.candidates[0]
        await model.split(secondID)
        #expect(model.draft.candidates.count == 3)
        #expect(model.draft.candidates[0] == originalFirst)
        #expect(model.draft.candidates[1].title == "拆出甲")
        #expect(model.draft.candidates[2].title == "拆出乙")
        #expect(model.draft.candidates[1].sourceCandidateID == secondID)
        #expect(!model.draft.candidates.map(\.id).contains(secondID))
        model.setSelectedForCalendar(id: firstID, selected: true)
        model.setSelectedForCalendar(id: model.draft.candidates[1].id, selected: true)
        model.refreshCalendarProposals()
        #expect(model.draft.candidates[0].proposal != nil)
        #expect(model.draft.candidates[1].proposal != nil)
        #expect(model.draft.candidates[2].proposal == nil)
    }

    @Test func commitGeneratesIDsOnlyThenAndMapsCommittedOutcome() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000840")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000841")!
        let firstBlock = UUID(uuidString: "00000000-0000-0000-0000-000000000842")!
        let secondBlock = UUID(uuidString: "00000000-0000-0000-0000-000000000843")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000844")!
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            uuid: SequentialUUID([firstID, secondID, firstBlock, secondBlock, itemID]).next
        )
        let model = fixture.model
        await model.start()
        #expect(fixture.store.state.notes[FixtureIDs.noteID]?.document.blocks.contains(where: {
            $0.id == BlockID(firstBlock)
        }) != true)
        model.setSelectedForCalendar(id: firstID, selected: true)
        model.advanceToSchedule()
        #expect(model.draft.candidates[0].proposal != nil)
        let generationBefore = fixture.store.statePublicationGeneration
        let result = await model.commit()
        guard case let .committed(created, scheduled, generation) = result else {
            Issue.record("expected committed result, got \(result)")
            return
        }
        #expect(created == 2)
        #expect(scheduled == 1)
        #expect(generation == fixture.store.statePublicationGeneration)
        #expect(fixture.store.statePublicationGeneration > generationBefore)
        #expect(fixture.store.state.notes[FixtureIDs.noteID]?.document.blocks.map(\.id).contains(BlockID(firstBlock)) == true)
        #expect(fixture.store.state.notes[FixtureIDs.noteID]?.document.blocks.map(\.id).contains(BlockID(secondBlock)) == true)
        #expect(fixture.store.calendarState.items[itemID] != nil)
        #expect(fixture.store.calendarState.items[itemID]?.title == "行动1")
        #expect(fixture.store.calendarState.items[itemID]?.notes.isEmpty == true)
        let completion = fixture.store.state.notes[FixtureIDs.noteID]?.document.blocks
            .first { $0.id == BlockID(firstBlock) }?
            .taskState?.completionDescription
        #expect(completion == "完成行动1")
        #expect(fixture.store.latestUndoLabel == "拆开并安排")
    }

    @Test func commitIsSingleFlightAndDoesNotDoubleWrite() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000850")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000851")!
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            uuid: SequentialUUID([
                firstID,
                secondID,
                UUID(uuidString: "00000000-0000-0000-0000-000000000852")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000853")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000854")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000855")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000856")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000857")!
            ]).next
        )
        let model = fixture.model
        await model.start()
        model.advanceToSchedule()
        await fixture.repository.suspendNextSave()
        async let first = model.commit()
        await fixture.repository.waitForSaveStart()
        async let second = model.commit()
        await fixture.repository.resumeSave()
        let results = await (first, second)
        let committedCount = [results.0, results.1].filter {
            if case .committed = $0 { return true }
            return false
        }.count
        #expect(committedCount == 1)
        #expect(await fixture.repository.saveCount == 1)
        #expect(model.isCommitting == false)
    }

    @Test func sourceConflictKeepsDraftAndReturnsToSplit() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            snapshotRevisionOffset: -1
        )
        let model = fixture.model
        await model.start()
        model.advanceToSchedule()
        let draft = model.draft
        let generation = fixture.store.statePublicationGeneration
        let result = await model.commit()
        #expect(result == .sourceChanged)
        #expect(model.draft.stage == .split)
        #expect(model.draft.candidates == draft.candidates)
        #expect(model.draft.answer == draft.answer)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
    }

    @Test func calendarConflictKeepsDraftAndReturnsToSchedule() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        model.setSelectedForCalendar(id: model.draft.candidates[0].id, selected: true)
        model.advanceToSchedule()
        let proposal = try #require(model.draft.candidates[0].proposal)
        let blocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000860")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: proposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await fixture.store.sendCalendar(.createItem(blocking), undoLabel: "挡路")
        let generation = fixture.store.statePublicationGeneration
        let draft = model.draft
        let result = await model.commit()
        #expect(result == .calendarConflict)
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.candidates.map(\.id) == draft.candidates.map(\.id))
        #expect(model.draft.lastRecoverableError == .calendarConflict)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
        #expect(fixture.store.calendarState.items[blocking.id] != nil)
    }

    @Test func persistenceFailureKeepsDraftAndDoesNotClaimSuccess() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        model.advanceToSchedule()
        await fixture.repository.failNextSave()
        let generation = fixture.store.statePublicationGeneration
        let draft = model.draft
        let result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.candidates == draft.candidates)
        #expect(model.draft.lastRecoverableError == .persistenceFailed)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
        #expect(await fixture.repository.saveCount == 0)
    }

    @Test func missingProposalBlocksCommitWithoutWriting() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        model.setSelectedForCalendar(id: model.draft.candidates[0].id, selected: true)
        model.advanceToSchedule()
        model.setProposal(id: model.draft.candidates[0].id, proposal: nil)
        let result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(await fixture.repository.saveCount == 0)
        #expect(model.draft.stage == .schedule)
    }

    fileprivate static let notCommittedMessage = "原笔记和日历没有被改动，可稍后重试"
}

@MainActor
private func makeModel(
    planner: any DecompositionPlanning,
    sleeper: ControllableSleeper = ControllableSleeper(),
    uuid: @escaping @Sendable () -> UUID = UUID.init,
    snapshotRevisionOffset: Int64 = 0
) async throws -> DecompositionWorkbenchModel {
    try await WorkbenchFixture.make(
        planner: planner,
        sleeper: sleeper,
        uuid: uuid,
        snapshotRevisionOffset: snapshotRevisionOffset
    ).model
}

@MainActor
private struct WorkbenchFixture {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let now = Date(timeIntervalSince1970: 1_787_356_800)
    static let day = CalendarDate(year: 2026, month: 8, day: 22)!

    let model: DecompositionWorkbenchModel
    let store: WorkspaceStore
    let repository: WorkspaceStoreTestRepository

    static func make(
        planner: any DecompositionPlanning,
        sleeper: ControllableSleeper = ControllableSleeper(),
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        snapshotRevisionOffset: Int64 = 0
    ) async throws -> WorkbenchFixture {
        let note = sourceNote()
        let calendar = CalendarState.empty(uncategorizedID: FixtureIDs.categoryID, now: now)
        let workspace = WorkspaceState(
            revision: 5,
            calendar: calendar,
            notes: [note.id: note],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: []
        )
        let repository = WorkspaceStoreTestRepository(initial: workspace)
        let store = WorkspaceStore(initialState: workspace, repository: repository)
        await store.load()
        var snapshot = try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: workspace.revision,
            selection: .text(
                anchor: .init(blockID: FixtureIDs.sourceBlockID, graphemeOffset: 0),
                focus: .init(blockID: FixtureIDs.sourceBlockID, graphemeOffset: 4),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
        if snapshotRevisionOffset != 0 {
            snapshot = DecompositionSourceSnapshot(
                noteID: snapshot.noteID,
                noteRevision: snapshot.noteRevision + snapshotRevisionOffset,
                workspaceRevision: snapshot.workspaceRevision,
                sourceBlockID: snapshot.sourceBlockID,
                selectedRange: snapshot.selectedRange,
                normalizedText: snapshot.normalizedText,
                noteChecksum: snapshot.noteChecksum,
                sourceChecksum: snapshot.sourceChecksum
            )
        }
        let clockNow = now
        let model = DecompositionWorkbenchModel(
            snapshot: snapshot,
            planner: planner,
            store: store,
            clock: { clockNow },
            timeZone: shanghai,
            sleeper: sleeper,
            uuid: uuid,
            requestTimeout: .seconds(20)
        )
        return .init(model: model, store: store, repository: repository)
    }
}

private enum FixtureIDs {
    static let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000800")!)
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
    static let sourceBlockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000802")!)
}

@MainActor
private func sourceNote() -> Note {
    Note(
        id: FixtureIDs.noteID,
        title: "来源笔记",
        document: .init(blocks: [
            .init(
                id: FixtureIDs.sourceBlockID,
                kind: .paragraph,
                inlineContent: .plain("预约牙医"),
                taskState: nil,
                indentLevel: 0
            )
        ]),
        categoryID: FixtureIDs.categoryID,
        archivedAt: nil,
        revision: 3,
        createdAt: WorkbenchFixture.now,
        updatedAt: WorkbenchFixture.now
    )
}

private func validSuggestions(count: Int) -> [PlannerCandidate] {
    (0..<count).map { index in
        PlannerCandidate(
            existingID: nil,
            title: "行动\(index + 1)",
            completionDescription: "完成行动\(index + 1)",
            estimatedMinutes: [15, 30, 45, 60, 90][index % 5]
        )
    }
}

private func planObjectsAreAbsent(_ state: WorkspaceState, noteID: NoteID) -> Bool {
    let titles = state.notes[noteID]?.document.blocks.map {
        $0.inlineContent.spans.map(\.text).joined()
    } ?? []
    return titles == ["预约牙医"]
        && state.taskBlockLinks.isEmpty
}

private final class SequentialUUID: @unchecked Sendable {
    private var values: [UUID]
    init(_ values: [UUID]) { self.values = values }
    func next() -> UUID {
        values.isEmpty ? UUID() : values.removeFirst()
    }
}

private final class ControllableSleeper: DecompositionSleeping, @unchecked Sendable {
    enum Policy: Sendable {
        case hangUntilCancelled
        case finishImmediately
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let policy: Policy

    init(policy: Policy = .hangUntilCancelled) {
        self.policy = policy
    }

    func sleep(for duration: Duration) async throws {
        if policy == .finishImmediately {
            try Task.checkCancellation()
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(throwing: CancellationError())
        }
    }
}

private actor SleepingForeverPlanner: DecompositionPlanning {
    nonisolated var availability: DecompositionPlannerAvailability { .available }

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        try await Task.sleep(for: .seconds(60 * 60))
        throw ScriptedPlannerFailure.exhausted
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        try await Task.sleep(for: .seconds(60 * 60))
        throw ScriptedPlannerFailure.exhausted
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        try await Task.sleep(for: .seconds(60 * 60))
        throw ScriptedPlannerFailure.exhausted
    }
}

private actor DualShotClarificationPlanner: DecompositionPlanning {
    nonisolated var availability: DecompositionPlannerAvailability { .available }

    private var shots: [CheckedContinuation<ClarificationDecision, Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedCount = 0

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        startedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { shots.append($0) }
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        throw ScriptedPlannerFailure.exhausted
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        throw ScriptedPlannerFailure.exhausted
    }

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func resumeOldest(_ decision: ClarificationDecision) {
        guard !shots.isEmpty else { return }
        shots.removeFirst().resume(returning: decision)
    }
}

private final class RecordingDecompositionPlanner: DecompositionPlanning, @unchecked Sendable {
    var availability: DecompositionPlannerAvailability
    var availabilityFlipAfterClarification: DecompositionPlannerAvailability?
    private var clarifications: [ClarificationDecision]
    private var candidateBatches: [[PlannerCandidate]]
    private var splitBatches: [[PlannerCandidate]]
    private(set) var candidateRequests: [CandidateRequest] = []
    private(set) var splitRequests: [SplitCandidateRequest] = []
    private(set) var clarificationCount = 0

    init(
        availability: DecompositionPlannerAvailability = .available,
        clarifications: [ClarificationDecision] = [.notNeeded],
        candidates: [[PlannerCandidate]] = [],
        splits: [[PlannerCandidate]] = []
    ) {
        self.availability = availability
        self.clarifications = clarifications
        self.candidateBatches = candidates
        self.splitBatches = splits
    }

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        clarificationCount += 1
        if let flipped = availabilityFlipAfterClarification {
            availability = flipped
        }
        guard !clarifications.isEmpty else { throw ScriptedPlannerFailure.exhausted }
        return clarifications.removeFirst()
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        candidateRequests.append(request)
        guard !candidateBatches.isEmpty else { throw ScriptedPlannerFailure.exhausted }
        return candidateBatches.removeFirst()
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        splitRequests.append(request)
        guard !splitBatches.isEmpty else { throw ScriptedPlannerFailure.exhausted }
        return splitBatches.removeFirst()
    }
}
