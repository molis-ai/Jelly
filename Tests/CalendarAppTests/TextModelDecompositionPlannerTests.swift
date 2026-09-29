import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("TextModelDecompositionPlannerTests")
struct TextModelDecompositionPlannerTests {
    private func snapshot(_ text: String) -> DecompositionSourceSnapshot {
        DecompositionSourceSnapshot(
            noteID: NoteID(),
            noteRevision: 1,
            workspaceRevision: 1,
            sourceBlockID: nil,
            selectedRange: nil,
            normalizedText: text,
            noteChecksum: "n",
            sourceChecksum: "s"
        )
    }

    @Test func actionsJSONBecomesValidatedCandidates() async throws {
        let model = ScriptedTextModel([.success("""
        ```json
        {"actions":[
          {"existingID":null,"title":"联系 2 家搬家公司获取书面报价","completionDescription":"拿到两份书面报价","estimatedMinutes":30},
          {"existingID":null,"title":"筛选并保存 3 套房源","completionDescription":"收藏夹里有 3 套房源","estimatedMinutes":"45"}
        ]}
        ```
        """)])
        let planner = SettingsRoutedDecompositionPlanner(
            textModel: model,
            fallback: UnavailableDecompositionPlanner(reason: .deviceNotEligible)
        )
        #expect(planner.availability == .available)
        #expect(planner.suggestedRequestTimeout == .seconds(90))
        let raw = try await planner.candidates(for: CandidateRequest(
            source: snapshot("月底前搬家，整体预算两万"),
            answer: nil,
            existingCandidates: [],
            validationFeedback: nil
        ))
        let candidates = try DecompositionOutputValidator.validateInitial(raw)
        #expect(candidates.map(\.estimatedMinutes) == [30, 45])
        #expect(model.requests.first?.system == DecompositionPromptBuilder.instructions)
        #expect(model.requests.first?.prompt.contains("月底前搬家") == true)
        #expect(model.requests.first?.prompt.contains("只输出一个 JSON") == true)
    }

    @Test func clarificationMapsFollowUpAndNoFollowUp() async throws {
        let model = ScriptedTextModel([
            .success(#"{"needsFollowUp":true,"question":"入住日期目前确定了吗？","quickAnswers":["已确定","尚未确定","大概下月初","多余"]}"#),
            .success(#"{"needsFollowUp":false,"question":"","quickAnswers":[]}"#)
        ])
        let generator = TextModelDecompositionGenerator(model: model)
        #expect(try await generator.clarification(instructions: "i", prompt: "p")
            == .ask(question: "入住日期目前确定了吗？", quickAnswers: ["已确定", "尚未确定", "大概下月初"]))
        #expect(try await generator.clarification(instructions: "i", prompt: "p") == .notNeeded)
    }

    @Test func withoutAModelTheAppleOrManualPathStays() async throws {
        let model = ScriptedTextModel([])
        model.isConfigured = false
        let planner = SettingsRoutedDecompositionPlanner(
            textModel: model,
            fallback: UnavailableDecompositionPlanner(reason: .deviceNotEligible)
        )
        #expect(planner.availability == .unavailable(.deviceNotEligible))
        #expect(planner.suggestedRequestTimeout == .seconds(20))
        await #expect(throws: DecompositionPlannerUnavailableError(reason: .deviceNotEligible)) {
            try await planner.clarification(for: ClarificationRequest(source: snapshot("x")))
        }
        #expect(model.requests.isEmpty)
    }

    @Test func garbageOutputIsAnErrorNotACrash() async throws {
        let generator = TextModelDecompositionGenerator(model: ScriptedTextModel([.success("我觉得可以先这样做")]))
        await #expect(throws: TextModelError.invalidOutput) {
            try await generator.actions(instructions: "i", prompt: "p")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_LOCAL"] == "1"))
    func liveLocalRuntimeDecomposesANote() async throws {
        let suite = "jelly-live-decompose-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DigestSettingsStore(defaults: defaults)
        settings.setSummarySource(.localRuntime)
        settings.setLocalRuntime(LocalSummaryRuntime(rawValue: ProcessInfo.processInfo.environment["JELLY_LIVE_RUNTIME"] ?? "") ?? .codex)
        let planner = SettingsRoutedDecompositionPlanner(
            textModel: LocalRuntimeTextModel(settings: settings),
            fallback: UnavailableDecompositionPlanner(reason: .deviceNotEligible)
        )
        let raw = try await planner.candidates(for: CandidateRequest(
            source: snapshot("下个月要把爸妈接来住一周，需要准备客房和安排两天周边游"),
            answer: nil,
            existingCandidates: [],
            validationFeedback: nil
        ))
        let candidates = try DecompositionOutputValidator.validateInitial(raw)
        print("LIVE DECOMPOSITION: \(candidates.map { "\($0.title)（\($0.estimatedMinutes) 分钟）" })")
        #expect((2...5).contains(candidates.count))
    }
}
