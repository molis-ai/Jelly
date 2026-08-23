import Foundation
import Testing
@testable import CalendarApp

@Suite("MiniMaxDecompositionLiveTests", .serialized)
struct MiniMaxDecompositionLiveTests {
    private var liveEnabled: Bool {
        MiniMaxLiveGate.isEnabled
    }

    @Test func ordinaryRunDoesNotConstructLiveClientOrSendNetworkRequest() {
        guard !liveEnabled else { return }
        #expect(MiniMaxLiveClientFactory.makeIfLiveEnabled() == nil)
        #expect(MiniMaxLiveNetworkProbe.liveClientConstructionCount == 0)
        #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
    }

    @Test func productionPromptBuildersAndJSONContractAreReusedWithoutNetwork() throws {
        let vague = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.vagueMoving)
        let dental = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.specificDental)

        let clarificationRequest = ClarificationRequest(source: vague)
        let clarificationPrompt = MiniMaxLivePrompt.clarification(clarificationRequest)
        #expect(clarificationPrompt.hasPrefix(DecompositionPromptBuilder.clarification(clarificationRequest)))
        #expect(clarificationPrompt.contains(MiniMaxJSONContract.clarification))
        #expect(clarificationPrompt.contains(MiniMaxLiveFixtures.vagueMoving))
        #expect(clarificationPrompt.contains("只问一个关键问题或明确无需追问"))

        let dentalPrompt = MiniMaxLivePrompt.clarification(ClarificationRequest(source: dental))
        #expect(dentalPrompt.contains(MiniMaxLiveFixtures.specificDental))
        #expect(dentalPrompt.contains(MiniMaxJSONContract.clarification))

        let candidateRequest = CandidateRequest(
            source: vague,
            answer: MiniMaxLiveFixtures.movingAnswer,
            existingCandidates: [],
            validationFeedback: nil
        )
        let candidatePrompt = MiniMaxLivePrompt.candidates(candidateRequest)
        #expect(candidatePrompt.hasPrefix(DecompositionPromptBuilder.candidates(candidateRequest)))
        #expect(candidatePrompt.contains(MiniMaxJSONContract.actions))
        #expect(candidatePrompt.contains(MiniMaxLiveFixtures.movingAnswer))
        #expect(candidatePrompt.contains("初始 2～5"))

        let refreshRequest = CandidateRequest(
            source: vague,
            answer: MiniMaxLiveFixtures.movingAnswer,
            existingCandidates: [
                MiniMaxLiveFixtures.titleLockedContext(),
                MiniMaxLiveFixtures.completionLockedContext()
            ],
            validationFeedback: nil
        )
        let refreshPrompt = MiniMaxLivePrompt.candidates(refreshRequest)
        #expect(refreshPrompt.hasPrefix(DecompositionPromptBuilder.candidates(refreshRequest)))
        #expect(refreshPrompt.contains(MiniMaxLiveFixtures.titleLockedID.uuidString))
        #expect(refreshPrompt.contains(MiniMaxLiveFixtures.completionLockedID.uuidString))
        #expect(refreshPrompt.contains("titleLockedByUser=true"))
        #expect(refreshPrompt.contains("completionLockedByUser=true"))
        #expect(refreshPrompt.contains("不得覆盖标记为 locked 的字段"))

        let splitRequest = SplitCandidateRequest(
            source: vague,
            answer: MiniMaxLiveFixtures.movingAnswer,
            target: MiniMaxLiveFixtures.splitTarget(),
            validationFeedback: nil
        )
        let splitPrompt = MiniMaxLivePrompt.split(splitRequest)
        #expect(splitPrompt.hasPrefix(DecompositionPromptBuilder.split(splitRequest)))
        #expect(splitPrompt.contains(MiniMaxJSONContract.actions))
        #expect(splitPrompt.contains(MiniMaxLiveFixtures.splitTargetTitle))
        #expect(splitPrompt.contains(MiniMaxLiveFixtures.splitTargetCompletion))
        #expect(splitPrompt.contains("局部重拆不谈其他候选"))

        let repairRequest = CandidateRequest(
            source: vague,
            answer: MiniMaxLiveFixtures.movingAnswer,
            existingCandidates: [],
            validationFeedback: .invalidDuration(index: 0, minutes: 20)
        )
        let repairProduction = DecompositionPromptBuilder.candidates(repairRequest)
        let repairPrompt = MiniMaxLivePrompt.candidates(repairRequest)
        #expect(repairPrompt.hasPrefix(repairProduction))
        #expect(repairProduction.contains("上次结构反馈："))
        #expect(repairProduction.contains(
            String(describing: DecompositionOutputError.invalidDuration(index: 0, minutes: 20))
        ))
        #expect(repairPrompt.contains(MiniMaxJSONContract.actions))

        if !liveEnabled {
            #expect(MiniMaxLiveNetworkProbe.liveClientConstructionCount == 0)
            #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
        }
    }

    @Test func decoderDoesNotCoerceInvalidDurationTwentyBeforeRealValidator() throws {
        let text = """
        {"actions":[\
        {"existingID":null,"title":"联系搬家公司","completionDescription":"拿到书面报价","estimatedMinutes":20},\
        {"existingID":null,"title":"确定房子","completionDescription":"签下租约或购房合同","estimatedMinutes":30}\
        ]}
        """
        let decoded = try MiniMaxResponseDecoder.decodeActions(text)
        #expect(decoded[0].estimatedMinutes == 20)
        #expect(decoded[0].estimatedMinutes != 15)
        #expect(decoded[0].estimatedMinutes != 30)
        #expect(throws: DecompositionOutputError.invalidDuration(index: 0, minutes: 20)) {
            try DecompositionOutputValidator.validateInitial(decoded)
        }
    }

    @Test func vagueMovingSourceAsksFollowUpWithAtMostThreeQuickAnswers() async throws {
        let source = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.vagueMoving)
        let request = ClarificationRequest(source: source)
        let prompt = MiniMaxLivePrompt.clarification(request)
        #expect(prompt.hasPrefix(DecompositionPromptBuilder.clarification(request)))
        #expect(prompt.contains(MiniMaxJSONContract.clarification))

        guard let client = MiniMaxLiveClientFactory.makeIfLiveEnabled() else {
            #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
            return
        }

        try await runLive(
            client: client,
            caseName: "vague_moving",
            prompt: prompt,
            decode: MiniMaxResponseDecoder.decodeClarification,
            count: { $0.quickAnswers.count },
            lines: MiniMaxLiveReporter.clarificationLines
        ) { payload in
            try #require(payload.needsFollowUp)
            try #require(!payload.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            try #require(payload.quickAnswers.count <= 3)
        }
    }

    @Test func specificDentalSourceDoesNotAskFollowUpAndQuestionIsEmpty() async throws {
        let source = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.specificDental)
        let request = ClarificationRequest(source: source)
        let prompt = MiniMaxLivePrompt.clarification(request)
        #expect(prompt.hasPrefix(DecompositionPromptBuilder.clarification(request)))
        #expect(prompt.contains(MiniMaxLiveFixtures.specificDental))

        guard let client = MiniMaxLiveClientFactory.makeIfLiveEnabled() else {
            #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
            return
        }

        try await runLive(
            client: client,
            caseName: "specific_dental",
            prompt: prompt,
            decode: MiniMaxResponseDecoder.decodeClarification,
            count: { $0.quickAnswers.count },
            lines: MiniMaxLiveReporter.clarificationLines
        ) { payload in
            try #require(!payload.needsFollowUp)
            try #require(payload.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func movingAnswerInitialDecompositionHasTwoToFiveValidatedCandidates() async throws {
        let source = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.vagueMoving)
        let request = CandidateRequest(
            source: source,
            answer: MiniMaxLiveFixtures.movingAnswer,
            existingCandidates: [],
            validationFeedback: nil
        )
        let prompt = MiniMaxLivePrompt.candidates(request)
        #expect(prompt.hasPrefix(DecompositionPromptBuilder.candidates(request)))
        #expect(prompt.contains(MiniMaxLiveFixtures.movingAnswer))
        #expect(prompt.contains(MiniMaxJSONContract.actions))

        guard let client = MiniMaxLiveClientFactory.makeIfLiveEnabled() else {
            #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
            return
        }

        try await runLive(
            client: client,
            caseName: "initial",
            prompt: prompt,
            decode: MiniMaxResponseDecoder.decodeActions,
            count: \.count,
            lines: { $0.map(MiniMaxLiveReporter.candidateLine) }
        ) { decoded in
            let validated = try DecompositionOutputValidator.validateInitial(decoded)
            try #require((2...5).contains(validated.count))
        }
    }

    @Test func lockedRefreshPreservesLockedFieldsAndEachIDOnceAfterValidatorAndMerge() async throws {
        let source = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.vagueMoving)
        let request = CandidateRequest(
            source: source,
            answer: MiniMaxLiveFixtures.movingAnswer,
            existingCandidates: [
                MiniMaxLiveFixtures.titleLockedContext(),
                MiniMaxLiveFixtures.completionLockedContext()
            ],
            validationFeedback: nil
        )
        let prompt = MiniMaxLivePrompt.candidates(request)
        #expect(prompt.hasPrefix(DecompositionPromptBuilder.candidates(request)))
        #expect(prompt.contains(MiniMaxLiveFixtures.titleLockedID.uuidString))
        #expect(prompt.contains(MiniMaxLiveFixtures.completionLockedID.uuidString))

        guard let client = MiniMaxLiveClientFactory.makeIfLiveEnabled() else {
            #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
            return
        }

        try await runLive(
            client: client,
            caseName: "locked_refresh",
            prompt: prompt,
            decode: MiniMaxResponseDecoder.decodeActions,
            count: \.count,
            lines: { $0.map(MiniMaxLiveReporter.candidateLine) }
        ) { decoded in
            let current = MiniMaxLiveFixtures.lockedCurrentActions()
            let validated = try DecompositionOutputValidator.validateRefresh(
                decoded,
                expectedIDs: Set(current.map(\.id))
            )
            let ids = validated.compactMap(\.existingID)
            try #require(ids.count == 2)
            try #require(Set(ids) == Set([MiniMaxLiveFixtures.titleLockedID, MiniMaxLiveFixtures.completionLockedID]))
            try #require(ids.filter { $0 == MiniMaxLiveFixtures.titleLockedID }.count == 1)
            try #require(ids.filter { $0 == MiniMaxLiveFixtures.completionLockedID }.count == 1)

            let merged = try DecompositionDraftReducer.mergeRefresh(validated, into: current)
            try #require(merged.map(\.id) == [MiniMaxLiveFixtures.titleLockedID, MiniMaxLiveFixtures.completionLockedID])
            try #require(merged[0].title == MiniMaxLiveFixtures.lockedTitle)
            try #require(merged[1].completionDescription == MiniMaxLiveFixtures.lockedCompletion)
            try #require(merged[0].titleLockedByUser)
            try #require(merged[1].completionLockedByUser)
        }
    }

    @Test func splitPrepareMovingReturnsTwoToFiveNewCandidatesWithoutExistingIDs() async throws {
        let source = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.vagueMoving)
        let request = SplitCandidateRequest(
            source: source,
            answer: MiniMaxLiveFixtures.movingAnswer,
            target: MiniMaxLiveFixtures.splitTarget(),
            validationFeedback: nil
        )
        let prompt = MiniMaxLivePrompt.split(request)
        #expect(prompt.hasPrefix(DecompositionPromptBuilder.split(request)))
        #expect(prompt.contains(MiniMaxLiveFixtures.splitTargetTitle))
        #expect(prompt.contains("局部重拆不谈其他候选"))

        guard let client = MiniMaxLiveClientFactory.makeIfLiveEnabled() else {
            #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
            return
        }

        try await runLive(
            client: client,
            caseName: "split",
            prompt: prompt,
            decode: MiniMaxResponseDecoder.decodeActions,
            count: \.count,
            lines: { $0.map(MiniMaxLiveReporter.candidateLine) }
        ) { decoded in
            let validated = try DecompositionOutputValidator.validateSplit(decoded)
            try #require((2...5).contains(validated.count))
            try #require(validated.allSatisfy { $0.existingID == nil })
        }
    }

    @Test func invalidDurationTwentyRepairPassesRealValidatorWithoutDecoderCoercion() async throws {
        let source = try MiniMaxLiveFixtures.source(from: MiniMaxLiveFixtures.vagueMoving)
        let request = CandidateRequest(
            source: source,
            answer: MiniMaxLiveFixtures.movingAnswer,
            existingCandidates: [],
            validationFeedback: .invalidDuration(index: 0, minutes: 20)
        )
        let production = DecompositionPromptBuilder.candidates(request)
        let prompt = MiniMaxLivePrompt.candidates(request)
        #expect(prompt.hasPrefix(production))
        #expect(production.contains(
            String(describing: DecompositionOutputError.invalidDuration(index: 0, minutes: 20))
        ))

        guard let client = MiniMaxLiveClientFactory.makeIfLiveEnabled() else {
            #expect(MiniMaxLiveNetworkProbe.urlSessionSendCount == 0)
            return
        }

        try await runLive(
            client: client,
            caseName: "repair_invalid_duration",
            prompt: prompt,
            decode: MiniMaxResponseDecoder.decodeActions,
            count: \.count,
            lines: { $0.map(MiniMaxLiveReporter.candidateLine) }
        ) { decoded in
            let validated = try DecompositionOutputValidator.validateInitial(decoded)
            try #require((2...5).contains(validated.count))
            try #require(validated.allSatisfy { CandidateDuration(rawValue: $0.estimatedMinutes) != nil })
        }
    }

    private func runLive<T>(
        client: MiniMaxLiveClient,
        caseName: String,
        prompt: String,
        decode: (String) throws -> T,
        count: (T) -> Int,
        lines: (T) -> [String],
        validate: (T) throws -> Void
    ) async throws {
        let started = Date()
        let model = client.configuration.model
        do {
            let text = try await client.text(
                system: DecompositionPromptBuilder.instructions,
                prompt: prompt
            )
            let decoded = try decode(text)
            try validate(decoded)
            MiniMaxLiveReporter.logCase(
                name: caseName,
                model: model,
                status: "PASS",
                latencyMS: MiniMaxLiveReporter.milliseconds(since: started),
                count: count(decoded),
                lines: lines(decoded)
            )
        } catch {
            MiniMaxLiveReporter.logCase(
                name: caseName,
                model: model,
                status: "FAIL",
                latencyMS: MiniMaxLiveReporter.milliseconds(since: started),
                error: error
            )
            throw error
        }
    }
}
