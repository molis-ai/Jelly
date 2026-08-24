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

    @Test func returningToScheduleKeepsManualProposalUntilExplicitRefresh() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        let firstID = model.draft.candidates[0].id
        model.setSelectedForCalendar(id: firstID, selected: true)
        model.advanceToSchedule()
        let generated = try #require(model.draft.candidates[0].proposal)
        #expect(generated.schedule.startDate == WorkbenchFixture.day)
        #expect(generated.schedule.endDate == WorkbenchFixture.day)
        #expect(generated.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(generated.schedule.endTime == MinuteOfDay(hour: 9, minute: 15))

        let manualSchedule = try CalendarSchedule(
            startDate: WorkbenchFixture.day,
            endDate: WorkbenchFixture.day,
            startTime: MinuteOfDay(hour: 14, minute: 0),
            endTime: MinuteOfDay(hour: 14, minute: 15)
        )
        let manual = CalendarProposal(schedule: manualSchedule)
        model.setProposal(id: firstID, proposal: manual)
        #expect(model.draft.candidates[0].proposal == manual)
        #expect(model.draft.candidates[0].proposal != generated)

        model.returnToStage(.split)
        #expect(model.draft.stage == .split)
        #expect(model.draft.candidates[0].proposal == manual)
        model.advanceToSchedule()
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.candidates[0].proposal == manual)
        #expect(model.draft.candidates[0].proposal?.schedule.startTime == MinuteOfDay(hour: 14, minute: 0))
        #expect(model.draft.candidates[0].proposal?.schedule.endTime == MinuteOfDay(hour: 14, minute: 15))
        #expect(model.draft.candidates[0].proposal != generated)

        model.refreshCalendarProposals()
        #expect(model.draft.candidates[0].proposal == generated)
        #expect(model.draft.candidates[0].proposal?.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(model.draft.candidates[0].proposal?.schedule.endTime == MinuteOfDay(hour: 9, minute: 15))
    }

    @Test func enablingCalendarForAnotherCandidateDoesNotOverwriteAManualProposal() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        let firstID = model.draft.candidates[0].id
        let secondID = model.draft.candidates[1].id
        model.setSelectedForCalendar(id: firstID, selected: true)
        model.advanceToSchedule()
        let manualSchedule = try CalendarSchedule(
            startDate: WorkbenchFixture.day,
            endDate: WorkbenchFixture.day,
            startTime: MinuteOfDay(hour: 14, minute: 0),
            endTime: MinuteOfDay(hour: 14, minute: 15)
        )
        let manual = CalendarProposal(schedule: manualSchedule)
        model.setProposal(id: firstID, proposal: manual)
        let snapshotA = model.draft.candidates[0]
        #expect(snapshotA.proposal == manual)

        model.setSelectedForCalendar(id: secondID, selected: true)

        #expect(model.draft.candidates[0] == snapshotA)
        #expect(model.draft.candidates[0].proposal == manual)
        let proposalB = try #require(model.draft.candidates[1].proposal)
        #expect(proposalB != manual)
        #expect(
            !CalendarTimedOccupancy.overlaps(manual.schedule, proposalB.schedule)
        )
        let otherDraftSchedules = model.draft.candidates.compactMap { candidate -> CalendarSchedule? in
            guard candidate.id != secondID else { return nil }
            return candidate.proposal?.schedule
        }
        #expect(otherDraftSchedules.allSatisfy { !CalendarTimedOccupancy.overlaps($0, proposalB.schedule) })
    }

    @Test func changingDurationAfterReturningFromScheduleCommitsNewDurationAndKeepsStart() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000880")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000881")!
        let firstBlock = UUID(uuidString: "00000000-0000-0000-0000-000000000882")!
        let secondBlock = UUID(uuidString: "00000000-0000-0000-0000-000000000883")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000884")!
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            uuid: SequentialUUID([firstID, secondID, firstBlock, secondBlock, itemID]).next
        )
        let model = fixture.model
        await model.start()
        model.setSelectedForCalendar(id: firstID, selected: true)
        model.advanceToSchedule()
        let original = try #require(model.draft.candidates[0].proposal)
        #expect(model.draft.candidates[0].estimatedDuration == .minutes15)
        #expect(original.schedule.startDate == WorkbenchFixture.day)
        #expect(original.schedule.startTime == MinuteOfDay(hour: 9, minute: 0))
        #expect(timedDurationMinutes(original.schedule) == CandidateDuration.minutes15.rawValue)

        model.returnToStage(.split)
        model.updateDuration(id: firstID, duration: .minutes60)
        #expect(model.draft.stage == .split)
        #expect(model.draft.candidates[0].estimatedDuration == .minutes60)
        #expect(model.draft.candidates[0].proposal?.schedule.startDate == original.schedule.startDate)
        #expect(model.draft.candidates[0].proposal?.schedule.startTime == original.schedule.startTime)
        #expect(timedDurationMinutes(try #require(model.draft.candidates[0].proposal).schedule)
            == CandidateDuration.minutes60.rawValue)

        model.advanceToSchedule()
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.candidates[0].proposal?.schedule.startDate == original.schedule.startDate)
        #expect(model.draft.candidates[0].proposal?.schedule.startTime == original.schedule.startTime)
        #expect(timedDurationMinutes(try #require(model.draft.candidates[0].proposal).schedule)
            == CandidateDuration.minutes60.rawValue)

        let result = await model.commit()
        guard case let .committed(_, scheduled, _) = result else {
            Issue.record("expected committed result, got \(result)")
            return
        }
        #expect(scheduled == 1)
        let item = try #require(fixture.store.calendarState.items[itemID])
        #expect(item.schedule.startDate == original.schedule.startDate)
        #expect(item.schedule.startTime == original.schedule.startTime)
        #expect(timedDurationMinutes(item.schedule) == CandidateDuration.minutes60.rawValue)
        #expect(item.schedule.endTime == MinuteOfDay(hour: 10, minute: 0))
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

    @Test func localEditsDuringInFlightRefreshKeepUserChangesAndReturnIdle() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000870")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000871")!
        let planner = DualShotCandidatePlanner()
        let model = try await makeModel(
            planner: planner,
            uuid: SequentialUUID([firstID, secondID]).next
        )
        let starting = Task { await model.start() }
        await planner.waitUntilStarted(count: 1)
        await planner.resumeOldest(validSuggestions(count: 2))
        await starting.value
        #expect(model.draft.candidates.map(\.id) == [firstID, secondID])
        #expect(model.requestState == .idle)

        let refresh = Task { await model.refreshUnlockedCandidates() }
        await planner.waitUntilStarted(count: 2)
        #expect({
            if case .running(_, .refreshCandidates) = model.requestState { return true }
            return false
        }())

        model.updateTitle(id: firstID, value: "手改标题")
        model.moveCandidate(id: secondID, toPositionOf: firstID)
        #expect(model.requestState == .idle)
        #expect(model.draft.candidates.map(\.id) == [secondID, firstID])
        #expect(model.draft.candidates[1].title == "手改标题")

        await planner.resumeOldest([
            PlannerCandidate(
                existingID: firstID,
                title: "迟到标题1",
                completionDescription: "迟到说明1",
                estimatedMinutes: 45
            ),
            PlannerCandidate(
                existingID: secondID,
                title: "迟到标题2",
                completionDescription: "迟到说明2",
                estimatedMinutes: 60
            )
        ])
        await refresh.value

        #expect(model.requestState == .idle)
        #expect(model.draft.candidates.map(\.id) == [secondID, firstID])
        #expect(model.draft.candidates[0].title == "行动2")
        #expect(model.draft.candidates[1].title == "手改标题")
        #expect(model.draft.candidates[1].titleLockedByUser)
        #expect(model.draft.candidates.map(\.title).contains("迟到标题1") == false)
        #expect(model.draft.candidates.map(\.title).contains("迟到标题2") == false)
        #expect(model.draft.candidates[0].estimatedDuration == .minutes30)
        #expect(model.draft.candidates[1].estimatedDuration == .minutes15)
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

    @Test func timeoutIsKeptWhenCooperativePlannerReturnsCancellationErrorImmediately() async throws {
        let planner = CooperativeCancellablePlanner()
        let sleeper = ControllableSleeper(policy: .waitUntilReleased)
        let model = try await makeModel(planner: planner, sleeper: sleeper)
        let starting = Task { await model.start() }
        await planner.waitUntilStarted(count: 1)
        sleeper.release()
        await starting.value
        #expect(model.draft.mode == .manual(reason: .timedOut))
        #expect(model.requestState == .idle)
        #expect(model.draft.question == nil)
        #expect(model.draft.candidates.count == 1)
        #expect(model.draft.candidates[0].title.isEmpty)
        #expect(model.draft.candidates[0].completionDescription.isEmpty)
        #expect(model.draft.lastRecoverableError == nil)
    }

    @Test func nonCooperativePlannerTimeoutReturnsWithoutWaitingAndDiscardsLateResult() async throws {
        let planner = DualShotClarificationPlanner()
        let sleeper = ControllableSleeper(policy: .finishImmediately)
        let model = try await makeModel(planner: planner, sleeper: sleeper)
        let starting = Task { await model.start() }
        await planner.waitUntilStarted(count: 1)

        #expect(await returnedWithin(starting, limit: .milliseconds(400)))
        #expect(model.draft.mode == .manual(reason: .timedOut))
        #expect(model.draft.question == nil)
        #expect(model.requestState == .idle)

        await planner.resumeOldest(.ask(question: "迟到的问题", quickAnswers: ["不该写入"]))
        await starting.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.draft.question == nil)
        #expect(model.draft.mode == .manual(reason: .timedOut))
        #expect(model.draft.candidates.count == 1)
        #expect(model.draft.candidates[0].title.isEmpty)
        #expect(model.draft.candidates[0].completionDescription.isEmpty)
    }

    @Test func cancelEndsOuterRequestWithoutWaitingForNonCooperativePlannerAndDiscardsLateResult() async throws {
        let planner = DualShotClarificationPlanner()
        let model = try await makeModel(planner: planner)
        let starting = Task { await model.start() }
        await planner.waitUntilStarted(count: 1)
        #expect({
            if case .running(_, .clarification) = model.requestState { return true }
            return false
        }())

        model.cancelRequest()
        #expect(await returnedWithin(starting, limit: .milliseconds(400)))
        #expect(model.requestState == .idle)
        #expect(model.draft.question == nil)
        #expect(model.draft.mode == .intelligent)

        await planner.resumeOldest(.ask(question: "取消后迟到的问题", quickAnswers: ["不该写入"]))
        await starting.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.draft.question == nil)
        #expect(model.draft.mode == .intelligent)
        #expect(model.draft.candidates.isEmpty)
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
        #expect(model.draft.candidates.count == 1)
        #expect(model.draft.candidates[0].title.isEmpty)
        #expect(model.draft.candidates[0].completionDescription.isEmpty)
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
        #expect(model.draft.candidates.count == 1)
        #expect(model.draft.candidates[0].title.isEmpty)
        #expect(model.draft.candidates[0].completionDescription.isEmpty)
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
        #expect(model.draft.candidates.count == 1)
        #expect(model.draft.candidates[0].title.isEmpty)
        #expect(model.draft.candidates[0].completionDescription.isEmpty)
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
        #expect(model.draft.candidates[0].title == "   ")
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
        model.moveCandidate(id: manualID, toPositionOf: firstID)
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

    @Test func reorderByCandidateIDMovesForwardAndBackwardKeepsFieldsAndIgnoresSelfOrUnknown() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000840")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000841")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000842")!
        let model = try await makeModel(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 3))
            ]),
            uuid: SequentialUUID([firstID, secondID, thirdID]).next
        )
        await model.start()
        model.updateTitle(id: firstID, value: "锁定标题一")
        model.updateCompletion(id: secondID, value: "锁定说明二")
        model.updateDuration(id: thirdID, duration: .minutes90)
        model.setSelectedForCreation(id: secondID, selected: false)
        model.setSelectedForCalendar(id: firstID, selected: true)
        model.refreshCalendarProposals()
        let snapshotByID = Dictionary(
            uniqueKeysWithValues: model.draft.candidates.map { ($0.id, $0) }
        )
        #expect(snapshotByID[firstID]?.titleLockedByUser == true)
        #expect(snapshotByID[secondID]?.completionLockedByUser == true)
        #expect(snapshotByID[firstID]?.proposal != nil)
        #expect(snapshotByID[secondID]?.selectedForCreation == false)

        model.moveCandidate(id: firstID, toPositionOf: thirdID)
        #expect(model.draft.candidates.map(\.id) == [secondID, thirdID, firstID])
        for candidate in model.draft.candidates {
            #expect(candidate == snapshotByID[candidate.id])
        }

        model.moveCandidate(id: firstID, toPositionOf: secondID)
        #expect(model.draft.candidates.map(\.id) == [firstID, secondID, thirdID])
        for candidate in model.draft.candidates {
            #expect(candidate == snapshotByID[candidate.id])
        }

        let beforeSelf = model.draft.candidates
        model.moveCandidate(id: secondID, toPositionOf: secondID)
        #expect(model.draft.candidates == beforeSelf)

        model.moveCandidate(id: firstID, toPositionOf: UUID())
        model.moveCandidate(id: UUID(), toPositionOf: secondID)
        #expect(model.draft.candidates == beforeSelf)
        for candidate in model.draft.candidates {
            #expect(candidate == snapshotByID[candidate.id])
        }
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

    @Test func commitGeneratesIDsOnlyThenAndMapsBoundaryTrimmedOutcome() async throws {
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
        model.updateTitle(id: firstID, value: "  手改标题  ")
        model.updateCompletion(id: firstID, value: "  完成说明  ")
        #expect(model.draft.candidates[0].title == "  手改标题  ")
        #expect(model.draft.candidates[0].completionDescription == "  完成说明  ")
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
        let firstBlockContent = fixture.store.state.notes[FixtureIDs.noteID]?.document.blocks
            .first { $0.id == BlockID(firstBlock) }
        #expect(firstBlockContent?.inlineContent.spans.map(\.text).joined() == "手改标题")
        #expect(fixture.store.calendarState.items[itemID] != nil)
        #expect(fixture.store.calendarState.items[itemID]?.title == "手改标题")
        #expect(fixture.store.calendarState.items[itemID]?.notes.isEmpty == true)
        let completion = firstBlockContent?.taskState?.completionDescription
        #expect(completion == "完成说明")
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
        model.updateAnswer("冲突后仍保留回答")
        let first = model.draft.candidates[0].id
        let second = model.draft.candidates[1].id
        model.setSelectedForCalendar(id: first, selected: true)
        model.setSelectedForCalendar(id: second, selected: true)
        model.advanceToSchedule()
        model.updateProposalTime(id: first, instant: fixture.date(hour: 16, minute: 30))
        model.updateDuration(id: first, duration: .minutes45)
        let lockedProposal = try #require(model.draft.candidates[0].proposal)
        let unlockedProposal = try #require(model.draft.candidates[1].proposal)
        #expect(model.draft.candidates[0].scheduleLockedByUser)
        #expect(!model.draft.candidates[1].scheduleLockedByUser)
        let blocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000860")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: unlockedProposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await fixture.store.sendCalendar(.createItem(blocking), undoLabel: "挡路")
        let generation = fixture.store.statePublicationGeneration
        let revision = fixture.store.state.revision
        let saves = await fixture.repository.saveCount
        let answer = model.draft.answer
        let snapshot = recoverySnapshot(of: model.draft.candidates)
        let result = await model.commit()
        #expect(result == .calendarConflict)
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.answer == answer)
        #expect(recoverySnapshot(of: model.draft.candidates) == snapshot)
        #expect(model.draft.candidates[0].title == "行动1")
        #expect(model.draft.candidates[0].completionDescription == "完成行动1")
        #expect(model.draft.candidates[0].selectedForCreation)
        #expect(model.draft.candidates[0].selectedForCalendar)
        #expect(model.draft.candidates[0].proposal == lockedProposal)
        #expect(model.draft.candidates[0].scheduleLockedByUser)
        #expect(model.draft.candidates[1].title == "行动2")
        #expect(model.draft.candidates[1].completionDescription == "完成行动2")
        #expect(model.draft.candidates[1].selectedForCalendar)
        #expect(model.draft.candidates[1].proposal == unlockedProposal)
        #expect(!model.draft.candidates[1].scheduleLockedByUser)
        #expect(model.draft.lastRecoverableError == .calendarConflict)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(fixture.store.state.revision == revision)
        #expect(await fixture.repository.saveCount == saves)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
        #expect(fixture.store.calendarState.items[blocking.id] != nil)

        model.refreshCalendarProposals(overwriteUserAdjustments: false)
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.candidates[0].proposal == lockedProposal)
        #expect(model.draft.candidates[0].estimatedDuration == .minutes45)
        #expect(model.draft.candidates[0].scheduleLockedByUser)
        #expect(!model.draft.candidates[1].scheduleLockedByUser)
        #expect(model.draft.candidates[1].proposal != unlockedProposal)
        #expect(model.draft.candidates[1].proposal != nil)
        #expect(model.draft.candidates[1].selectedForCalendar)
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
        model.updateAnswer("保存失败后仍保留回答")
        let first = model.draft.candidates[0].id
        model.setSelectedForCalendar(id: first, selected: true)
        model.advanceToSchedule()
        model.updateProposalTime(id: first, instant: fixture.date(hour: 16, minute: 30))
        model.updateDuration(id: first, duration: .minutes45)
        #expect(model.draft.candidates[0].scheduleLockedByUser)
        let lockedProposal = try #require(model.draft.candidates[0].proposal)
        await fixture.repository.failNextSave()
        let generation = fixture.store.statePublicationGeneration
        let revision = fixture.store.state.revision
        let noteRevision = try #require(fixture.store.state.notes[FixtureIDs.noteID]).revision
        let answer = model.draft.answer
        let snapshot = recoverySnapshot(of: model.draft.candidates)
        let result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(model.draft.stage == .schedule)
        #expect(model.draft.answer == answer)
        #expect(recoverySnapshot(of: model.draft.candidates) == snapshot)
        #expect(model.draft.candidates[0].title == "行动1")
        #expect(model.draft.candidates[0].completionDescription == "完成行动1")
        #expect(model.draft.candidates[0].selectedForCreation)
        #expect(model.draft.candidates[0].selectedForCalendar)
        #expect(model.draft.candidates[0].proposal == lockedProposal)
        #expect(model.draft.candidates[0].scheduleLockedByUser)
        #expect(model.draft.candidates[1].title == "行动2")
        #expect(model.draft.candidates[1].selectedForCreation)
        #expect(!model.draft.candidates[1].selectedForCalendar)
        #expect(model.draft.lastRecoverableError == .persistenceFailed)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(fixture.store.state.revision == revision)
        #expect(fixture.store.state.notes[FixtureIDs.noteID]?.revision == noteRevision)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
        #expect(await fixture.repository.saveCount == 0)
        #expect(planObjectCounts(fixture.store.state, noteID: FixtureIDs.noteID) == (0, 0, 0))

        let retry = await model.commit()
        guard case let .committed(created, scheduled, committedGeneration) = retry else {
            Issue.record("same model must commit after the failed save is cleared, got \(retry)")
            return
        }
        #expect(created == 2)
        #expect(scheduled == 1)
        #expect(committedGeneration == fixture.store.statePublicationGeneration)
        #expect(fixture.store.statePublicationGeneration > generation)
        #expect(fixture.store.state.revision == revision + 1)
        #expect(fixture.store.state.notes[FixtureIDs.noteID]?.revision == noteRevision + 1)
        #expect(await fixture.repository.saveCount == 1)
        let counts = planObjectCounts(fixture.store.state, noteID: FixtureIDs.noteID)
        #expect(counts == (2, 1, 1))
        let tasks = fixture.store.state.notes[FixtureIDs.noteID]?.document.blocks.filter { $0.kind == .task } ?? []
        #expect(Set(tasks.map(\.id)).count == 2)
        #expect(tasks.map { $0.inlineContent.spans.map(\.text).joined() } == ["行动1", "行动2"])
        #expect(fixture.store.calendarState.items.values.map(\.title) == ["行动1"])
        #expect(Set(fixture.store.state.taskBlockLinks.map(\.calendarItemID)).count == 1)
        #expect(model.draft.lastRecoverableError == nil)
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
        #expect(model.commitBlockingReason == .missingCalendarProposal(count: 1))
        #expect(model.advanceBlockingReason == nil)
        #expect(!model.canCommit)
        #expect(model.canAdvance)
        let result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(await fixture.repository.saveCount == 0)
        #expect(model.draft.stage == .schedule)
    }

    @Test func blockingReasonReportsNoSelectedActions() async throws {
        let model = try await makeModel(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        await model.start()
        #expect(model.advanceBlockingReason == nil)
        #expect(model.commitBlockingReason == nil)
        for candidate in model.draft.candidates {
            model.setSelectedForCreation(id: candidate.id, selected: false)
        }
        #expect(model.advanceBlockingReason == .noSelectedActions)
        #expect(model.commitBlockingReason == .noSelectedActions)
        #expect(!model.canAdvance)
        #expect(!model.canCommit)
        model.advanceToSchedule()
        #expect(model.draft.stage == .split)
    }

    @Test func blockingReasonCountsMissingTitlesAmongSelectedActions() async throws {
        let model = try await makeModel(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 3))
            ])
        )
        await model.start()
        let first = model.draft.candidates[0].id
        let second = model.draft.candidates[1].id
        let third = model.draft.candidates[2].id
        model.updateTitle(id: first, value: "   ")
        model.updateTitle(id: second, value: "")
        model.updateTitle(id: third, value: "保留的标题")
        model.updateCompletion(id: first, value: "")
        #expect(model.advanceBlockingReason == .missingTitle(count: 2))
        #expect(model.commitBlockingReason == .missingTitle(count: 2))
        model.setSelectedForCreation(id: first, selected: false)
        #expect(model.advanceBlockingReason == .missingTitle(count: 1))
        #expect(model.commitBlockingReason == .missingTitle(count: 1))
        model.setSelectedForCreation(id: second, selected: false)
        #expect(model.advanceBlockingReason == nil)
        #expect(model.canAdvance)
        model.setSelectedForCreation(id: first, selected: true)
        model.setSelectedForCreation(id: second, selected: true)
        for candidate in model.draft.candidates {
            model.setSelectedForCreation(id: candidate.id, selected: false)
        }
        #expect(model.advanceBlockingReason == .noSelectedActions)
    }

    @Test func blockingReasonCountsMissingCompletionsAmongSelectedActions() async throws {
        let model = try await makeModel(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 3))
            ])
        )
        await model.start()
        let first = model.draft.candidates[0].id
        let second = model.draft.candidates[1].id
        let third = model.draft.candidates[2].id
        model.updateCompletion(id: first, value: "\n")
        model.updateCompletion(id: second, value: "  ")
        #expect(model.advanceBlockingReason == .missingCompletion(count: 2))
        #expect(model.commitBlockingReason == .missingCompletion(count: 2))
        model.setSelectedForCreation(id: first, selected: false)
        #expect(model.advanceBlockingReason == .missingCompletion(count: 1))
        model.updateCompletion(id: second, value: "完成第二项")
        #expect(model.advanceBlockingReason == nil)
        #expect(model.canAdvance)
        model.updateCompletion(id: third, value: "")
        #expect(model.advanceBlockingReason == .missingCompletion(count: 1))
        #expect(model.commitBlockingReason == .missingCompletion(count: 1))
    }

    @Test func blockingReasonSelectsAndMarksFirstInvalidCandidate() async throws {
        let model = try await makeModel(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 3))
            ])
        )
        await model.start()
        let first = model.draft.candidates[0].id
        let second = model.draft.candidates[1].id
        let third = model.draft.candidates[2].id
        #expect(model.draft.candidates.allSatisfy { $0.selectedForCreation })
        #expect(model.firstBlockingCandidateID == nil)

        model.updateCompletion(id: second, value: "  \n")
        model.updateTitle(id: third, value: "\t")
        #expect(model.firstBlockingCandidateID == second)

        model.updateCompletion(id: second, value: "完成第二项")
        #expect(model.firstBlockingCandidateID == third)

        model.updateTitle(id: first, value: "")
        model.setSelectedForCreation(id: first, selected: false)
        #expect(model.firstBlockingCandidateID == third)

        model.updateTitle(id: third, value: "第三项")
        #expect(model.firstBlockingCandidateID == nil)

        for candidate in model.draft.candidates {
            model.setSelectedForCreation(id: candidate.id, selected: false)
        }
        #expect(model.advanceBlockingReason == .noSelectedActions)
        #expect(model.firstBlockingCandidateID == nil)

        model.setSelectedForCreation(id: second, selected: true)
        model.setSelectedForCreation(id: third, selected: true)
        model.setSelectedForCalendar(id: second, selected: true)
        model.setSelectedForCalendar(id: third, selected: true)
        model.advanceToSchedule()
        model.setProposal(id: second, proposal: nil)
        model.setProposal(id: third, proposal: nil)
        #expect(model.firstBlockingCandidateID == second)

        model.setSelectedForCalendar(id: second, selected: false)
        #expect(model.firstBlockingCandidateID == third)

        model.setSelectedForCalendar(id: third, selected: false)
        #expect(model.firstBlockingCandidateID == nil)

        model.returnToStage(.split)
        model.setSelectedForCalendar(id: third, selected: true)
        model.setProposal(id: third, proposal: nil)
        #expect(model.draft.stage == .split)
        #expect(model.firstBlockingCandidateID == nil)

        let sourceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            snapshotRevisionOffset: -1
        )
        await sourceFixture.model.start()
        sourceFixture.model.advanceToSchedule()
        #expect(await sourceFixture.model.commit() == .sourceChanged)
        #expect(sourceFixture.model.advanceBlockingReason == .sourceChanged)
        sourceFixture.model.updateTitle(
            id: sourceFixture.model.draft.candidates[0].id,
            value: ""
        )
        #expect(sourceFixture.model.firstBlockingCandidateID == nil)

        let persistenceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        await persistenceFixture.model.start()
        persistenceFixture.model.advanceToSchedule()
        await persistenceFixture.repository.failNextSave()
        #expect(
            await persistenceFixture.model.commit()
                == .notCommitted(message: Self.notCommittedMessage)
        )
        #expect(persistenceFixture.model.draft.lastRecoverableError == .persistenceFailed)
        #expect(persistenceFixture.model.firstBlockingCandidateID == nil)
    }

    @Test func commitBlockingReasonCountsMissingCalendarProposals() async throws {
        let model = try await makeModel(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 3))
            ])
        )
        await model.start()
        let first = model.draft.candidates[0].id
        let second = model.draft.candidates[1].id
        let third = model.draft.candidates[2].id
        model.setSelectedForCalendar(id: first, selected: true)
        model.setSelectedForCalendar(id: second, selected: true)
        model.setSelectedForCalendar(id: third, selected: true)
        model.advanceToSchedule()
        model.setProposal(id: first, proposal: nil)
        model.setProposal(id: second, proposal: nil)
        #expect(model.advanceBlockingReason == nil)
        #expect(model.canAdvance)
        #expect(model.commitBlockingReason == .missingCalendarProposal(count: 2))
        #expect(!model.canCommit)
        model.setSelectedForCreation(id: first, selected: false)
        #expect(model.commitBlockingReason == .missingCalendarProposal(count: 1))
        model.setSelectedForCalendar(id: second, selected: false)
        #expect(model.commitBlockingReason == nil)
        #expect(model.canCommit)
    }

    @Test func sourceChangedBlocksAdvanceAndRecommitWithoutWriting() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            snapshotRevisionOffset: -1
        )
        let model = fixture.model
        await model.start()
        model.updateAnswer("来源变化后仍可读")
        let first = model.draft.candidates[0].id
        model.updateTitle(id: first, value: "给物业打电话")
        model.updateCompletion(id: first, value: "拿到明确上门时间")
        model.setSelectedForCalendar(id: first, selected: true)
        model.advanceToSchedule()
        model.updateProposalTime(id: first, instant: fixture.date(hour: 16, minute: 30))
        model.updateDuration(id: first, duration: .minutes45)
        let lockedProposal = try #require(model.draft.candidates[0].proposal)
        #expect(model.draft.candidates[0].scheduleLockedByUser)
        let generation = fixture.store.statePublicationGeneration
        let revision = fixture.store.state.revision
        let noteRevision = try #require(fixture.store.state.notes[FixtureIDs.noteID]).revision
        let saves = await fixture.repository.saveCount
        let answer = model.draft.answer
        let snapshot = recoverySnapshot(of: model.draft.candidates)
        let result = await model.commit()
        #expect(result == .sourceChanged)
        #expect(model.draft.lastRecoverableError == .sourceChanged)
        #expect(model.draft.stage == .split)
        #expect(model.draft.answer == answer)
        #expect(recoverySnapshot(of: model.draft.candidates) == snapshot)
        #expect(model.draft.candidates[0].title == "给物业打电话")
        #expect(model.draft.candidates[0].completionDescription == "拿到明确上门时间")
        #expect(model.draft.candidates[0].selectedForCreation)
        #expect(model.draft.candidates[0].selectedForCalendar)
        #expect(model.draft.candidates[0].proposal == lockedProposal)
        #expect(model.draft.candidates[0].scheduleLockedByUser)
        #expect(model.draft.candidates[1].title == "行动2")
        #expect(model.draft.candidates[1].completionDescription == "完成行动2")
        #expect(model.draft.candidates[1].selectedForCreation)
        #expect(!model.draft.candidates[1].selectedForCalendar)
        #expect(model.advanceBlockingReason == .sourceChanged)
        #expect(model.commitBlockingReason == .sourceChanged)
        #expect(!model.canAdvance)
        #expect(!model.canCommit)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(fixture.store.state.revision == revision)
        #expect(fixture.store.state.notes[FixtureIDs.noteID]?.revision == noteRevision)
        #expect(await fixture.repository.saveCount == saves)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
        #expect(planObjectCounts(fixture.store.state, noteID: FixtureIDs.noteID) == (0, 0, 0))

        model.updateTitle(id: first, value: "改过标题")
        model.updateCompletion(id: first, value: "改过说明")
        model.setSelectedForCreation(id: first, selected: true)
        model.setSelectedForCalendar(id: first, selected: true)
        model.setProposal(id: first, proposal: nil)
        model.refreshCalendarProposals()
        let editedAnswer = model.draft.answer
        let editedSnapshot = recoverySnapshot(of: model.draft.candidates)
        #expect(model.draft.lastRecoverableError == .sourceChanged)
        #expect(model.advanceBlockingReason == .sourceChanged)
        #expect(model.commitBlockingReason == .sourceChanged)

        model.advanceToSchedule()
        model.returnToStage(.schedule)
        #expect(model.draft.stage == .split)
        let recommit = await model.commit()
        #expect(recommit == .sourceChanged)
        #expect(model.draft.stage == .split)
        #expect(model.draft.lastRecoverableError == .sourceChanged)
        #expect(model.draft.answer == editedAnswer)
        #expect(recoverySnapshot(of: model.draft.candidates) == editedSnapshot)
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(fixture.store.state.revision == revision)
        #expect(fixture.store.state.notes[FixtureIDs.noteID]?.revision == noteRevision)
        #expect(await fixture.repository.saveCount == saves)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
        #expect(planObjectCounts(fixture.store.state, noteID: FixtureIDs.noteID) == (0, 0, 0))
    }

    @Test func calendarAdjustmentClearsCalendarConflict() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        let first = model.draft.candidates[0].id
        model.setSelectedForCalendar(id: first, selected: true)
        model.advanceToSchedule()
        let proposal = try #require(model.draft.candidates[0].proposal)
        let blocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000861")!,
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
        let result = await model.commit()
        #expect(result == .calendarConflict)
        #expect(model.draft.lastRecoverableError == .calendarConflict)

        let adjusted = try CalendarSchedule(
            startDate: WorkbenchFixture.day,
            endDate: WorkbenchFixture.day,
            startTime: MinuteOfDay(hour: 15, minute: 0),
            endTime: MinuteOfDay(hour: 15, minute: 15)
        )
        model.setProposal(id: first, proposal: CalendarProposal(schedule: adjusted))
        #expect(model.draft.lastRecoverableError == nil)
        #expect(model.commitBlockingReason == nil)
        #expect(model.canCommit)
    }

    @Test func contentEditsKeepCalendarConflictUntilDateOrCalendarChanges() async throws {
        let dateFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let dateModel = dateFixture.model
        await dateModel.start()
        let dateID = dateModel.draft.candidates[0].id
        dateModel.setSelectedForCalendar(id: dateID, selected: true)
        dateModel.advanceToSchedule()
        let dateProposal = try #require(dateModel.draft.candidates[0].proposal)
        let dateBlocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000863")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: dateProposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await dateFixture.store.sendCalendar(.createItem(dateBlocking), undoLabel: "挡路")
        #expect(await dateModel.commit() == .calendarConflict)
        #expect(dateModel.draft.lastRecoverableError == .calendarConflict)

        dateModel.updateTitle(id: dateID, value: "改标题不解冲突")
        dateModel.updateCompletion(id: dateID, value: "改说明不解冲突")
        #expect(dateModel.draft.lastRecoverableError == .calendarConflict)

        dateModel.setSelectedForCalendar(id: dateID, selected: true)
        dateModel.setSelectedForCreation(id: dateID, selected: true)
        #expect(dateModel.draft.lastRecoverableError == .calendarConflict)
        #expect(dateModel.draft.candidates[0].proposal == dateProposal)

        dateModel.updateProposalDate(
            id: dateID,
            instant: dateModel.editorInstant(id: dateID).addingTimeInterval(24 * 60 * 60)
        )
        #expect(dateModel.draft.lastRecoverableError == nil)
        #expect(dateModel.draft.candidates[0].proposal?.schedule.startDate
            == CalendarDate(year: 2026, month: 8, day: 23))
        #expect(dateModel.commitBlockingReason == nil)
        #expect(dateModel.canCommit)

        let cancelFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let cancelModel = cancelFixture.model
        await cancelModel.start()
        let cancelID = cancelModel.draft.candidates[0].id
        cancelModel.setSelectedForCalendar(id: cancelID, selected: true)
        cancelModel.advanceToSchedule()
        let cancelProposal = try #require(cancelModel.draft.candidates[0].proposal)
        let cancelBlocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000864")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: cancelProposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await cancelFixture.store.sendCalendar(.createItem(cancelBlocking), undoLabel: "挡路")
        #expect(await cancelModel.commit() == .calendarConflict)
        #expect(cancelModel.draft.lastRecoverableError == .calendarConflict)

        cancelModel.updateTitle(id: cancelID, value: "仍只改标题")
        cancelModel.updateCompletion(id: cancelID, value: "仍只改说明")
        #expect(cancelModel.draft.lastRecoverableError == .calendarConflict)

        cancelModel.setSelectedForCalendar(id: cancelID, selected: false)
        #expect(cancelModel.draft.lastRecoverableError == nil)
        #expect(cancelModel.draft.candidates[0].proposal == nil)
        #expect(cancelModel.commitBlockingReason == nil)
        #expect(cancelModel.canCommit)
    }

    @Test func refreshCalendarProposalsClearsCalendarConflictButKeepsSourceChanged() async throws {
        let conflictFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let conflictModel = conflictFixture.model
        await conflictModel.start()
        let conflictID = conflictModel.draft.candidates[0].id
        conflictModel.setSelectedForCalendar(id: conflictID, selected: true)
        conflictModel.advanceToSchedule()
        let proposal = try #require(conflictModel.draft.candidates[0].proposal)
        let blocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000862")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: proposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await conflictFixture.store.sendCalendar(.createItem(blocking), undoLabel: "挡路")
        #expect(await conflictModel.commit() == .calendarConflict)
        #expect(conflictModel.draft.lastRecoverableError == .calendarConflict)
        conflictModel.refreshCalendarProposals()
        #expect(conflictModel.draft.lastRecoverableError == nil)

        let sourceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            snapshotRevisionOffset: -1
        )
        let sourceModel = sourceFixture.model
        await sourceModel.start()
        sourceModel.advanceToSchedule()
        #expect(await sourceModel.commit() == .sourceChanged)
        #expect(sourceModel.draft.lastRecoverableError == .sourceChanged)
        sourceModel.refreshCalendarProposals()
        sourceModel.updateTitle(id: sourceModel.draft.candidates[0].id, value: "仍被来源变化挡住")
        #expect(sourceModel.draft.lastRecoverableError == .sourceChanged)
        #expect(sourceModel.advanceBlockingReason == .sourceChanged)
        #expect(sourceModel.commitBlockingReason == .sourceChanged)
    }

    @Test func userEditsClearPersistenceFailureButKeepSourceChanged() async throws {
        let persistenceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let persistenceModel = persistenceFixture.model
        await persistenceModel.start()
        persistenceModel.advanceToSchedule()
        await persistenceFixture.repository.failNextSave()
        #expect(await persistenceModel.commit() == .notCommitted(message: Self.notCommittedMessage))
        #expect(persistenceModel.draft.lastRecoverableError == .persistenceFailed)
        persistenceModel.updateTitle(
            id: persistenceModel.draft.candidates[0].id,
            value: "改标题后可重试"
        )
        #expect(persistenceModel.draft.lastRecoverableError == nil)

        await persistenceFixture.repository.failNextSave()
        #expect(await persistenceModel.commit() == .notCommitted(message: Self.notCommittedMessage))
        #expect(persistenceModel.draft.lastRecoverableError == .persistenceFailed)
        persistenceModel.updateCompletion(
            id: persistenceModel.draft.candidates[0].id,
            value: "改说明后可重试"
        )
        #expect(persistenceModel.draft.lastRecoverableError == nil)

        await persistenceFixture.repository.failNextSave()
        #expect(await persistenceModel.commit() == .notCommitted(message: Self.notCommittedMessage))
        #expect(persistenceModel.draft.lastRecoverableError == .persistenceFailed)
        persistenceModel.addManualCandidate()
        #expect(persistenceModel.draft.lastRecoverableError == nil)

        let sourceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            snapshotRevisionOffset: -1
        )
        let sourceModel = sourceFixture.model
        await sourceModel.start()
        sourceModel.advanceToSchedule()
        #expect(await sourceModel.commit() == .sourceChanged)
        sourceModel.updateCompletion(
            id: sourceModel.draft.candidates[0].id,
            value: "来源变化不得被编辑清掉"
        )
        sourceModel.setSelectedForCalendar(
            id: sourceModel.draft.candidates[1].id,
            selected: true
        )
        #expect(sourceModel.draft.lastRecoverableError == .sourceChanged)
        #expect(sourceModel.advanceBlockingReason == .sourceChanged)
    }

    @Test func deletingCalendarSelectedCandidateClearsArrangementErrorsButKeepsSourceChanged() async throws {
        let conflictFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let conflictModel = conflictFixture.model
        await conflictModel.start()
        let scheduledID = conflictModel.draft.candidates[0].id
        let neighborID = conflictModel.draft.candidates[1].id
        conflictModel.setSelectedForCalendar(id: scheduledID, selected: true)
        conflictModel.advanceToSchedule()
        let proposal = try #require(conflictModel.draft.candidates[0].proposal)
        let blocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000865")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: proposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await conflictFixture.store.sendCalendar(.createItem(blocking), undoLabel: "挡路")
        #expect(await conflictModel.commit() == .calendarConflict)
        #expect(conflictModel.draft.lastRecoverableError == .calendarConflict)
        conflictModel.deleteCandidate(id: scheduledID)
        #expect(conflictModel.draft.candidates.map(\.id) == [neighborID])
        #expect(conflictModel.draft.lastRecoverableError == nil)

        let persistenceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let persistenceModel = persistenceFixture.model
        await persistenceModel.start()
        let persistenceID = persistenceModel.draft.candidates[0].id
        persistenceModel.setSelectedForCalendar(id: persistenceID, selected: true)
        persistenceModel.advanceToSchedule()
        await persistenceFixture.repository.failNextSave()
        #expect(await persistenceModel.commit() == .notCommitted(message: Self.notCommittedMessage))
        #expect(persistenceModel.draft.lastRecoverableError == .persistenceFailed)
        persistenceModel.deleteCandidate(id: persistenceID)
        #expect(persistenceModel.draft.lastRecoverableError == nil)

        let sourceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ]),
            snapshotRevisionOffset: -1
        )
        let sourceModel = sourceFixture.model
        await sourceModel.start()
        let sourceID = sourceModel.draft.candidates[0].id
        sourceModel.setSelectedForCalendar(id: sourceID, selected: true)
        sourceModel.advanceToSchedule()
        #expect(await sourceModel.commit() == .sourceChanged)
        #expect(sourceModel.draft.lastRecoverableError == .sourceChanged)
        sourceModel.deleteCandidate(id: sourceID)
        #expect(sourceModel.draft.lastRecoverableError == .sourceChanged)
        #expect(sourceModel.advanceBlockingReason == .sourceChanged)
        #expect(sourceModel.commitBlockingReason == .sourceChanged)
    }

    @Test func deletingUnscheduledCandidateClearsOnlyPersistenceFailed() async throws {
        let persistenceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let persistenceModel = persistenceFixture.model
        await persistenceModel.start()
        persistenceModel.advanceToSchedule()
        await persistenceFixture.repository.failNextSave()
        #expect(await persistenceModel.commit() == .notCommitted(message: Self.notCommittedMessage))
        #expect(persistenceModel.draft.lastRecoverableError == .persistenceFailed)
        #expect(!persistenceModel.draft.candidates[0].selectedForCalendar)
        let unscheduledID = persistenceModel.draft.candidates[0].id
        let remainingID = persistenceModel.draft.candidates[1].id
        persistenceModel.deleteCandidate(id: unscheduledID)
        #expect(persistenceModel.draft.candidates.map(\.id) == [remainingID])
        #expect(persistenceModel.draft.lastRecoverableError == nil)

        let conflictFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let conflictModel = conflictFixture.model
        await conflictModel.start()
        let scheduledID = conflictModel.draft.candidates[0].id
        let extraID = conflictModel.draft.candidates[1].id
        conflictModel.setSelectedForCalendar(id: scheduledID, selected: true)
        conflictModel.advanceToSchedule()
        let proposal = try #require(conflictModel.draft.candidates[0].proposal)
        let blocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000866")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: proposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await conflictFixture.store.sendCalendar(.createItem(blocking), undoLabel: "挡路")
        #expect(await conflictModel.commit() == .calendarConflict)
        #expect(conflictModel.draft.lastRecoverableError == .calendarConflict)
        #expect(!conflictModel.draft.candidates[1].selectedForCalendar)
        conflictModel.deleteCandidate(id: extraID)
        #expect(conflictModel.draft.candidates.map(\.id) == [scheduledID])
        #expect(conflictModel.draft.candidates[0].selectedForCalendar)
        #expect(conflictModel.draft.lastRecoverableError == .calendarConflict)
    }

    @Test func deletingUnknownCandidateLeavesStateUnchanged() async throws {
        let conflictFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let conflictModel = conflictFixture.model
        await conflictModel.start()
        let scheduledID = conflictModel.draft.candidates[0].id
        conflictModel.setSelectedForCalendar(id: scheduledID, selected: true)
        conflictModel.advanceToSchedule()
        let proposal = try #require(conflictModel.draft.candidates[0].proposal)
        let blocking = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000867")!,
            kind: .task,
            title: "挡路事项",
            categoryID: FixtureIDs.categoryID,
            schedule: proposal.schedule,
            creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
            completedAt: nil,
            createdAt: WorkbenchFixture.now,
            updatedAt: WorkbenchFixture.now
        )
        _ = try await conflictFixture.store.sendCalendar(.createItem(blocking), undoLabel: "挡路")
        #expect(await conflictModel.commit() == .calendarConflict)
        let conflictBefore = conflictModel.draft
        conflictModel.deleteCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000890")!)
        #expect(conflictModel.draft == conflictBefore)
        #expect(conflictModel.requestState == .idle)

        let persistenceFixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let persistenceModel = persistenceFixture.model
        await persistenceModel.start()
        persistenceModel.advanceToSchedule()
        await persistenceFixture.repository.failNextSave()
        #expect(await persistenceModel.commit() == .notCommitted(message: Self.notCommittedMessage))
        #expect(persistenceModel.draft.lastRecoverableError == .persistenceFailed)
        let persistenceBefore = persistenceModel.draft
        persistenceModel.deleteCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000891")!)
        #expect(persistenceModel.draft == persistenceBefore)
    }

    @Test func correctingBlankFieldsRemovesAdvanceBlocking() async throws {
        let model = try await makeModel(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        await model.start()
        let first = model.draft.candidates[0].id
        model.updateTitle(id: first, value: "   ")
        #expect(model.advanceBlockingReason == .missingTitle(count: 1))
        #expect(!model.canAdvance)
        model.advanceToSchedule()
        #expect(model.draft.stage == .split)

        model.updateTitle(id: first, value: "给物业打电话")
        model.updateCompletion(id: first, value: "")
        #expect(model.advanceBlockingReason == .missingCompletion(count: 1))
        model.updateCompletion(id: first, value: "拿到明确上门时间")
        #expect(model.advanceBlockingReason == nil)
        #expect(model.commitBlockingReason == nil)
        #expect(model.canAdvance)
        #expect(model.canCommit)
        model.advanceToSchedule()
        #expect(model.draft.stage == .schedule)
    }

    @Test func prepareCommitRejectsInvalidDraftWithoutWriting() async throws {
        let fixture = try await WorkbenchFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        let model = fixture.model
        await model.start()
        model.advanceToSchedule()
        #expect(model.draft.stage == .schedule)

        for candidate in model.draft.candidates {
            model.setSelectedForCreation(id: candidate.id, selected: false)
        }
        #expect(model.commitBlockingReason == .noSelectedActions)
        var result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(await fixture.repository.saveCount == 0)
        #expect(model.draft.stage == .schedule)

        model.setSelectedForCreation(id: model.draft.candidates[0].id, selected: true)
        model.updateTitle(id: model.draft.candidates[0].id, value: "  ")
        #expect(model.commitBlockingReason == .missingTitle(count: 1))
        result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(await fixture.repository.saveCount == 0)

        model.updateTitle(id: model.draft.candidates[0].id, value: "合法标题")
        model.updateCompletion(id: model.draft.candidates[0].id, value: "")
        #expect(model.commitBlockingReason == .missingCompletion(count: 1))
        result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(await fixture.repository.saveCount == 0)

        model.updateCompletion(id: model.draft.candidates[0].id, value: "合法完成说明")
        model.setSelectedForCalendar(id: model.draft.candidates[0].id, selected: true)
        model.setProposal(id: model.draft.candidates[0].id, proposal: nil)
        #expect(model.commitBlockingReason == .missingCalendarProposal(count: 1))
        result = await model.commit()
        #expect(result == .notCommitted(message: Self.notCommittedMessage))
        #expect(await fixture.repository.saveCount == 0)
        #expect(model.draft.stage == .schedule)
        #expect(planObjectsAreAbsent(fixture.store.state, noteID: FixtureIDs.noteID))
    }

    @Test func unavailableModePreparesOneEditableActionAndMarksMeaningfulDraft() async throws {
        let fixture = try await WorkbenchModelFixture.make(
            planner: UnavailableDecompositionPlanner(reason: .deviceNotEligible)
        )
        #expect(fixture.model.hasMeaningfulDraft == false)
        await fixture.model.start()
        #expect(fixture.model.draft.mode == .manual(reason: .deviceNotEligible))
        #expect(fixture.model.draft.stage == .split)
        #expect(fixture.model.draft.candidates.count == 1)
        #expect(fixture.model.draft.candidates[0].title.isEmpty)
        #expect(fixture.model.draft.candidates[0].completionDescription.isEmpty)
        #expect(fixture.model.hasMeaningfulDraft)
    }

    @Test func meaningfulDraftTracksAnswerCandidatesAndReachedStagesWithoutPersistence() async throws {
        let fixture = try await WorkbenchModelFixture.make(planner: ScriptedWorkbenchPlanner())
        #expect(!fixture.model.hasMeaningfulDraft)
        fixture.model.updateAnswer("下周前完成")
        #expect(fixture.model.hasMeaningfulDraft)
    }

    @Test func refreshKeepsUserAdjustedScheduleUnlessOverwriteIsExplicit() async throws {
        let fixture = try await WorkbenchModelFixture.splitWithCalendar()
        let first = try #require(fixture.model.draft.candidates.first)
        let chosen = fixture.date(hour: 16, minute: 30, dayOffset: 2)
        fixture.model.updateProposalTime(id: first.id, instant: chosen)
        let locked = try #require(fixture.model.draft.candidates.first?.proposal)
        #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)

        fixture.model.refreshCalendarProposals()
        #expect(fixture.model.draft.candidates[0].proposal == locked)

        fixture.model.refreshCalendarProposals(overwriteUserAdjustments: true)
        #expect(fixture.model.draft.candidates[0].proposal != locked)
        #expect(!fixture.model.draft.candidates[0].scheduleLockedByUser)
    }

    @Test func nilProposalBecomesManualOnlyAfterExplicitBegin() async throws {
        let fixture = try await WorkbenchModelFixture.splitWithoutAvailableSlot()
        let first = try #require(fixture.model.draft.candidates.first)
        fixture.model.setSelectedForCalendar(id: first.id, selected: true)
        #expect(fixture.model.draft.candidates[0].proposal == nil)
        fixture.model.beginManualCalendarProposal(id: first.id)
        #expect(fixture.model.draft.candidates[0].proposal != nil)
        #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)
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

extension ScriptedDecompositionPlanner {
    init() {
        self.init([
            .clarification(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"]))
        ])
    }
}

private typealias ScriptedWorkbenchPlanner = ScriptedDecompositionPlanner

@MainActor
private struct WorkbenchModelFixture {
    let model: DecompositionWorkbenchModel
    let store: WorkspaceStore
    let repository: WorkspaceStoreTestRepository

    static func make(
        planner: any DecompositionPlanning,
        sleeper: ControllableSleeper = ControllableSleeper(),
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        snapshotRevisionOffset: Int64 = 0
    ) async throws -> WorkbenchModelFixture {
        let fixture = try await WorkbenchFixture.make(
            planner: planner,
            sleeper: sleeper,
            uuid: uuid,
            snapshotRevisionOffset: snapshotRevisionOffset
        )
        return .init(model: fixture.model, store: fixture.store, repository: fixture.repository)
    }

    func date(hour: Int, minute: Int, dayOffset: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WorkbenchFixture.shanghai
        let day = WorkbenchFixture.day.addingDays(dayOffset)
        return calendar.date(from: DateComponents(
            year: day.year,
            month: day.month,
            day: day.day,
            hour: hour,
            minute: minute
        ))!
    }

    static func splitWithCalendar() async throws -> WorkbenchModelFixture {
        let fixture = try await make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        await fixture.model.start()
        let first = try #require(fixture.model.draft.candidates.first)
        fixture.model.setSelectedForCalendar(id: first.id, selected: true)
        fixture.model.advanceToSchedule()
        return fixture
    }

    static func splitWithoutAvailableSlot() async throws -> WorkbenchModelFixture {
        let fixture = try await make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates(validSuggestions(count: 2))
            ])
        )
        for offset in 0...6 {
            let day = WorkbenchFixture.day.addingDays(offset)
            let item = try CalendarItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000087\(offset)")!,
                kind: .task,
                title: "占满空档",
                categoryID: FixtureIDs.categoryID,
                schedule: try CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: MinuteOfDay(hour: 9, minute: 0),
                    endTime: MinuteOfDay(hour: 21, minute: 0)
                ),
                creationTimeZoneIdentifier: WorkbenchFixture.shanghai.identifier,
                completedAt: nil,
                createdAt: WorkbenchFixture.now,
                updatedAt: WorkbenchFixture.now
            )
            _ = try await fixture.store.sendCalendar(.createItem(item), undoLabel: "占满")
        }
        await fixture.model.start()
        return fixture
    }
}

