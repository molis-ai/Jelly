import CalendarPersistence
import Foundation
import WorkspaceDomain

@MainActor
protocol NoteAutosaveScheduling: AnyObject {
    func sleep(milliseconds: UInt64) async throws
}

@MainActor
final class SystemNoteAutosaveScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(for: .milliseconds(Int64(milliseconds)))
    }
}

struct NoteAutosaveTriple: Hashable, Equatable, Sendable {
    let identityAndGeneration: DraftJournalIdentityAndGeneration
    let noteSnapshotChecksum: String

    init(submission: NoteDraftSubmission) {
        identityAndGeneration = .init(
            identity: .init(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID)),
            draftGeneration: submission.draftGeneration
        )
        noteSnapshotChecksum = submission.noteSnapshotChecksum
    }
}

enum NoteAutosaveBarrierEvidence: Equatable, Sendable {
    case clean
    case persisted(NoteAutosaveTriple)
    case protectedOnly(NoteAutosaveTriple)
    case unsafeLatestUnprotected
}

enum NoteAutosaveState: Equatable, Sendable {
    case editable
    case waitingToProtect(NoteAutosaveTriple)
    case protecting(NoteAutosaveTriple)
    case protected(NoteAutosaveTriple)
    case committing(NoteAutosaveTriple)
    case finalizingNativeInput(NoteNativeInputPermit)
    case nativeInputUnresolved(NoteAutosaveTriple)
    case sealed(NoteAutosaveTriple)
    case committed(NoteAutosaveTriple)
    case invalidPersistedReceipt(NoteAutosaveTriple)
    case restoredNotProof(NoteAutosaveTriple)
    case noChange(NoteAutosaveTriple)
    case conflict(NoteAutosaveTriple)
    case draftSuperseded(NoteAutosaveTriple)
    case commitPending(NoteAutosaveTriple, transactionID: UUID)
    case notCommitted(NoteAutosaveTriple)
    case externalSourceChanged(NoteAutosaveTriple)
    case persistenceBlocked(NoteAutosaveTriple)
    case cleanupPending(NoteAutosaveTriple, identity: DraftJournalIdentity, step: JournalCleanupStep)
    case mainSaveFailedProtected(NoteAutosaveTriple)
    case protectionFailed(NoteAutosaveTriple)
}

enum NoteAutosaveCoordinatorError: Error, Equatable, Sendable {
    case noActiveSession
    case editingIsSealed
    case staleNativeInputPermit
    case invalidDraft
}

struct NoteAutosaveOutcomeMapping: Equatable, Sendable {
    let state: NoteAutosaveState
    let evidence: NoteAutosaveBarrierEvidence

    static func workspace(
        _ outcome: WorkspaceTransactionOutcome,
        triple: NoteAutosaveTriple,
        hasDurableProtection: Bool
    ) -> Self {
        switch outcome {
        case let .committed(receipt, journal):
            guard receiptMatches(receipt, triple: triple) else {
                return .init(state: .invalidPersistedReceipt(triple), evidence: .unsafeLatestUnprotected)
            }
            if case let .cleanupPending(identity, step) = journal {
                return .init(
                    state: .cleanupPending(triple, identity: identity, step: step),
                    evidence: .persisted(triple)
                )
            }
            return .init(state: .committed(triple), evidence: .persisted(triple))
        case let .draftAlreadyPersisted(receipt, journal):
            guard receiptMatches(receipt, triple: triple) else {
                return .init(state: .invalidPersistedReceipt(triple), evidence: .unsafeLatestUnprotected)
            }
            if case let .cleanupPending(identity, step) = journal {
                return .init(
                    state: .cleanupPending(triple, identity: identity, step: step),
                    evidence: .persisted(triple)
                )
            }
            return .init(state: .noChange(triple), evidence: .persisted(triple))
        case .restored, .noChange:
            return .init(state: .noChange(triple), evidence: .unsafeLatestUnprotected)
        case .conflict:
            return .init(state: .conflict(triple), evidence: .unsafeLatestUnprotected)
        case .draftSuperseded:
            return .init(state: .draftSuperseded(triple), evidence: .unsafeLatestUnprotected)
        case let .commitPending(transactionID, _):
            return .init(
                state: .commitPending(triple, transactionID: transactionID),
                evidence: .unsafeLatestUnprotected
            )
        case let .notCommitted(_, journal, _):
            guard hasDurableProtection else {
                return .init(state: .protectionFailed(triple), evidence: .unsafeLatestUnprotected)
            }
            if case let .cleanupPending(identity, step) = journal {
                return .init(
                    state: .cleanupPending(triple, identity: identity, step: step),
                    evidence: .protectedOnly(triple)
                )
            }
            return .init(state: .mainSaveFailedProtected(triple), evidence: .protectedOnly(triple))
        case .externalSourceChanged:
            return .init(state: .externalSourceChanged(triple), evidence: .unsafeLatestUnprotected)
        case .persistenceBlocked:
            return .init(state: .persistenceBlocked(triple), evidence: .unsafeLatestUnprotected)
        }
    }

