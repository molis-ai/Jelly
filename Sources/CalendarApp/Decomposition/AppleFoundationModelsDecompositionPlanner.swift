import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationModelsAvailabilityProbe {
    static func snapshot(locale: Locale) -> SystemLanguageModelAvailabilitySnapshot {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.supportsLocale(locale) ? .available : .localeUnsupported
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .unknown
            @unknown default:
                return .unknown
            }
        }
#endif
        return .systemVersionUnsupported
    }
}

final class AppleFoundationModelsDecompositionPlanner: DecompositionPlanning, @unchecked Sendable {
    private let locale: Locale
    private let capability: any SystemLanguageModelCapabilityChecking
    private let generator: any DecompositionModelGenerating

    init(
        locale: Locale,
        capability: any SystemLanguageModelCapabilityChecking = LiveSystemLanguageModelCapability(),
        generator: (any DecompositionModelGenerating)? = nil
    ) {
        self.locale = locale
        self.capability = capability
        self.generator = generator ?? LiveDecompositionModelGenerator()
    }

    var availability: DecompositionPlannerAvailability {
        capability.availability(locale: locale)
    }

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        try ensureAvailable()
        try Task.checkCancellation()
        return try await generator.clarification(
            instructions: DecompositionPromptBuilder.instructions,
            prompt: DecompositionPromptBuilder.clarification(request)
        )
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        try ensureAvailable()
        try Task.checkCancellation()
        return try await generator.actions(
            instructions: DecompositionPromptBuilder.instructions,
            prompt: DecompositionPromptBuilder.candidates(request)
        )
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        try ensureAvailable()
        try Task.checkCancellation()
        return try await generator.split(
            instructions: DecompositionPromptBuilder.instructions,
            prompt: DecompositionPromptBuilder.split(request)
        )
    }

    private func ensureAvailable() throws {
        if case let .unavailable(reason) = availability {
            throw DecompositionPlannerUnavailableError(reason: reason)
        }
    }
}

struct LiveDecompositionModelGenerator: DecompositionModelGenerating {
    func clarification(instructions: String, prompt: String) async throws -> ClarificationDecision {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let content = try await FoundationModelsSessionClient.respond(
                instructions: instructions,
                prompt: prompt,
                generating: GeneratedClarification.self
            )
            try Task.checkCancellation()
            let question = content.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.needsFollowUp, !question.isEmpty {
                return .ask(question: question, quickAnswers: content.quickAnswers)
            }
            return .notNeeded
        }
#endif
        throw DecompositionPlannerUnavailableError(reason: .systemVersionUnsupported)
    }

    func actions(instructions: String, prompt: String) async throws -> [PlannerCandidate] {
        try await generateActions(instructions: instructions, prompt: prompt)
    }

    func split(instructions: String, prompt: String) async throws -> [PlannerCandidate] {
        try await generateActions(instructions: instructions, prompt: prompt)
    }

    private func generateActions(instructions: String, prompt: String) async throws -> [PlannerCandidate] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let content = try await FoundationModelsSessionClient.respond(
                instructions: instructions,
                prompt: prompt,
                generating: GeneratedActionList.self
            )
            try Task.checkCancellation()
            return content.actions.map { action in
                PlannerCandidate(
                    existingID: action.existingID.flatMap(UUID.init(uuidString:)),
                    title: action.title,
                    completionDescription: action.completionDescription,
                    estimatedMinutes: action.estimatedMinutes
                )
            }
        }
#endif
        throw DecompositionPlannerUnavailableError(reason: .systemVersionUnsupported)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum FoundationModelsSessionClient {
    static func respond<T: Generable>(
        instructions: String,
        prompt: String,
        generating type: T.Type
    ) async throws -> T {
        try Task.checkCancellation()
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, generating: type)
            try Task.checkCancellation()
            return response.content
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelSession.GenerationError {
            throw mapGenerationError(error)
        }
    }

    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .unsupportedLanguageOrLocale:
            return DecompositionPlannerUnavailableError(reason: .localeUnsupported)
        default:
            return error
        }
    }
}

// Command Line Tools currently ship FoundationModels without FoundationModelsMacros,
// so `@Generable` fails with "plugin not found". These types use the public Generable
// protocol and GenerationSchema for equivalent structured output; do not delete them
// to "switch back" to the macro until the plugin is actually available in this toolchain.
@available(macOS 26.0, *)
struct GeneratedActionList: Generable {
    var actions: [GeneratedAction]

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: Self.self,
            description: "2 到 5 个按执行顺序排列的独立行动",
            properties: [
                .init(
                    name: "actions",
                    description: "2 到 5 个按执行顺序排列的独立行动",
                    type: [GeneratedAction].self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        actions = try content.value([GeneratedAction].self, forProperty: "actions")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "actions": actions
        ])
    }
}

@available(macOS 26.0, *)
struct GeneratedAction: Generable {
    var existingID: String?
    var title: String
    var completionDescription: String
    var estimatedMinutes: Int

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: Self.self,
            properties: [
                .init(name: "existingID", type: String?.self),
                .init(name: "title", type: String.self),
                .init(name: "completionDescription", type: String.self),
                .init(
                    name: "estimatedMinutes",
                    description: "只能是 15、30、45、60 或 90",
                    type: Int.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        existingID = try content.value(String?.self, forProperty: "existingID")
        title = try content.value(String.self, forProperty: "title")
        completionDescription = try content.value(String.self, forProperty: "completionDescription")
        estimatedMinutes = try content.value(Int.self, forProperty: "estimatedMinutes")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "existingID": existingID as String?,
            "title": title,
            "completionDescription": completionDescription,
            "estimatedMinutes": estimatedMinutes
        ])
    }
}

@available(macOS 26.0, *)
struct GeneratedClarification: Generable {
    var needsFollowUp: Bool
    var question: String
    var quickAnswers: [String]

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: Self.self,
            properties: [
                .init(
                    name: "needsFollowUp",
                    description: "必须追问一个关键问题时为 true，无需追问为 false",
                    type: Bool.self
                ),
                .init(name: "question", type: String.self),
                .init(name: "quickAnswers", type: [String].self)
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        needsFollowUp = try content.value(Bool.self, forProperty: "needsFollowUp")
        question = try content.value(String.self, forProperty: "question")
        quickAnswers = try content.value([String].self, forProperty: "quickAnswers")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "needsFollowUp": needsFollowUp,
            "question": question,
            "quickAnswers": quickAnswers
        ])
    }
}
#endif
