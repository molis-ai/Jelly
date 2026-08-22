import Foundation
import Testing
@testable import CalendarApp
import CalendarPersistence
import WorkspaceDomain

@Suite("NoteAutosaveCoordinatorTests")
@MainActor
struct NoteAutosaveCoordinatorTests {
    @Test func undoingAfterThePreviousGenerationPersistedStillAllowsTermination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-autosave-undo-after-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar),
            journal: journal
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(
            note,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )

        let edited = try coordinator.update(title: "临时输入")
        #expect(await coordinator.flushLatest() == .persisted(NoteAutosaveTriple(submission: edited)))
        _ = try coordinator.update(title: note.title)

        let decision = await NoteCloseProtectionBridge(coordinator: coordinator)
            .decision(for: .termination)

        #expect(decision == .allow)
        #expect(store.state.notes[note.id]?.title == note.title)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func titleEditBuildsACompleteNextGenerationFromTheImmutableSessionBase() async throws {
        let state = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: state.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: state)
        let store = WorkspaceStore(initialState: .empty(calendar: state), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(
            store: store,
            scheduler: AutosaveImmediateScheduler()
        )
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000001201")!

        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: sessionID, activeHostToken: UUID())
        let submission = try coordinator.update(title: "已改标题")

        #expect(submission.noteID == note.id)
        #expect(submission.editSessionID == sessionID)
        #expect(submission.baseSnapshot == note)
        #expect(submission.snapshot.title == "已改标题")
        #expect(submission.draftGeneration == 1)
        #expect(submission.modifiedFields == [.title])
    }

    @Test func bodyGenerationPersistsAfterAnEarlierTitleGenerationWasRebased() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-autosave-rebase-fields-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.notes[note.id] = note
        let seeded = initial
        let repository = JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("workspace.json"),
            seed: { seeded }
        )
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: initial, repository: repository, journal: journal)
        await store.load()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(
            note,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )

        _ = try coordinator.update(title: "真实输入验收笔记")
        let titleTriple = try #require(coordinator.currentTriple)
        #expect(await coordinator.flushLatest() == .persisted(titleTriple))

        var body = note.document
        body.blocks[0].inlineContent = .plain("keyboard")
        _ = try coordinator.update(document: body)
        let bodyTriple = try #require(coordinator.currentTriple)
        #expect(await coordinator.flushLatest() == .persisted(bodyTriple))
        #expect(store.state.notes[note.id]?.title == "真实输入验收笔记")
        #expect(store.state.notes[note.id]?.document == body)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func newerEditCancelsOnlyTheOlderUnfiredTimersBeforeAnyOldStoreIOStarts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-timer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        var workspace = WorkspaceState.empty(calendar: calendar)
        workspace.notes[note.id] = note
        let initial = workspace
        let repository = JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("workspace.json"),
            seed: { initial }
        )
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: initial, repository: repository, journal: journal)
        await store.load()
        let scheduler = GateAutosaveScheduler()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: scheduler)
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())

        _ = try coordinator.update(title: "旧版本")
        await scheduler.waitForSleepCount(2)
        _ = try coordinator.update(title: "新版本")
        await scheduler.waitForSleepCount(4)

        scheduler.release(at: 0)
        scheduler.release(at: 1)
        await Task.yield()
        await Task.yield()

        #expect(store.state.notes[note.id]?.title == "")
        #expect(try await journal.current() == nil)

        scheduler.release(at: 2)
        scheduler.release(at: 3)
        let evidence = await coordinator.flushLatest()

        #expect(evidence == .persisted(try #require(coordinator.currentTriple)))
        #expect(store.state.notes[note.id]?.title == "新版本")
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func finalizationPermitAcceptsOneExactCallbackAndPersistsThatTerminalGeneration() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        // Keep successor timers asleep: only the cleanup retry is allowed to
        // linearize N+1 after N's already-started Store operation resolves.
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: GateAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "组合态之前")

        let evidence = await coordinator.flushLatest { permit, apply in
            let edit = NoteNativeInputEdit(title: "组合态完成")
            #expect(apply(permit, edit))
            #expect(!apply(permit, edit))
            return true
        }

        let triple = try #require(coordinator.currentTriple)
        #expect(evidence == .persisted(triple))
        #expect(triple.identityAndGeneration.draftGeneration == 2)
        #expect(store.state.notes[note.id]?.title == "组合态完成")
    }

    @Test func firstIMEFinalizerCreatesGenerationOneBeforeTheNoCandidateCleanDecision() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())

        let evidence = await coordinator.flushLatest { permit, apply in
            apply(permit, .init(title: "首次 IME 回调"))
        }
        let triple = try #require(coordinator.currentTriple)
        #expect(triple.identityAndGeneration.draftGeneration == 1)
        #expect(evidence == .persisted(triple))
        #expect(store.state.notes[note.id]?.title == "首次 IME 回调")
    }

    @Test func sessionWithNoEditAndNoNativeCandidateReturnsSafeCleanEvidence() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let coordinator = NoteAutosaveCoordinator(
            store: WorkspaceStore(initialState: .empty(calendar: calendar), repository: InMemoryWorkspaceRepository(initialState: calendar)),
            scheduler: AutosaveImmediateScheduler()
        )
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        #expect(await coordinator.flushLatest() == .clean)
        #expect(coordinator.currentTriple == nil)
    }

    @Test func identicalNativeFinalizerSnapshotDoesNotManufactureANoChangeDraft() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let persisted = try #require(store.state.notes[note.id])
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(
            persisted,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )

        let evidence = await coordinator.flushLatest { permit, apply in
            apply(permit, .init(title: persisted.title, document: persisted.document))
        }

        #expect(evidence == .clean)
        #expect(coordinator.currentTriple == nil)
        #expect(store.state.notes[note.id] == persisted)
    }

    @Test func concurrentLifecycleFlushesShareOneNativePermitAndOneFinalizerResult() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "等待并发 finalizer")
        let finalizer = NativeFinalizerGate()

        let first = Task { @MainActor in
            await coordinator.flushLatest(finalizer: finalizer.finalize)
        }
        await finalizer.waitForFirstRequest()
        let route = Task { @MainActor in await coordinator.flushLatest(finalizer: finalizer.finalize) }
        let inactive = Task { @MainActor in await coordinator.flushLatest(finalizer: finalizer.finalize) }
        let selection = Task { @MainActor in await coordinator.flushLatest(finalizer: finalizer.finalize) }
        await Task.yield()
        #expect(finalizer.requestCount == 1)
        finalizer.release()

        let firstEvidence = await first.value
        let triple = try #require(coordinator.currentTriple)
        #expect(firstEvidence == .persisted(triple))
        #expect(await route.value == .persisted(triple))
        #expect(await inactive.value == .persisted(triple))
        #expect(await selection.value == .persisted(triple))
        #expect(finalizer.acceptedCount == 1)
    }

    @Test func laterGenerationsAccumulateDeletionDispositionsAndRemoveRestoredBlockIDsDeterministically() throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let coordinator = NoteAutosaveCoordinator(
            store: WorkspaceStore(initialState: .empty(calendar: calendar), repository: InMemoryWorkspaceRepository(initialState: calendar)),
            scheduler: AutosaveImmediateScheduler()
        )
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        let deletedBlock = BlockID()
        let stillDeletedBlock = BlockID()
        _ = try coordinator.update(linkedBlockDeletionDispositions: [deletedBlock: .deleteCalendarItem])
        let carrying = try coordinator.update(
            title: "继续编辑",
            linkedBlockDeletionDispositions: [stillDeletedBlock: .keepCalendarItem]
        )
        #expect(carrying.linkedBlockDeletionDispositions == [
            deletedBlock: .deleteCalendarItem,
            stillDeletedBlock: .keepCalendarItem
        ])

        let restoredDocument = BlockDocument(blocks: [.init(
            id: deletedBlock,
            kind: .paragraph,
            inlineContent: .plain("恢复的原块"),
            taskState: nil,
            indentLevel: 0
        )])
        let restored = try coordinator.update(document: restoredDocument)
        #expect(restored.linkedBlockDeletionDispositions == [stillDeletedBlock: .keepCalendarItem])
    }

    @Test func onlyARestoredTaskClearsItsLinkedDeletionDispositionAndTheRealReducerReceivesTaskToParagraph() async throws {
        let calendar = makeEmptyState()
        let linkedBlockID = BlockID()
        let item = try makeItem(categoryID: calendar.uncategorizedID, title: "linked task")
        var note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        note.document = .init(blocks: [try .task(id: linkedBlockID, text: "linked task")])
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.notes[note.id] = note
        initial.calendar.items[item.id] = item
        initial.taskBlockLinks = [.init(noteID: note.id, blockID: linkedBlockID, calendarItemID: item.id)]
        initial.calendarNoteRelations.baselines[.item(item.id)] = .init(primaryNoteID: note.id, referenceNoteIDs: [])
        let repository = WorkspaceStoreTestRepository(initial: initial)
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        let link = try #require(initial.taskBlockLinks.first)
        try coordinator.beginSession(note, linkedTaskBlockLinks: [link], editSessionID: UUID(), activeHostToken: UUID())
        let paragraph = BlockDocument(blocks: [.init(
            id: linkedBlockID, kind: .paragraph, inlineContent: .plain("not a task"), taskState: nil, indentLevel: 0
        )])
        let removedTask = try coordinator.update(
            document: paragraph,
            linkedBlockDeletionDispositions: [linkedBlockID: LinkedTaskBlockDeletionDisposition.keepCalendarItem]
        )
        #expect(removedTask.linkedBlockDeletionDispositions == [linkedBlockID: LinkedTaskBlockDeletionDisposition.keepCalendarItem])
        #expect(await coordinator.flushLatest() == .persisted(try #require(coordinator.currentTriple)))
        #expect(store.state.taskBlockLinks.isEmpty)
        #expect(store.state.calendar.items[item.id] != nil)

        let secondCoordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        let restoredParagraph = try #require(store.state.notes[note.id])
        try secondCoordinator.beginSession(restoredParagraph, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try secondCoordinator.update(
            document: paragraph,
            linkedBlockDeletionDispositions: [linkedBlockID: LinkedTaskBlockDeletionDisposition.deleteCalendarItem]
        )
        let restoredTaskDocument = BlockDocument(blocks: [try DocumentBlock.task(id: linkedBlockID, text: "task again")])
        let restoredTask = try secondCoordinator.update(document: restoredTaskDocument)
        #expect(restoredTask.linkedBlockDeletionDispositions.isEmpty)
    }

    @Test func terminalNoncurrentGenerationsReleaseTheirFullOperationsAcrossALongEditSession() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())

        for generation in 1...24 {
            _ = try coordinator.update(title: "generation \(generation)")
            #expect(await coordinator.flushLatest() == .persisted(try #require(coordinator.currentTriple)))
            #expect(coordinator.debugOperationCount <= 1)
        }
        #expect(coordinator.debugOperationCount == 1)
    }

    @Test func commitPendingBlocksTheNextGenerationUntilItsExactRetryThenSubmitsTheNewerDraftOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.notes[note.id] = note
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: initial, repository: repository, journal: journal)
        await store.load()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "N")

        #expect(await coordinator.flushLatest() == .unsafeLatestUnprotected)
        guard case .commitPending = coordinator.autosaveState else {
            Issue.record("uncertain commit must enter the typed read-only state")
            return
        }
        #expect(throws: NoteAutosaveCoordinatorError.editingIsSealed) {
            _ = try coordinator.update(title: "N+1 过早")
        }

        await repository.setReconciliation(.notCommitted(.init()))
        #expect(await coordinator.retryLatest() == .protectedOnly(try #require(coordinator.currentTriple)))
        let newer = try coordinator.update(title: "N+1")
        #expect(newer.draftGeneration == 2)
        #expect(await coordinator.flushLatest() == .persisted(try #require(coordinator.currentTriple)))
        #expect(store.state.notes[note.id]?.title == "N+1")
        #expect(await repository.saveCount == 1)
    }

    @Test func suspendedCommitSharesOneExactOperationAcrossConcurrentBarrierCallers() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let baselineSaveCount = await repository.saveCount
        await repository.suspendNextSave()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "共享中的保存")
        let triple = try #require(coordinator.currentTriple)

        let first = Task { @MainActor in await coordinator.flushLatest() }
        await repository.waitForSaveStart()
        let second = Task { @MainActor in await coordinator.flushLatest() }
        await Task.yield()

        #expect(await repository.saveCount == baselineSaveCount)
        await repository.resumeSave()

        #expect(await first.value == .persisted(triple))
        #expect(await second.value == .persisted(triple))
        #expect(await repository.saveCount == baselineSaveCount + 1)
    }

    @Test func aNewerGenerationDoesNotCancelOrReplayAlreadyStartedStoreIO() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let baselineSaveCount = await repository.saveCount
        await repository.suspendNextSave()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "N")
        let oldBarrier = Task { @MainActor in await coordinator.flushLatest() }
        await repository.waitForSaveStart()

        let newerSubmission = try coordinator.update(title: "N+1")
        let newerTriple = NoteAutosaveTriple(submission: newerSubmission)
        await repository.resumeSave()

        #expect(await oldBarrier.value == .persisted(newerTriple))
        #expect(await coordinator.flushLatest() == .persisted(newerTriple))
        #expect(await repository.saveCount == baselineSaveCount + 2)
        #expect(store.state.notes[note.id]?.title == "N+1")
        #expect(coordinator.autosaveState == .committed(newerTriple))
        #expect(coordinator.debugOperationCount == 1)
        try coordinator.beginSession(
            try #require(store.state.notes[note.id]),
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )
        #expect(coordinator.debugOperationCount == 0)
    }

    @Test func stillPendingKeepsTheOriginalTransactionReadOnlyUntilThatExactRetryCommits() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "等待确认")
        let triple = try #require(coordinator.currentTriple)

        #expect(await coordinator.flushLatest() == .unsafeLatestUnprotected)
        let pendingID = try #require({
            if case let .commitPending(_, transactionID) = coordinator.autosaveState { transactionID } else { nil }
        }())
        #expect(await coordinator.retryLatest() == .unsafeLatestUnprotected)
        #expect(coordinator.autosaveState == .commitPending(triple, transactionID: pendingID))
        #expect(throws: NoteAutosaveCoordinatorError.editingIsSealed) {
            _ = try coordinator.update(title: "不得越过待确认")
        }

        let receipt = PersistedDraftReceipt(
            noteID: note.id,
            editSessionID: triple.identityAndGeneration.identity.editSessionID,
            draftGeneration: triple.identityAndGeneration.draftGeneration,
            noteSnapshotChecksum: triple.noteSnapshotChecksum,
            persistedNoteRevision: 2
        )
        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 2, persistedDraft: receipt))))

        #expect(await coordinator.retryLatest() == .persisted(triple))
        #expect(store.state.notes[note.id]?.title == "等待确认")
    }

    @Test func protectWaitsThrough149ThenRunsAt150AndCommitWaitsThrough649ThenRunsAt650() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.notes[note.id] = note
        let initialState = initial
        let repository = JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("workspace.json"),
            seed: { initialState }
        )
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: initialState, repository: repository, journal: journal)
        await store.load()
        let scheduler = BoundaryAutosaveScheduler()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: scheduler)
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "边界")
        await scheduler.waitForRequested([150, 650])

        // 149ms: neither timer has fired; the single durable Journal is empty.
        #expect(try await journal.current() == nil)
        #expect(store.state.notes[note.id]?.title == "")

        // 150ms: protection is durable, but 649ms still cannot commit main state.
        scheduler.release(milliseconds: 150)
        await scheduler.waitForJournalRecord(journal)
        #expect(store.state.notes[note.id]?.title == "")
        #expect(try await journal.current()?.records.count == 1)

        // 650ms: only the matching commit timer (or the shared flush) may save.
        scheduler.release(milliseconds: 650)
        let triple = try #require(coordinator.currentTriple)
        #expect(await coordinator.flushLatest() == .persisted(triple))
        #expect(store.state.notes[note.id]?.title == "边界")
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func routePreparationStartsDraftProtectionWithoutWaitingForTheDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-route-protection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: repository,
            journal: journal
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let scheduler = GateAutosaveScheduler()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: scheduler)
        try coordinator.beginSession(
            note,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )
        _ = try coordinator.update(title: "切页也立刻保护")
        await scheduler.waitForSleepCount(2)

        #expect(await coordinator.finalizeNativeInputForRoute(nil))
        for _ in 0..<20 { await Task.yield() }
        #expect(try await journal.current()?.records.count == 1)
        #expect(store.state.notes[note.id]?.title != "切页也立刻保护")
    }

    @Test func realJournalProtectionAt150ThenSuspended650CommitAndCloseShareTheExactBarrier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-150-650-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, journal: journal)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        await repository.suspendNextSave()
        let scheduler = BoundaryAutosaveScheduler()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: scheduler)
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "150/650 close")
        await scheduler.waitForRequested([150, 650])

        scheduler.release(milliseconds: 150)
        await scheduler.waitForJournalRecord(journal)
        scheduler.release(milliseconds: 650)
        await repository.waitForSaveStart()
        let bridge = NoteCloseProtectionBridge(coordinator: coordinator)
        let close = Task { @MainActor in await bridge.decision(for: .windowClose) }
        await Task.yield()
        await repository.resumeSave()

        #expect(await close.value == .allow)
        #expect(store.state.notes[note.id]?.title == "150/650 close")
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func failedOrStaleNativeFinalizationChangesNoGenerationBeforeTheBarrierDecides() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        let original = try coordinator.update(title: "N")

        #expect(await coordinator.flushLatest { _, _ in false } == .unsafeLatestUnprotected)
        #expect(coordinator.autosaveState == .nativeInputUnresolved(NoteAutosaveTriple(submission: original)))
        #expect(coordinator.currentTriple == NoteAutosaveTriple(submission: original))
        #expect(store.state.notes[note.id]?.title == "")
        #expect(coordinator.cancelUnresolvedNativeInput())

        let staleHostResult = await coordinator.flushLatest { permit, apply in
            try? coordinator.updateActiveHostToken(UUID())
            return apply(permit, .init(title: "不得接受旧 host"))
        }
        #expect(staleHostResult == .unsafeLatestUnprotected)
        #expect(store.state.notes[note.id]?.title == "")
        #expect(coordinator.currentTriple == NoteAutosaveTriple(submission: original))
        #expect(coordinator.cancelUnresolvedNativeInput())

        var ordinaryPermit: NoteNativeInputPermit?
        var ordinaryCallback: (@MainActor (NoteNativeInputPermit, NoteNativeInputEdit) -> Bool)?
        #expect(await coordinator.flushLatest { permit, apply in
            ordinaryPermit = permit
            ordinaryCallback = apply
            return false
        } == .unsafeLatestUnprotected)
        let rejectedPermit = try #require(ordinaryPermit)
        let rejectedCallback = try #require(ordinaryCallback)
        #expect(!rejectedCallback(rejectedPermit, .init(title: "普通 callback 不得进入")))
        #expect(coordinator.currentTriple == NoteAutosaveTriple(submission: original))
    }

    @Test func committedCleanupRetryReleasesOnlyThatExactTripleAndThenAllowsTheSuccessor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let writer = CleanupFailingJournalWriter(failOnWrite: 3)
        let journal = DraftJournalRepository(
            fileURL: directory.appendingPathComponent("draft.json"),
            writer: writer
        )
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar), repository: repository, journal: journal
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "已保存、清理待重试")
        let triple = try #require(coordinator.currentTriple)

        #expect(await coordinator.flushLatest() == .persisted(triple))
        guard case .cleanupPending = coordinator.autosaveState else {
            Issue.record("the failed record write must remain a typed read-only cleanup")
            return
        }
        #expect(throws: NoteAutosaveCoordinatorError.editingIsSealed) {
            _ = try coordinator.update(title: "不得越过 cleanup")
        }

        writer.failOnWrite = nil
        #expect(await coordinator.retryLatest() == .persisted(triple))
        #expect(coordinator.autosaveState == .committed(triple))
        #expect((try coordinator.update(title: "N+1")).draftGeneration == 2)
    }

    @Test func cleanupPendingNoChangeFinalizerRestoresCleanupPendingThenRetryStillCallsJournal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-cleanup-noop-ime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let writer = CleanupFailingJournalWriter(failOnWrite: 3)
        let journal = DraftJournalRepository(
            fileURL: directory.appendingPathComponent("draft.json"),
            writer: writer
        )
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar), repository: repository, journal: journal
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "已保存、清理待重试")
        let triple = try #require(coordinator.currentTriple)

        #expect(await coordinator.flushLatest() == .persisted(triple))
        guard case .cleanupPending = coordinator.autosaveState else {
            Issue.record("the failed record write must remain a typed read-only cleanup")
            return
        }
        let writesAfterPending = writer.writeCount

        let evidence = await coordinator.flushLatest { permit, apply in
            apply(permit, .init(title: "已保存、清理待重试"))
        }
        #expect(evidence == .persisted(triple))
        guard case .cleanupPending = coordinator.autosaveState else {
            Issue.record("identical IME finalization must restore cleanupPending, not editable")
            return
        }
        #expect(throws: NoteAutosaveCoordinatorError.editingIsSealed) {
            _ = try coordinator.update(title: "不得越过 cleanup")
        }

        writer.failAllSubsequent = true
        #expect(await coordinator.retryLatest() == .persisted(triple))
        guard case .cleanupPending = coordinator.autosaveState else {
            Issue.record("a still-failing cleanup retry must remain pending")
            return
        }
        #expect(writer.writeCount > writesAfterPending)
    }

    @Test func cleanupPendingChangedFinalizerCannotBypassTheSafetyGate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-cleanup-changed-ime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let writer = CleanupFailingJournalWriter(failOnWrite: 3)
        let journal = DraftJournalRepository(
            fileURL: directory.appendingPathComponent("draft.json"),
            writer: writer
        )
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar), repository: repository, journal: journal
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "已保存、清理待重试")
        let triple = try #require(coordinator.currentTriple)

        #expect(await coordinator.flushLatest() == .persisted(triple))
        guard case .cleanupPending = coordinator.autosaveState else {
            Issue.record("the failed record write must remain a typed read-only cleanup")
            return
        }

        var acceptedChangedEdit = true
        let evidence = await coordinator.flushLatest { permit, apply in
            acceptedChangedEdit = apply(permit, .init(title: "不得越过 cleanup"))
            return true
        }
        #expect(!acceptedChangedEdit)
        #expect(evidence == .persisted(triple))
        guard case .cleanupPending = coordinator.autosaveState else {
            Issue.record("a changed IME callback must fail closed and keep cleanupPending")
            return
        }
        #expect(coordinator.currentTriple == triple)
        #expect(store.state.notes[note.id]?.title == "已保存、清理待重试")
        #expect(throws: NoteAutosaveCoordinatorError.editingIsSealed) {
            _ = try coordinator.update(title: "仍不得越过 cleanup")
        }
    }

    @Test func failedMainSaveAndJournalCleanupWritePreserveProtectedOnlyUntilThatCleanupRetries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-main-journal-dual-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let writer = CleanupFailingJournalWriter(failOnWrite: 3)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, journal: journal)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        await repository.failNextSave()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: AutosaveImmediateScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "主存储与 cleanup 同时失败")
        let triple = try #require(coordinator.currentTriple)

        #expect(await coordinator.flushLatest() == .protectedOnly(triple))
        #expect(coordinator.statusMessage == "保存失败—草稿已保护；清理尚未完成，当前为只读状态。")
        #expect(try await journal.current()?.records.isEmpty == false)
        guard case let .cleanupPending(actualTriple, _, step) = coordinator.autosaveState else {
            Issue.record("main failure plus a failed Journal cleanup must remain typed and read-only")
            return
        }
        #expect(actualTriple == triple)
        #expect(step == .unbind)
        #expect(store.state.notes[note.id]?.title == "")
        writer.failOnWrite = nil
        #expect(await coordinator.retryLatest() == .protectedOnly(triple))
        #expect(coordinator.autosaveState == .mainSaveFailedProtected(triple))
    }

    @Test func cleanupOfOlderGenerationPreservesItsProofThenSubmitsTheAlreadyDraftedSuccessorOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-cleanup-successor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let writer = CleanupFailingJournalWriter(failOnWrite: 3)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, journal: journal)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let baselineSaveCount = await repository.saveCount
        await repository.suspendNextSave()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: GateAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        let old = try coordinator.update(title: "N")
        let oldTriple = NoteAutosaveTriple(submission: old)
        let firstBarrier = Task { @MainActor in await coordinator.flushLatest() }
        await repository.waitForSaveStart()
        let successor = try coordinator.update(title: "N+1")
        let successorTriple = NoteAutosaveTriple(submission: successor)
        await repository.resumeSave()

        #expect(await firstBarrier.value == .persisted(oldTriple))
        guard case let .cleanupPending(blockedTriple, _, _) = coordinator.autosaveState else {
            Issue.record("the old failed cleanup must block the pre-existing successor")
            return
        }
        #expect(blockedTriple == oldTriple)

        writer.failOnWrite = nil
        #expect(await coordinator.retryLatest() == .persisted(successorTriple))
        #expect(coordinator.terminalEvidence(for: oldTriple) == .persisted(oldTriple))
        #expect(coordinator.autosaveState == .committed(successorTriple))
        #expect(store.state.notes[note.id]?.title == "N+1")
        #expect(await repository.saveCount == baselineSaveCount + 2)
    }

    @Test func anOlderCommitPendingBlocksTheAlreadyDraftedSuccessorAndEveryBarrierUntilExactRetry() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let scheduler = BoundaryAutosaveScheduler()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: scheduler)
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "N")
        let oldBarrier = Task { @MainActor in await coordinator.flushLatest() }
        await repository.waitForSaveStart()

        _ = try coordinator.update(title: "N+1 已产生但不得提交")
        await repository.resumeSave()

        #expect(await oldBarrier.value == .unsafeLatestUnprotected)
        guard case .commitPending = coordinator.autosaveState else {
            Issue.record("the old exact pending transaction must seal every successor")
            return
        }
        #expect(throws: NoteAutosaveCoordinatorError.editingIsSealed) {
            _ = try coordinator.update(title: "N+2 也不得进入")
        }
        #expect(await coordinator.flushLatest() == .unsafeLatestUnprotected)

        await repository.setReconciliation(.notCommitted(.init()))
        let newerTriple = try #require(coordinator.currentTriple)
        #expect(await coordinator.retryLatest() == .persisted(newerTriple))
        #expect(store.state.notes[note.id]?.title == "N+1 已产生但不得提交")
    }

    @Test func exhaustiveWorkspaceAndRetryOutcomeMappingNeverTreatsWrongReceiptsOrRestoresAsSavedEvidence() throws {
        let triple = try makeMappingTriple()
        let validReceipt = makeReceipt(for: triple)
        let pendingID = UUID(uuidString: "00000000-0000-0000-0000-0000000012F0")!
        let cleanupIdentity = triple.identityAndGeneration.identity
        let cleanup = JournalResolutionStatus.cleanupPending(identity: cleanupIdentity, step: .record)

        #expect(NoteAutosaveOutcomeMapping.workspace(
            .committed(.init(workspaceRevision: 1, persistedDraft: validReceipt), journal: .clean),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .committed(triple), evidence: .persisted(triple)))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .draftAlreadyPersisted(validReceipt, journal: .clean),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .noChange(triple), evidence: .persisted(triple)))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .noChange(.identical, journal: .clean), triple: triple, hasDurableProtection: true
        ) == .init(state: .noChange(triple), evidence: .unsafeLatestUnprotected))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .conflict(.noteMissing(triple.identityAndGeneration.identity.noteID)),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .conflict(triple), evidence: .unsafeLatestUnprotected))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .draftSuperseded, triple: triple, hasDurableProtection: true
        ) == .init(state: .draftSuperseded(triple), evidence: .unsafeLatestUnprotected))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .commitPending(transactionID: pendingID, artifacts: .init()),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .commitPending(triple, transactionID: pendingID), evidence: .unsafeLatestUnprotected))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .notCommitted(transactionID: pendingID, journal: .clean, artifacts: .init()),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .mainSaveFailedProtected(triple), evidence: .protectedOnly(triple)))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .notCommitted(transactionID: pendingID, journal: .clean, artifacts: .init()),
            triple: triple, hasDurableProtection: false
        ) == .init(state: .protectionFailed(triple), evidence: .unsafeLatestUnprotected))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .externalSourceChanged(transactionID: pendingID, reason: .externalBytesChanged, journal: .clean, artifacts: .init()),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .externalSourceChanged(triple), evidence: .unsafeLatestUnprotected))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .persistenceBlocked(transactionID: pendingID, reason: .unreadablePrimary, journal: .clean),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .persistenceBlocked(triple), evidence: .unsafeLatestUnprotected))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .committed(.init(workspaceRevision: 1, persistedDraft: validReceipt), journal: cleanup),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .cleanupPending(triple, identity: cleanupIdentity, step: .record), evidence: .persisted(triple)))
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .draftAlreadyPersisted(validReceipt, journal: cleanup),
            triple: triple, hasDurableProtection: true
        ) == .init(state: .cleanupPending(triple, identity: cleanupIdentity, step: .record), evidence: .persisted(triple)))

        let wrongReceipts = [
            WorkspaceSaveReceipt(workspaceRevision: 1, persistedDraft: nil),
            .init(workspaceRevision: 1, persistedDraft: .init(
                noteID: NoteID(UUID()), editSessionID: validReceipt.editSessionID,
                draftGeneration: validReceipt.draftGeneration,
                noteSnapshotChecksum: validReceipt.noteSnapshotChecksum,
                persistedNoteRevision: validReceipt.persistedNoteRevision
            )),
            .init(workspaceRevision: 1, persistedDraft: .init(
                noteID: validReceipt.noteID, editSessionID: .editor(UUID()),
                draftGeneration: validReceipt.draftGeneration,
                noteSnapshotChecksum: validReceipt.noteSnapshotChecksum,
                persistedNoteRevision: validReceipt.persistedNoteRevision
            )),
            .init(workspaceRevision: 1, persistedDraft: .init(
                noteID: validReceipt.noteID, editSessionID: validReceipt.editSessionID,
                draftGeneration: validReceipt.draftGeneration + 1,
                noteSnapshotChecksum: validReceipt.noteSnapshotChecksum,
                persistedNoteRevision: validReceipt.persistedNoteRevision
            )),
            .init(workspaceRevision: 1, persistedDraft: .init(
                noteID: validReceipt.noteID, editSessionID: validReceipt.editSessionID,
                draftGeneration: validReceipt.draftGeneration,
                noteSnapshotChecksum: "wrong-checksum",
                persistedNoteRevision: validReceipt.persistedNoteRevision
            ))
        ]
        for receipt in wrongReceipts {
            let mapping = NoteAutosaveOutcomeMapping.workspace(
                .committed(receipt, journal: .clean), triple: triple, hasDurableProtection: true
            )
            #expect(mapping.evidence == .unsafeLatestUnprotected)
            #expect(mapping.state == .invalidPersistedReceipt(triple))

            let retryMapping = NoteAutosaveOutcomeMapping.retry(
                .committed(.save(receipt), journal: .clean), triple: triple, hasDurableProtection: true
            )
            #expect(retryMapping.state == .invalidPersistedReceipt(triple))
            #expect(retryMapping.evidence == .unsafeLatestUnprotected)
            #expect(retryMapping.state.statusMessage == "保存回执异常，当前草稿未保存。")

            if let persistedDraft = receipt.persistedDraft {
                let identicalMapping = NoteAutosaveOutcomeMapping.workspace(
                    .draftAlreadyPersisted(persistedDraft, journal: .clean),
                    triple: triple,
                    hasDurableProtection: true
                )
                #expect(identicalMapping.state == .invalidPersistedReceipt(triple))
                #expect(identicalMapping.evidence == .unsafeLatestUnprotected)
            }
        }

        let restored = WorkspaceRestoreOutcome(
            receipt: .init(workspaceRevision: 1, persistedDraft: nil),
            rollback: .nonePreviousSourceAbsent
        )
        #expect(NoteAutosaveOutcomeMapping.workspace(
            .restored(restored), triple: triple, hasDurableProtection: true
        ) == .init(state: .noChange(triple), evidence: .unsafeLatestUnprotected))
        let restoreRetry = NoteAutosaveOutcomeMapping.retry(
            .committed(.restore(restored), journal: .clean), triple: triple, hasDurableProtection: true
        )
        #expect(restoreRetry == .init(state: .restoredNotProof(triple), evidence: .unsafeLatestUnprotected))
        #expect(restoreRetry.state.statusMessage == "恢复结果不能证明当前草稿已保存。")
    }

    @Test func everyCleanupStepKeepsItsExactIdentityReadOnlyAndMapsItsOriginalTerminalProof() throws {
        let triple = try makeMappingTriple()
        let receipt = makeReceipt(for: triple)
        let identity = triple.identityAndGeneration.identity
        let token = DraftRecoveryToken(
            identityAndGeneration: triple.identityAndGeneration,
            noteSnapshotChecksum: triple.noteSnapshotChecksum,
            journalChecksum: "journal-checksum"
        )
        let completion = DraftRecoveryCompletion(
            token: token,
            action: .restoreAsCurrent,
            source: .init(workspaceRevision: 3, workspaceChecksum: "source"),
            result: .init(
                noteID: identity.noteID,
                noteSnapshotChecksum: triple.noteSnapshotChecksum,
                noteRevision: 4,
                workspaceRevision: 4
            ),
            state: .pending
        )
        let steps: [JournalCleanupStep] = [
            .record, .acknowledge, .unbind, .clear,
            .discardRecovery(token), .markRecoveryCompletion(completion),
            .discardRecoveryCompletion(completion), .abandonRecoveryCompletion(completion)
        ]

        for step in steps {
            let journal = JournalResolutionStatus.cleanupPending(identity: identity, step: step)
            #expect(NoteAutosaveOutcomeMapping.workspace(
                .committed(.init(workspaceRevision: 4, persistedDraft: receipt), journal: journal),
                triple: triple, hasDurableProtection: true
            ) == .init(state: .cleanupPending(triple, identity: identity, step: step), evidence: .persisted(triple)))
            #expect(NoteAutosaveOutcomeMapping.workspace(
                .notCommitted(transactionID: UUID(), journal: journal, artifacts: .init()),
                triple: triple, hasDurableProtection: true
            ) == .init(state: .cleanupPending(triple, identity: identity, step: step), evidence: .protectedOnly(triple)))
            #expect(NoteAutosaveOutcomeMapping.retry(
                .committed(.save(.init(workspaceRevision: 4, persistedDraft: receipt)), journal: journal),
                triple: triple, hasDurableProtection: true
            ) == .init(state: .cleanupPending(triple, identity: identity, step: step), evidence: .persisted(triple)))
        }
    }

    @Test func realStoreNoChangeConflictAndDraftSupersededUseTheirTypedUnsafeTerminalStates() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)

        let noChangeRepository = InMemoryWorkspaceRepository(initialState: calendar)
        let noChangeStore = WorkspaceStore(initialState: .empty(calendar: calendar), repository: noChangeRepository)
        await noChangeStore.load()
        _ = try await noChangeStore.sendWorkspace(.createNote(.init(note: note)))
        let noChangeCoordinator = NoteAutosaveCoordinator(store: noChangeStore, scheduler: BoundaryAutosaveScheduler())
        try noChangeCoordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try noChangeCoordinator.update(title: "")
        let noChangeTriple = try #require(noChangeCoordinator.currentTriple)
        #expect(await noChangeCoordinator.flushLatest() == .unsafeLatestUnprotected)
        #expect(noChangeCoordinator.autosaveState == .noChange(noChangeTriple))

        let conflictRepository = InMemoryWorkspaceRepository(initialState: calendar)
        let conflictStore = WorkspaceStore(initialState: .empty(calendar: calendar), repository: conflictRepository)
        await conflictStore.load()
        _ = try await conflictStore.sendWorkspace(.createNote(.init(note: note)))
        let conflictCoordinator = NoteAutosaveCoordinator(store: conflictStore, scheduler: BoundaryAutosaveScheduler())
        try conflictCoordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        let submitted = try conflictCoordinator.update(title: "编辑者标题")
        var externalSnapshot = submitted.baseSnapshot
        externalSnapshot.title = "外部标题"
        let externalSubmission = NoteDraftSubmission(
            noteID: submitted.noteID,
            editSessionID: UUID(),
            baseNoteRevision: submitted.baseNoteRevision,
            baseNoteSnapshotChecksum: submitted.baseNoteSnapshotChecksum,
            baseSnapshot: submitted.baseSnapshot,
            baseLinkedTaskBlockLinks: submitted.baseLinkedTaskBlockLinks,
            draftGeneration: 1,
            snapshot: externalSnapshot,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(externalSnapshot),
            modifiedFields: [.title],
            linkedBlockDeletionDispositions: [:]
        )
        _ = try await conflictStore.sendWorkspace(.updateNote(externalSubmission))
        let conflictTriple = try #require(conflictCoordinator.currentTriple)
        #expect(await conflictCoordinator.flushLatest() == .unsafeLatestUnprotected)
        #expect(conflictCoordinator.autosaveState == .conflict(conflictTriple))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-superseded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let supersededRepository = InMemoryWorkspaceRepository(initialState: calendar)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let supersededStore = WorkspaceStore(
            initialState: .empty(calendar: calendar), repository: supersededRepository, journal: journal
        )
        await supersededStore.load()
        _ = try await supersededStore.sendWorkspace(.createNote(.init(note: note)))
        let supersededCoordinator = NoteAutosaveCoordinator(store: supersededStore, scheduler: BoundaryAutosaveScheduler())
        try supersededCoordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        let supersededSubmission = try supersededCoordinator.update(title: "旧 generation")
        let futureSubmission = NoteDraftSubmission(
            noteID: supersededSubmission.noteID,
            editSessionID: supersededSubmission.editSessionID,
            baseNoteRevision: supersededSubmission.baseNoteRevision,
            baseNoteSnapshotChecksum: supersededSubmission.baseNoteSnapshotChecksum,
            baseSnapshot: supersededSubmission.baseSnapshot,
            baseLinkedTaskBlockLinks: supersededSubmission.baseLinkedTaskBlockLinks,
            draftGeneration: supersededSubmission.draftGeneration + 1,
            snapshot: supersededSubmission.snapshot,
            noteSnapshotChecksum: supersededSubmission.noteSnapshotChecksum,
            modifiedFields: supersededSubmission.modifiedFields,
            linkedBlockDeletionDispositions: supersededSubmission.linkedBlockDeletionDispositions
        )
        try await journal.persist(try DraftJournalCoordinator.entry(
            submission: futureSubmission, workspaceRevision: supersededStore.state.revision, clock: Date.init
        ))
        let supersededTriple = try #require(supersededCoordinator.currentTriple)
        #expect(await supersededCoordinator.flushLatest() == .unsafeLatestUnprotected)
        #expect(supersededCoordinator.autosaveState == .draftSuperseded(supersededTriple))
    }

    @Test func realStoreExternalSourceAndUnreadablePrimaryFailuresUseTypedUnsafeTerminalStates() async throws {
        let calendar = makeEmptyState()
        let note = makeAutosaveTestNote(categoryID: calendar.uncategorizedID)

        let sourceChangedRepository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let sourceChangedStore = WorkspaceStore(
            initialState: .empty(calendar: calendar), repository: sourceChangedRepository
        )
        await sourceChangedStore.load()
        _ = try await sourceChangedStore.sendWorkspace(.createNote(.init(note: note)))
        let sourceChangedCoordinator = NoteAutosaveCoordinator(
            store: sourceChangedStore, scheduler: BoundaryAutosaveScheduler()
        )
        try sourceChangedCoordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try sourceChangedCoordinator.update(title: "外部变化")
        let sourceChangedTriple = try #require(sourceChangedCoordinator.currentTriple)
        await sourceChangedRepository.failNextSaveWithSourceChanged()
        #expect(await sourceChangedCoordinator.flushLatest() == .unsafeLatestUnprotected)
        #expect(sourceChangedCoordinator.autosaveState == .externalSourceChanged(sourceChangedTriple))

        let unreadableRepository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let unreadableStore = WorkspaceStore(initialState: .empty(calendar: calendar), repository: unreadableRepository)
        await unreadableStore.load()
        _ = try await unreadableStore.sendWorkspace(.createNote(.init(note: note)))
        let unreadableCoordinator = NoteAutosaveCoordinator(store: unreadableStore, scheduler: BoundaryAutosaveScheduler())
        try unreadableCoordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try unreadableCoordinator.update(title: "主文件不可读")
        let unreadableTriple = try #require(unreadableCoordinator.currentTriple)
        await unreadableRepository.failNextSaveWithUnreadablePrimary()
        #expect(await unreadableCoordinator.flushLatest() == .unsafeLatestUnprotected)
        #expect(unreadableCoordinator.autosaveState == .persistenceBlocked(unreadableTriple))
    }
}

