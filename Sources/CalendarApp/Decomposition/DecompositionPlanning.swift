import Foundation

protocol DecompositionPlanning: Sendable {
    var availability: DecompositionPlannerAvailability { get }
    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision
    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate]
    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate]
}

enum DecompositionOutputValidator {
    static func validateInitial(_ output: [PlannerCandidate]) throws -> [PlannerCandidate] {
        try validateCount(output)
        return try canonicalize(output)
    }

    static func validateRefresh(
        _ output: [PlannerCandidate],
        expectedIDs: Set<UUID>
    ) throws -> [PlannerCandidate] {
        let canonical = try canonicalize(output)
        let ids = canonical.compactMap(\.existingID)
        guard ids.count == canonical.count, Set(ids) == expectedIDs else {
            throw DecompositionOutputError.unexpectedExistingIDs
        }
        return canonical
    }

    static func validateSplit(_ output: [PlannerCandidate]) throws -> [PlannerCandidate] {
        try validateCount(output)
        let canonical = try canonicalize(output)
        guard canonical.allSatisfy({ $0.existingID == nil }) else {
            throw DecompositionOutputError.unexpectedExistingIDs
        }
        return canonical
    }

    private static func validateCount(_ output: [PlannerCandidate]) throws {
        guard (2...5).contains(output.count) else {
            throw DecompositionOutputError.invalidCount(output.count)
        }
    }

    private static func canonicalize(_ output: [PlannerCandidate]) throws -> [PlannerCandidate] {
        var seen = Set<UUID>()
        return try output.enumerated().map { index, item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let completion = item.completionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw DecompositionOutputError.emptyTitle(index: index)
            }
            guard !completion.isEmpty else {
                throw DecompositionOutputError.emptyCompletion(index: index)
            }
            guard CandidateDuration(rawValue: item.estimatedMinutes) != nil else {
                throw DecompositionOutputError.invalidDuration(index: index, minutes: item.estimatedMinutes)
            }
            if let existingID = item.existingID {
                if seen.contains(existingID) {
                    throw DecompositionOutputError.duplicateExistingID(existingID)
                }
                seen.insert(existingID)
            }
            return PlannerCandidate(
                existingID: item.existingID,
                title: title,
                completionDescription: completion,
                estimatedMinutes: item.estimatedMinutes
            )
        }
    }
}

enum DecompositionDraftReducer {
    static func mergeRefresh(
        _ output: [PlannerCandidate],
        into current: [CandidateAction]
    ) throws -> [CandidateAction] {
        let validated = try DecompositionOutputValidator.validateRefresh(
            output,
            expectedIDs: Set(current.map(\.id))
        )
        let byID = Dictionary(uniqueKeysWithValues: validated.map { item in
            (item.existingID!, item)
        })
        return current.map { candidate in
            let item = byID[candidate.id]!
            var merged = candidate
            if !merged.titleLockedByUser {
                merged.title = item.title
            }
            if !merged.completionLockedByUser {
                merged.completionDescription = item.completionDescription
            }
            merged.estimatedDuration = CandidateDuration(rawValue: item.estimatedMinutes)!
            return merged
        }
    }

    static func replaceCandidate(
        id: UUID,
        with output: [PlannerCandidate],
        in current: [CandidateAction]
    ) throws -> [CandidateAction] {
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            throw DecompositionOutputError.unexpectedExistingIDs
        }
        let validated = try DecompositionOutputValidator.validateSplit(output)
        let target = current[index]
        let replacements = validated.map { item in
            CandidateAction(
                id: UUID(),
                title: item.title,
                completionDescription: item.completionDescription,
                estimatedDuration: CandidateDuration(rawValue: item.estimatedMinutes)!,
                selectedForCreation: target.selectedForCreation,
                selectedForCalendar: target.selectedForCalendar,
                titleLockedByUser: false,
                completionLockedByUser: false,
                sourceCandidateID: target.id,
                proposal: nil
            )
        }
        var result = current
        result.replaceSubrange(index...index, with: replacements)
        return result
    }
}