    static func retry(
        _ outcome: PendingCommitRetryOutcome,
        triple: NoteAutosaveTriple,
        hasDurableProtection: Bool
    ) -> Self {
        switch outcome {
        case let .committed(operation, journal):
            switch operation {
            case let .save(receipt):
                guard receiptMatches(receipt, triple: triple) else {
                    return .init(state: .invalidPersistedReceipt(triple), evidence: .unsafeLatestUnprotected)
                }
            case .restore:
                // Store restoration is unsafe evidence, but it is distinct
                // from a malformed save receipt.
                return .init(state: .restoredNotProof(triple), evidence: .unsafeLatestUnprotected)
            }
            if case let .cleanupPending(identity, step) = journal {
                return .init(
                    state: .cleanupPending(triple, identity: identity, step: step),
                    evidence: .persisted(triple)
                )
            }
            return .init(state: .committed(triple), evidence: .persisted(triple))
        case let .notCommitted(_, journal, _):
            return workspace(
                .notCommitted(transactionID: UUID(), journal: journal, artifacts: .init()),
                triple: triple,
                hasDurableProtection: hasDurableProtection
            )
        case .sourceChanged:
            return .init(state: .externalSourceChanged(triple), evidence: .unsafeLatestUnprotected)
        case let .stillPending(transactionID, _):
            return .init(
                state: .commitPending(triple, transactionID: transactionID),
                evidence: .unsafeLatestUnprotected
            )
        }
    }

    private static func receiptMatches(_ receipt: WorkspaceSaveReceipt, triple: NoteAutosaveTriple) -> Bool {
        guard let draft = receipt.persistedDraft else { return false }
        return receiptMatches(draft, triple: triple)
    }

    private static func receiptMatches(_ draft: PersistedDraftReceipt, triple: NoteAutosaveTriple) -> Bool {
        return draft.noteID == triple.identityAndGeneration.identity.noteID
            && draft.editSessionID == triple.identityAndGeneration.identity.editSessionID
            && draft.draftGeneration == triple.identityAndGeneration.draftGeneration
            && draft.noteSnapshotChecksum == triple.noteSnapshotChecksum
    }
}

struct NoteNativeInputPermit: Equatable, Sendable {
    let noteID: NoteID
    let editSessionID: UUID
    let activeHostToken: UUID
    fileprivate let nonce: UUID
}

struct NoteNativeInputEdit: Sendable {
    let title: String?
    let document: BlockDocument?
    let categoryID: UUID?
    let linkedBlockDeletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition]

    init(
        title: String? = nil,
        document: BlockDocument? = nil,
        categoryID: UUID? = nil,
        linkedBlockDeletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition] = [:]
    ) {
        self.title = title
        self.document = document
        self.categoryID = categoryID
        self.linkedBlockDeletionDispositions = linkedBlockDeletionDispositions
    }
}

typealias NoteNativeInputFinalizer = @MainActor (
    NoteNativeInputPermit,
    @escaping @MainActor (NoteNativeInputPermit, NoteNativeInputEdit) -> Bool
) async -> Bool

@MainActor
final class NoteAutosaveCoordinator {
    private enum ProtectionTerminal {
        case protected(ProtectedNoteDraft)
        case superseded
        case failed
    }

    private final class Operation {
        let submission: NoteDraftSubmission
        var protectTimer: Task<Void, Never>?
        var commitTimer: Task<Void, Never>?
        var protectTask: Task<ProtectionTerminal, Never>?
        var commitTask: Task<NoteAutosaveBarrierEvidence, Never>?
        var hasDurableProtection = false
        var terminalState: NoteAutosaveState?
        var terminalEvidence: NoteAutosaveBarrierEvidence?

