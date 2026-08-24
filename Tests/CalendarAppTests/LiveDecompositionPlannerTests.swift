import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

private struct FixedCapability: SystemLanguageModelCapabilityChecking, Sendable {
    let result: DecompositionPlannerAvailability

    func availability(locale: Locale) -> DecompositionPlannerAvailability {
        result
    }
}

private struct ScriptedGenerator: DecompositionModelGenerating, Sendable {
    var clarificationResult: Result<ClarificationDecision, Error>
    var actionsResult: Result<[PlannerCandidate], Error>
    var splitResult: Result<[PlannerCandidate], Error>
    var hangUntilCancelled = false

    func clarification(instructions: String, prompt: String) async throws -> ClarificationDecision {
        try await maybeHang()
        _ = instructions
        _ = prompt
        return try clarificationResult.get()
    }

    func actions(instructions: String, prompt: String) async throws -> [PlannerCandidate] {
        try await maybeHang()
        _ = instructions
        _ = prompt
        return try actionsResult.get()
    }

    func split(instructions: String, prompt: String) async throws -> [PlannerCandidate] {
        try await maybeHang()
        _ = instructions
        _ = prompt
        return try splitResult.get()
    }

    private func maybeHang() async throws {
        guard hangUntilCancelled else { return }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        try Task.checkCancellation()
    }
}

@Suite("LiveDecompositionPlannerTests")
@MainActor
struct LiveDecompositionPlannerTests {
    @Test func mapsEveryUnavailableCapabilityToTypedManualReason() {
        let cases: [(SystemLanguageModelAvailabilitySnapshot, ManualDecompositionReason)] = [
            (.systemVersionUnsupported, .systemVersionUnsupported),
            (.deviceNotEligible, .deviceNotEligible),
            (.appleIntelligenceNotEnabled, .appleIntelligenceNotEnabled),
            (.modelNotReady, .modelNotReady),
            (.localeUnsupported, .localeUnsupported),
            (.unknown, .modelFailure)
        ]
        for (snapshot, reason) in cases {
            #expect(
                SystemLanguageModelAvailabilityMapper.map(snapshot)
                    == .unavailable(reason)
            )
        }
        #expect(SystemLanguageModelAvailabilityMapper.map(.available) == .available)
    }

    @Test func factoryReturnsUnavailablePlannerWhenSystemCannotHostFoundationModels() {
        let planner = LiveDecompositionPlanner.make(
            locale: Locale(identifier: "zh_CN"),
            capability: FixedCapability(result: .unavailable(.systemVersionUnsupported))
        )
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            #expect(planner.availability == .unavailable(.systemVersionUnsupported))
            let name = String(describing: type(of: planner))
            #expect(name.contains("AppleFoundationModelsDecompositionPlanner"))
            return
        }
