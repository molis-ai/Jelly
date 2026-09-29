import Foundation

/// Decomposition through the model chosen in 摘要设置 (cloud preset or a local
/// Codex / Claude command). It reuses the same prompts and validators as the
/// Apple on-device path; only the transport and the JSON envelope differ.
struct TextModelDecompositionGenerator: DecompositionModelGenerating {
    let model: any TextModelGenerating

    static let clarificationFormat = """

    只输出一个 JSON 对象，不要输出其他文字：{"needsFollowUp":true 或 false,"question":"需要追问时的一个问题，否则空字符串","quickAnswers":["最多 3 个简短回答"]}
    """

    static let actionsFormat = """

    只输出一个 JSON 对象，不要输出其他文字：{"actions":[{"existingID":"刷新时原样返回现有候选的 id，新候选用 null","title":"行动标题","completionDescription":"本次时段结束时可验证的结果","estimatedMinutes":15、30、45、60 或 90}]}
    """

    func clarification(instructions: String, prompt: String) async throws -> ClarificationDecision {
        let object = try await respond(instructions: instructions, prompt: prompt + Self.clarificationFormat, tokens: 500)
        let question = (object["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsFollowUp = (object["needsFollowUp"] as? Bool) ?? !question.isEmpty
        guard wantsFollowUp, !question.isEmpty else { return .notNeeded }
        return .ask(question: question, quickAnswers: Array(TextModelJSON.strings(object["quickAnswers"]).prefix(3)))
    }

    func actions(instructions: String, prompt: String) async throws -> [PlannerCandidate] {
        try Self.candidates(from: try await respond(instructions: instructions, prompt: prompt + Self.actionsFormat, tokens: 1_500))
    }

    func split(instructions: String, prompt: String) async throws -> [PlannerCandidate] {
        try await actions(instructions: instructions, prompt: prompt)
    }

    static func candidates(from object: [String: Any]) throws -> [PlannerCandidate] {
        guard let actions = object["actions"] as? [[String: Any]] else { throw TextModelError.invalidOutput }
        return actions.map { action in
            let minutes: Int
            if let value = action["estimatedMinutes"] as? Int {
                minutes = value
            } else if let text = action["estimatedMinutes"] as? String, let value = Int(text) {
                minutes = value
            } else {
                minutes = 0
            }
            return PlannerCandidate(
                existingID: (action["existingID"] as? String).flatMap(UUID.init(uuidString:)),
                title: action["title"] as? String ?? "",
                completionDescription: action["completionDescription"] as? String ?? "",
                estimatedMinutes: minutes
            )
        }
    }

    private func respond(instructions: String, prompt: String, tokens: Int) async throws -> [String: Any] {
        try Task.checkCancellation()
        let response = try await model.generate(TextModelRequest(
            system: instructions,
            prompt: prompt,
            maximumTokens: tokens,
            temperature: 0.2
        ))
        try Task.checkCancellation()
        return try TextModelJSON.object(from: response.text)
    }
}

private struct AlwaysAvailableCapability: SystemLanguageModelCapabilityChecking {
    func availability(locale: Locale) -> DecompositionPlannerAvailability { .available }
}

/// Picks the model per call so a change in 设置 applies without relaunching:
/// the configured text model first, Apple's on-device model otherwise.
final class SettingsRoutedDecompositionPlanner: DecompositionPlanning, @unchecked Sendable {
    private let textModel: any TextModelGenerating
    private let textPlanner: any DecompositionPlanning
    private let fallback: any DecompositionPlanning

    init(
        textModel: any TextModelGenerating,
        fallback: any DecompositionPlanning = LiveDecompositionPlanner.make(),
        locale: Locale = .autoupdatingCurrent
    ) {
        self.textModel = textModel
        self.fallback = fallback
        textPlanner = AppleFoundationModelsDecompositionPlanner(
            locale: locale,
            capability: AlwaysAvailableCapability(),
            generator: TextModelDecompositionGenerator(model: textModel)
        )
    }

    private var active: any DecompositionPlanning {
        textModel.isConfigured ? textPlanner : fallback
    }

    var availability: DecompositionPlannerAvailability { active.availability }

    var suggestedRequestTimeout: Duration {
        textModel.isConfigured ? .seconds(90) : fallback.suggestedRequestTimeout
    }

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        try await active.clarification(for: request)
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        try await active.candidates(for: request)
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        try await active.splitCandidate(for: request)
    }
}
