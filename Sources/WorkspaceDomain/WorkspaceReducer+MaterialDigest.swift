import Foundation

extension WorkspaceReducer {
    static func startMaterialDigest(
        _ payload: StartMaterialDigestPayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard let inspiration = candidate.inspirations[payload.inspirationID] else {
            throw WorkspaceReducerError.missingInspiration(payload.inspirationID)
        }
        guard inspiration.lifecycle == .active,
              inspiration.supportsMaterialDigest
        else {
            throw WorkspaceReducerError.invalidInspiration
        }
        let currentChecksum = WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        guard currentChecksum == payload.expectedSourceChecksum else {
            return .result(.noChange(.staleMaterialDigestSource))
        }
        if let existing = candidate.materialDigests[payload.inspirationID], existing.currentRun != nil {
            return .result(.noChange(.materialDigestAlreadyRunning))
        }

        let initialStage: MaterialDigestStage
        let preparedSnapshot = candidate.materialDigests[payload.inspirationID]?.preparedSnapshot
        var pendingSnapshot = candidate.materialDigests[payload.inspirationID]?.pendingSnapshot
        switch payload.mode {
        case .refreshSource:
            initialStage = .resolvingSource
            pendingSnapshot = nil
        case .reusePreparedSnapshot:
            guard let snapshot = pendingSnapshot ?? preparedSnapshot,
                  snapshot.sourceChecksum == payload.expectedSourceChecksum
            else {
                throw WorkspaceReducerError.invalidMaterialDigestStage
            }
            pendingSnapshot = snapshot
            initialStage = .preparingSummary
        }
        let run = MaterialDigestRun(
            id: payload.runID,
            stage: initialStage,
            startedAt: now,
            updatedAt: now
        )
        if var existing = candidate.materialDigests[payload.inspirationID] {
            existing.currentRun = run
            existing.pendingSnapshot = pendingSnapshot
            existing.lastFailure = nil
            existing.updatedAt = now
            candidate.materialDigests[payload.inspirationID] = existing
        } else {
            candidate.materialDigests[payload.inspirationID] = MaterialDigest(
                id: payload.digestID,
                inspirationID: payload.inspirationID,
                sourceChecksum: payload.expectedSourceChecksum,
                currentRun: run,
                result: nil,
                lastFailure: nil,
                preparedSnapshot: nil,
                pendingSnapshot: pendingSnapshot,
                createdAt: now,
                updatedAt: now
            )
        }
        return .proceed
    }

    static func saveMaterialSnapshot(
        _ payload: SaveMaterialSnapshotPayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(payload.expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, run):
            guard payload.snapshot.sourceChecksum == payload.expectation.sourceChecksum,
                  payload.snapshot.sourceChecksum == digest.sourceChecksum
            else {
                return .result(.noChange(.staleMaterialDigestSource))
            }
            var digest = digest
            var run = run
            digest.pendingSnapshot = payload.snapshot
            run.stage = .preparingSummary
            run.updatedAt = now
            digest.currentRun = run
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func advanceMaterialDigestStage(
        _ payload: AdvanceMaterialDigestStagePayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(payload.expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, run):
            guard isAllowedStageTransition(from: run.stage, to: payload.stage) else {
                throw WorkspaceReducerError.invalidMaterialDigestStage
            }
            var digest = digest
            var run = run
            run.stage = payload.stage
            if payload.stage == .awaitingModelDownloadConsent {
                run.modelDownloadApproximateBytes = payload.modelDownloadApproximateBytes
            }
            run.updatedAt = now
            digest.currentRun = run
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func completeMaterialDigest(
        _ payload: CompleteMaterialDigestPayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(payload.expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, run):
            guard run.stage == .summarizing else {
                throw WorkspaceReducerError.invalidMaterialDigestStage
            }
            guard let snapshot = digest.pendingSnapshot,
                  snapshot.contentFingerprint == payload.expectedContentFingerprint
            else {
                throw WorkspaceReducerError.invalidMaterialDigestStage
            }
            var provenance = payload.provenance
            provenance.generatedAt = now
            var digest = digest
            digest.currentRun = nil
            digest.preparedSnapshot = snapshot
            digest.pendingSnapshot = nil
            digest.result = MaterialDigestResult(
                summary: payload.summary,
                provenance: provenance,
                completedAt: now,
                contentFingerprint: payload.expectedContentFingerprint
            )
            digest.lastFailure = nil
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func failMaterialDigest(
        _ payload: FailMaterialDigestPayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(payload.expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, _):
            var digest = digest
            digest.currentRun = nil
            digest.lastFailure = MaterialDigestFailure(
                code: payload.code,
                userMessage: payload.userMessage,
                occurredAt: now
            )
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func cancelMaterialDigest(
        _ expectation: MaterialDigestRunExpectation,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, _):
            var digest = digest
            digest.currentRun = nil
            digest.lastFailure = MaterialDigestFailure(
                code: .cancelled,
                userMessage: "已取消提炼，原始材料仍然保留。",
                occurredAt: now
            )
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func markInterruptedMaterialDigest(
        _ expectation: MaterialDigestRunExpectation,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, run):
            guard run.stage != .awaitingModelDownloadConsent else {
                return .result(.noChange(.identical))
            }
            var digest = digest
            digest.currentRun = nil
            digest.lastFailure = MaterialDigestFailure(
                code: .interrupted,
                userMessage: digest.pendingSnapshot == nil
                    ? "上次处理被中断，可以重新提炼。"
                    : "材料已就绪，可继续生成摘要。",
                occurredAt: now
            )
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    private enum MaterialDigestRunMatch {
        case matched(MaterialDigest, MaterialDigestRun)
        case noChange(WorkspaceNoChangeReason)
    }

    private static func withCurrentRun(
        _ expectation: MaterialDigestRunExpectation,
        in candidate: WorkspaceState
    ) throws -> MaterialDigestRunMatch {
        guard let inspiration = candidate.inspirations[expectation.inspirationID] else {
            throw WorkspaceReducerError.missingInspiration(expectation.inspirationID)
        }
        guard let digest = candidate.materialDigests[expectation.inspirationID],
              let run = digest.currentRun
        else {
            return .noChange(.materialDigestNotRunning)
        }
        let currentChecksum = WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        if digest.sourceChecksum != expectation.sourceChecksum
            || currentChecksum != expectation.sourceChecksum {
            return .noChange(.staleMaterialDigestSource)
        }
        if run.id != expectation.runID {
            return .noChange(.staleMaterialDigestRun)
        }
        return .matched(digest, run)
    }

    private static func isAllowedStageTransition(
        from: MaterialDigestStage,
        to: MaterialDigestStage
    ) -> Bool {
        switch (from, to) {
        case (.resolvingSource, .fetchingSource),
             (.fetchingSource, .extractingText),
             (.fetchingSource, .transcribing),
             (.fetchingSource, .recognizingImages),
             (.fetchingSource, .awaitingModelDownloadConsent),
             (.extractingText, .preparingSummary),
             (.extractingText, .recognizingImages),
             (.transcribing, .preparingSummary),
             (.transcribing, .awaitingModelDownloadConsent),
             (.recognizingImages, .preparingSummary),
             (.preparingSummary, .summarizing),
             (.awaitingModelDownloadConsent, .downloadingModel),
             (.downloadingModel, .fetchingSource):
            true
        default:
            false
        }
    }

}
