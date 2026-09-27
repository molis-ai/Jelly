import CalendarDomain
import CalendarPersistence
import Foundation
import Observation
import WorkspaceDomain

enum WorkspaceStorePhase: Equatable, Sendable {
    case notLoaded, loading, ready, mutating
    /// A recovery resolution owns the FIFO but must never borrow the normal
    /// `.mutating` admission gate for ordinary calendar/editor commands.
    case resolvingDraftRecovery
    /// Repair/adoption that originates from an unresolved recovery record is
    /// likewise not an ordinary mutation window.  Its final Journal rescan
    /// must publish the exact recovery phase before any tail can execute.
    case reconcilingDraftRecovery
    case parkedCommitUncertain(UUID)
    case parkedJournalCleanup(DraftJournalIdentity, JournalCleanupStep)
    case needsDraftRecovery([DraftRecoveryCandidate])
    case needsRelationshipRepair
    case externalSourceChanged(WorkspaceExternalSourceChangeReason)
    case opaquePrimaryLoadFailed, unreadablePrimaryLoadFailed, loadFailed
}

enum WorkspaceExternalSourceChangeReason: Equatable, Sendable {
    case externalBytesChanged
    case publishedDraftNotPersisted
}

enum WorkspaceTransactionOutcome: Equatable, Sendable {
    case committed(WorkspaceSaveReceipt, journal: JournalResolutionStatus)
    case draftAlreadyPersisted(PersistedDraftReceipt, journal: JournalResolutionStatus)
    case restored(WorkspaceRestoreOutcome)
    case noChange(WorkspaceNoChangeReason, journal: JournalResolutionStatus)
    case conflict(WorkspaceConflict)
    case draftSuperseded
    case commitPending(transactionID: UUID, artifacts: WorkspacePendingCommitArtifacts)
    case notCommitted(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case externalSourceChanged(transactionID: UUID?, reason: WorkspaceExternalSourceChangeReason, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case persistenceBlocked(transactionID: UUID?, reason: WorkspacePersistenceBlockReason, journal: JournalResolutionStatus)
}

enum PendingCommitRetryOutcome: Equatable, Sendable {
    case committed(WorkspaceCommittedOperation, journal: JournalResolutionStatus)
    case notCommitted(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case sourceChanged(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case stillPending(transactionID: UUID, artifacts: WorkspacePendingCommitArtifacts)
}

enum WorkspaceExternalReloadOutcome: Equatable, Sendable {
    case source(WorkspaceReloadedSource)
    case transaction(WorkspaceTransactionOutcome)
}

enum WorkspacePersistenceBlockReason: Equatable, Sendable { case unreadablePrimary, opaqueInvalidPrimary, loadFailed }
enum WorkspaceStoreError: Error, Equatable, Sendable { case frozen, nothingToUndo, nothingToRedo }

/// An opaque, Store-issued capability.  Only this file can construct one, and
/// only the Store keeps the complete frozen `NoteDraftSubmission` it names.
struct ProtectedNoteDraft: Equatable, Sendable {
    fileprivate let capability: UUID
    let identityAndGeneration: DraftJournalIdentityAndGeneration
    let noteSnapshotChecksum: String
    let journalChecksum: String

    fileprivate init(
        capability: UUID,
        identityAndGeneration: DraftJournalIdentityAndGeneration,
        noteSnapshotChecksum: String,
        journalChecksum: String
    ) {
        self.capability = capability
        self.identityAndGeneration = identityAndGeneration
        self.noteSnapshotChecksum = noteSnapshotChecksum
        self.journalChecksum = journalChecksum
    }
}

enum DraftProtectionOutcome: Equatable, Sendable {
    case protected(ProtectedNoteDraft)
    case superseded(currentGeneration: UInt64)
}

struct DraftRecoveryCandidate: Equatable, Sendable {
    let token: DraftRecoveryToken
    let draft: Note
    let persisted: Note?
    let updatedAt: Date
}

enum DraftRecoveryAction: Equatable, Sendable {
    case restoreAsCurrent
    case keepPersisted
    case saveAsNew(noteID: NoteID, blockIDs: [BlockID])
}

@MainActor
@Observable final class WorkspaceStore {
    private static let recoveryUndoLabel = "恢复笔记版本"
    private(set) var state: WorkspaceState { didSet { statePublicationGeneration &+= 1 } }
    var calendarState: CalendarState { state.calendar }
    private(set) var statePublicationGeneration: UInt = 0
    private(set) var phase: WorkspaceStorePhase = .notLoaded
    private(set) var hasRawRecoverySource = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    var latestUndoLabel: String? { undoStack.last?.label }
    var canUndoRecoverySelection: Bool {
        undoStack.last?.label == Self.recoveryUndoLabel
    }

    private let repository: any WorkspaceRepository
    private let journal: DraftJournalRepository?
    private let clock: @Sendable () -> Date
    private let queue = WorkspaceTransactionQueue()
    private var undoStack: [WorkspaceStoreUndoRecord] = []
    private var redoStack: [WorkspaceStoreUndoRecord] = []
    private var noteRevisionHighWatermarks: [NoteID: Int64] = [:]
    private var journalCleanupReceipts: [DraftJournalIdentity: PersistedDraftReceipt] = [:]
    private var journalCleanupTerminalPhases: [DraftJournalIdentity: WorkspaceStorePhase] = [:]
    private var acceptedDraftGenerations: [DraftJournalIdentity: AcceptedDraftGeneration] = [:]
    private var protectedDrafts: [UUID: FrozenProtectedDraft] = [:]
    private var journalProtectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var draftRecoveryCandidates: [DraftRecoveryCandidate] = []
    private var draftRecoveryTerminalPhaseWhenClean: WorkspaceStorePhase = .ready
    private var claimedDraftRecoveryTokens: Set<DraftRecoveryToken> = []
    /// New recovery selections may join an actively draining recovery FIFO,
    /// but never a parked/uncertain/terminal resolution.
    private var recoveryResolutionQueueOpen = false
    private var journalCleanupRecoveryFinalizations: [DraftJournalIdentity: DraftRecoveryCleanupFinalization] = [:]
    private var journalCleanupRequiresStartupRescan: Set<DraftJournalIdentity> = []
    private var parkedSave: ParkedSave?
    private var parkedRestore: ParkedRestore?
    private var pendingExternalRepairState: WorkspaceState?
    /// Every accepted external source is incomplete until its durable Journal
    /// has been scanned against that exact source.  This deliberately does
    /// not infer recovery ownership from an already-published candidate: a
    /// fresh Store can have only a completion marker, and another process can
    /// create a bare record after the in-memory candidate list was emptied.
    private var requiresJournalReconciliation = false
    /// Read-only admission evidence for recovery UI. A phase alone is not
    /// authoritative while the durable Journal still belongs to an
    /// incomplete source reconciliation.
    var hasUnresolvedJournalReconciliation: Bool { requiresJournalReconciliation }

    private struct ParkedSave {
        let transactionID: UUID
        let candidate: WorkspaceState
        let draftReceipt: PersistedDraftReceipt?
        let completion: SaveCompletion
    }
    private enum SaveCompletion {
        case forward(undoRecord: WorkspaceStoreUndoRecord?, acceptedDraft: AcceptedDraftGeneration?)
        case undo(undo: Bool, reverseRecord: WorkspaceStoreUndoRecord, ledger: [NoteID: Int64])
        case externalAdoption(ledger: [NoteID: Int64])
        case externalRepair(ledger: [NoteID: Int64])
        case draftRecoveryRepair(ledger: [NoteID: Int64])
        case draftRecovery(
            completion: DraftRecoveryCompletion,
            terminalPhase: WorkspaceStorePhase,
            failurePhase: WorkspaceStorePhase,
            undoRecord: WorkspaceStoreUndoRecord?
        )

        var notCommittedTerminalPhase: WorkspaceStorePhase {
            switch self {
            case .externalRepair, .draftRecoveryRepair:
                .needsRelationshipRepair
            case .externalAdoption:
                .externalSourceChanged(.externalBytesChanged)
            case let .draftRecovery(_, _, failurePhase, _):
                failurePhase
            case .forward, .undo:
                .ready
            }
        }

        var resumesQueueAfterNotCommitted: Bool {
            switch self {
            case .forward, .undo:
                true
            case .externalAdoption, .externalRepair, .draftRecoveryRepair, .draftRecovery:
                false
            }
        }

        var sourceChangedTerminalPhase: WorkspaceStorePhase {
            // A direct or reconciled source change invalidates every saved
            // candidate, including a repair candidate held only in memory.
            switch self {
            case .draftRecovery:
                .externalSourceChanged(.externalBytesChanged)
            case .forward, .undo, .externalAdoption, .externalRepair, .draftRecoveryRepair:
                .externalSourceChanged(.externalBytesChanged)
            }
        }
    }
    private struct ParkedRestore {
        let transactionID: UUID
        let candidate: WorkspaceState
        let prepared: PreparedWorkspaceRestore
    }
    private struct AcceptedDraftGeneration {
        let identity: DraftJournalIdentity
        let generation: UInt64
        let accepted: PreviousAcceptedDraft
    }
    private struct FrozenProtectedDraft: Sendable {
        let protected: ProtectedNoteDraft
        let submission: NoteDraftSubmission
        let recoveryToken: DraftRecoveryToken?
    }
    private enum DraftRecoveryCleanupFinalization {
        case completed(DraftRecoveryToken)
        case abandoned(DraftRecoveryToken)
    }
    private enum DraftRecoveryCompletionVerification {
        case committed
        case notCommitted
        case sourceChanged
    }

    init(
        initialState: WorkspaceState,
        repository: any WorkspaceRepository,
        journal: DraftJournalRepository? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.state = initialState
        self.repository = repository
        self.journal = journal
        self.clock = clock
        self.noteRevisionHighWatermarks = initialState.notes.mapValues(\.revision)
    }

    func load() async {
        guard phase == .notLoaded || phase == .ready else { return }
        phase = .loading
        do {
            let loaded = try await repository.load()
            hasRawRecoverySource = false
            state = loaded.state
            noteRevisionHighWatermarks = loaded.state.notes.mapValues(\.revision)
            requiresJournalReconciliation = journal != nil
            phase = loaded.consistencyIssues.isEmpty
                ? (requiresJournalReconciliation ? .reconcilingDraftRecovery : .ready)
                : .needsRelationshipRepair
            pendingExternalRepairState = loaded.consistencyIssues.isEmpty ? nil : loaded.state
            if loaded.consistencyIssues.isEmpty {
                await recoverJournalAtStartup()
            }
        } catch {
            let projection = try? await repository.reloadCurrentSourceAfterExternalChange()
            switch projection {
            case .opaqueInvalid:
                hasRawRecoverySource = true
                await recoverJournalAtStartup(terminalPhaseWhenClean: .opaquePrimaryLoadFailed)
            case .unreadableUnknown:
                hasRawRecoverySource = false
                await recoverJournalAtStartup(terminalPhaseWhenClean: .unreadablePrimaryLoadFailed)
            default:
                hasRawRecoverySource = false
                phase = .loadFailed
            }
        }
    }

    func sendWorkspace(_ command: WorkspaceCommand, undoLabel: String? = nil) async throws -> WorkspaceTransactionOutcome {
        if phase == .unreadablePrimaryLoadFailed {
            return .persistenceBlocked(transactionID: nil, reason: .unreadablePrimary, journal: .clean)
        }
        if case let .repairConsistency(payload) = command,
           phase == .needsRelationshipRepair,
           pendingExternalRepairState != nil {
            return try await enqueueTransaction { [weak self] id in
                guard let self else { throw CancellationError() }
                return try await self.performExternalRepair(payload: payload, transactionID: id)
            }
        }
        try ensureOrdinaryMutationAllowed()
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.perform(command: command, undoLabel: undoLabel, transactionID: id)
        }
    }

    func sendCalendar(_ command: CalendarCommand, undoLabel: String? = nil) async throws -> WorkspaceTransactionOutcome {
        try await sendWorkspace(.calendar(command), undoLabel: undoLabel)
    }

    func submitDraft(_ submission: NoteDraftSubmission) async throws -> WorkspaceTransactionOutcome {
        switch try await protectDraft(submission) {
        case let .protected(protected):
            return try await commitProtectedDraft(protected)
        case .superseded:
            return .draftSuperseded
        }
    }

    func protectDraft(_ submission: NoteDraftSubmission) async throws -> DraftProtectionOutcome {
        try ensureOrdinaryMutationAllowed()
        let identity = DraftJournalIdentity(
            noteID: submission.noteID,
            editSessionID: .editor(submission.editSessionID)
        )
        let protected: ProtectedNoteDraft
        let token: DraftRecoveryToken?
        if let journal {
            let entry = try DraftJournalCoordinator.entry(
                submission: submission, workspaceRevision: state.revision, clock: clock
            )
            switch try await journal.protect(entry) {
            case let .superseded(currentGeneration):
                return .superseded(currentGeneration: currentGeneration)
            case .busy:
                // An in-process head may have bound this identity immediately
                // before its main save. Wait for that one head to reach a
                // terminal Journal state, then retry protection; a peer-owned
                // occupied record remains synchronously read-only.
                if phase == .mutating {
                    await waitForCurrentTransactionJournalResolution()
                    return try await protectDraft(submission)
                }
                // The head can finish after `protect` observed its occupied
                // bytes but before this actor resumes. Re-read once so that
                // a now-absent or exactly unbound record does not become a
                // false permanent busy result.
                if phase == .ready {
                    let current = try await journal.current()?.records.first { $0.identity == identity }
                    if current == nil || (
                        current?.pendingReceipt == nil
                            && current?.savedReceipt == nil
                            && current?.recoveryCompletion == nil
                    ) {
                        return try await protectDraft(submission)
                    }
                }
                throw WorkspaceStoreError.frozen
            case let .protected(value):
                if let existing = protectedDrafts.values.first(where: { $0.recoveryToken == value }) {
                    return .protected(existing.protected)
                }
                protectedDrafts = protectedDrafts.filter { _, frozen in
                    frozen.protected.identityAndGeneration.identity != identity
                }
                token = value
                protected = .init(
                    capability: UUID(),
                    identityAndGeneration: value.identityAndGeneration,
                    noteSnapshotChecksum: value.noteSnapshotChecksum,
                    journalChecksum: value.journalChecksum
                )
            }
        } else {
            let generation = DraftJournalIdentityAndGeneration(
                identity: identity, draftGeneration: submission.draftGeneration
            )
            if let existing = protectedDrafts.values.first(where: {
                $0.protected.identityAndGeneration == generation
                    && $0.submission == submission
            }) {
                return .protected(existing.protected)
            }
            protectedDrafts = protectedDrafts.filter { _, frozen in
                frozen.protected.identityAndGeneration.identity != identity
            }
            token = nil
            protected = .init(
                capability: UUID(),
                identityAndGeneration: generation,
                noteSnapshotChecksum: submission.noteSnapshotChecksum,
                journalChecksum: ""
            )
        }
        protectedDrafts[protected.capability] = .init(
            protected: protected, submission: submission, recoveryToken: token
        )
        return .protected(protected)
    }

    func commitProtectedDraft(_ protected: ProtectedNoteDraft) async throws -> WorkspaceTransactionOutcome {
        try ensureOrdinaryMutationAllowed()
        guard let frozen = protectedDrafts.removeValue(forKey: protected.capability),
              frozen.protected == protected
        else { return .draftSuperseded }
        if let token = frozen.recoveryToken, let journal,
           try await journal.isCurrentBare(token) == false {
            return .draftSuperseded
        }
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.perform(
                command: .updateNote(frozen.submission),
                undoLabel: "编辑笔记",
                transactionID: id,
                protectedToken: frozen.recoveryToken
            )
        }
    }

    func undo() async throws -> WorkspaceTransactionOutcome {
        try ensureOrdinaryMutationAllowed()
        guard let record = undoStack.last else { throw WorkspaceStoreError.nothingToUndo }
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.performUndo(record: record, transactionID: id, undo: true)
        }
    }

    func redo() async throws -> WorkspaceTransactionOutcome {
        try ensureOrdinaryMutationAllowed()
        guard let record = redoStack.last else { throw WorkspaceStoreError.nothingToRedo }
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.performUndo(record: record, transactionID: id, undo: false)
        }
    }