@MainActor
private final class AutosaveImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

@MainActor
private final class GateAutosaveScheduler: NoteAutosaveScheduling {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(milliseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitForSleepCount(_ expected: Int) async {
        while continuations.count < expected { await Task.yield() }
    }

    func release(at index: Int) {
        continuations[index].resume()
    }
}

@MainActor
private final class BoundaryAutosaveScheduler: NoteAutosaveScheduling {
    private var requested: [UInt64] = []
    private var continuations: [UInt64: [CheckedContinuation<Void, Error>]] = [:]

    func sleep(milliseconds: UInt64) async throws {
        requested.append(milliseconds)
        try await withCheckedThrowingContinuation { continuation in
            continuations[milliseconds, default: []].append(continuation)
        }
    }

    func waitForRequested(_ expected: Set<UInt64>) async {
        while !expected.isSubset(of: Set(requested)) { await Task.yield() }
    }

    func release(milliseconds: UInt64) {
        guard var waiting = continuations[milliseconds], !waiting.isEmpty else {
            Issue.record("No timer waiting at \(milliseconds)ms")
            return
        }
        let continuation = waiting.removeFirst()
        continuations[milliseconds] = waiting
        continuation.resume()
    }

    func waitForJournalRecord(_ journal: DraftJournalRepository) async {
        while (try? await journal.current())?.records.isEmpty != false { await Task.yield() }
    }
}

private final class CleanupFailingJournalWriter: AtomicFileWriting, @unchecked Sendable {
    var failOnWrite: Int?
    var failAllSubsequent = false
    private(set) var writeCount = 0