@MainActor
private struct WorkbenchFixture {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let now = Date(timeIntervalSince1970: 1_787_356_800)
    static let day = CalendarDate(year: 2026, month: 8, day: 22)!

    let model: DecompositionWorkbenchModel
    let store: WorkspaceStore
    let repository: WorkspaceStoreTestRepository

    func date(hour: Int, minute: Int, dayOffset: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.shanghai
        let day = Self.day.addingDays(dayOffset)
        return calendar.date(from: DateComponents(
            year: day.year,
            month: day.month,
            day: day.day,
            hour: hour,
            minute: minute
        ))!
    }

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
            inspirationNoteLinks: [],
            materialDigests: [:]
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

private struct CandidateRecoverySnapshot: Equatable {
    var id: UUID
    var title: String
    var completionDescription: String
    var estimatedDuration: CandidateDuration
    var selectedForCreation: Bool
    var selectedForCalendar: Bool
    var titleLockedByUser: Bool
    var completionLockedByUser: Bool
    var sourceCandidateID: UUID?
    var proposal: CalendarProposal?
    var scheduleLockedByUser: Bool
}

private func recoverySnapshot(of candidates: [CandidateAction]) -> [CandidateRecoverySnapshot] {
    candidates.map {
        CandidateRecoverySnapshot(
            id: $0.id,
            title: $0.title,
            completionDescription: $0.completionDescription,
            estimatedDuration: $0.estimatedDuration,
            selectedForCreation: $0.selectedForCreation,
            selectedForCalendar: $0.selectedForCalendar,
            titleLockedByUser: $0.titleLockedByUser,
            completionLockedByUser: $0.completionLockedByUser,
            sourceCandidateID: $0.sourceCandidateID,
            proposal: $0.proposal,
            scheduleLockedByUser: $0.scheduleLockedByUser
        )
    }
}

private func planObjectCounts(
    _ state: WorkspaceState,
    noteID: NoteID
) -> (tasks: Int, items: Int, links: Int) {
    let tasks = state.notes[noteID]?.document.blocks.filter { $0.kind == .task }.count ?? 0
    return (tasks, state.calendar.items.count, state.taskBlockLinks.count)
}

private func returnedWithin(_ task: Task<Void, Never>, limit: Duration) async -> Bool {
    let gate = ReturnWithinGate()
    return await withCheckedContinuation { continuation in
        gate.attach(continuation)
        Task.detached {
            await task.value
            gate.finish(true)
        }
        Task.detached {
            try? await Task.sleep(for: limit)
            gate.finish(false)
        }
    }
}

private final class ReturnWithinGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var pending: Bool?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if finished, let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        pending = value
        lock.unlock()
    }
}

