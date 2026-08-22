import CalendarDomain
import Foundation
import Observation
import WorkspaceDomain

enum DecompositionOperation: Equatable, Sendable {
    case clarification
    case generateCandidates
    case refreshCandidates
    case splitCandidate(UUID)
}

enum DecompositionRequestState: Equatable, Sendable {
    case idle
    case running(id: UUID, operation: DecompositionOperation)
}

protocol DecompositionSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousClockDecompositionSleeper: DecompositionSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

enum DecompositionPlanningFailure: Error, Equatable {
    case unavailable(ManualDecompositionReason)
    case timedOut
    case cancelled
    case invalidOutput(DecompositionOutputError)
    case modelFailure
}

enum DecompositionCommitResult: Equatable {
    case committed(createdActions: Int, scheduledActions: Int, stateGeneration: UInt)
    case sourceChanged
    case calendarConflict
    case notCommitted(message: String)
}

@MainActor
@Observable
final class DecompositionWorkbenchModel {
    private static let notCommittedMessage = "原笔记和日历没有被改动，可稍后重试"
    private static let undoLabel = "拆开并安排"

    private(set) var draft: DecompositionDraft
    private(set) var requestState: DecompositionRequestState = .idle
    private(set) var isCommitting = false
    private var activeRequest: Task<Void, Never>?
    private var hasCommitted = false
    private var lastCommitResult: DecompositionCommitResult?

    private let planner: any DecompositionPlanning
    private let store: WorkspaceStore
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    private let sleeper: any DecompositionSleeping
    private let uuid: @Sendable () -> UUID
    private let requestTimeout: Duration

    init(
        snapshot: DecompositionSourceSnapshot,
        planner: any DecompositionPlanning,
        store: WorkspaceStore,
        clock: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone = .autoupdatingCurrent,
        sleeper: any DecompositionSleeping = ContinuousClockDecompositionSleeper(),
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        requestTimeout: Duration = .seconds(20)
    ) {
        self.planner = planner
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        self.sleeper = sleeper
        self.uuid = uuid
        self.requestTimeout = requestTimeout
        self.draft = DecompositionDraft(
            source: snapshot,
            stage: .understand,
            question: nil,
            answer: "",
            candidates: [],
            mode: .intelligent,
            lastRecoverableError: nil
        )
    }

    func start() async {
        guard !isManual else { return }
        if let reason = unavailableReason() {
            applyManualMode(reason: reason)
            return
        }
        await performUserRequest(.clarification) { requestID in
            await self.performClarification(requestID: requestID)
        }
    }

    func submitAnswer(_ answer: String) async {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft.answer = trimmed
        guard !isManual else { return }
        await performUserRequest(.generateCandidates) { requestID in
            await self.performGenerate(
                requestID: requestID,
                existing: self.draft.candidates
            )
        }
    }

    func updateAnswer(_ answer: String) {
        draft.answer = answer
    }

    func refreshUnlockedCandidates() async {
        guard !isManual, !draft.candidates.isEmpty else { return }
        await performUserRequest(.refreshCandidates) { requestID in
            await self.performGenerate(
                requestID: requestID,
                existing: self.draft.candidates
            )
        }
    }

    func split(_ candidateID: UUID) async {
        guard !isManual, draft.candidates.contains(where: { $0.id == candidateID }) else { return }
        await performUserRequest(.splitCandidate(candidateID)) { requestID in
            await self.performSplit(requestID: requestID, candidateID: candidateID)
        }
    }

    func cancelRequest() {
        activeRequest?.cancel()
        activeRequest = nil
        requestState = .idle
    }

    func enterManualMode(reason: ManualDecompositionReason) {
        cancelRequest()
        applyManualMode(reason: reason)
    }