    func restore(
        _ preview: WorkspaceRestorePreview,
        rollbackDirectoryURL: URL
    ) async throws -> WorkspaceTransactionOutcome {
        guard requiresJournalReconciliation == false,
              phase == .ready
            || phase.isExternalSourceChanged
            || phase == .opaquePrimaryLoadFailed
            || phase == .needsRelationshipRepair
        else {
            throw WorkspaceStoreError.frozen
        }
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.performRestore(
                preview: preview, rollbackDirectoryURL: rollbackDirectoryURL, transactionID: id
            )
        }
    }

    func resolveDraftRecovery(
        _ token: DraftRecoveryToken,
        action: DraftRecoveryAction
    ) async throws -> WorkspaceTransactionOutcome {
        guard allowsDraftRecoveryResolution else { throw WorkspaceStoreError.frozen }
        guard let recovery = draftRecoveryCandidates.first(where: { $0.token == token }) else {
            return .draftSuperseded
        }
        // This claim deliberately happens before the first await. A repeated
        // tap cannot pass an asynchronous Journal read and independently
        // initiate a second main-file save.
        guard claimedDraftRecoveryTokens.insert(token).inserted else {
            return .draftSuperseded
        }
        recoveryResolutionQueueOpen = true
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.performDraftRecovery(
                recovery, action: action, transactionID: id
            )
        }
    }

    func currentDocumentData() async throws -> Data { try await repository.currentDocumentData() }
    func rawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact { try await repository.currentRawRecoveryData() }
    /// Read-only evidence export for a currently reviewed recovery candidate.
    /// It does not acknowledge, discard or otherwise mutate the Journal.
    func draftRecoveryMarkdown(_ token: DraftRecoveryToken) throws -> String {
        guard let candidate = draftRecoveryCandidates.first(where: { $0.token == token }) else {
            throw WorkspaceStoreError.frozen
        }
        return try BlockMarkdownCodec.exportMarkdown(candidate.draft.document)
    }
    func exportBackup(to destination: URL) async throws {
        try await BackupService().exportCurrent(from: repository, to: destination)
    }
    func inspectRestoreSource(at source: URL) async throws -> WorkspaceRestorePreview {
        try await BackupService().inspectRestoreSource(source)
    }
    func exportRawRecoveryCopy(to destination: URL) async throws -> WorkspaceRawRecoveryArtifact {
        let artifact = try await repository.currentRawRecoveryData()
        do {
            try FoundationAtomicFileWriter().replaceAtomically(data: artifact.rawData, at: destination)
            guard try Data(contentsOf: destination) == artifact.rawData else {
                throw WorkspacePersistenceError.atomicWriteFailed
            }
            return artifact
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    @discardableResult
    func reloadExternalSource() async throws -> WorkspaceExternalReloadOutcome {
        guard phase.allowsExternalReload else { throw WorkspaceStoreError.frozen }
        let previousPhase = phase
        let previousReconciliationRequirement = requiresJournalReconciliation
        let previousRawRecoveryAvailability = hasRawRecoverySource
        requiresJournalReconciliation = journal != nil
        if requiresJournalReconciliation { phase = .reconcilingDraftRecovery }
        let reloaded: WorkspaceReloadedSource
        do {
            reloaded = try await repository.reloadCurrentSourceAfterExternalChange()
        } catch {
            phase = previousPhase
            requiresJournalReconciliation = previousReconciliationRequirement
            hasRawRecoverySource = previousRawRecoveryAvailability
            throw error
        }
        switch reloaded {
        case let .valid(external):
            hasRawRecoverySource = false
            let adoption: WorkspaceExternalSourceAdoption
            do {
                adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
                    current: state, external: external.state, sessionNoteHighWatermarks: noteRevisionHighWatermarks
                )
            } catch {
                phase = previousPhase
                requiresJournalReconciliation = previousReconciliationRequirement
                throw error
            }
            guard adoption.consistencyIssues.isEmpty else {
                pendingExternalRepairState = external.state
                phase = .needsRelationshipRepair
                return .source(reloaded)
            }
            let direct = external.provenance.sourceSchema == WorkspaceDocument.currentSchemaVersion
                && adoption.candidate == external.state && !adoption.requiresNormalization
            if direct {
                state = adoption.candidate
                noteRevisionHighWatermarks = adoption.noteRevisionHighWatermarks
            } else {
                let outcome = try await enqueueTransaction { [weak self] id in
                    guard let self else { throw CancellationError() }
                    return try await self.performExternalAdoption(
                        candidate: adoption.candidate, ledger: adoption.noteRevisionHighWatermarks, transactionID: id
                    )
                }
                return .transaction(outcome)
            }
            pendingExternalRepairState = nil
            phase = requiresJournalReconciliation ? .reconcilingDraftRecovery : .ready
            await recoverJournalAtStartup()
        case .opaqueInvalid:
            hasRawRecoverySource = true
            pendingExternalRepairState = nil
            await recoverJournalAtStartup(terminalPhaseWhenClean: .opaquePrimaryLoadFailed)
        case .unreadableUnknown:
            hasRawRecoverySource = false
            pendingExternalRepairState = nil
            await recoverJournalAtStartup(terminalPhaseWhenClean: .unreadablePrimaryLoadFailed)
        case .absent:
            hasRawRecoverySource = false
            pendingExternalRepairState = nil
            await recoverJournalAtStartup(
                terminalPhaseWhenClean: .externalSourceChanged(.externalBytesChanged)
            )
        }
        return .source(reloaded)
    }


    func retryPendingCommit(_ transactionID: UUID) async throws -> PendingCommitRetryOutcome {
        guard case let .parkedCommitUncertain(parked) = phase, parked == transactionID else {
            throw WorkspaceStoreError.frozen
        }
        switch try await repository.reconcilePendingCommit() {
        case let .committed(operation):
            switch operation {
            case let .save(receipt):
                guard let parked = parkedSave, parked.transactionID == transactionID else { throw WorkspaceStoreError.frozen }
                let journalStatus = await finishCommittedSave(
                    candidate: parked.candidate, completion: parked.completion, draftReceipt: parked.draftReceipt
                )
                parkedSave = nil
                if case .cleanupPending = journalStatus {
                    if case .parkedJournalCleanup = phase {
                        // `finishCommittedSave` retained the exact terminal
                        // phase (notably remaining draft-recovery candidates).
                    } else {
                        parkJournalCleanup(journalStatus, receipt: parked.draftReceipt)
                    }
                } else {
                    if phase == .parkedCommitUncertain(transactionID) { phase = .ready }
                    if phase == .ready { queue.resume() }
                }
                return .committed(.save(receipt), journal: journalStatus)
            case let .restore(outcome):
                guard let parked = parkedRestore, parked.transactionID == transactionID else { throw WorkspaceStoreError.frozen }
                state = parked.candidate
                undoStack.removeAll(); redoStack.removeAll(); updateUndoAvailability()
                mergeSessionNoteLedger(with: parked.candidate)
                pendingExternalRepairState = nil
                hasRawRecoverySource = false
                parkedRestore = nil
                phase = .ready
                queue.resume()
                return .committed(.restore(outcome), journal: .clean)
            }
        case let .notCommitted(artifacts):
            guard (parkedSave?.transactionID == transactionID) || (parkedRestore?.transactionID == transactionID) else { throw WorkspaceStoreError.frozen }
            let parked = parkedSave
            let restore = parkedRestore
            let draftReceipt = parked?.draftReceipt
            if let restore, restore.transactionID == transactionID {
                _ = await repository.discardPreparedRestore(restore.prepared)
            }
            let journalStatus: JournalResolutionStatus
            if let parked, parked.transactionID == transactionID {
                journalStatus = await finishNotCommittedSave(
                    completion: parked.completion, draftReceipt: draftReceipt, artifacts: artifacts
                )
            } else {
                journalStatus = await unbindIfNeeded(draftReceipt).journalStatus
            }
            parkedSave = nil
            parkedRestore = nil
            if restore?.transactionID == transactionID {
                phase = .ready
            }
            if case .cleanupPending = journalStatus {
                if parked == nil { parkJournalCleanup(journalStatus, receipt: draftReceipt) }
            } else if parked?.completion.resumesQueueAfterNotCommitted ?? true {
                queue.resume()
            }
            return .notCommitted(transactionID: transactionID, journal: journalStatus, artifacts: artifacts)
        case let .sourceChanged(artifacts):
            let parked = parkedSave
            let draftReceipt = parked?.draftReceipt
            if let parked = parkedRestore, parked.transactionID == transactionID {
                _ = await repository.discardPreparedRestore(parked.prepared)
            }
            let journalStatus: JournalResolutionStatus
            if let parked, parked.transactionID == transactionID {
                journalStatus = await finishSourceChangedSave(
                    completion: parked.completion, draftReceipt: draftReceipt, artifacts: artifacts
                )
            } else {
                journalStatus = await finishSourceChangedRestore(artifacts: artifacts)
            }
            parkedSave = nil
            parkedRestore = nil
            return .sourceChanged(transactionID: transactionID, journal: journalStatus, artifacts: artifacts)
        case let .stillPending(artifacts):
            return .stillPending(transactionID: transactionID, artifacts: artifacts)
        }
    }

    func retryJournalCleanup(_ identity: DraftJournalIdentity) async -> JournalResolutionStatus {
        guard case let .parkedJournalCleanup(parked, step) = phase, parked == identity, let journal else {
            return .clean
        }
        let resolution = await DraftJournalCoordinator.retryCleanup(
            identity, step: step, receipt: journalCleanupReceipts[identity], journal: journal
        )
        let status = resolution.journalStatus
        switch resolution {
        case let .cleanupPending(nextIdentity, _):
            // A retry can make partial progress (for example record succeeds
            // and clear then fails).  Park the returned, not captured, step
            // so the next retry cannot repeat an already completed action.
            parkJournalCleanup(
                status,
                receipt: journalCleanupReceipts[identity],
                terminalPhase: journalCleanupTerminalPhases[identity] ?? .ready
            )
            if nextIdentity != identity {
                journalCleanupReceipts.removeValue(forKey: identity)
                journalCleanupTerminalPhases.removeValue(forKey: identity)
            }
        case .clean, .staleOrMissing:
            journalCleanupReceipts.removeValue(forKey: identity)
            let terminalPhase = journalCleanupTerminalPhases.removeValue(forKey: identity) ?? .ready
            let recoveryFinalization = journalCleanupRecoveryFinalizations.removeValue(forKey: identity)
            if let recoveryFinalization, resolution == .clean {
                switch recoveryFinalization {
                case let .completed(token): finalizeDraftRecoveryCandidate(token)
                case let .abandoned(token): claimedDraftRecoveryTokens.remove(token)
                }
            } else if let recoveryFinalization {
                switch recoveryFinalization {
                case let .completed(token), let .abandoned(token): claimedDraftRecoveryTokens.remove(token)
                }
            }
            let requiresStartupRescan = journalCleanupRequiresStartupRescan.remove(identity) != nil
                || resolution == .staleOrMissing
            if requiresStartupRescan {
                let terminalPhaseAfterRecoveryBatch = recoveryFinalization == nil
                    ? terminalPhase
                    : draftRecoveryTerminalPhaseWhenClean
                await recoverJournalAtStartup(
                    terminalPhaseWhenClean: terminalPhaseAfterRecoveryBatch
                )
                if phase.isDraftRecovery, claimedDraftRecoveryTokens.isEmpty == false {
                    recoveryResolutionQueueOpen = true
                    queue.resume()
                }
                return status
            }
            phase = terminalPhase
            if terminalPhase == .ready || terminalPhase.isDraftRecovery {
                // Ordinary mutations cannot enter the FIFO while recovery is
                // parked.  Any retained entry is therefore a previously
                // claimed recovery resolution and may continue exactly once.
                queue.resume()
            }
        }
        return status
    }

    private func perform(
        command originalCommand: WorkspaceCommand,
        undoLabel: String?,
        transactionID: UUID,
        protectedToken: DraftRecoveryToken? = nil
    ) async throws -> WorkspaceTransactionOutcome {
        phase = .mutating
        defer { if phase == .mutating { phase = .ready } }
        let now = clock()
        let command = try rebasedDraftCommand(normalized(command: originalCommand))
        let reduction = try WorkspaceReducer.reduce(state, command: command, now: now)
        switch reduction {
        case let .noChange(reason):
            return try await resolveNoChange(reason: reason, command: command, transactionID: transactionID)
        case let .conflict(conflict):
            return .conflict(conflict)
        case let .changed(unrevisedChange):
            let change = try applyingSessionNoteRevisions(to: unrevisedChange)
            let draftReceipt: PersistedDraftReceipt?
            if let context = change.draftContext {
                let receipt = PersistedDraftReceipt(
                    noteID: context.noteID, editSessionID: context.editSessionID,
                    draftGeneration: context.draftGeneration,
                    noteSnapshotChecksum: context.noteSnapshotChecksum,
                    persistedNoteRevision: context.persistedNoteRevision
                )
                if let journal {
                    guard let candidateNote = change.state.notes[receipt.noteID] else {
                        throw WorkspaceStoreError.frozen
                    }
                    let binding: DraftJournalBindingResult
                    if let protectedToken {
                        binding = try await journal.rebaseAndBind(
                            expected: protectedToken, finalCandidateNote: candidateNote, receipt: receipt
                        )
                    } else {
                        binding = try await journal.rebaseAndBind(
                            expected: .init(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), draftGeneration: receipt.draftGeneration),
                            finalCandidateNote: candidateNote, receipt: receipt
                        )
                    }
                    switch binding {
                    case .bound: break
                    case .supersededByNewerDraft: return .draftSuperseded
                    }
                }
                draftReceipt = receipt
            } else {
                draftReceipt = nil
            }
            return try await persistSave(
                candidate: change.state,
                draftContext: change.draftContext,
                draftReceipt: draftReceipt,
                completion: .forward(
                    undoRecord: WorkspaceUndoReducer.record(before: state, after: change.state, label: undoLabel),
                    acceptedDraft: acceptedDraft(command: command, candidate: change.state)
                ),
                transactionID: transactionID
            )
        }
    }

    private func resolveNoChange(
        reason: WorkspaceNoChangeReason,
        command: WorkspaceCommand,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        guard case let .updateNote(submission) = command, let journal,
              let note = state.notes[submission.noteID]
        else { return .noChange(reason, journal: .clean) }
        let receipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(submission.editSessionID),
            draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            persistedNoteRevision: note.revision
        )
        switch try await repository.verifyPersistedDraft(.init(
            noteID: receipt.noteID, editSessionID: receipt.editSessionID,
            draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: receipt.noteSnapshotChecksum,
            persistedNoteRevision: receipt.persistedNoteRevision
        )) {
        case let .verified(verifiedReceipt):
            let resolution = await DraftJournalCoordinator.acknowledgeAndClear(receipt, journal: journal)
            let status = resolution.journalStatus
            if case .cleanupPending = resolution {
                parkJournalCleanup(status, receipt: receipt)
            } else if case .staleOrMissing = resolution {
                await recoverJournalAtStartup()
            }
            return .draftAlreadyPersisted(verifiedReceipt, journal: status)
        case .sourceChanged:
            phase = .externalSourceChanged(.externalBytesChanged)
            terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: .init())
            return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: .clean, artifacts: .init())
        case .notPersisted:
            phase = .externalSourceChanged(.publishedDraftNotPersisted)
            terminateQueuedForExternal(reason: .publishedDraftNotPersisted, artifacts: .init())
            return .externalSourceChanged(transactionID: transactionID, reason: .publishedDraftNotPersisted, journal: .clean, artifacts: .init())
        case .unreadableUnknown:
            phase = .unreadablePrimaryLoadFailed
            terminateQueuedForPersistenceBlock(reason: .unreadablePrimary)
            return .persistenceBlocked(transactionID: transactionID, reason: .unreadablePrimary, journal: .clean)
        }
    }

    private func unbindIfNeeded(_ receipt: PersistedDraftReceipt?) async -> DraftRecoveryJournalResolution {
        guard let receipt, let journal else { return .clean }
        do {
            switch try await journal.unbindPending(receipt) {
            case .applied: return .clean
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .unbind)
        }
    }

    private func parkJournalCleanup(
        _ status: JournalResolutionStatus,
        receipt: PersistedDraftReceipt?,
        terminalPhase: WorkspaceStorePhase = .ready,
        recoveryFinalization: DraftRecoveryCleanupFinalization? = nil,
        requiresStartupRescan: Bool = false
    ) {
        guard case let .cleanupPending(identity, step) = status else { return }
        if let receipt { journalCleanupReceipts[identity] = receipt }
        journalCleanupTerminalPhases[identity] = terminalPhase
        if let recoveryFinalization { journalCleanupRecoveryFinalizations[identity] = recoveryFinalization }
        if requiresStartupRescan { journalCleanupRequiresStartupRescan.insert(identity) }
        phase = .parkedJournalCleanup(identity, step)
    }

    private func recoverJournalAtStartup(
        terminalPhaseWhenClean: WorkspaceStorePhase = .ready
    ) async {
        draftRecoveryTerminalPhaseWhenClean = terminalPhaseWhenClean
        guard let journal else {
            requiresJournalReconciliation = false
            phase = terminalPhaseWhenClean
            if terminalPhaseWhenClean == .ready { queue.resume() }
            return
        }
        // Set the nonordinary phase before the first Journal await.  Advisory
        // locking can suspend here, and a durable record may be the only
        // recovery evidence in a fresh Store.
        requiresJournalReconciliation = true
        phase = .reconcilingDraftRecovery
        do {
            guard let envelope = try await journal.current() else {
                draftRecoveryCandidates.removeAll()
                claimedDraftRecoveryTokens.removeAll()
                recoveryResolutionQueueOpen = false
                requiresJournalReconciliation = false
                phase = terminalPhaseWhenClean
                if terminalPhaseWhenClean == .ready { queue.resume() }
                return
            }
            var candidates: [DraftRecoveryCandidate] = []
            for record in envelope.records {
                let identity = record.identity
                if let recoveryCompletion = record.recoveryCompletion {
                    switch try verifyRecoveryCompletion(recoveryCompletion, record: record) {
                    case .committed:
                        let resolution = await DraftJournalCoordinator.completeRecovery(recoveryCompletion, journal: journal)
                        if case .cleanupPending = resolution {
                            parkJournalCleanup(
                                resolution.journalStatus,
                                receipt: nil,
                                terminalPhase: terminalPhaseWhenClean,
                                requiresStartupRescan: true
                            )
                            return
                        }
                        if case .staleOrMissing = resolution {
                            await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                            return
                        }
                        await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                        return
                    case .notCommitted:
                        let resolution = await DraftJournalCoordinator.abandonRecovery(recoveryCompletion, journal: journal)
                        if case .cleanupPending = resolution {
                            parkJournalCleanup(
                                resolution.journalStatus,
                                receipt: nil,
                                terminalPhase: terminalPhaseWhenClean,
                                requiresStartupRescan: true
                            )
                            return
                        }
                        if case .staleOrMissing = resolution {
                            await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                            return
                        }
                        await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                        return
                    case .sourceChanged:
                        phase = .externalSourceChanged(.externalBytesChanged)
                        return
                    }
                }
                if let saved = record.savedReceipt {
                    let resolution = await DraftJournalCoordinator.retryCleanup(
                        identity, step: .clear, receipt: saved, journal: journal
                    )
                    if case .cleanupPending = resolution {
                        parkJournalCleanup(
                            resolution.journalStatus,
                            receipt: saved,
                            terminalPhase: terminalPhaseWhenClean,
                            requiresStartupRescan: true
                        )
                        return
                    }
                    await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                    return
                }
                if let pending = record.pendingReceipt {
                    let verification = try await repository.verifyPersistedDraft(.init(
                        noteID: pending.noteID, editSessionID: pending.editSessionID,
                        draftGeneration: pending.draftGeneration, noteSnapshotChecksum: pending.noteSnapshotChecksum,
                        persistedNoteRevision: pending.persistedNoteRevision
                    ))
                    switch verification {
                    case let .verified(receipt) where receipt == pending:
                        let resolution = await DraftJournalCoordinator.recordAndClear(pending, journal: journal)
                        if case .cleanupPending = resolution {
                            parkJournalCleanup(
                                resolution.journalStatus,
                                receipt: pending,
                                terminalPhase: terminalPhaseWhenClean,
                                requiresStartupRescan: true
                            )
                            return
                        }
                        await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                        return
                    case .notPersisted:
                        let resolution = await unbindIfNeeded(pending)
                        if case .cleanupPending = resolution {
                            parkJournalCleanup(
                                resolution.journalStatus,
                                receipt: pending,
                                terminalPhase: terminalPhaseWhenClean,
                                requiresStartupRescan: true
                            )
                            return
                        }
                        await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                        return
                    case .sourceChanged:
                        phase = .externalSourceChanged(.externalBytesChanged)
                        return
                    case .unreadableUnknown, .verified:
                        phase = .unreadablePrimaryLoadFailed
                        return
                    }
                }
                let persisted = state.notes[record.entry.noteID]
                if let persisted,
                   Self.hasSameRecoverableContent(record.entry.noteSnapshot, persisted) {
                    // Loaded state may be stale or retained after an unreadable
                    // main file. Verify the current persisted snapshot before
                    // discarding this exact Journal token; this receipt does
                    // not acknowledge the draft's possibly different revision.
                    let context = PersistableDraftContext(
                        noteID: persisted.id, editSessionID: record.entry.editSessionID,
                        draftGeneration: record.entry.draftGeneration,
                        noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(persisted),
                        persistedNoteRevision: persisted.revision
                    )
                    switch try await repository.verifyPersistedDraft(context) {
                    case let .verified(receipt) where
                        receipt.noteID == context.noteID
                            && receipt.editSessionID == context.editSessionID
                            && receipt.draftGeneration == context.draftGeneration
                            && receipt.noteSnapshotChecksum == context.noteSnapshotChecksum
                            && receipt.persistedNoteRevision == context.persistedNoteRevision:
                        let token = DraftRecoveryToken(
                            identityAndGeneration: .init(
                                identity: record.identity,
                                draftGeneration: record.entry.draftGeneration
                            ),
                            noteSnapshotChecksum: record.entry.noteSnapshotChecksum,
                            journalChecksum: record.entry.journalChecksum
                        )
                        let resolution = await DraftJournalCoordinator.discardRecovery(token, journal: journal)
                        if case .cleanupPending = resolution {
                            parkJournalCleanup(
                                resolution.journalStatus,
                                receipt: nil,
                                terminalPhase: terminalPhaseWhenClean,
                                requiresStartupRescan: true
                            )
                            return
                        }
                        await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                        return
                    case .notPersisted:
                        break
                    case .sourceChanged:
                        phase = .externalSourceChanged(.externalBytesChanged)
                        return
                    case .unreadableUnknown, .verified:
                        phase = .unreadablePrimaryLoadFailed
                        return
                    }
                } else if let persisted,
                   (try WorkspaceChecksum.noteSnapshotChecksum(persisted)) == record.entry.noteSnapshotChecksum {
                    let context = PersistableDraftContext(
                        noteID: persisted.id, editSessionID: record.entry.editSessionID,
                        draftGeneration: record.entry.draftGeneration,
                        noteSnapshotChecksum: record.entry.noteSnapshotChecksum,
                        persistedNoteRevision: persisted.revision
                    )
                    switch try await repository.verifyPersistedDraft(context) {
                    case let .verified(receipt):
                        let resolution: DraftRecoveryJournalResolution
                        if receipt.persistedNoteRevision == record.entry.baseNoteRevision {
                            // Older builds could protect an unchanged native finalizer snapshot.
                            // Its exact bytes are already durable, so no revision bump exists for
                            // acknowledgeAlreadyPersisted to bind. Discard only this still-bare,
                            // checksum-bound record instead of recursively rescanning forever.
                            let token = DraftRecoveryToken(
                                identityAndGeneration: .init(
                                    identity: record.identity,
                                    draftGeneration: record.entry.draftGeneration
                                ),
                                noteSnapshotChecksum: record.entry.noteSnapshotChecksum,
                                journalChecksum: record.entry.journalChecksum
                            )
                            resolution = await DraftJournalCoordinator.discardRecovery(token, journal: journal)
                        } else {
                            resolution = await DraftJournalCoordinator.acknowledgeAndClear(receipt, journal: journal)
                        }
                        if case .cleanupPending = resolution {
                            parkJournalCleanup(
                                resolution.journalStatus,
                                receipt: receipt,
                                terminalPhase: terminalPhaseWhenClean,
                                requiresStartupRescan: true
                            )
                            return
                        }
                        await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhaseWhenClean)
                        return
                    case .unreadableUnknown:
                        phase = .unreadablePrimaryLoadFailed
                        return
                    case .notPersisted, .sourceChanged:
                        break
                    }
                }
                candidates.append(.init(
                    token: .init(
                        identityAndGeneration: .init(
                            identity: record.identity,
                            draftGeneration: record.entry.draftGeneration
                        ),
                        noteSnapshotChecksum: record.entry.noteSnapshotChecksum,
                        journalChecksum: record.entry.journalChecksum
                    ),
                    draft: record.entry.noteSnapshot,
                    persisted: persisted,
                    updatedAt: record.entry.updatedAt
                ))
            }
            draftRecoveryCandidates = candidates
            claimedDraftRecoveryTokens.formIntersection(Set(candidates.map(\.token)))
            requiresJournalReconciliation = false
            if candidates.isEmpty {
                recoveryResolutionQueueOpen = false
                phase = terminalPhaseWhenClean
                if terminalPhaseWhenClean == .ready { queue.resume() }
            } else {
                phase = .needsDraftRecovery(candidates)
            }
        } catch {
            phase = .unreadablePrimaryLoadFailed
        }
    }

    private static func hasSameRecoverableContent(_ draft: Note, _ persisted: Note) -> Bool {
        draft.id == persisted.id
            && draft.title == persisted.title
            && draft.document == persisted.document
            && draft.categoryID == persisted.categoryID
            && draft.archivedAt == persisted.archivedAt
            && draft.createdAt == persisted.createdAt
    }

    private func verifyRecoveryCompletion(
        _ completion: DraftRecoveryCompletion,
        record: StoredDraftJournalRecord
    ) throws -> DraftRecoveryCompletionVerification {
        let result = completion.result
        if state.revision == result.workspaceRevision,
           let note = state.notes[result.noteID],
           note.revision == result.noteRevision,
           try WorkspaceChecksum.noteSnapshotChecksum(note) == result.noteSnapshotChecksum {
            return .committed
        }
        // A committed marker is intentionally irreversible: a later source
        // rollback must never turn a known committed recovery into a bare
        // record and replay its main save.
        guard completion.state == .pending else { return .sourceChanged }
        let source = try DraftJournal.recoverySourceIdentity(for: state)
        return source == completion.source ? .notCommitted : .sourceChanged
    }

    /// All ordinary, undo/redo, external-normalization and repair saves go
    /// through this single driver.  The parked record owns the post-save
    /// transition, so a later FIFO head can never publish the earlier save.
    private func persistSave(
        candidate: WorkspaceState,
        draftContext: PersistableDraftContext?,
        draftReceipt: PersistedDraftReceipt?,
        completion: SaveCompletion,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        do {
            let receipt = try await repository.save(candidate, draft: draftContext)
            let journalStatus = await finishCommittedSave(candidate: candidate, completion: completion, draftReceipt: draftReceipt)
            return .committed(receipt, journal: journalStatus)
        } catch let failure as WorkspaceDirectCommitFailure {
            let artifacts: WorkspacePendingCommitArtifacts
            switch failure { case let .sourceChanged(value): artifacts = value }
            let cleanup = await finishSourceChangedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: artifacts
            )
            return .externalSourceChanged(
                transactionID: transactionID, reason: .externalBytesChanged, journal: cleanup, artifacts: artifacts
            )
        } catch WorkspacePersistenceError.commitUncertain {
            return try await reconcileImmediately(
                transactionID: transactionID, candidate: candidate, draftReceipt: draftReceipt, completion: completion
            )
        } catch WorkspacePersistenceError.atomicWriteFailed {
            let journalStatus = await finishNotCommittedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: .init()
            )
            return .notCommitted(transactionID: transactionID, journal: journalStatus, artifacts: .init())
        } catch WorkspacePersistenceError.invalidDocument {
            let unreadablePrimary = await repositoryReportsUnreadablePrimary()
            if case .draftRecovery = completion {
                let journalStatus = await finishRejectedRecoverySave(completion: completion)
                if unreadablePrimary {
                    if case .cleanupPending = journalStatus {
                        throw WorkspacePersistenceError.invalidDocument
                    }
                    return .persistenceBlocked(
                        transactionID: transactionID,
                        reason: .unreadablePrimary,
                        journal: journalStatus
                    )
                }
                throw WorkspacePersistenceError.invalidDocument
            }
            guard unreadablePrimary else { throw WorkspacePersistenceError.invalidDocument }
            let journalStatus = await finishUnreadablePrimarySave(draftReceipt)
            return .persistenceBlocked(
                transactionID: transactionID, reason: .unreadablePrimary, journal: journalStatus
            )
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw error
        }
    }

    private func finishCommittedSave(
        candidate: WorkspaceState,
        completion: SaveCompletion,
        draftReceipt: PersistedDraftReceipt?
    ) async -> JournalResolutionStatus {
        hasRawRecoverySource = false
        switch completion {
        case let .forward(undoRecord, acceptedDraft):
            publish(candidate, undoRecord: undoRecord)
            remember(acceptedDraft)
        case let .undo(undo, reverseRecord, ledger):
            state = candidate
            noteRevisionHighWatermarks = ledger
            if undo { _ = undoStack.popLast(); redoStack.append(reverseRecord) }
            else { _ = redoStack.popLast(); undoStack.append(reverseRecord) }
            updateUndoAvailability()
        case let .externalAdoption(ledger), let .externalRepair(ledger):
            state = candidate
            noteRevisionHighWatermarks = ledger
            pendingExternalRepairState = nil
            updateUndoAvailability()
        case let .draftRecoveryRepair(ledger):
            state = candidate
            noteRevisionHighWatermarks = ledger
            pendingExternalRepairState = nil
            updateUndoAvailability()
            draftRecoveryTerminalPhaseWhenClean = .ready
            // The repair wrote only the persisted relationship graph.  Read
            // the Journal again rather than carrying an in-memory reviewed
            // draft across the durable repair boundary: another process may
            // have superseded a token while the repair was saving.
            await recoverJournalAtStartup(
                terminalPhaseWhenClean: draftRecoveryTerminalPhaseWhenClean
            )
        case let .draftRecovery(recoveryCompletion, terminalPhase, _, undoRecord):
            publish(candidate, undoRecord: undoRecord)
            draftRecoveryTerminalPhaseWhenClean = .ready
            let committedTerminalPhase: WorkspaceStorePhase = terminalPhase.isDraftRecovery
                ? terminalPhase
                : .ready
            let resolution = if let journal {
                await DraftJournalCoordinator.completeRecovery(recoveryCompletion, journal: journal)
            } else { DraftRecoveryJournalResolution.clean }
            let journalStatus = resolution.journalStatus
            if case .cleanupPending = resolution {
                parkJournalCleanup(
                    journalStatus,
                    receipt: nil,
                    terminalPhase: committedTerminalPhase,
                    recoveryFinalization: .completed(recoveryCompletion.token),
                    requiresStartupRescan: true
                )
            } else if case .staleOrMissing = resolution {
                claimedDraftRecoveryTokens.remove(recoveryCompletion.token)
                await recoverJournalAtStartup(
                    terminalPhaseWhenClean: draftRecoveryTerminalPhaseWhenClean
                )
            } else {
                finalizeDraftRecoveryCandidate(recoveryCompletion.token)
                phase = committedTerminalPhase
                if committedTerminalPhase == .ready { queue.resume() }
            }
            return journalStatus
        }
        let journalResolution = if case .forward = completion, let journal, let draftReceipt {
            await DraftJournalCoordinator.recordAndClear(draftReceipt, journal: journal)
        } else { DraftRecoveryJournalResolution.clean }
        let journalStatus = journalResolution.journalStatus
        if case .cleanupPending = journalResolution {
            parkJournalCleanup(journalStatus, receipt: draftReceipt)
        } else if case .staleOrMissing = journalResolution {
            await recoverJournalAtStartup()
        }
        return journalStatus
    }

    /// A definite failure cannot leave callers guessing.  External adoption
    /// and repair have deliberately different terminal ownership: repair
    /// keeps its inspected candidate for another repair attempt, while an
    /// adoption requires the source to be read again before any ordinary
    /// command may proceed.
    private func finishNotCommittedSave(
        completion: SaveCompletion,
        draftReceipt: PersistedDraftReceipt?,
        artifacts: WorkspacePendingCommitArtifacts
    ) async -> JournalResolutionStatus {
        if case let .draftRecovery(recoveryCompletion, _, failurePhase, _) = completion,
           let journal {
            let resolution = await DraftJournalCoordinator.abandonRecovery(recoveryCompletion, journal: journal)
            let journalStatus = resolution.journalStatus
            if case .cleanupPending = resolution {
                parkJournalCleanup(
                    journalStatus,
                    receipt: nil,
                    terminalPhase: failurePhase,
                    recoveryFinalization: .abandoned(recoveryCompletion.token),
                    requiresStartupRescan: true
                )
                return journalStatus
            }
            claimedDraftRecoveryTokens.remove(recoveryCompletion.token)
            if case .staleOrMissing = resolution {
                await recoverJournalAtStartup(
                    terminalPhaseWhenClean: draftRecoveryTerminalPhaseWhenClean
                )
            } else {
                phase = failurePhase
            }
            return .clean
        }
        let journalResolution = await unbindIfNeeded(draftReceipt)
        let journalStatus = journalResolution.journalStatus
        if case .cleanupPending = journalResolution {
            parkJournalCleanup(
                journalStatus, receipt: draftReceipt, terminalPhase: completion.notCommittedTerminalPhase
            )
            return journalStatus
        }
        if case .staleOrMissing = journalResolution {
            await recoverJournalAtStartup(
                terminalPhaseWhenClean: completion.notCommittedTerminalPhase
            )
            return .clean
        }
        applyNotCommittedTerminal(completion: completion, artifacts: artifacts)
        return .clean
    }

    private func applyNotCommittedTerminal(
        completion: SaveCompletion,
        artifacts: WorkspacePendingCommitArtifacts
    ) {
        switch completion {
        case .externalRepair, .draftRecoveryRepair:
            phase = .needsRelationshipRepair
            queue.terminateQueued { transactionID in
                .notCommitted(transactionID: transactionID, journal: .clean, artifacts: artifacts)
            }
        case .externalAdoption:
            phase = .externalSourceChanged(.externalBytesChanged)
            terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
        case let .draftRecovery(_, _, failurePhase, _):
            phase = failurePhase
        case .forward, .undo:
            phase = .ready
        }
    }

    private func repositoryReportsUnreadablePrimary() async -> Bool {
        do {
            if case .unreadableUnknown = try await repository.reloadCurrentSourceAfterExternalChange() {
                return true
            }
        } catch {
            // The original save error is the authoritative result when the
            // verification probe itself cannot establish unreadability.
        }
        return false
    }

    private func finishUnreadablePrimarySave(
        _ draftReceipt: PersistedDraftReceipt?
    ) async -> JournalResolutionStatus {
        let journalResolution = await unbindIfNeeded(draftReceipt)
        let journalStatus = journalResolution.journalStatus
        let terminalPhase = WorkspaceStorePhase.unreadablePrimaryLoadFailed
        if case .cleanupPending = journalResolution {
            parkJournalCleanup(journalStatus, receipt: draftReceipt, terminalPhase: terminalPhase)
        } else if case .staleOrMissing = journalResolution {
            await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhase)
        } else {
            phase = terminalPhase
        }
        terminateQueuedForPersistenceBlock(reason: .unreadablePrimary)
        return journalStatus
    }

    /// A recovery completion marker is written before the main-file save.
    /// If the repository then rejects the save before any write can begin,
    /// reopen only that exact marker. A failed reopen is durable cleanup work;
    /// a stale marker requires a full truth rescan.
    private func finishRejectedRecoverySave(
        completion: SaveCompletion
    ) async -> JournalResolutionStatus {
        guard case let .draftRecovery(recoveryCompletion, _, failurePhase, _) = completion,
              let journal
        else { return .clean }
        let resolution = await DraftJournalCoordinator.abandonRecovery(
            recoveryCompletion,
            journal: journal
        )
        let journalStatus = resolution.journalStatus
        if case .cleanupPending = resolution {
            parkJournalCleanup(
                journalStatus,
                receipt: nil,
                terminalPhase: failurePhase,
                recoveryFinalization: .abandoned(recoveryCompletion.token),
                requiresStartupRescan: true
            )
            return journalStatus
        }

        claimedDraftRecoveryTokens.remove(recoveryCompletion.token)
        if case .staleOrMissing = resolution {
            await recoverJournalAtStartup(
                terminalPhaseWhenClean: draftRecoveryTerminalPhaseWhenClean
            )
        } else {
            phase = failurePhase
        }
        recoveryResolutionQueueOpen = claimedDraftRecoveryTokens.isEmpty == false
        if recoveryResolutionQueueOpen { queue.resume() }
        return .clean
    }

    private func finishSourceChangedSave(
        completion: SaveCompletion,
        draftReceipt: PersistedDraftReceipt?,
        artifacts: WorkspacePendingCommitArtifacts
    ) async -> JournalResolutionStatus {
        if case let .draftRecovery(recoveryCompletion, _, _, _) = completion,
           let journal {
            let resolution = await DraftJournalCoordinator.abandonRecovery(recoveryCompletion, journal: journal)
            let journalStatus = resolution.journalStatus
            if case .cleanupPending = resolution {
                parkJournalCleanup(
                    journalStatus,
                    receipt: nil,
                    terminalPhase: .externalSourceChanged(.externalBytesChanged),
                    recoveryFinalization: .abandoned(recoveryCompletion.token),
                    requiresStartupRescan: true
                )
            } else if case .staleOrMissing = resolution {
                claimedDraftRecoveryTokens.remove(recoveryCompletion.token)
                await recoverJournalAtStartup(
                    terminalPhaseWhenClean: .externalSourceChanged(.externalBytesChanged)
                )
            } else {
                claimedDraftRecoveryTokens.remove(recoveryCompletion.token)
                phase = completion.sourceChangedTerminalPhase
            }
            terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
            return journalStatus
        }
        let journalResolution = await unbindIfNeeded(draftReceipt)
        let journalStatus = journalResolution.journalStatus
        let terminalPhase = completion.sourceChangedTerminalPhase
        if case .cleanupPending = journalResolution {
            parkJournalCleanup(journalStatus, receipt: draftReceipt, terminalPhase: terminalPhase)
        } else if case .staleOrMissing = journalResolution {
            await recoverJournalAtStartup(terminalPhaseWhenClean: terminalPhase)
        } else {
            phase = terminalPhase
        }
        terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
        return journalStatus
    }

    private func finishSourceChangedRestore(
        artifacts: WorkspacePendingCommitArtifacts
    ) async -> JournalResolutionStatus {
        let terminalPhase = WorkspaceStorePhase.externalSourceChanged(.externalBytesChanged)
        phase = terminalPhase
        terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
        return .clean
    }

    private func reconcileImmediately(
        transactionID: UUID,
        candidate: WorkspaceState,
        draftReceipt: PersistedDraftReceipt?,
        completion: SaveCompletion
    ) async throws -> WorkspaceTransactionOutcome {
        switch try await repository.reconcilePendingCommit() {
        case let .committed(.save(receipt)):
            let journalStatus = await finishCommittedSave(
                candidate: candidate, completion: completion, draftReceipt: draftReceipt
            )
            return .committed(receipt, journal: journalStatus)
        case .committed(.restore):
            throw WorkspaceStoreError.frozen
        case let .notCommitted(artifacts):
            let journalStatus = await finishNotCommittedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: artifacts
            )
            return .notCommitted(transactionID: transactionID, journal: journalStatus, artifacts: artifacts)
        case let .sourceChanged(artifacts):
            let cleanup = await finishSourceChangedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: artifacts
            )
            return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: cleanup, artifacts: artifacts)
        case let .stillPending(artifacts):
            parkedSave = .init(
                transactionID: transactionID, candidate: candidate, draftReceipt: draftReceipt, completion: completion
            )
            phase = .parkedCommitUncertain(transactionID)
            return .commitPending(transactionID: transactionID, artifacts: artifacts)
        }
    }

    private func performUndo(
        record: WorkspaceStoreUndoRecord,
        transactionID: UUID,
        undo: Bool
    ) async throws -> WorkspaceTransactionOutcome {
        phase = .mutating
        defer { if phase == .mutating { phase = .ready } }
        let application = try WorkspaceUndoReducer.apply(
            record, direction: undo ? .undo : .redo, to: state,
            noteRevisionHighWatermarks: noteRevisionHighWatermarks
        )
        return try await persistSave(
            candidate: application.candidate,
            draftContext: nil,
            draftReceipt: nil,
            completion: .undo(
                undo: undo, reverseRecord: application.reverseRecord, ledger: application.noteRevisionHighWatermarks
            ),
            transactionID: transactionID
        )
    }

    private func performExternalRepair(
        payload: WorkspaceConsistencyRepairPayload,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        guard let external = pendingExternalRepairState else { throw WorkspaceStoreError.frozen }
        let preservesDraftRecovery = requiresJournalReconciliation
        let repairPhase: WorkspaceStorePhase = preservesDraftRecovery
            ? .reconcilingDraftRecovery
            : .mutating
        phase = repairPhase
        defer {
            if phase == repairPhase {
                phase = .needsRelationshipRepair
            }
        }
        _ = clock()
        let reduction = try WorkspaceReducer.reduce(external, command: .repairConsistency(payload), now: .distantPast)
        switch reduction {
        case let .noChange(reason):
            return .noChange(reason, journal: .clean)
        case let .conflict(conflict):
            return .conflict(conflict)
        case let .changed(change):
            let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
                current: state,
                external: change.state,
                sessionNoteHighWatermarks: noteRevisionHighWatermarks
            )
            guard adoption.consistencyIssues.isEmpty else { throw WorkspaceStoreError.frozen }
            let outcome = try await persistSave(
                candidate: adoption.candidate,
                draftContext: nil,
                draftReceipt: nil,
                completion: preservesDraftRecovery
                    ? .draftRecoveryRepair(ledger: adoption.noteRevisionHighWatermarks)
                    : .externalRepair(ledger: adoption.noteRevisionHighWatermarks),
                transactionID: transactionID
            )
            if case .committed = outcome, preservesDraftRecovery == false { phase = .ready }
            return outcome
        }
    }

    private func performExternalAdoption(
        candidate: WorkspaceState,
        ledger: [NoteID: Int64],
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        let adoptionPhase: WorkspaceStorePhase = requiresJournalReconciliation
            ? .reconcilingDraftRecovery
            : .mutating
        phase = adoptionPhase
        defer { if phase == adoptionPhase { phase = .ready } }
        _ = clock()
        let outcome = try await persistSave(
            candidate: candidate,
            draftContext: nil,
            draftReceipt: nil,
            completion: .externalAdoption(ledger: ledger),
            transactionID: transactionID
        )
        if case .committed = outcome {
            if requiresJournalReconciliation == false { phase = .ready }
            await recoverJournalAtStartup()
        }
        return outcome
    }

    private func performRestore(
        preview: WorkspaceRestorePreview,
        rollbackDirectoryURL: URL,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        phase = .mutating
        defer { if phase == .mutating { phase = .ready } }
        let payload = WorkspaceRestoreContentPayload(
            content: .init(state: preview.loadResult.state),
            sourceRevisionHighWatermark: preview.loadResult.state.revision,
            sourceNoteRevisions: preview.sourceNoteRevisions
        )
        let reduction = try WorkspaceReducer.reduce(state, command: .restoreContent(payload), now: clock())
        switch reduction {
        case let .noChange(reason):
            return .noChange(reason, journal: .clean)
        case let .conflict(conflict):
            return .conflict(conflict)
        case let .changed(change):
            let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: rollbackDirectoryURL)
            do {
                let outcome = try await repository.commitRestore(prepared, state: change.state)
                state = change.state
                undoStack.removeAll()
                redoStack.removeAll()
                mergeSessionNoteLedger(with: change.state)
                pendingExternalRepairState = nil
                hasRawRecoverySource = false
                updateUndoAvailability()
                return .restored(outcome)
            } catch let failure as WorkspaceDirectCommitFailure {
                _ = await repository.discardPreparedRestore(prepared)
                let artifacts: WorkspacePendingCommitArtifacts
                switch failure { case let .sourceChanged(value): artifacts = value }
                phase = .externalSourceChanged(.externalBytesChanged)
                terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
                return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: .clean, artifacts: artifacts)
            } catch WorkspacePersistenceError.commitUncertain {
                switch try await repository.reconcilePendingCommit() {
                case let .committed(.restore(outcome)):
                    state = change.state
                    undoStack.removeAll(); redoStack.removeAll(); updateUndoAvailability()
                    mergeSessionNoteLedger(with: change.state)
                    pendingExternalRepairState = nil
                    hasRawRecoverySource = false
                    return .restored(outcome)
                case let .notCommitted(artifacts):
                    _ = await repository.discardPreparedRestore(prepared)
                    return .notCommitted(transactionID: transactionID, journal: .clean, artifacts: artifacts)
                case let .sourceChanged(artifacts):
                    _ = await repository.discardPreparedRestore(prepared)
                    phase = .externalSourceChanged(.externalBytesChanged)
                    terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
                    return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: .clean, artifacts: artifacts)
                case let .stillPending(artifacts):
                    parkedRestore = .init(transactionID: transactionID, candidate: change.state, prepared: prepared)
                    phase = .parkedCommitUncertain(transactionID)
                    return .commitPending(transactionID: transactionID, artifacts: artifacts)
                case .committed(.save):
                    throw WorkspaceStoreError.frozen
                }
            } catch {
                _ = await repository.discardPreparedRestore(prepared)
                throw error
            }
        }
    }

    private func normalized(command: WorkspaceCommand) -> WorkspaceCommand {
        guard case let .calendar(.updateItem(item)) = command,
              let current = state.calendar.items[item.id]
        else { return command }
        var latest = item
        latest.completedAt = current.completedAt
        return .calendar(.updateItem(latest))
    }

    private func applyingSessionNoteRevisions(to reduction: WorkspaceReduction) throws -> WorkspaceReduction {
        var candidate = reduction.state
        var draftContext = reduction.draftContext
        for id in reduction.changedNoteIDs {
            guard var note = candidate.notes[id] else { continue }
            let highWatermark = max(
                noteRevisionHighWatermarks[id] ?? 0,
                state.notes[id]?.revision ?? 0
            )
            guard highWatermark < Int64.max else { throw WorkspaceReducerError.revisionOverflow }
            let nextRevision = highWatermark + 1
            guard nextRevision <= candidate.revision else { throw WorkspaceReducerError.revisionOverflow }
            note.revision = nextRevision
            candidate.notes[id] = note
            if let context = draftContext, context.noteID == id {
                draftContext = .init(
                    noteID: note.id,
                    editSessionID: context.editSessionID,
                    draftGeneration: context.draftGeneration,
                    noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
                    persistedNoteRevision: note.revision
                )
            }
        }
        return .init(
            state: candidate,
            changedNoteIDs: reduction.changedNoteIDs,
            draftContext: draftContext,
            seriesOutcome: reduction.seriesOutcome
        )
    }

    private func mergeSessionNoteLedger(with next: WorkspaceState) {
        for (id, note) in next.notes {
            noteRevisionHighWatermarks[id] = max(noteRevisionHighWatermarks[id] ?? 0, note.revision)
        }
    }

    private func rebasedDraftCommand(_ command: WorkspaceCommand) throws -> WorkspaceCommand {
        guard case let .updateNote(submission) = command else { return command }
        let identity = DraftJournalIdentity(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID))
        guard let previous = acceptedDraftGenerations[identity],
              submission.draftGeneration > previous.generation,
              let latest = state.notes[submission.noteID]
        else { return command }
        do {
            let result = try NoteDraftSequenceRebasePlanner.plan(
                previousAccepted: previous.accepted, next: submission, latest: latest
            )
            var rebasedModifiedFields = Set<NoteDraftField>()
            if result.rebasedBase.title != result.rebasedSnapshot.title { rebasedModifiedFields.insert(.title) }
            if result.rebasedBase.document != result.rebasedSnapshot.document { rebasedModifiedFields.insert(.document) }
            if result.rebasedBase.categoryID != result.rebasedSnapshot.categoryID { rebasedModifiedFields.insert(.categoryID) }
            if result.rebasedBase.archivedAt != result.rebasedSnapshot.archivedAt { rebasedModifiedFields.insert(.archivedAt) }
            let rebased = NoteDraftSubmission(
                noteID: submission.noteID,
                editSessionID: submission.editSessionID,
                baseNoteRevision: result.rebasedBase.revision,
                baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(result.rebasedBase),
                baseSnapshot: result.rebasedBase,
                baseLinkedTaskBlockLinks: submission.baseLinkedTaskBlockLinks,
                draftGeneration: submission.draftGeneration,
                snapshot: result.rebasedSnapshot,
                noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(result.rebasedSnapshot),
                modifiedFields: rebasedModifiedFields,
                linkedBlockDeletionDispositions: submission.linkedBlockDeletionDispositions
            )
            return .updateNote(rebased)
        } catch NoteDraftSequenceRebaseError.conflict {
            return command
        }
    }

    private func acceptedDraft(command: WorkspaceCommand, candidate: WorkspaceState) -> AcceptedDraftGeneration? {
        guard case let .updateNote(submission) = command,
              let finalNote = candidate.notes[submission.noteID]
        else { return nil }
        return .init(
            identity: .init(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID)),
            generation: submission.draftGeneration,
            accepted: .init(base: submission.baseSnapshot, accepted: finalNote, modifiedFields: submission.modifiedFields)
        )
    }

    private func remember(_ accepted: AcceptedDraftGeneration?) {
        guard let accepted else { return }
        if let current = acceptedDraftGenerations[accepted.identity], current.generation > accepted.generation { return }
        acceptedDraftGenerations[accepted.identity] = accepted
    }

    private func publish(_ next: WorkspaceState, undoRecord: WorkspaceStoreUndoRecord?) {
        state = next
        for (id, note) in next.notes { noteRevisionHighWatermarks[id] = max(noteRevisionHighWatermarks[id] ?? 0, note.revision) }
        if let undoRecord { undoStack.append(undoRecord); redoStack.removeAll() }
        updateUndoAvailability()
    }

    private func updateUndoAvailability() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    private func enqueueTransaction(
        _ operation: @escaping WorkspaceTransactionQueue.Operation
    ) async throws -> WorkspaceTransactionOutcome {
        defer { resumeJournalProtectionWaiters() }
        return try await queue.enqueue(operation) { [weak self] in
            guard let self else { return true }
            if self.recoveryResolutionQueueOpen,
               self.claimedDraftRecoveryTokens.isEmpty == false,
               self.phase.isDraftRecovery {
                return false
            }
            return self.phase.blocksQueuedDrainAfterFailure
        }
    }

    private func waitForCurrentTransactionJournalResolution() async {
        await withCheckedContinuation { continuation in
            journalProtectionWaiters.append(continuation)
        }
    }

    private func resumeJournalProtectionWaiters() {
        let waiters = journalProtectionWaiters
        journalProtectionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func terminateQueuedForExternal(
        reason: WorkspaceExternalSourceChangeReason,
        artifacts: WorkspacePendingCommitArtifacts
    ) {
        claimedDraftRecoveryTokens.removeAll()
        recoveryResolutionQueueOpen = false
        queue.terminateQueued { transactionID in
            .externalSourceChanged(
                transactionID: transactionID, reason: reason, journal: .clean, artifacts: artifacts
            )
        }
    }

    private func terminateQueuedForPersistenceBlock(reason: WorkspacePersistenceBlockReason) {
        claimedDraftRecoveryTokens.removeAll()
        recoveryResolutionQueueOpen = false
        queue.terminateQueued { transactionID in
            .persistenceBlocked(transactionID: transactionID, reason: reason, journal: .clean)
        }
    }

    private func ensureOrdinaryMutationAllowed() throws {
        switch phase {
        case .ready, .mutating:
            return
        default:
            throw WorkspaceStoreError.frozen
        }
    }

    private var allowsDraftRecoveryResolution: Bool {
        switch phase {
        case .needsDraftRecovery:
            true
        case .resolvingDraftRecovery:
            recoveryResolutionQueueOpen
        case .notLoaded, .loading, .ready, .mutating, .reconcilingDraftRecovery, .parkedCommitUncertain,
             .parkedJournalCleanup, .needsRelationshipRepair, .externalSourceChanged,
             .opaquePrimaryLoadFailed, .unreadablePrimaryLoadFailed, .loadFailed:
            false
        }
    }

    private func draftRecoveryTerminalPhase(
        afterResolving token: DraftRecoveryToken,
        from candidates: [DraftRecoveryCandidate]
    ) -> WorkspaceStorePhase {
        let remaining = candidates.filter { $0.token != token }
        return remaining.isEmpty
            ? draftRecoveryTerminalPhaseWhenClean
            : .needsDraftRecovery(remaining)
    }

    private func finalizeDraftRecoveryCandidate(_ token: DraftRecoveryToken) {
        draftRecoveryCandidates.removeAll { $0.token == token }
        claimedDraftRecoveryTokens.remove(token)
        recoveryResolutionQueueOpen = false
    }

    private func performDraftRecovery(
        _ recovery: DraftRecoveryCandidate,
        action: DraftRecoveryAction,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        guard claimedDraftRecoveryTokens.contains(recovery.token),
              let journal
        else { return .draftSuperseded }
        let candidates = draftRecoveryCandidates
        let terminalPhase = draftRecoveryTerminalPhase(afterResolving: recovery.token, from: candidates)
        switch action {
        case .keepPersisted:
            let undoRecord = (try? recoveredCurrentState(
                from: recovery,
                entersRelationshipRepairOnFailure: false
            )).flatMap {
                WorkspaceUndoReducer.record(
                    before: $0,
                    after: state,
                    label: Self.recoveryUndoLabel
                )
            }
            let resolution = await DraftJournalCoordinator.discardRecovery(recovery.token, journal: journal)
            if case .staleOrMissing = resolution {
                claimedDraftRecoveryTokens.remove(recovery.token)
                await recoverJournalAtStartup(
                    terminalPhaseWhenClean: draftRecoveryTerminalPhaseWhenClean
                )
                return .draftSuperseded
            }
            let status = resolution.journalStatus
            if case .cleanupPending = resolution {
                parkJournalCleanup(
                    status,
                    receipt: nil,
                    terminalPhase: terminalPhase,
                    recoveryFinalization: .completed(recovery.token),
                    requiresStartupRescan: true
                )
            } else {
                finalizeDraftRecoveryCandidate(recovery.token)
                phase = terminalPhase
            }
            publish(state, undoRecord: undoRecord)
            recoveryResolutionQueueOpen = false
            return .noChange(.identical, journal: status)

        case .restoreAsCurrent, .saveAsNew:
            let candidate: WorkspaceState
            let completionAction: DraftRecoveryCompletionAction
            let resultNoteID: NoteID
            let completion: DraftRecoveryCompletion
            let undoRecord: WorkspaceStoreUndoRecord?
            do {
                switch action {
                case .restoreAsCurrent:
                    candidate = try recoveredCurrentState(from: recovery)
                    completionAction = .restoreAsCurrent
                    resultNoteID = recovery.token.identityAndGeneration.identity.noteID
                case let .saveAsNew(noteID, blockIDs):
                    candidate = try recoveredNewNoteState(from: recovery, noteID: noteID, blockIDs: blockIDs)
                    completionAction = .saveAsNew
                    resultNoteID = noteID
                case .keepPersisted:
                    fatalError("covered above")
                }
                undoRecord = WorkspaceUndoReducer.record(
                    before: state,
                    after: candidate,
                    label: Self.recoveryUndoLabel
                )
                completion = try recoveryCompletion(
                    token: recovery.token,
                    action: completionAction,
                    candidate: candidate,
                    resultNoteID: resultNoteID
                )
                guard try await journal.beginRecoveryCompletion(completion) == .applied else {
                    claimedDraftRecoveryTokens.remove(recovery.token)
                    await recoverJournalAtStartup(
                        terminalPhaseWhenClean: draftRecoveryTerminalPhaseWhenClean
                    )
                    return .draftSuperseded
                }
            } catch {
                claimedDraftRecoveryTokens.remove(recovery.token)
                throw error
            }
            phase = .resolvingDraftRecovery
            defer {
                if phase == .resolvingDraftRecovery {
                    claimedDraftRecoveryTokens.remove(recovery.token)
                    recoveryResolutionQueueOpen = false
                    phase = .needsDraftRecovery(draftRecoveryCandidates)
                }
            }
            let outcome = try await persistSave(
                candidate: candidate,
                draftContext: nil,
                draftReceipt: nil,
                completion: .draftRecovery(
                    completion: completion,
                    terminalPhase: terminalPhase,
                    failurePhase: .needsDraftRecovery(candidates),
                    undoRecord: undoRecord
                ),
                transactionID: transactionID
            )
            if phase != .resolvingDraftRecovery { recoveryResolutionQueueOpen = false }
            return outcome
        }
    }

    private func recoveryCompletion(
        token: DraftRecoveryToken,
        action: DraftRecoveryCompletionAction,
        candidate: WorkspaceState,
        resultNoteID: NoteID
    ) throws -> DraftRecoveryCompletion {
        guard let note = candidate.notes[resultNoteID] else { throw WorkspaceStoreError.frozen }
        return .init(
            token: token,
            action: action,
            source: try DraftJournal.recoverySourceIdentity(for: state),
            result: .init(
                noteID: note.id,
                noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
                noteRevision: note.revision,
                workspaceRevision: candidate.revision
            ),
            state: .pending
        )
    }

    private func recoveredCurrentState(
        from recovery: DraftRecoveryCandidate,
        entersRelationshipRepairOnFailure: Bool = true
    ) throws -> WorkspaceState {
        // Relationship repair always begins from the current persisted graph.
        // Do not place any reviewed draft bytes into that repair candidate:
        // the user must separately and explicitly choose a later restore.
        guard state.calendar.categories[recovery.draft.categoryID] != nil else {
            if entersRelationshipRepairOnFailure { enterDraftRecoveryRelationshipRepair() }
            throw WorkspaceStoreError.frozen
        }
        let sourceLinks = state.taskBlockLinks.filter { $0.noteID == recovery.draft.id }
        for link in sourceLinks {
            guard state.calendar.items[link.calendarItemID] != nil else {
                if entersRelationshipRepairOnFailure { enterDraftRecoveryRelationshipRepair() }
                throw WorkspaceStoreError.frozen
            }
        }

        var candidate = state
        var restored = recovery.draft
        guard candidate.revision < Int64.max else { throw WorkspaceReducerError.revisionOverflow }
        candidate.revision += 1
        if let current = candidate.notes[restored.id] {
            restored.createdAt = current.createdAt
        }
        restored.revision = candidate.revision
        restored.updatedAt = clock()
        candidate.notes[restored.id] = restored

        let links = candidate.taskBlockLinks.filter { $0.noteID == restored.id }
        for link in links {
            guard var item = candidate.calendar.items[link.calendarItemID] else {
                if entersRelationshipRepairOnFailure { enterDraftRecoveryRelationshipRepair() }
                throw WorkspaceStoreError.frozen
            }
            guard let index = restored.document.blocks.firstIndex(where: {
                $0.id == link.blockID && $0.kind == .task
            }) else {
                candidate.taskBlockLinks.remove(link)
                continue
            }
            restored.document.blocks[index].taskState?.completedAt = item.completedAt
            // Restoring a reviewed draft is the same title ownership rule as
            // an ordinary note edit. Completion remains calendar-authoritative.
            let restoredTitle = TaskBlockCalendarTitle.normalized(
                restored.document.blocks[index].inlineContent.spans.map(\.text).joined()
            )
            if item.title != restoredTitle {
                item.title = restoredTitle
                item.updatedAt = restored.updatedAt
                candidate.calendar.items[item.id] = item
            }
        }
        candidate.notes[restored.id] = restored
        do {
            try WorkspaceValidator.validate(candidate)
        } catch {
            if entersRelationshipRepairOnFailure { enterDraftRecoveryRelationshipRepair() }
            throw WorkspaceStoreError.frozen
        }
        return candidate
    }

    private func enterDraftRecoveryRelationshipRepair() {
        requiresJournalReconciliation = true
        pendingExternalRepairState = state
        claimedDraftRecoveryTokens.removeAll()
        recoveryResolutionQueueOpen = false
        phase = .needsRelationshipRepair
    }

    private func recoveredNewNoteState(
        from recovery: DraftRecoveryCandidate,
        noteID: NoteID,
        blockIDs: [BlockID]
    ) throws -> WorkspaceState {
        let sourceIDs = recovery.draft.document.blocks.map(\.id)
        let allExistingBlockIDs = Set(state.notes.values.flatMap { $0.document.blocks.map(\.id) })
        guard state.notes[noteID] == nil,
              blockIDs.count == sourceIDs.count,
              Set(blockIDs).count == blockIDs.count,
              Set(sourceIDs).isDisjoint(with: Set(blockIDs)),
              allExistingBlockIDs.isDisjoint(with: Set(blockIDs))
        else { throw WorkspaceStoreError.frozen }
        var document = recovery.draft.document
        document.blocks = zip(document.blocks, blockIDs).map { block, id in
            .init(
                id: id,
                kind: block.kind,
                inlineContent: block.inlineContent,
                taskState: block.taskState,
                indentLevel: block.indentLevel,
                codeInfoString: block.codeInfoString
            )
        }
        let now = clock()
        let created = Note(
            id: noteID,
            title: recovery.draft.title,
            document: document,
            categoryID: recovery.draft.categoryID,
            archivedAt: nil,
            revision: 0,
            createdAt: now,
            updatedAt: now
        )
        switch try WorkspaceReducer.reduce(state, command: .createNote(.init(note: created)), now: now) {
        case let .changed(change):
            return change.state
        case .noChange, .conflict:
            throw WorkspaceStoreError.frozen
        }
    }
}

private extension WorkspaceStorePhase {
    var isExternalSourceChanged: Bool {
        if case .externalSourceChanged = self { return true }
        return false
    }

    var blocksQueuedDrainAfterFailure: Bool {
        switch self {
        case .ready:
            false
        case .mutating, .resolvingDraftRecovery, .reconcilingDraftRecovery:
            true
        default:
            true
        }
    }

    var allowsExternalReload: Bool {
        switch self {
        case .ready, .needsRelationshipRepair, .opaquePrimaryLoadFailed, .externalSourceChanged:
            true
        case .notLoaded, .loading, .mutating, .resolvingDraftRecovery, .reconcilingDraftRecovery, .parkedCommitUncertain, .parkedJournalCleanup,
             .needsDraftRecovery, .unreadablePrimaryLoadFailed, .loadFailed:
            false
        }
    }

    var isDraftRecovery: Bool {
        if case .needsDraftRecovery = self { return true }
        return false
    }
}
