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
        #expect(clarificationPrompt.contains("需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答"))
        #expect(clarificationPrompt.contains("来源明确表示会改变行动范围的事实尚未确定时必须追问，不得直接判断为无需追问"))
        #expect(clarificationPrompt.contains("不得让用户先选择想理清哪个或从哪一块开始"))
        #expect(clarificationPrompt.contains("错误：你更想先理清入住日期还是预算？"))
        #expect(clarificationPrompt.contains("正确：入住日期目前确定了吗？"))
        #expect(clarificationPrompt.contains("错误快捷回答：先不确定。正确快捷回答：尚未确定"))

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
        #expect(candidatePrompt.contains("每个候选都必须基于当前来源立即开始"))
        #expect(candidatePrompt.contains("不得依赖另一个候选先完成或假设其结果已经存在"))
        #expect(candidatePrompt.contains("来源未说明候选对象已经存在时，不得安排查看、预约或比较这些对象"))
        #expect(candidatePrompt.contains("每个行动必须能在一次专注时段内完成"))
        #expect(candidatePrompt.contains("不得把搜集、比较、决定、付款等多个阶段合成一项"))
        #expect(candidatePrompt.contains("不得把签合同、付定金或下单设为完成标准"))
        #expect(candidatePrompt.contains("不得新增来源和回答未提到的协作者、地点、承诺或截止日期"))
        #expect(candidatePrompt.contains("不得把来源未提到的偏好、规格、房型、区域或服务类型变成筛选条件"))
        #expect(candidatePrompt.contains("不得复述这些规则或把列出待确认项、准备信息、制定计划当成行动"))
        #expect(candidatePrompt.contains("不得用整理、处理、落实等模糊动词代替可直接执行的动作"))
        #expect(candidatePrompt.contains("范围不明确的金额只能保留为整体约束"))
        #expect(candidatePrompt.contains("错误：把整体预算两万元改成月租两万元以内的房源条件"))
        #expect(candidatePrompt.contains("整体预算是最终方案的总约束，不是多份备选报价的合计上限"))
        #expect(candidatePrompt.contains("错误：两家搬家公司的报价合计不超过整体预算"))

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
        #expect(refreshPrompt.contains("刷新时只返回这 2 个现有候选，总数必须恰好为 2"))
        #expect(refreshPrompt.contains("至少一个未锁定字段必须返回新的改进内容，不得把全部未锁定字段原样照抄"))
        #expect(refreshPrompt.contains("completionDescription=拿到搬家公司书面报价"))
        #expect(!refreshPrompt.contains(" completion=拿到搬家公司书面报价"))
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
        #expect(splitPrompt.contains("局部重拆必须返回 2～5 个比目标候选更小、可独立开始的行动"))
        #expect(splitPrompt.contains("两项已经覆盖目标时只返回两项"))
        #expect(splitPrompt.contains("不得为凑数量添加依赖前项产物的后续行动"))
        #expect(splitPrompt.contains("局部重拆仍须遵守整体预算不得写入单个房源或搬家公司候选的约束"))
        #expect(splitPrompt.contains("房源或搬家公司候选的标题与完成说明禁止出现两万元、2 万或 20000"))
        #expect(splitPrompt.contains("如需处理整体预算，只能单独生成预算分配行动"))

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
            let preferenceMarkers = ["更想先", "想先", "先理清哪个", "从哪一块", "优先"]
            try #require(!preferenceMarkers.contains { payload.question.contains($0) })
            try #require(payload.quickAnswers.allSatisfy { answer in
                !["更想", "想先", "优先"].contains { answer.contains($0) }
                    && !answer.hasPrefix("先")
            })
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
            try requireMovingCandidateSemantics(validated)
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
            try #require(
                merged[0].completionDescription != "旧说明"
                    || merged[1].title != "联系搬家公司"
            )
            try #require(!merged.contains { candidate in
                ["整租", "合租"].contains { marker in
                    candidate.title.contains(marker) || candidate.completionDescription.contains(marker)
                }
            })
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
            try requireMovingCandidateSemantics(validated)
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
        #expect(production.contains("修复上次结构错误时仍须遵守全部事实和行动约束"))
        #expect(production.contains("不得为了修复数量、时长或 id 而重新解释来源"))

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
            try requireMovingCandidateSemantics(validated)
        }
    }

    private func requireMovingCandidateSemantics(_ candidates: [PlannerCandidate]) throws {
        let forbiddenMarkers = [
            "签合同", "签署租赁合同", "付定金", "支付定金", "下单",
            "邻居", "朋友", "9月10日", "9 月 10 日", "整租", "合租",
            "需要确认的", "需要准备的", "约束条件本身", "不得额外", "只写已由来源", "只写可由本次",
            "整理当前可租房源", "比较两份报价", "对比两份报价", "报价差异", "差异对比",
            "查看 2 家搬家公司报价", "查看两家搬家公司报价", "查看 3 套保存房源", "查看三套保存房源",
            "预约看房", "预约房源", "预约 1 套", "预约 3 套", "预约一套", "预约三套"
        ]
        try #require(candidates.allSatisfy { candidate in
            !forbiddenMarkers.contains { marker in
                candidate.title.contains(marker) || candidate.completionDescription.contains(marker)
            }
        })
        try #require(candidates.allSatisfy { candidate in
            let text = candidate.title + candidate.completionDescription
            let isIndividualSubitem = text.contains("房源") || text.contains("搬家公司")
            let appliesAmbiguousOverallBudget = text.contains("两万") || text.contains("20000") || text.contains("2 万")
            return !isIndividualSubitem || !appliesAmbiguousOverallBudget
        })
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
        let decoded: T
        let text: String
        do {
            text = try await client.text(
                system: DecompositionPromptBuilder.instructions,
                prompt: prompt
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
        do {
            decoded = try decode(text)
        } catch {
            MiniMaxLiveReporter.logCase(
                name: caseName,
                model: model,
                status: "FAIL",
                latencyMS: MiniMaxLiveReporter.milliseconds(since: started),
                lines: [MiniMaxLiveReporter.rawOutputLine(text)],
                error: error
            )
            throw error
        }
        do {
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
                count: count(decoded),
                lines: lines(decoded),
                error: error
            )
            throw error
        }
    }
}