    func addManualCandidate() {
        draft.candidates.append(
            CandidateAction(
                id: uuid(),
                title: "",
                completionDescription: "",
                estimatedDuration: .minutes30,
                selectedForCreation: true,
                selectedForCalendar: false,
                titleLockedByUser: false,
                completionLockedByUser: false,
                sourceCandidateID: nil,
                proposal: nil
            )
        )
        if draft.stage == .understand {
            draft.stage = .split
        }
    }

    func deleteCandidate(id: UUID) {
        draft.candidates.removeAll { $0.id == id }
    }

    func moveCandidate(fromOffsets source: IndexSet, toOffset destination: Int) {
        var items = draft.candidates
        let moving = source.sorted().compactMap { index -> CandidateAction? in
            items.indices.contains(index) ? items[index] : nil
        }
        for index in source.sorted(by: >) where items.indices.contains(index) {
            items.remove(at: index)
        }
        let adjusted = min(
            max(0, destination - source.filter { $0 < destination }.count),
            items.count
        )
        items.insert(contentsOf: moving, at: adjusted)
        draft.candidates = items
    }

    func updateTitle(id: UUID, value: String) {
        guard let index = draft.candidates.firstIndex(where: { $0.id == id }) else { return }
        draft.candidates[index].title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.candidates[index].titleLockedByUser = true
    }

    func updateCompletion(id: UUID, value: String) {
        guard let index = draft.candidates.firstIndex(where: { $0.id == id }) else { return }
        draft.candidates[index].completionDescription = value.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.candidates[index].completionLockedByUser = true
    }

    func setSelectedForCreation(id: UUID, selected: Bool) {
        guard let index = draft.candidates.firstIndex(where: { $0.id == id }) else { return }
        draft.candidates[index].selectedForCreation = selected
        if !selected {
            draft.candidates[index].selectedForCalendar = false
            draft.candidates[index].proposal = nil
        }
    }

    func setSelectedForCalendar(id: UUID, selected: Bool) {
        guard let index = draft.candidates.firstIndex(where: { $0.id == id }) else { return }
        guard draft.candidates[index].selectedForCreation else { return }
        draft.candidates[index].selectedForCalendar = selected
        if !selected {
            draft.candidates[index].proposal = nil
        }
    }

    func setProposal(id: UUID, proposal: CalendarProposal?) {
        guard let index = draft.candidates.firstIndex(where: { $0.id == id }) else { return }
        draft.candidates[index].proposal = proposal
    }

    func advanceToSchedule() {
        guard canAdvanceToSchedule() else { return }
        refreshCalendarProposals()
        draft.stage = .schedule
    }

    func returnToStage(_ stage: DecompositionStage) {
        guard stage.rawValue <= draft.stage.rawValue else { return }
        draft.stage = stage
    }

    func refreshCalendarProposals() {
        let proposals = CalendarProposalEngine.propose(
            for: draft.candidates,
            calendarState: store.calendarState,
            now: clock(),
            timeZone: timeZone
        )
        for index in draft.candidates.indices {
            draft.candidates[index].proposal = proposals[draft.candidates[index].id]
        }
    }

    func commit() async -> DecompositionCommitResult {
        if hasCommitted, let lastCommitResult {
            return lastCommitResult
        }
        if isCommitting {
            return .notCommitted(message: Self.notCommittedMessage)
        }
        switch prepareCommit() {
        case let .rejected(result):
            return result
        case let .payload(payload, created, scheduled):
            isCommitting = true
            defer { isCommitting = false }
            do {
                let outcome = try await store.sendWorkspace(
                    .applyDecompositionPlan(payload),
                    undoLabel: Self.undoLabel
                )
                let mapped = mapCommit(
                    outcome,
                    created: created,
                    scheduled: scheduled
                )
                if case .committed = mapped {
                    hasCommitted = true
                    lastCommitResult = mapped
                }
                return mapped
            } catch {
                draft.lastRecoverableError = .persistenceFailed
                return .notCommitted(message: Self.notCommittedMessage)
            }
        }
    }

    private var isManual: Bool {
        if case .manual = draft.mode { return true }
        return false
    }