private func timedDurationMinutes(_ schedule: CalendarSchedule) -> Int {
    guard let start = schedule.startTime, let end = schedule.endTime else {
        return 0
    }
    return schedule.startDate.days(until: schedule.endDate) * 24 * 60 + end.value - start.value
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
        case waitUntilReleased
    }

    private enum Terminal {
        case released
        case cancelled
    }

    private let policy: Policy
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var terminal: Terminal?

    init(policy: Policy = .hangUntilCancelled) {
        self.policy = policy
    }

    func sleep(for duration: Duration) async throws {
        switch policy {
        case .finishImmediately:
            try Task.checkCancellation()
        case .hangUntilCancelled:
            try await ContinuousClock().sleep(for: duration)
        case .waitUntilReleased:
            try await waitUntilReleased()
        }
    }

    func release() {
        complete(.released)
    }

    private func waitUntilReleased() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let terminal {
                    lock.unlock()
                    switch terminal {
                    case .released:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            complete(.cancelled)
        }
    }

    private func complete(_ terminal: Terminal) {
        lock.lock()
        if self.terminal != nil {
            lock.unlock()
            return
        }
        self.terminal = terminal
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            switch terminal {
            case .released:
                waiter.resume()
            case .cancelled:
                waiter.resume(throwing: CancellationError())
            }
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

private actor CooperativeCancellablePlanner: DecompositionPlanning {
    nonisolated var availability: DecompositionPlannerAvailability { .available }

    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedCount = 0

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        startedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60 * 60))
        throw ScriptedPlannerFailure.exhausted
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

private actor DualShotCandidatePlanner: DecompositionPlanning {
    nonisolated var availability: DecompositionPlannerAvailability { .available }

    private var shots: [CheckedContinuation<[PlannerCandidate], Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedCount = 0

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        .notNeeded
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        startedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { shots.append($0) }
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        throw ScriptedPlannerFailure.exhausted
    }

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func resumeOldest(_ items: [PlannerCandidate]) {
        guard !shots.isEmpty else { return }
        shots.removeFirst().resume(returning: items)
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