    init(failOnWrite: Int?) {
        self.failOnWrite = failOnWrite
    }

    func replaceAtomically(data: Data, at destination: URL) throws {
        writeCount += 1
        if failAllSubsequent || writeCount == failOnWrite {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

@MainActor
private final class NativeFinalizerGate {
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0
    private(set) var acceptedCount = 0

    func finalize(
        _ permit: NoteNativeInputPermit,
        apply: @escaping @MainActor (NoteNativeInputPermit, NoteNativeInputEdit) -> Bool
    ) async -> Bool {
        requestCount += 1
        if requestCount == 1 {
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
        let accepted = apply(permit, .init(title: "已完成并发原生输入"))
        if accepted { acceptedCount += 1 }
        return accepted
    }

    func waitForFirstRequest() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func makeAutosaveTestNote(categoryID: UUID) -> Note {
    Note.empty(
        id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000001200")!),
        categoryID: categoryID,
        now: Date(timeIntervalSince1970: 1_754_000_000)
    )
}

private func makeMappingTriple() throws -> NoteAutosaveTriple {
    let note = makeAutosaveTestNote(categoryID: UUID(uuidString: "00000000-0000-0000-0000-0000000012EE")!)
    let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
    let submission = NoteDraftSubmission(
        noteID: note.id,
        editSessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000012EF")!,
        baseNoteRevision: note.revision,
        baseNoteSnapshotChecksum: checksum,
        baseSnapshot: note,
        baseLinkedTaskBlockLinks: [],
        draftGeneration: 7,
        snapshot: note,
        noteSnapshotChecksum: checksum,
        modifiedFields: [],
        linkedBlockDeletionDispositions: [:]
    )
    return .init(submission: submission)
}

private func makeReceipt(for triple: NoteAutosaveTriple) -> PersistedDraftReceipt {
    .init(
        noteID: triple.identityAndGeneration.identity.noteID,
        editSessionID: triple.identityAndGeneration.identity.editSessionID,
        draftGeneration: triple.identityAndGeneration.draftGeneration,
        noteSnapshotChecksum: triple.noteSnapshotChecksum,
        persistedNoteRevision: 1
    )
}