    private var normalizedAnswer: String? {
        let trimmed = draft.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func unavailableReason() -> ManualDecompositionReason? {
        switch planner.availability {
        case .available:
            return nil
        case let .unavailable(reason):
            return reason
        }
    }

    private func beginRequest(_ operation: DecompositionOperation) -> UUID {
        activeRequest?.cancel()
        let id = UUID()
        requestState = .running(id: id, operation: operation)
        return id
    }

    private func accepts(_ requestID: UUID) -> Bool {
        guard case let .running(currentID, _) = requestState else { return false }
        return currentID == requestID && !Task.isCancelled
    }

    private func finish(_ requestID: UUID) {
        if case let .running(currentID, _) = requestState, currentID == requestID {
            requestState = .idle
        }
    }

    private func performUserRequest(
        _ operation: DecompositionOperation,
        body: @escaping @MainActor (UUID) async -> Void
    ) async {
        let requestID = beginRequest(operation)
        let task = Task { @MainActor in
            await body(requestID)
        }
        activeRequest = task
        await task.value
        if case let .running(currentID, _) = requestState, currentID == requestID {
            requestState = .idle
        }
    }

    private func performClarification(requestID: UUID) async {
        if let reason = unavailableReason() {
            applyFailure(.unavailable(reason), requestID: requestID)
            return
        }
        let planner = self.planner
        let source = draft.source
        let result = await race {
            try await planner.clarification(for: ClarificationRequest(source: source))
        }
        guard accepts(requestID) else { return }
        switch result {
        case .success(.notNeeded):
            if let reason = unavailableReason() {
                applyFailure(.unavailable(reason), requestID: requestID)
                return
            }
            let generateID = UUID()
            requestState = .running(id: generateID, operation: .generateCandidates)
            await performGenerate(requestID: generateID, existing: [])
        case let .success(.ask(question, quickAnswers)):
            draft.question = DecompositionQuestion(
                text: question,
                quickAnswers: Array(quickAnswers.prefix(3))
            )
            draft.stage = .understand
            finish(requestID)
        case let .failure(failure):
            applyFailure(failure, requestID: requestID)
        }
    }

    private func performGenerate(requestID: UUID, existing: [CandidateAction]) async {
        let source = draft.source
        let answer = normalizedAnswer
        let contexts = contexts(from: existing)
        let planner = self.planner
        let result = await runValidated(requestID: requestID) { output in
            if existing.isEmpty {
                return try DecompositionOutputValidator.validateInitial(output)
            }
            _ = try DecompositionDraftReducer.mergeRefresh(output, into: existing)
            return output
        } operation: { feedback in
            try await planner.candidates(
                for: CandidateRequest(
                    source: source,
                    answer: answer,
                    existingCandidates: contexts,
                    validationFeedback: feedback
                )
            )
        }
        guard accepts(requestID) else { return }
        switch result {
        case let .success(output):
            if existing.isEmpty {
                draft.candidates = candidateActions(from: output)
            } else if let merged = try? DecompositionDraftReducer.mergeRefresh(output, into: existing) {
                draft.candidates = merged
            }
            draft.stage = .split
            draft.lastRecoverableError = nil
            finish(requestID)
        case let .failure(failure):
            applyFailure(failure, requestID: requestID)
        }
    }

    private func performSplit(requestID: UUID, candidateID: UUID) async {
        guard let target = draft.candidates.first(where: { $0.id == candidateID }) else {
            finish(requestID)
            return
        }
        let source = draft.source
        let answer = normalizedAnswer
        let context = PlannerCandidateContext(
            id: target.id,
            title: target.title,
            completionDescription: target.completionDescription,
            estimatedMinutes: target.estimatedDuration.rawValue,
            titleLockedByUser: target.titleLockedByUser,
            completionLockedByUser: target.completionLockedByUser
        )
        let planner = self.planner
        let current = draft.candidates
        let result = await runValidated(requestID: requestID) { output in
            try DecompositionOutputValidator.validateSplit(output)
        } operation: { feedback in
            try await planner.splitCandidate(
                for: SplitCandidateRequest(
                    source: source,
                    answer: answer,
                    target: context,
                    validationFeedback: feedback
                )
            )
        }
        guard accepts(requestID) else { return }
        switch result {
        case let .success(output):
            if let replaced = try? DecompositionDraftReducer.replaceCandidate(
                id: candidateID,
                with: output,
                in: current
            ) {
                draft.candidates = replaced
            }
            draft.lastRecoverableError = nil
            finish(requestID)
        case let .failure(failure):
            applyFailure(failure, requestID: requestID)
        }
    }

    private func runValidated<T: Sendable>(
        requestID: UUID,
        validate: (T) throws -> T,
        operation: @escaping @Sendable (DecompositionOutputError?) async throws -> T
    ) async -> Result<T, DecompositionPlanningFailure> {
        var feedback: DecompositionOutputError?
        for attempt in 0..<2 {
            guard accepts(requestID) else { return .failure(.cancelled) }
            if let reason = unavailableReason() {
                return .failure(.unavailable(reason))
            }
            let requestFeedback = feedback
            let raced = await race {
                try await operation(requestFeedback)
            }
            switch raced {
            case let .success(raw):
                do {
                    return .success(try validate(raw))
                } catch let error as DecompositionOutputError {
                    if attempt == 0 {
                        feedback = error
                        continue
                    }
                    return .failure(.invalidOutput(error))
                } catch {
                    return .failure(.modelFailure)
                }
            case let .failure(failure):
                return .failure(failure)
            }
        }
        return .failure(.modelFailure)
    }

    private func race<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async -> Result<T, DecompositionPlanningFailure> {
        let sleeper = self.sleeper
        let timeout = requestTimeout
        do {
            return try await withThrowingTaskGroup(of: T?.self) { group in
                group.addTask {
                    try await work()
                }
                group.addTask {
                    try await sleeper.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next()!
                group.cancelAll()
                if let value = first {
                    return .success(value)
                }
                return .failure(.timedOut)
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(mapPlannerError(error))
        }
    }

    private func mapPlannerError(_ error: Error) -> DecompositionPlanningFailure {
        if error is CancellationError {
            return .cancelled
        }
        if let failure = error as? DecompositionPlanningFailure {
            return failure
        }
        if let output = error as? DecompositionOutputError {
            return .invalidOutput(output)
        }
        return .modelFailure
    }

    private func applyFailure(_ failure: DecompositionPlanningFailure, requestID: UUID) {
        guard accepts(requestID) || requestStateMatches(requestID) else { return }
        switch failure {
        case .cancelled:
            break
        case .timedOut:
            applyManualMode(reason: .timedOut)
        case let .unavailable(reason):
            applyManualMode(reason: reason)
        case .invalidOutput:
            applyManualMode(reason: .repeatedInvalidOutput)
        case .modelFailure:
            applyManualMode(reason: .modelFailure)
            draft.lastRecoverableError = .planningFailed
        }
        finish(requestID)
    }

    private func requestStateMatches(_ requestID: UUID) -> Bool {
        if case let .running(currentID, _) = requestState {
            return currentID == requestID
        }
        return false
    }

    private func applyManualMode(reason: ManualDecompositionReason) {
        draft.mode = .manual(reason: reason)
        if draft.candidates.isEmpty {
            draft.stage = .split
        }
    }

    private func candidateActions(from output: [PlannerCandidate]) -> [CandidateAction] {
        output.map { item in
            CandidateAction(
                id: uuid(),
                title: item.title,
                completionDescription: item.completionDescription,
                estimatedDuration: CandidateDuration(rawValue: item.estimatedMinutes) ?? .minutes30,
                selectedForCreation: true,
                selectedForCalendar: false,
                titleLockedByUser: false,
                completionLockedByUser: false,
                sourceCandidateID: nil,
                proposal: nil
            )
        }
    }

    private func contexts(from candidates: [CandidateAction]) -> [PlannerCandidateContext] {
        candidates.map {
            PlannerCandidateContext(
                id: $0.id,
                title: $0.title,
                completionDescription: $0.completionDescription,
                estimatedMinutes: $0.estimatedDuration.rawValue,
                titleLockedByUser: $0.titleLockedByUser,
                completionLockedByUser: $0.completionLockedByUser
            )
        }
    }

    private func canAdvanceToSchedule() -> Bool {
        let selected = draft.candidates.filter(\.selectedForCreation)
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy {
            !$0.title.isEmpty && !$0.completionDescription.isEmpty
        }
    }

    private enum PreparedCommit {
        case payload(ApplyDecompositionPlanPayload, created: Int, scheduled: Int)
        case rejected(DecompositionCommitResult)
    }

    private func prepareCommit() -> PreparedCommit {
        guard draft.stage == .schedule else {
            return .rejected(.notCommitted(message: Self.notCommittedMessage))
        }
        let selected = draft.candidates.filter(\.selectedForCreation)
        guard !selected.isEmpty else {
            return .rejected(.notCommitted(message: Self.notCommittedMessage))
        }
        guard selected.allSatisfy({ !$0.title.isEmpty && !$0.completionDescription.isEmpty }) else {
            return .rejected(.notCommitted(message: Self.notCommittedMessage))
        }
        if selected.contains(where: { $0.selectedForCalendar && $0.proposal == nil }) {
            return .rejected(.notCommitted(message: Self.notCommittedMessage))
        }
        guard let note = store.state.notes[draft.source.noteID] else {
            draft.stage = .split
            draft.lastRecoverableError = .sourceChanged
            return .rejected(.sourceChanged)
        }
        let scheduled = selected.filter { $0.selectedForCalendar && $0.proposal != nil }
        let ids = DecompositionPlanIDs(
            blockIDs: selected.map { _ in BlockID(uuid()) },
            calendarItemIDs: scheduled.map { _ in uuid() }
        )
        do {
            let payload = try DecompositionPlanBuilder.makePayload(
                snapshot: draft.source,
                candidates: draft.candidates,
                note: note,
                workspaceRevision: store.state.revision,
                now: clock(),
                ids: ids,
                timeZone: timeZone
            )
            return .payload(payload, created: selected.count, scheduled: scheduled.count)
        } catch {
            return .rejected(.notCommitted(message: Self.notCommittedMessage))
        }
    }

    private func mapCommit(
        _ outcome: WorkspaceTransactionOutcome,
        created: Int,
        scheduled: Int
    ) -> DecompositionCommitResult {
        switch outcome {
        case .committed:
            draft.lastRecoverableError = nil
            return .committed(
                createdActions: created,
                scheduledActions: scheduled,
                stateGeneration: store.statePublicationGeneration
            )
        case let .conflict(conflict):
            switch conflict {
            case .decomposition(.calendarChanged):
                draft.stage = .schedule
                draft.lastRecoverableError = .calendarConflict
                return .calendarConflict
            case .decomposition(.noteMissing),
                 .decomposition(.noteChanged),
                 .decomposition(.anchorMissing),
                 .noteMissing,
                 .noteDraft:
                draft.stage = .split
                draft.lastRecoverableError = .sourceChanged
                return .sourceChanged
            }
        case .notCommitted, .persistenceBlocked, .commitPending, .externalSourceChanged:
            draft.lastRecoverableError = .persistenceFailed
            return .notCommitted(message: Self.notCommittedMessage)
        case .draftAlreadyPersisted, .restored, .noChange, .draftSuperseded:
            draft.lastRecoverableError = .persistenceFailed
            return .notCommitted(message: Self.notCommittedMessage)
        }
    }
}