        init(submission: NoteDraftSubmission) {
            self.submission = submission
        }
    }

    private final class FlushFlight {
        var task: Task<NoteAutosaveBarrierEvidence, Never>?
    }

    private struct Session {
        var baseSnapshot: Note
        var baseChecksum: String
        var baseLinkedTaskBlockLinks: Set<TaskBlockCalendarLink>
        let editSessionID: UUID
        var activeHostToken: UUID
        var draft: Note
        var nextGeneration: UInt64
        var linkedBlockDeletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition]
    }

    private let store: WorkspaceStore
    private let scheduler: any NoteAutosaveScheduling
    private var session: Session?
    private var latestSubmission: NoteDraftSubmission?
    private var operations: [NoteAutosaveTriple: Operation] = [:]
    private var retiredTerminalEvidence: [NoteAutosaveTriple: NoteAutosaveBarrierEvidence] = [:]
    private var activePermit: NoteNativeInputPermit?
    private var consumedPermitNonce: UUID?
    private var stateBeforeNativeFinalization: NoteAutosaveState?
    private var activeFlushFlight: FlushFlight?
    private(set) var autosaveState: NoteAutosaveState = .editable
    private(set) var latestEvidence: NoteAutosaveBarrierEvidence = .unsafeLatestUnprotected
    var currentEditSessionID: UUID? { session?.editSessionID }
    var currentNoteID: NoteID? { session?.baseSnapshot.id }
    var currentTriple: NoteAutosaveTriple? {
        latestSubmission.map(NoteAutosaveTriple.init(submission:))
    }
    var debugOperationCount: Int { operations.count }
    var currentSnapshotChecksum: String? { latestSubmission?.noteSnapshotChecksum }
    var canReplaceSessionWithPersistedStoreSnapshot: Bool {
        switch latestEvidence {
        case .clean:
            return currentTriple == nil
        case let .persisted(triple):
            return currentTriple == triple
        case .protectedOnly, .unsafeLatestUnprotected:
            return false
        }
    }
    var hasUnresolvedNativeInput: Bool {
        if case .nativeInputUnresolved = autosaveState { return true }
        return false
    }
    func terminalEvidence(for triple: NoteAutosaveTriple) -> NoteAutosaveBarrierEvidence? {
        operations[triple]?.terminalEvidence ?? retiredTerminalEvidence[triple]
    }
    var statusMessage: String? {
        autosaveState.statusMessage
    }

    init(store: WorkspaceStore, scheduler: any NoteAutosaveScheduling = SystemNoteAutosaveScheduler()) {
        self.store = store
        self.scheduler = scheduler
    }

    func beginSession(
        _ note: Note,
        linkedTaskBlockLinks: Set<TaskBlockCalendarLink>,
        editSessionID: UUID,
        activeHostToken: UUID
    ) throws {
        guard autosaveState.isEditableForNewSession else { throw NoteAutosaveCoordinatorError.editingIsSealed }
        let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
        session = .init(
            baseSnapshot: note,
            baseChecksum: checksum,
            baseLinkedTaskBlockLinks: linkedTaskBlockLinks,
            editSessionID: editSessionID,
            activeHostToken: activeHostToken,
            draft: note,
            nextGeneration: 0,
            linkedBlockDeletionDispositions: [:]
        )
        latestSubmission = nil
        latestEvidence = .clean
        autosaveState = .editable
        pruneOperations()
    }

    func update(
        title: String? = nil,
        document: BlockDocument? = nil,
        categoryID: UUID? = nil,
        linkedBlockDeletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition] = [:]
    ) throws -> NoteDraftSubmission {
        guard autosaveState.allowsOrdinaryEdit else { throw NoteAutosaveCoordinatorError.editingIsSealed }
        guard var session else { throw NoteAutosaveCoordinatorError.noActiveSession }
        session.nextGeneration &+= 1
        let previousBlockIDs = Set(session.draft.document.blocks.map(\.id))
        if let title { session.draft.title = title }
        if let document { session.draft.document = document }
        if let categoryID { session.draft.categoryID = categoryID }
        // Merge first so a same-update task→paragraph disposition is retained.
        // Only a restored *task*, or a block ID reintroduced after total removal,
        // may drop its deletion disposition. Converting a still-present linked
        // task into a paragraph must keep the disposition for the reducer.
        session.linkedBlockDeletionDispositions.merge(
            linkedBlockDeletionDispositions,
            uniquingKeysWith: { _, newest in newest }
        )
        if let document {
            let presentIDs = Set(document.blocks.map(\.id))
            let restoredTaskIDs = Set(document.blocks.compactMap { block in
                block.kind == .task ? block.id : nil
            })
            let reintroducedIDs = presentIDs.subtracting(previousBlockIDs)
            session.linkedBlockDeletionDispositions = session.linkedBlockDeletionDispositions.filter {
                !restoredTaskIDs.contains($0.key) && !reintroducedIDs.contains($0.key)
            }
        }
        let submission = try Self.makeSubmission(
            base: session.baseSnapshot,
            baseChecksum: session.baseChecksum,
            baseLinks: session.baseLinkedTaskBlockLinks,
            editSessionID: session.editSessionID,
            generation: session.nextGeneration,
            draft: session.draft,
            dispositions: session.linkedBlockDeletionDispositions
        )
        self.session = session
        let hadNoPendingSubmission = latestSubmission == nil
        if hadNoPendingSubmission,
           submission.modifiedFields.isEmpty,
           submission.linkedBlockDeletionDispositions.isEmpty {
            latestSubmission = nil
            latestEvidence = .clean
            autosaveState = .editable
            pruneOperations()
            cancelUnfiredTimers(for: .init(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID)))
            return submission
        }
        latestSubmission = submission
        latestEvidence = .unsafeLatestUnprotected
        pruneOperations()
        let triple = NoteAutosaveTriple(submission: submission)
        autosaveState = .waitingToProtect(triple)
        cancelUnfiredTimers(for: triple.identityAndGeneration.identity)
        scheduleTimers(for: submission)
        return submission
    }

    func updateActiveHostToken(_ token: UUID) throws {
        guard var session else { throw NoteAutosaveCoordinatorError.noActiveSession }
        session.activeHostToken = token
        self.session = session
    }

    /// A user explicitly abandoned the unresolved native composition. This is
    /// the only non-terminal path that may release the native-input veto.
    func cancelUnresolvedNativeInput() -> Bool {
        guard case .nativeInputUnresolved = autosaveState else { return false }
        autosaveState = .editable
        return true
    }

    func flushLatest(finalizer: NoteNativeInputFinalizer? = nil) async -> NoteAutosaveBarrierEvidence {
        if let task = activeFlushFlight?.task { return await task.value }
        let flight = FlushFlight()
        let task = Task { @MainActor [weak self, weak flight] () -> NoteAutosaveBarrierEvidence in
            guard let self else { return .unsafeLatestUnprotected }
            let evidence = await self.performFlushLatest(finalizer: finalizer)
            if self.activeFlushFlight === flight { self.activeFlushFlight = nil }
            return evidence
        }
        flight.task = task
        activeFlushFlight = flight
        return await task.value
    }

    /// Switching workspace tabs does not destroy the mounted Notes module. It
    /// only needs to settle native composition into the in-memory draft; the
    /// main-file save continues in background. Protection starts immediately
    /// so a fast switch followed by termination is still recoverable, without
    /// making the route transition wait on disk I/O.
    func finalizeNativeInputForRoute(_ finalizer: NoteNativeInputFinalizer?) async -> Bool {
        guard await finalizeNativeInputIfNeeded(finalizer) else { return false }
        guard let submission = latestSubmission else {
            latestEvidence = .clean
            return true
        }
        let triple = NoteAutosaveTriple(submission: submission)
        let operation = operation(for: submission)
        _ = startProtection(for: triple, operation: operation)
        return true
    }

    private func performFlushLatest(
        finalizer: NoteNativeInputFinalizer?
    ) async -> NoteAutosaveBarrierEvidence {
        guard await finalizeNativeInputIfNeeded(finalizer) else {
            latestEvidence = .unsafeLatestUnprotected
            return latestEvidence
        }
        guard latestSubmission != nil else {
            latestEvidence = .clean
            return .clean
        }
        return await flushCurrentTriple(successorLoopsRemaining: 1)
    }

    /// A caller may arrive while an older exact Store operation is already
    /// suspended. Its result is still truthful for that old triple, but it
    /// cannot authorize a lifecycle transition after a newer generation
    /// exists. We drain that old operation, then make exactly one linearized
    /// attempt at the latest successor; further churn fails closed.
    private func flushCurrentTriple(
        successorLoopsRemaining: Int
    ) async -> NoteAutosaveBarrierEvidence {
        guard !autosaveState.blocksSuccessorSubmission else { return latestEvidence }
        guard let submission = latestSubmission else { return .unsafeLatestUnprotected }
        let triple = NoteAutosaveTriple(submission: submission)
        let operation = operation(for: submission)
        let evidence: NoteAutosaveBarrierEvidence
        // A later lifecycle caller must observe the original operation's
        // terminal state, rather than overwriting it with a synthetic sealed
        // state after the operation has already become protected/pending/etc.
        if let terminal = operation.terminalEvidence, operation.terminalState != nil {
            evidence = terminal
        } else if let task = operation.commitTask {
            evidence = await task.value
        } else {
            autosaveState = .sealed(triple)
            operation.protectTimer?.cancel()
            operation.commitTimer?.cancel()
            operation.protectTimer = nil
            operation.commitTimer = nil
            evidence = await startCommit(for: triple, operation: operation).value
        }

        guard currentTriple != triple else { return evidence }
        guard successorLoopsRemaining > 0 else { return .unsafeLatestUnprotected }
        return await flushCurrentTriple(successorLoopsRemaining: successorLoopsRemaining - 1)
    }

    func acceptNativeInput(_ permit: NoteNativeInputPermit, edit: NoteNativeInputEdit) -> Bool {
        guard activePermit == permit,
              consumedPermitNonce != permit.nonce,
              let session,
              session.baseSnapshot.id == permit.noteID,
              session.editSessionID == permit.editSessionID,
              session.activeHostToken == permit.activeHostToken
        else { return false }
        consumedPermitNonce = permit.nonce
        activePermit = nil
        let changesDraft = edit.title.map { $0 != session.draft.title } == true
            || edit.document.map { $0 != session.draft.document } == true
            || edit.categoryID.map { $0 != session.draft.categoryID } == true
            || !edit.linkedBlockDeletionDispositions.isEmpty
        // An identical native snapshot is a legal no-op. Leave
        // `finalizingNativeInput` in place so the caller restores the exact
        // pre-finalization state, including cleanupPending / commitPending.
        guard changesDraft else { return true }
        let previous = stateBeforeNativeFinalization ?? autosaveState
        // A real successor must not pass through `.editable` to dodge a
        // read-only safety gate that was already in force.
        guard previous.allowsOrdinaryEdit else { return false }
        autosaveState = .editable
        return (try? update(
            title: edit.title,
            document: edit.document,
            categoryID: edit.categoryID,
            linkedBlockDeletionDispositions: edit.linkedBlockDeletionDispositions
        )) != nil
    }

    func retryLatest() async -> NoteAutosaveBarrierEvidence {
        switch autosaveState {
        case let .commitPending(triple, transactionID):
            do {
                let outcome = try await store.retryPendingCommit(transactionID)
                let evidence = applyRetry(outcome, for: triple)
                if currentTriple != triple, !autosaveState.blocksSuccessorSubmission {
                    return await flushCurrentTriple(successorLoopsRemaining: 0)
                }
                return evidence
            } catch {
                latestEvidence = .unsafeLatestUnprotected
                return latestEvidence
            }
        case let .cleanupPending(triple, identity, _):
            let result = await store.retryJournalCleanup(identity)
            switch result {
            case .clean:
                // Cleanup retries are only Journal transitions. They restore
                // the old operation's exact terminal proof and never replay
                // its Store work. A successor typed while that Store work was
                // in flight is then submitted exactly once.
                let proof = operations[triple]?.terminalEvidence
                    ?? retiredTerminalEvidence[triple]
                    ?? latestEvidence
                let terminalState: NoteAutosaveState
                switch proof {
                case .clean:
                    terminalState = .noChange(triple)
                case .persisted:
                    terminalState = .committed(triple)
                case .protectedOnly:
                    terminalState = .mainSaveFailedProtected(triple)
                case .unsafeLatestUnprotected:
                    terminalState = .protectionFailed(triple)
                }
                recordTerminalState(terminalState, evidence: proof, for: triple)
                if currentTriple == triple {
                    autosaveState = terminalState
                    latestEvidence = proof
                    pruneOperations()
                    return proof
                }
                autosaveState = terminalState
                latestEvidence = proof
                pruneOperations()
                return await flushCurrentTriple(successorLoopsRemaining: 0)
            case let .cleanupPending(nextIdentity, step):
                autosaveState = .cleanupPending(triple, identity: nextIdentity, step: step)
            }
            return latestEvidence
        default:
            return await flushLatest()
        }
    }

    private func scheduleTimers(for submission: NoteDraftSubmission) {
        let operation = operation(for: submission)
        let triple = NoteAutosaveTriple(submission: submission)
        operation.protectTimer?.cancel()
        operation.commitTimer?.cancel()
        operation.protectTimer = Task { @MainActor [weak self, scheduler] in
            do {
                try await scheduler.sleep(milliseconds: 150)
            } catch { return }
            guard !Task.isCancelled else { return }
            _ = self?.startProtection(for: triple, operation: operation)
        }
        operation.commitTimer = Task { @MainActor [weak self, scheduler] in
            do {
                try await scheduler.sleep(milliseconds: 650)
            } catch { return }
            guard !Task.isCancelled, let self else { return }
            _ = self.startCommit(for: triple, operation: operation)
        }
    }

    /// A newer generation never cancels Store work already begun for the old
    /// generation. It may only cancel its not-yet-fired scheduler sleeps.
    private func cancelUnfiredTimers(for identity: DraftJournalIdentity) {
        for (triple, operation) in operations where triple.identityAndGeneration.identity == identity {
            if operation.protectTask == nil {
                operation.protectTimer?.cancel()
                operation.protectTimer = nil
            }
            if operation.commitTask == nil {
                operation.commitTimer?.cancel()
                operation.commitTimer = nil
            }
        }
    }

    private func operation(for submission: NoteDraftSubmission) -> Operation {
        let triple = NoteAutosaveTriple(submission: submission)
        if let operation = operations[triple] { return operation }
        let operation = Operation(submission: submission)
        operations[triple] = operation
        return operation
    }

    private func startProtection(
        for triple: NoteAutosaveTriple,
        operation: Operation
    ) -> Task<ProtectionTerminal, Never> {
        if let task = operation.protectTask { return task }
        operation.protectTimer = nil
        if latestSubmission.map(NoteAutosaveTriple.init(submission:)) == triple {
            autosaveState = .protecting(triple)
        }
        let store = store
        let submission = operation.submission
        let task: Task<ProtectionTerminal, Never> = Task { @MainActor () -> ProtectionTerminal in
            do {
                switch try await store.protectDraft(submission) {
                case let .protected(protected): return .protected(protected)
                case .superseded: return .superseded
                }
            } catch {
                return .failed
            }
        }
        operation.protectTask = task
        return task
    }

    private func startCommit(
        for triple: NoteAutosaveTriple,
        operation: Operation
    ) -> Task<NoteAutosaveBarrierEvidence, Never> {
        if let task = operation.commitTask { return task }
        operation.commitTimer = nil
        let protectTask = startProtection(for: triple, operation: operation)
        let store = store
        let task: Task<NoteAutosaveBarrierEvidence, Never> = Task {
            @MainActor [weak self] () -> NoteAutosaveBarrierEvidence in
            let protection = await protectTask.value
            guard let self else { return .unsafeLatestUnprotected }
            guard !self.autosaveState.vetoesBackgroundCommit else {
                return .unsafeLatestUnprotected
            }
            switch protection {
            case let .protected(protected):
                operation.hasDurableProtection = !protected.journalChecksum.isEmpty
                if self.latestSubmission.map(NoteAutosaveTriple.init(submission:)) == triple {
                    self.autosaveState = .protected(triple)
                    self.autosaveState = .committing(triple)
                }
                do {
                    let outcome = try await store.commitProtectedDraft(protected)
                    return self.apply(
                        outcome,
                        for: triple,
                        hasDurableProtection: operation.hasDurableProtection
                    )
                } catch {
                    return self.applyProtectionFailure(for: triple)
                }
            case .superseded:
                self.setState(.draftSuperseded(triple), evidence: .unsafeLatestUnprotected, for: triple)
                return .unsafeLatestUnprotected
            case .failed:
                return self.applyProtectionFailure(for: triple)
            }
        }
        operation.commitTask = task
        return task
    }

    private func finalizeNativeInputIfNeeded(_ finalizer: NoteNativeInputFinalizer?) async -> Bool {
        if case .nativeInputUnresolved = autosaveState { return false }
        guard let finalizer, let session else { return true }
        let permit = NoteNativeInputPermit(
            noteID: session.baseSnapshot.id,
            editSessionID: session.editSessionID,
            activeHostToken: session.activeHostToken,
            nonce: UUID()
        )
        let stateBeforeFinalization = autosaveState
        stateBeforeNativeFinalization = stateBeforeFinalization
        activePermit = permit
        consumedPermitNonce = nil
        autosaveState = .finalizingNativeInput(permit)
        let completed = await finalizer(permit) { [weak self] candidate, edit in
            self?.acceptNativeInput(candidate, edit: edit) ?? false
        }
        if activePermit == permit { activePermit = nil }
        stateBeforeNativeFinalization = nil
        guard completed else {
            if let triple = currentTriple { autosaveState = .nativeInputUnresolved(triple) } else { autosaveState = .editable }
            return false
        }
        if autosaveState == .finalizingNativeInput(permit) {
            autosaveState = stateBeforeFinalization
        }
        return true
    }

    private func apply(
        _ outcome: WorkspaceTransactionOutcome,
        for triple: NoteAutosaveTriple,
        hasDurableProtection: Bool
    ) -> NoteAutosaveBarrierEvidence {
        let mapping = NoteAutosaveOutcomeMapping.workspace(
            outcome,
            triple: triple,
            hasDurableProtection: hasDurableProtection
        )
        setState(mapping.state, evidence: mapping.evidence, for: triple)
        return mapping.evidence
    }

    private func applyRetry(
        _ outcome: PendingCommitRetryOutcome,
        for triple: NoteAutosaveTriple
    ) -> NoteAutosaveBarrierEvidence {
        let mapping = NoteAutosaveOutcomeMapping.retry(
            outcome,
            triple: triple,
            hasDurableProtection: operations[triple]?.hasDurableProtection == true
        )
        setState(mapping.state, evidence: mapping.evidence, for: triple)
        return mapping.evidence
    }

    private func applyProtectionFailure(for triple: NoteAutosaveTriple) -> NoteAutosaveBarrierEvidence {
        setState(.protectionFailed(triple), evidence: .unsafeLatestUnprotected, for: triple)
        return .unsafeLatestUnprotected
    }

    private func setState(
        _ state: NoteAutosaveState,
        evidence: NoteAutosaveBarrierEvidence,
        for triple: NoteAutosaveTriple
    ) {
        guard !autosaveState.vetoesBackgroundCommit else { return }
        recordTerminalState(state, evidence: evidence, for: triple)
        // A pending or cleanup terminal from an older in-flight triple takes
        // ownership even when a newer draft was typed while Store I/O was
        // suspended. Otherwise that newer draft could bypass the exact retry
        // gate which is the only safe way to resolve the old transaction.
        guard latestSubmission.map(NoteAutosaveTriple.init(submission:)) == triple
                || state.blocksSuccessorSubmission
                || autosaveState.blocksSuccessorSubmission
        else { return }
        if case .persisted = evidence {
            rebaseCurrentSessionAfterPersistence(for: triple)
        }
        autosaveState = state
        latestEvidence = evidence
    }

    private func rebaseCurrentSessionAfterPersistence(for triple: NoteAutosaveTriple) {
        guard latestSubmission.map(NoteAutosaveTriple.init(submission:)) == triple,
              var session,
              let persisted = store.state.notes[triple.identityAndGeneration.identity.noteID],
              let checksum = try? WorkspaceChecksum.noteSnapshotChecksum(persisted)
        else { return }
        session.baseSnapshot = persisted
        session.baseChecksum = checksum
        session.baseLinkedTaskBlockLinks = Set(store.state.taskBlockLinks.filter {
            $0.noteID == persisted.id
        })
        session.draft = persisted
        session.linkedBlockDeletionDispositions = [:]
        self.session = session
    }

    /// This record is per exact Store operation, not presentation state.
    /// An older terminal still must be retained truthfully and released even
    /// when a newer generation remains the globally visible editor state.
    private func recordTerminalState(
        _ state: NoteAutosaveState,
        evidence: NoteAutosaveBarrierEvidence,
        for triple: NoteAutosaveTriple
    ) {
        guard let operation = operations[triple] else { return }
        operation.terminalEvidence = evidence
        guard !state.blocksSuccessorSubmission else { return }
        operation.terminalState = state
        operation.protectTimer?.cancel()
        operation.commitTimer?.cancel()
        operation.protectTimer = nil
        operation.commitTimer = nil
        operation.protectTask = nil
        operation.commitTask = nil
        pruneOperations()
    }

    private func pruneOperations() {
        let current = currentTriple
        operations = operations.filter { triple, operation in
            if triple == current { return true }
            if operation.terminalState != nil {
                if let evidence = operation.terminalEvidence {
                    retiredTerminalEvidence[triple] = evidence
                }
                return false
            }
            return operation.protectTask != nil || operation.commitTask != nil
        }
    }

    private static func makeSubmission(
        base: Note,
        baseChecksum: String,
        baseLinks: Set<TaskBlockCalendarLink>,
        editSessionID: UUID,
        generation: UInt64,
        draft: Note,
        dispositions: [BlockID: LinkedTaskBlockDeletionDisposition]
    ) throws -> NoteDraftSubmission {
        var fields = Set<NoteDraftField>()
        if base.title != draft.title { fields.insert(.title) }
        if base.document != draft.document { fields.insert(.document) }
        if base.categoryID != draft.categoryID { fields.insert(.categoryID) }
        if base.archivedAt != draft.archivedAt { fields.insert(.archivedAt) }
        return .init(
            noteID: base.id,
            editSessionID: editSessionID,
            baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: baseChecksum,
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: baseLinks,
            draftGeneration: generation,
            snapshot: draft,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(draft),
            modifiedFields: fields,
            linkedBlockDeletionDispositions: dispositions
        )
    }
}