#endif
        #expect(planner.availability == .unavailable(.systemVersionUnsupported))
        #expect(planner is UnavailableDecompositionPlanner)
    }

    @Test(
        "unavailable reasons stay typed on the live adapter",
        arguments: [
            DecompositionPlannerAvailability.unavailable(.deviceNotEligible),
            .unavailable(.appleIntelligenceNotEnabled),
            .unavailable(.modelNotReady),
            .unavailable(.localeUnsupported)
        ]
    )
    func liveAdapterSurfacesInjectedUnavailableReasons(
        availability: DecompositionPlannerAvailability
    ) async throws {
        let planner = LiveDecompositionPlanner.make(
            locale: Locale(identifier: "zh_CN"),
            capability: FixedCapability(result: availability)
        )
        #expect(planner.availability == availability)
        let source = try Self.makeSnapshot()
        await #expect(throws: DecompositionPlannerUnavailableError.self) {
            try await planner.clarification(for: ClarificationRequest(source: source))
        }
        await #expect(throws: DecompositionPlannerUnavailableError.self) {
            try await planner.candidates(
                for: CandidateRequest(
                    source: source,
                    answer: nil,
                    existingCandidates: [],
                    validationFeedback: nil
                )
            )
        }
        await #expect(throws: DecompositionPlannerUnavailableError.self) {
            try await planner.splitCandidate(
                for: SplitCandidateRequest(
                    source: source,
                    answer: nil,
                    target: PlannerCandidateContext(
                        id: UUID(),
                        title: "给物业打电话",
                        completionDescription: "拿到明确上门时间",
                        estimatedMinutes: 15,
                        titleLockedByUser: false,
                        completionLockedByUser: false
                    ),
                    validationFeedback: nil
                )
            )
        }
    }

    @Test func threeAdapterCallsUseInjectedGeneratorWithoutValidatingCounts() async throws {
        let generator = ScriptedGenerator(
            clarificationResult: .success(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"])),
            actionsResult: .success([
                PlannerCandidate(
                    existingID: nil,
                    title: "只做一件",
                    completionDescription: "说明",
                    estimatedMinutes: 15
                )
            ]),
            splitResult: .success([
                PlannerCandidate(
                    existingID: nil,
                    title: "拆开A",
                    completionDescription: "说明A",
                    estimatedMinutes: 15
                )
            ])
        )
        let planner = LiveDecompositionPlanner.make(
            locale: Locale(identifier: "zh_CN"),
            capability: FixedCapability(result: .available),
            generator: generator
        )
        let source = try Self.makeSnapshot()
        let decision = try await planner.clarification(for: ClarificationRequest(source: source))
        #expect(decision == .ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"]))

        let generated = try await planner.candidates(
            for: CandidateRequest(
                source: source,
                answer: "拿到确认",
                existingCandidates: [],
                validationFeedback: nil
            )
        )
        #expect(generated.count == 1)

        let split = try await planner.splitCandidate(
            for: SplitCandidateRequest(
                source: source,
                answer: nil,
                target: PlannerCandidateContext(
                    id: UUID(),
                    title: "给物业打电话",
                    completionDescription: "拿到明确上门时间",
                    estimatedMinutes: 15,
                    titleLockedByUser: true,
                    completionLockedByUser: false
                ),
                validationFeedback: nil
            )
        )
        #expect(split.count == 1)
    }

    @Test func cancelledRequestsPropagateCancellation() async {
        let generator = ScriptedGenerator(
            clarificationResult: .success(.notNeeded),
            actionsResult: .success([]),
            splitResult: .success([]),
            hangUntilCancelled: true
        )
        let planner = LiveDecompositionPlanner.make(
            locale: Locale(identifier: "zh_CN"),
            capability: FixedCapability(result: .available),
            generator: generator
        )
        let source = try! Self.makeSnapshot()
        let task = Task {
            try await planner.clarification(for: ClarificationRequest(source: source))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消必须传播为 CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("取消应传播 CancellationError，实际为 \(error)")
        }
    }

    @Test func productionLivePlannerTypeNameIsNotAFake() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-8-environment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment.live(environment: [
            "JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path,
            "JELLY_DECOMPOSITION_PLANNER": "Scripted"
        ])
        let name = String(describing: type(of: environment.decompositionPlanner))
        #expect(!name.localizedCaseInsensitiveContains("scripted"))
        #expect(!name.localizedCaseInsensitiveContains("mock"))
        #expect(!name.localizedCaseInsensitiveContains("fixture"))
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            #expect(name.contains("AppleFoundationModelsDecompositionPlanner"))
            return
        }
#endif
        #expect(environment.decompositionPlanner is UnavailableDecompositionPlanner)
    }

    private static func makeSnapshot() throws -> DecompositionSourceSnapshot {
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: UUID(), now: .distantPast)
        note.document = .init(blocks: [
            .init(id: blockID, kind: .paragraph, inlineContent: .plain("预约牙医"), taskState: nil, indentLevel: 0)
        ])
        return try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 1,
            selection: .text(
                anchor: .init(blockID: blockID, graphemeOffset: 0),
                focus: .init(blockID: blockID, graphemeOffset: 4),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
    }
}
