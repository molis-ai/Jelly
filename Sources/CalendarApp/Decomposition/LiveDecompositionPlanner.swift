import Foundation

protocol SystemLanguageModelCapabilityChecking: Sendable {
    func availability(locale: Locale) -> DecompositionPlannerAvailability
}

protocol DecompositionModelGenerating: Sendable {
    func clarification(instructions: String, prompt: String) async throws -> ClarificationDecision
    func actions(instructions: String, prompt: String) async throws -> [PlannerCandidate]
    func split(instructions: String, prompt: String) async throws -> [PlannerCandidate]
}

enum SystemLanguageModelAvailabilitySnapshot: Equatable, Sendable {
    case available
    case systemVersionUnsupported
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case localeUnsupported
    case unknown
}

enum SystemLanguageModelAvailabilityMapper {
    static func map(_ snapshot: SystemLanguageModelAvailabilitySnapshot) -> DecompositionPlannerAvailability {
        switch snapshot {
        case .available:
            return .available
        case .systemVersionUnsupported:
            return .unavailable(.systemVersionUnsupported)
        case .deviceNotEligible:
            return .unavailable(.deviceNotEligible)
        case .appleIntelligenceNotEnabled:
            return .unavailable(.appleIntelligenceNotEnabled)
        case .modelNotReady:
            return .unavailable(.modelNotReady)
        case .localeUnsupported:
            return .unavailable(.localeUnsupported)
        case .unknown:
            return .unavailable(.modelFailure)
        }
    }
}

struct LiveSystemLanguageModelCapability: SystemLanguageModelCapabilityChecking {
    func availability(locale: Locale) -> DecompositionPlannerAvailability {
        SystemLanguageModelAvailabilityMapper.map(Self.snapshot(locale: locale))
    }

    static func snapshot(locale: Locale) -> SystemLanguageModelAvailabilitySnapshot {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsAvailabilityProbe.snapshot(locale: locale)
        }
#endif
        return .systemVersionUnsupported
    }
}

enum LiveDecompositionPlanner {
    static func make(locale: Locale = .autoupdatingCurrent) -> any DecompositionPlanning {
        make(locale: locale, capability: LiveSystemLanguageModelCapability())
    }

    static func make(
        locale: Locale = .autoupdatingCurrent,
        capability: any SystemLanguageModelCapabilityChecking,
        generator: (any DecompositionModelGenerating)? = nil
    ) -> any DecompositionPlanning {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationModelsDecompositionPlanner(
                locale: locale,
                capability: capability,
                generator: generator
            )
        }
#endif
        if generator != nil {
            return AppleFoundationModelsDecompositionPlanner(
                locale: locale,
                capability: capability,
                generator: generator
            )
        }
        switch capability.availability(locale: locale) {
        case .unavailable(.systemVersionUnsupported):
            return UnavailableDecompositionPlanner(reason: .systemVersionUnsupported)
        default:
            return AppleFoundationModelsDecompositionPlanner(
                locale: locale,
                capability: capability,
                generator: generator
            )
        }
    }
}