extension NoteAutosaveState {
    var statusMessage: String? {
        switch self {
        case .mainSaveFailedProtected:
            "保存失败—草稿已保护"
        case .protectionFailed:
            "保存失败—草稿未保护"
        case .commitPending:
            "保存结果尚未确认，当前为只读状态。"
        case let .cleanupPending(_, _, step):
            step == .unbind
                ? "保存失败—草稿已保护；清理尚未完成，当前为只读状态。"
                : "内容已写入，但草稿清理尚未完成；当前为只读状态。"
        case .externalSourceChanged:
            "检测到外部数据变化，当前草稿未保存。"
        case .persistenceBlocked:
            "当前无法安全写入，草稿未保存。"
        case .invalidPersistedReceipt:
            "保存回执异常，当前草稿未保存。"
        case .restoredNotProof:
            "恢复结果不能证明当前草稿已保存。"
        case .nativeInputUnresolved:
            "原生输入尚未完成，当前不能关闭或导出。"
        case .editable, .waitingToProtect, .protecting, .protected, .committing,
             .finalizingNativeInput, .sealed, .committed, .noChange, .conflict,
             .draftSuperseded, .notCommitted:
            nil
        }
    }

    var vetoesBackgroundCommit: Bool {
        if case .nativeInputUnresolved = self { return true }
        return false
    }

    var blocksSuccessorSubmission: Bool {
        switch self {
        case .commitPending, .cleanupPending:
            true
        default:
            false
        }
    }

    var allowsOrdinaryEdit: Bool {
        switch self {
        case .editable, .waitingToProtect, .protecting, .protected, .committing,
             .committed, .noChange, .conflict, .draftSuperseded, .notCommitted,
             .invalidPersistedReceipt, .restoredNotProof, .externalSourceChanged, .persistenceBlocked, .mainSaveFailedProtected,
             .protectionFailed:
            true
        case .finalizingNativeInput, .nativeInputUnresolved, .sealed, .commitPending, .cleanupPending:
            false
        }
    }

    var isEditableForNewSession: Bool {
        switch self {
        case .finalizingNativeInput, .nativeInputUnresolved, .sealed, .commitPending, .cleanupPending:
            false
        default:
            true
        }
    }
}
