import CalendarDomain
@testable import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("NoteDraftRecoveryStoreTests")
@MainActor
struct NoteDraftRecoveryStoreTests {
    @Test @MainActor func startupSilentlyClearsARecoveryRecordThatOnlyChangesRevisionAndTime() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.title = "内容完全相同"
        persisted.revision = 1
        var draft = persisted
        draft.revision = 2
        draft.updatedAt = Date(timeIntervalSince1970: 50)
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-identical-persisted-recovery-\(UUID())", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("workspace.json")
        try WorkspaceDocumentCodec.encode(state).write(to: documentURL)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        try await journal.persist(recoveryEntry(draft: draft, session: UUID(), workspaceRevision: state.revision))
        let repository = JSONWorkspaceRepository(documentURL: documentURL, seed: { state })
        let store = WorkspaceStore(initialState: .empty(calendar: state.calendar), repository: repository, journal: journal)
        await store.load()

        #expect(store.phase == .ready)
        #expect(try await journal.current()?.records.isEmpty == true)
        #expect(store.state.notes[persisted.id] == persisted)
    }
    @Test func continuousEditorRecoveryPreservesSoftBreaksFormattingEmptyBlocksAndLinkedTasks() async throws {
        let categoryID = UUID()
        let noteID = NoteID()
        let richID = BlockID()
        let emptyID = BlockID()
        let linkedID = BlockID()
        let localID = BlockID()
        let completedAt = Date(timeIntervalSince1970: 1_755_001_000)
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "已联动待办",
            categoryID: categoryID,
            schedule: .init(
                startDate: .init(year: 2026, month: 8, day: 19)!,
                endDate: .init(year: 2026, month: 8, day: 19)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: completedAt,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.document = .init(blocks: [
            try .task(id: linkedID, text: "已联动待办", completedAt: completedAt)
        ])
        persisted.revision = 1
        var draft = persisted
        draft.title = "连续编辑器恢复"
        draft.document = .init(blocks: [
            .init(
                id: richID,
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "第一行", marks: [.bold]),
                    .init(text: "\n第二行", marks: [.italic])
                ]),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: emptyID,
                kind: .paragraph,
                inlineContent: .plain(""),
                taskState: nil,
                indentLevel: 0
            ),
            try .task(id: linkedID, text: "已联动待办", completedAt: completedAt),
            try .task(id: localID, text: "仅本地待办")
        ])
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.calendar.items[item.id] = item
        state.notes[noteID] = persisted
        state.taskBlockLinks = [.init(noteID: noteID, blockID: linkedID, calendarItemID: item.id)]
        state.calendarNoteRelations.baselines[.item(item.id)] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: []
        )
        let fixture = try await recoveryFixture(state: state, draft: draft)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        #expect(candidate.draft == draft)

        guard case .committed = try await fixture.store.resolveDraftRecovery(
            candidate.token,
            action: .restoreAsCurrent
        ) else {
            Issue.record("复杂连续正文草稿必须能够原样恢复")
            return
        }
        let restored = try #require(fixture.store.state.notes[noteID])
        #expect(restored.document == draft.document)
        #expect(restored.document.blocks[0].inlineContent.spans[0].marks == [.bold])
        #expect(restored.document.blocks[0].inlineContent.spans[1].text == "\n第二行")
        #expect(restored.document.blocks[1].inlineContent.spans.map(\.text).joined().isEmpty)
        #expect(restored.document.blocks[2].taskState?.completedAt == completedAt)
        #expect(restored.document.blocks[3].taskState?.completedAt == nil)
    }

    @Test func protectedCapabilityCommitsItsFrozenSubmissionExactlyOnce() async throws {
        let categoryID = UUID()
        let base = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        var persisted = base
        persisted.revision = 1
        state.revision = 1
        state.notes[persisted.id] = persisted
        var edited = persisted
        edited.title = "protected title"
        let submission = NoteDraftSubmission(
            noteID: persisted.id,
            editSessionID: UUID(),
            baseNoteRevision: persisted.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(persisted),
            baseSnapshot: persisted,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: 1,
            snapshot: edited,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(edited),
            modifiedFields: [.title],
            linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-10a-capability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initialState = state
        let repository = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("workspace.json"), seed: { initialState })
        let store = WorkspaceStore(
            initialState: state,
            repository: repository,
            journal: DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json")),
            clock: { .distantPast }
        )
        await store.load()
        #expect(store.phase == .ready)

        let capability: ProtectedNoteDraft
        switch try await store.protectDraft(submission) {
        case let .protected(value): capability = value
        case .superseded: Issue.record("Initial draft must receive a Store-issued capability"); return
        }
        guard case .committed = try await store.commitProtectedDraft(capability) else {
            Issue.record("The protected draft must be queued and saved once")
            return
        }

        #expect(try await store.commitProtectedDraft(capability) == .draftSuperseded)
        #expect(store.state.notes[persisted.id]?.title == "protected title")
    }

    @Test func startupPublishesABareDifferentJournalRecordAsARecoveryCandidateAndKeepDiscardsOnlyIt() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "review this recovered draft"
        let fixture = try await recoveryFixture(persisted: persisted, draft: draft, categoryID: categoryID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        #expect(candidate.draft == draft)
        #expect(candidate.persisted == persisted)

        let outcome = try await fixture.store.resolveDraftRecovery(candidate.token, action: .keepPersisted)
        #expect(outcome == .noChange(.identical, journal: .clean))
        #expect(fixture.store.phase == .ready)
        #expect(fixture.store.state.notes[persisted.id] == persisted)
        #expect(try await fixture.journal.current()?.records.isEmpty == true)
    }

    @Test func keepingTheCurrentNoteCanBeUndoneBackToTheExitVersionDuringThisSession() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.title = "当前笔记"
        var draft = persisted
        draft.title = "退出前版本"
        let fixture = try await recoveryFixture(persisted: persisted, draft: draft, categoryID: categoryID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        _ = try await fixture.store.resolveDraftRecovery(candidate.token, action: .keepPersisted)

        #expect(fixture.store.canUndo)
        #expect(fixture.store.canUndoRecoverySelection)
        guard case .committed = try await fixture.store.undo() else {
            Issue.record("撤销恢复选择必须保存另一个版本")
            return
        }
        #expect(fixture.store.state.notes[persisted.id]?.title == "退出前版本")
    }

    @Test func restoringTheExitVersionCanBeUndoneBackToTheCurrentNote() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.title = "当前笔记"
        var draft = persisted
        draft.title = "退出前版本"
        let fixture = try await recoveryFixture(persisted: persisted, draft: draft, categoryID: categoryID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        _ = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)

        #expect(fixture.store.canUndo)
        #expect(fixture.store.canUndoRecoverySelection)
        _ = try await fixture.store.undo()
        #expect(fixture.store.state.notes[persisted.id]?.title == "当前笔记")
    }

    @Test func savingBothVersionsCanBeUndoneByRemovingOnlyTheRecoveredCopy() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "退出前版本"
        let fixture = try await recoveryFixture(persisted: persisted, draft: draft, categoryID: categoryID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        let recoveredID = NoteID(UUID())
        let blockIDs = draft.document.blocks.map { _ in BlockID(UUID()) }

        _ = try await fixture.store.resolveDraftRecovery(
            candidate.token,
            action: .saveAsNew(noteID: recoveredID, blockIDs: blockIDs)
        )

        #expect(fixture.store.state.notes[recoveredID] != nil)
        #expect(fixture.store.canUndo)
        #expect(fixture.store.canUndoRecoverySelection)
        _ = try await fixture.store.undo()
        #expect(fixture.store.state.notes[recoveredID] == nil)
        #expect(fixture.store.state.notes[persisted.id] != nil)
    }

    @Test func restoreAsCurrentNormalizesRetainedTaskCompletionToTheCurrentCalendarItem() async throws {
        let categoryID = UUID()
        let noteID = NoteID(UUID())
        let blockID = BlockID(UUID())
        let completedAt = Date(timeIntervalSince1970: 42)
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "linked", categoryID: categoryID,
            schedule: .init(
                startDate: .init(year: 2026, month: 8, day: 10)!,
                endDate: .init(year: 2026, month: 8, day: 10)!,
                startTime: nil, endTime: nil
            ),
            completedAt: completedAt, createdAt: .distantPast, updatedAt: .distantPast
        )
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.document = .init(blocks: [try .task(id: blockID, text: "linked", completedAt: completedAt)])
        persisted.revision = 1
        var draft = persisted
        draft.title = "restored task title"
        draft.document.blocks[0].taskState?.completedAt = nil
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.calendar.items[item.id] = item
        state.notes[noteID] = persisted
        state.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: item.id)]
        state.calendarNoteRelations.baselines[.item(item.id)] = .init(primaryNoteID: noteID, referenceNoteIDs: [])
        let fixture = try await recoveryFixture(state: state, draft: draft)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        guard case .committed = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent) else {
            Issue.record("Restoring a valid recovery candidate must save it once")
            return
        }
        #expect(fixture.store.phase == .ready)
        #expect(fixture.store.state.notes[noteID]?.title == "restored task title")
        #expect(fixture.store.state.notes[noteID]?.document.blocks.first?.taskState?.completedAt == completedAt)
        #expect(fixture.store.state.taskBlockLinks == [.init(noteID: noteID, blockID: blockID, calendarItemID: item.id)])
    }

    @Test func saveAsNewRemapsEveryBlockAndDropsCalendarRelationsWhileKeepingTaskContent() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        let sourceBlock = BlockID(UUID())
        var draft = persisted
        draft.title = "separate recovered note"
        draft.document = .init(blocks: [try .task(id: sourceBlock, text: "done independently", completedAt: .distantPast)])
        let fixture = try await recoveryFixture(persisted: persisted, draft: draft, categoryID: categoryID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        let savedID = NoteID(UUID())
        let remappedBlock = BlockID(UUID())

        guard case .committed = try await fixture.store.resolveDraftRecovery(
            candidate.token,
            action: .saveAsNew(noteID: savedID, blockIDs: [remappedBlock])
        ) else {
            Issue.record("Saving a reviewed draft as new must persist one new Note")
            return
        }
        let saved = try #require(fixture.store.state.notes[savedID])
        #expect(saved.document.blocks.map(\.id) == [remappedBlock])
        #expect(saved.document.blocks.first?.taskState?.completedAt == .distantPast)
        #expect(saved.archivedAt == nil)
        #expect(fixture.store.state.taskBlockLinks.contains { $0.noteID == savedID } == false)
        #expect(fixture.store.state.calendarNoteRelations.baselines.values.contains { $0.primaryNoteID == savedID } == false)
    }

    @Test func recoveryDiscardFailurePublishesTheRestoreOnceThenParksAnExactReadonlyRetry() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "published before discard retry"
        let writer = RecoveryToggleJournalWriter()
        let fixture = try await recoveryFixture(
            persisted: persisted,
            draft: draft,
            categoryID: categoryID,
            writer: writer
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        writer.failOnWrite(offsetFromNow: 3)

        let outcome = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)
        guard case let .committed(_, journal: .cleanupPending(identity, .discardRecoveryCompletion(completion))) = outcome else {
            Issue.record("A failed exact recovery discard must park its typed token after the save")
            return
        }
        #expect(completion.token == candidate.token)
        #expect(fixture.store.state.notes[persisted.id]?.title == "published before discard retry")
        #expect(fixture.store.phase == .parkedJournalCleanup(identity, .discardRecoveryCompletion(completion)))
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await fixture.store.sendWorkspace(.archiveNote(persisted.id, at: .distantFuture))
        }

        writer.shouldFail = false
        #expect(await fixture.store.retryJournalCleanup(identity) == .clean)
        #expect(fixture.store.phase == .ready)
        #expect(try await fixture.journal.current()?.records.isEmpty == true)
    }

    @Test func differentRecoveryCandidatesClaimImmediatelyThenSaveInFIFOOrder() async throws {
        let categoryID = UUID()
        var firstPersisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        firstPersisted.revision = 1
        var firstDraft = firstPersisted
        firstDraft.title = "first recovered change"
        var secondPersisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        secondPersisted.revision = 1
        var secondDraft = secondPersisted
        secondDraft.title = "second recovered change"
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [firstPersisted.id: firstPersisted, secondPersisted.id: secondPersisted]
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [firstDraft, secondDraft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
        let first = try #require(candidates.first { $0.draft.id == firstDraft.id })
        let second = try #require(candidates.first { $0.draft.id == secondDraft.id })
        let secondSavedID = NoteID(UUID())
        let secondBlockIDs = second.draft.document.blocks.map { _ in BlockID(UUID()) }

        await fixture.repository.suspendNextSave()
        let firstResolution = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(first.token, action: .restoreAsCurrent)
        }
        await fixture.repository.waitForSaveStart()
        #expect(try await fixture.store.resolveDraftRecovery(first.token, action: .restoreAsCurrent) == .draftSuperseded)
        let secondResolution = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(
                second.token,
                action: .saveAsNew(noteID: secondSavedID, blockIDs: secondBlockIDs)
            )
        }

        await fixture.repository.resumeSave()
        guard case .committed = try await firstResolution.value,
              case .committed = try await secondResolution.value
        else {
            Issue.record("Two claimed recovery records must each finish through the Store FIFO")
            return
        }
        #expect(await fixture.repository.saveCount == 2)
        #expect(fixture.store.phase == .ready)
        #expect(fixture.store.state.notes[firstPersisted.id]?.title == "first recovered change")
        #expect(fixture.store.state.notes[secondPersisted.id] == secondPersisted)
        #expect(fixture.store.state.notes[secondSavedID]?.title == "second recovered change")
    }

    @Test func committedSaveAsNewWithDiscardFailureIsDurablyCompletedAcrossFreshStore() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "separate durable recovery"
        let writer = RecoveryToggleJournalWriter()
        let fixture = try await controlledRecoveryFixture(
            state: recoveryState(persisted: persisted, categoryID: categoryID),
            drafts: [draft],
            writer: writer
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        let savedID = NoteID(UUID())
        let blockIDs = candidate.draft.document.blocks.map { _ in BlockID(UUID()) }
        writer.failOnWrite(offsetFromNow: 3)

        guard case .committed = try await fixture.store.resolveDraftRecovery(
            candidate.token,
            action: .saveAsNew(noteID: savedID, blockIDs: blockIDs)
        ) else {
            Issue.record("The first save-as-new must write its main state before cleanup fails")
            return
        }
        #expect(await fixture.repository.saveCount == 1)

        writer.shouldFail = false
        let fresh = WorkspaceStore(
            initialState: .empty(calendar: fixture.initialCalendar),
            repository: fixture.repository,
            journal: fixture.journal,
            clock: { .distantPast }
        )
        await fresh.load()
        #expect(fresh.phase == .ready)
        #expect(fresh.state.notes[savedID]?.title == "separate durable recovery")
        #expect(await fixture.repository.saveCount == 1)
        #expect(try await fixture.journal.current()?.records.isEmpty == true)
    }

    @Test func startupCleanupRetryRescansRemainingBareRecoveryBeforePublishingReady() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var bareDraft = persisted
        bareDraft.title = "still requires review after saved cleanup"
        let writer = RecoveryToggleJournalWriter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-startup-cleanup-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let savedEntry = try recoveryEntry(draft: persisted, session: UUID(), workspaceRevision: 1)
        try await journal.persist(savedEntry)
        let savedReceipt = PersistedDraftReceipt(
            noteID: persisted.id,
            editSessionID: savedEntry.editSessionID,
            draftGeneration: savedEntry.draftGeneration,
            noteSnapshotChecksum: savedEntry.noteSnapshotChecksum,
            persistedNoteRevision: persisted.revision
        )
        #expect(try await journal.acknowledgeAlreadyPersisted(savedReceipt) == .applied)
        try await journal.persist(try recoveryEntry(draft: bareDraft, session: UUID(), workspaceRevision: 1))
        writer.failOnWrite(offsetFromNow: 1)

        let initial = recoveryState(persisted: persisted, categoryID: categoryID)
        let repository = RecoveryControlledRepository(backing: JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("workspace.json"), seed: { initial }
        ))
        let store = WorkspaceStore(
            initialState: .empty(calendar: initial.calendar), repository: repository,
            journal: journal, clock: { .distantPast }
        )
        await store.load()
        guard case let .parkedJournalCleanup(identity, .clear) = store.phase else {
            Issue.record("A failed startup clear must stay parked instead of skipping later bare records")
            return
        }

        #expect(await store.retryJournalCleanup(identity) == .clean)
        let candidates = try #require(recoveryCandidates(from: store.phase))
        #expect(candidates.count == 1)
        #expect(candidates[0].draft.title == "still requires review after saved cleanup")
    }

    @Test func repairAfterDanglingRecoveryKeepsTheExactBareCandidateInsteadOfPublishingReady() async throws {
        let categoryID = UUID()
        let noteID = NoteID(UUID())
        let blockID = BlockID(UUID())
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.document = .init(blocks: [try .task(id: blockID, text: "dangling", completedAt: nil)])
        var draft = persisted
        draft.title = "recovery must survive relationship repair"
        var invalid = recoveryState(persisted: persisted, categoryID: categoryID)
        let missingItemID = UUID()
        invalid.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: missingItemID)]
        let report = WorkspaceConsistencyInspector.inspect(invalid)
        #expect(report.hasFatalIssues == false)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-recovery-repair-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        try await journal.persist(try recoveryEntry(draft: draft, session: UUID(), workspaceRevision: invalid.revision))
        let repository = RecoveryRepairRepository(initial: invalid)
        let store = WorkspaceStore(
            initialState: .empty(calendar: invalid.calendar), repository: repository,
            journal: journal, clock: { .distantPast }
        )
        await store.load()
        let candidate = try #require(recoveryCandidate(from: store.phase))

        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)
        }
        #expect(store.phase == .needsRelationshipRepair)
        #expect(try await journal.isCurrentBare(candidate.token))

        var supersedingDraft = draft
        supersedingDraft.title = "new generation while repair is saving"
        guard case let .editor(session) = candidate.token.identityAndGeneration.identity.editSessionID else {
            Issue.record("Recovery fixture must use an editor session")
            return
        }
        let supersedingToken: DraftRecoveryToken
        switch try await journal.protect(try recoveryEntry(
            draft: supersedingDraft, session: session, workspaceRevision: invalid.revision, generation: 2
        )) {
        case let .protected(value): supersedingToken = value
        case .superseded, .busy: Issue.record("The newer recovery generation must replace the reviewed token"); return
        }

        guard case .committed = try await store.sendWorkspace(.repairConsistency(repair)) else {
            Issue.record("The dangling relation repair must persist its repaired candidate")
            return
        }
        let recovered = try #require(recoveryCandidates(from: store.phase))
        #expect(recovered.map(\.token) == [supersedingToken])
        #expect(try await journal.isCurrentBare(candidate.token) == false)
        #expect(try await journal.isCurrentBare(supersedingToken))
        #expect(await repository.saveCount == 1)
        #expect(store.state.notes[noteID]?.title == persisted.title)
        #expect(store.state.notes[noteID]?.document == persisted.document)
        #expect(store.state.notes[noteID]?.revision == persisted.revision)
    }

    @Test func saveAsNewRejectsBlockCollisionWithoutConsumingRecoveryThenPreservesMultiBlockOrder() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        let sourceIDs = [BlockID(UUID()), BlockID(UUID()), BlockID(UUID())]
        var draft = persisted
        draft.document = .init(blocks: [
            .init(id: sourceIDs[0], kind: .paragraph, inlineContent: .plain("first"), taskState: nil, indentLevel: 0),
            try .task(id: sourceIDs[1], text: "second task", completedAt: .distantPast),
            .init(id: sourceIDs[2], kind: .quote, inlineContent: .plain("third"), taskState: nil, indentLevel: 0)
        ])
        let collision = BlockID(UUID())
        var other = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        other.revision = 1
        other.document = .init(blocks: [
            .init(id: collision, kind: .paragraph, inlineContent: .plain("existing"), taskState: nil, indentLevel: 0)
        ])
        var state = recoveryState(persisted: persisted, categoryID: categoryID)
        state.notes[other.id] = other
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [draft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        let savedID = NoteID(UUID())
        let first = BlockID(UUID())
        let third = BlockID(UUID())

        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await fixture.store.resolveDraftRecovery(
                candidate.token,
                action: .saveAsNew(noteID: savedID, blockIDs: [first, collision, third])
            )
        }
        #expect(try await fixture.journal.isCurrentBare(candidate.token))

        let remapped = [BlockID(UUID()), BlockID(UUID()), BlockID(UUID())]
        guard case .committed = try await fixture.store.resolveDraftRecovery(
            candidate.token,
            action: .saveAsNew(noteID: savedID, blockIDs: remapped)
        ) else {
            Issue.record("A rejected collision must not consume the recovery selection")
            return
        }
        let saved = try #require(fixture.store.state.notes[savedID])
        #expect(saved.document.blocks.map(\.id) == remapped)
        #expect(saved.document.blocks.map(\.kind) == [.paragraph, .task, .quote])
        #expect(saved.document.blocks[1].taskState?.completedAt == .distantPast)
    }

    @Test func uncertainRecoveryRestartReconcilesCommittedNotCommittedAndSourceChangedWithoutReplay() async throws {
        let categoryID = UUID()

        func makeFixture() async throws -> (ControlledRecoveryStoreFixture, DraftRecoveryCandidate, NoteID, [BlockID]) {
            var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
            persisted.revision = 1
            var draft = persisted
            draft.title = "uncertain recovery"
            let fixture = try await controlledRecoveryFixture(
                state: recoveryState(persisted: persisted, categoryID: categoryID), drafts: [draft]
            )
            let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
            return (fixture, candidate, NoteID(UUID()), candidate.draft.document.blocks.map { _ in BlockID(UUID()) })
        }

        let committed = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: committed.0.directory) }
        await committed.0.repository.makeNextSaveUncertain(afterWriting: true)
        await committed.0.repository.setReconciliation(.stillPending(.init()))
        guard case .commitPending = try await committed.0.store.resolveDraftRecovery(
            committed.1.token,
            action: .saveAsNew(noteID: committed.2, blockIDs: committed.3)
        ) else { Issue.record("Injected uncertain write must park"); return }
        let committedFresh = WorkspaceStore(
            initialState: .empty(calendar: committed.0.initialCalendar), repository: committed.0.repository,
            journal: committed.0.journal, clock: { .distantPast }
        )
        await committedFresh.load()
        #expect(committedFresh.phase == .ready)
        #expect(committedFresh.state.notes[committed.2] != nil)
        #expect(await committed.0.repository.saveCount == 1)

        let notCommitted = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: notCommitted.0.directory) }
        await notCommitted.0.repository.makeNextSaveUncertain(afterWriting: false)
        await notCommitted.0.repository.setReconciliation(.stillPending(.init()))
        guard case .commitPending = try await notCommitted.0.store.resolveDraftRecovery(
            notCommitted.1.token,
            action: .saveAsNew(noteID: notCommitted.2, blockIDs: notCommitted.3)
        ) else { Issue.record("Unwritten uncertain recovery must park"); return }
        let notCommittedFresh = WorkspaceStore(
            initialState: .empty(calendar: notCommitted.0.initialCalendar), repository: notCommitted.0.repository,
            journal: notCommitted.0.journal, clock: { .distantPast }
        )
        await notCommittedFresh.load()
        #expect(recoveryCandidates(from: notCommittedFresh.phase)?.map(\.token) == [notCommitted.1.token])
        #expect(await notCommitted.0.repository.saveCount == 0)

        let sourceChanged = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: sourceChanged.0.directory) }
        await sourceChanged.0.repository.makeNextSaveUncertain(afterWriting: false)
        await sourceChanged.0.repository.setReconciliation(.stillPending(.init()))
        guard case .commitPending = try await sourceChanged.0.store.resolveDraftRecovery(
            sourceChanged.1.token,
            action: .saveAsNew(noteID: sourceChanged.2, blockIDs: sourceChanged.3)
        ) else { Issue.record("Source-change uncertain recovery must park"); return }
        var external = sourceChanged.0.store.state
        external.revision += 20
        external.notes[sourceChanged.1.draft.id]?.title = "external source"
        await sourceChanged.0.repository.replacePersistedState(external)
        let sourceChangedFresh = WorkspaceStore(
            initialState: .empty(calendar: sourceChanged.0.initialCalendar), repository: sourceChanged.0.repository,
            journal: sourceChanged.0.journal, clock: { .distantPast }
        )
        await sourceChangedFresh.load()
        #expect(sourceChangedFresh.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(await sourceChanged.0.repository.saveCount == 0)
    }

    @Test func restoreDropsRemovedAndNonTaskLinksButNeverInventsALinkForANewTask() async throws {
        let categoryID = UUID()
        let noteID = NoteID(UUID())
        let linkedBlockID = BlockID(UUID())
        let newTaskID = BlockID(UUID())
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "linked", categoryID: categoryID,
            schedule: .init(
                startDate: .init(year: 2026, month: 8, day: 10)!,
                endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil
            ),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.document = .init(blocks: [try .task(id: linkedBlockID, text: "linked", completedAt: nil)])
        var draft = persisted
        draft.document = .init(blocks: [
            .init(id: linkedBlockID, kind: .paragraph, inlineContent: .plain("no longer task"), taskState: nil, indentLevel: 0),
            try .task(id: newTaskID, text: "new unlinked task", completedAt: nil)
        ])
        var state = recoveryState(persisted: persisted, categoryID: categoryID)
        state.calendar.items[item.id] = item
        state.taskBlockLinks = [.init(noteID: noteID, blockID: linkedBlockID, calendarItemID: item.id)]
        state.calendarNoteRelations.baselines[.item(item.id)] = .init(primaryNoteID: noteID, referenceNoteIDs: [])
        let fixture = try await recoveryFixture(state: state, draft: draft)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        guard case .committed = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent) else {
            Issue.record("The reviewed non-task draft must persist")
            return
        }
        #expect(fixture.store.state.calendar.items[item.id] == item)
        #expect(fixture.store.state.taskBlockLinks.contains { $0.noteID == noteID } == false)
        #expect(fixture.store.state.taskBlockLinks.contains { $0.blockID == newTaskID } == false)
    }

    @Test func keepAndRestoreDifferentCandidatesAreSerializedAndLeaveNoRecoveryPhase() async throws {
        let categoryID = UUID()
        var kept = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        kept.revision = 1
        var keptDraft = kept
        keptDraft.title = "discard after keep"
        var restored = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        restored.revision = 1
        var restoredDraft = restored
        restoredDraft.title = "restore after keep"
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [kept.id: kept, restored.id: restored]
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [keptDraft, restoredDraft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
        let keep = try #require(candidates.first { $0.draft.id == kept.id })
        let restore = try #require(candidates.first { $0.draft.id == restored.id })

        let keptResult = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(keep.token, action: .keepPersisted)
        }
        let restoredResult = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(restore.token, action: .restoreAsCurrent)
        }
        #expect(try await keptResult.value == .noChange(.identical, journal: .clean))
        guard case .committed = try await restoredResult.value else {
            Issue.record("The queued restore must run after keep")
            return
        }
        #expect(fixture.store.phase == .ready)
        #expect(fixture.store.state.notes[kept.id] == kept)
        #expect(fixture.store.state.notes[restored.id]?.title == "restore after keep")
    }

    @Test func normalizedRestoreWithDiscardFailureStartsFreshWithoutReplayingMainSave() async throws {
        let categoryID = UUID()
        let noteID = NoteID(UUID())
        let blockID = BlockID(UUID())
        let completedAt = Date(timeIntervalSince1970: 101)
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "linked", categoryID: categoryID,
            schedule: .init(
                startDate: .init(year: 2026, month: 8, day: 10)!,
                endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil
            ),
            completedAt: completedAt, createdAt: .distantPast, updatedAt: .distantPast
        )
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.document = .init(blocks: [try .task(id: blockID, text: "linked", completedAt: completedAt)])
        var draft = persisted
        draft.title = "normalized recovery"
        draft.document.blocks[0].taskState?.completedAt = nil
        var state = recoveryState(persisted: persisted, categoryID: categoryID)
        state.calendar.items[item.id] = item
        state.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: item.id)]
        state.calendarNoteRelations.baselines[.item(item.id)] = .init(primaryNoteID: noteID, referenceNoteIDs: [])
        let writer = RecoveryToggleJournalWriter()
        let fixture = try await recoveryFixture(state: state, draft: draft, writer: writer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        writer.failOnWrite(offsetFromNow: 3)
        guard case .committed = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent) else {
            Issue.record("Normalized restore must commit before cleanup failure")
            return
        }
        writer.shouldFail = false
        let initial = state
        let freshRepository = JSONWorkspaceRepository(
            documentURL: fixture.directory.appendingPathComponent("workspace.json"), seed: { initial }
        )
        let fresh = WorkspaceStore(
            initialState: .empty(calendar: state.calendar), repository: freshRepository,
            journal: fixture.journal, clock: { .distantPast }
        )
        await fresh.load()
        #expect(fresh.phase == .ready)
        #expect(fresh.state.notes[noteID]?.document.blocks.first?.taskState?.completedAt == completedAt)
        #expect(try await fixture.journal.current()?.records.isEmpty == true)
    }

    @Test func recoveryCandidateCanBeExportedAsReadOnlyMarkdownWithoutResolvingIt() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "exported recovery"
        draft.document = .init(blocks: [
            .init(id: BlockID(UUID()), kind: .heading1, inlineContent: .plain("Recovered"), taskState: nil, indentLevel: 0),
            try .task(id: BlockID(UUID()), text: "keep evidence", completedAt: .distantPast)
        ])
        let fixture = try await recoveryFixture(persisted: persisted, draft: draft, categoryID: categoryID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        let markdown = try fixture.store.draftRecoveryMarkdown(candidate.token)
        #expect(markdown.contains("# Recovered"))
        #expect(markdown.contains("- [x] keep evidence"))
        #expect(fixture.store.phase == .needsDraftRecovery([candidate]))
        #expect(throws: WorkspaceStoreError.frozen) {
            _ = try fixture.store.draftRecoveryMarkdown(DraftRecoveryToken(
                identityAndGeneration: candidate.token.identityAndGeneration,
                noteSnapshotChecksum: "wrong", journalChecksum: candidate.token.journalChecksum
            ))
        }
    }

    @Test func recoverySaveRejectsOrdinaryMutationInsteadOfQueueingItBehindTheRecovery() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "recovery owns the write gate"
        let fixture = try await controlledRecoveryFixture(
            state: recoveryState(persisted: persisted, categoryID: categoryID),
            drafts: [draft]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        await fixture.repository.suspendNextSave()
        let recovery = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)
        }
        await fixture.repository.waitForSaveStart()
        let ordinary = Task { @MainActor in
            try await fixture.store.sendWorkspace(.archiveNote(persisted.id, at: .distantFuture))
        }

        await fixture.repository.resumeSave()
        guard case .committed = try await recovery.value else {
            Issue.record("The recovery save must complete before checking the ordinary gate")
            return
        }
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await ordinary.value
        }
        #expect(fixture.store.state.notes[persisted.id]?.archivedAt == nil)
    }

    @Test func retryingRecoveryCleanupResumesOnePreviouslyQueuedRecovery() async throws {
        let categoryID = UUID()
        var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        first.revision = 1
        var firstDraft = first
        firstDraft.title = "first recovery"
        var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        second.revision = 1
        var secondDraft = second
        secondDraft.title = "queued recovery"
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [first.id: first, second.id: second]
        let writer = RecoveryToggleJournalWriter()
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [firstDraft, secondDraft], writer: writer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
        let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
        let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })

        await fixture.repository.suspendNextSave()
        writer.failOnWrite(offsetFromNow: 3)
        let firstResolution = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(firstCandidate.token, action: .restoreAsCurrent)
        }
        await fixture.repository.waitForSaveStart()
        let queuedSecond = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(secondCandidate.token, action: .restoreAsCurrent)
        }
        await fixture.repository.resumeSave()
        guard case let .committed(_, journal: .cleanupPending(identity, _)) = try await firstResolution.value else {
            Issue.record("The first recovery must park only its exact cleanup")
            return
        }

        writer.shouldFail = false
        #expect(await fixture.store.retryJournalCleanup(identity) == .clean)
        guard case .committed = try await queuedSecond.value else {
            Issue.record("The previously queued recovery must continue exactly once")
            return
        }
        #expect(await fixture.repository.saveCount == 2)
        #expect(fixture.store.phase == .ready)
    }

    @Test func freshStartupReopensAnUnwrittenSecondRecoveryAgainstTheActualPostFirstSource() async throws {
        let categoryID = UUID()
        var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        first.revision = 1
        var firstDraft = first
        firstDraft.title = "first committed recovery"
        var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        second.revision = 1
        var secondDraft = second
        secondDraft.title = "second remains unwritten"
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [first.id: first, second.id: second]
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [firstDraft, secondDraft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
        let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
        let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })

        guard case .committed = try await fixture.store.resolveDraftRecovery(firstCandidate.token, action: .restoreAsCurrent) else {
            Issue.record("The first recovery must advance the actual source before B starts")
            return
        }
        await fixture.repository.makeNextSaveUncertain(afterWriting: false)
        await fixture.repository.setReconciliation(.stillPending(.init()))
        let newID = NoteID(UUID())
        guard case .commitPending = try await fixture.store.resolveDraftRecovery(
            secondCandidate.token,
            action: .saveAsNew(noteID: newID, blockIDs: secondDraft.document.blocks.map { _ in BlockID(UUID()) })
        ) else {
            Issue.record("The second recovery must have a durable uncertain marker")
            return
        }

        let fresh = WorkspaceStore(
            initialState: .empty(calendar: fixture.initialCalendar), repository: fixture.repository,
            journal: fixture.journal, clock: { .distantPast }
        )
        await fresh.load()
        #expect(recoveryCandidates(from: fresh.phase)?.map(\.token) == [secondCandidate.token])
        #expect(await fixture.repository.saveCount == 1)
        #expect(fresh.state.notes[first.id]?.title == "first committed recovery")
        #expect(fresh.state.notes[newID] == nil)
    }

    @Test func startupCleanupRetryWithNoRemainingRecordsClearsRecoveryStateAndPublishesReady() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        let writer = RecoveryToggleJournalWriter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-empty-startup-rescan-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let entry = try recoveryEntry(draft: persisted, session: UUID(), workspaceRevision: persisted.revision)
        try await journal.persist(entry)
        let receipt = PersistedDraftReceipt(
            noteID: persisted.id, editSessionID: entry.editSessionID, draftGeneration: entry.draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum, persistedNoteRevision: persisted.revision
        )
        #expect(try await journal.acknowledgeAlreadyPersisted(receipt) == .applied)
        writer.failOnWrite(offsetFromNow: 1)
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let repository = RecoveryControlledRepository(backing: JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("workspace.json"), seed: { state }
        ))
        let store = WorkspaceStore(
            initialState: .empty(calendar: state.calendar), repository: repository,
            journal: journal, clock: { .distantPast }
        )
        await store.load()
        guard case let .parkedJournalCleanup(identity, .clear) = store.phase else {
            Issue.record("A failed final cleanup must park before deciding the terminal phase")
            return
        }

        writer.shouldFail = false
        #expect(await store.retryJournalCleanup(identity) == .clean)
        #expect(store.phase == .ready)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func aCommittedRecoveryMarkerNeverReopensWhenThePrimaryRollsBackToItsOldSource() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "must not replay after rollback"
        let writer = RecoveryToggleJournalWriter()
        let fixture = try await controlledRecoveryFixture(
            state: recoveryState(persisted: persisted, categoryID: categoryID), drafts: [draft], writer: writer
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        writer.failOnWrite(offsetFromNow: 3)
        guard case .committed = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent) else {
            Issue.record("The main recovery must commit before its discard write fails")
            return
        }

        writer.shouldFail = false
        await fixture.repository.replacePersistedState(recoveryState(persisted: persisted, categoryID: categoryID))
        let fresh = WorkspaceStore(
            initialState: .empty(calendar: fixture.initialCalendar), repository: fixture.repository,
            journal: fixture.journal, clock: { .distantPast }
        )
        await fresh.load()
        #expect(fresh.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(try await fixture.journal.current()?.records.count == 1)
        #expect(await fixture.repository.saveCount == 1)
    }

    @Test func terminalSourceChangeReleasesAQueuedRecoveryClaimForTheNextVerifiedRecoveryPhase() async throws {
        let categoryID = UUID()
        var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        first.revision = 1
        var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        second.revision = 1
        var firstDraft = first
        firstDraft.title = "will become source changed"
        var secondDraft = second
        secondDraft.title = "claim must be released"
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [first.id: first, second.id: second]
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [firstDraft, secondDraft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
        let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
        let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })

        await fixture.repository.suspendNextSave()
        await fixture.repository.makeNextSaveUncertain(afterWriting: false)
        await fixture.repository.setReconciliation(.sourceChanged(.init()))
        let firstResolution = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(firstCandidate.token, action: .restoreAsCurrent)
        }
        await fixture.repository.waitForSaveStart()
        let queuedSecond = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(secondCandidate.token, action: .restoreAsCurrent)
        }
        await fixture.repository.resumeSave()
        guard case .externalSourceChanged = try await firstResolution.value,
              case .externalSourceChanged = try await queuedSecond.value
        else {
            Issue.record("A terminal source change must resolve every queued recovery exactly once")
            return
        }

        // This controlled repository seeds `load` in memory; external reload
        // intentionally reads only an actual primary file.
        await fixture.repository.replacePersistedState(state)
        _ = try await fixture.store.reloadExternalSource()
        let refreshed = try #require(recoveryCandidates(from: fixture.store.phase))
        #expect(refreshed.contains { $0.token == secondCandidate.token })
        guard case .committed = try await fixture.store.resolveDraftRecovery(secondCandidate.token, action: .restoreAsCurrent) else {
            Issue.record("The source-change terminal must release B's stale in-memory claim")
            return
        }
    }

    @Test func recoveryOriginRelationshipRepairFreezesOrdinaryTailUntilExactCandidateIsRescanned() async throws {
        let categoryID = UUID()
        let noteID = NoteID(UUID())
        let blockID = BlockID(UUID())
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.document = .init(blocks: [try .task(id: blockID, text: "dangling", completedAt: nil)])
        var draft = persisted
        draft.title = "must not publish during repair"
        var invalid = recoveryState(persisted: persisted, categoryID: categoryID)
        invalid.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: UUID())]
        let report = WorkspaceConsistencyInspector.inspect(invalid)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-recovery-repair-gate-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        try await journal.persist(try recoveryEntry(draft: draft, session: UUID(), workspaceRevision: invalid.revision))
        let repository = RecoveryRepairRepository(initial: invalid)
        let store = WorkspaceStore(
            initialState: .empty(calendar: invalid.calendar), repository: repository,
            journal: journal, clock: { .distantPast }
        )
        await store.load()
        let candidate = try #require(recoveryCandidate(from: store.phase))
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)
        }

        await repository.suspendNextSave()
        let repairing = Task { @MainActor in
            try await store.sendWorkspace(.repairConsistency(repair))
        }
        await repository.waitForSaveStart()
        let ordinary = Task { @MainActor in
            try await store.sendWorkspace(.archiveNote(noteID, at: .distantFuture))
        }
        await repository.resumeSave()

        guard case .committed = try await repairing.value else {
            Issue.record("The persisted relationship graph must repair once")
            return
        }
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await ordinary.value
        }
        #expect(await repository.saveCount == 1)
        #expect(recoveryCandidates(from: store.phase)?.map(\.token) == [candidate.token])
        #expect(store.state.notes[noteID]?.archivedAt == nil)
    }

    @Test func recoveryOriginNormalizedReloadFreezesOrdinaryTailAndRepublishesExactRecovery() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "survives normalized reload"
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [draft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        await fixture.repository.makeNextSaveUncertain(afterWriting: false)
        await fixture.repository.setReconciliation(.sourceChanged(.init()))
        guard case .externalSourceChanged = try await fixture.store.resolveDraftRecovery(
            candidate.token, action: .restoreAsCurrent
        ) else {
            Issue.record("The setup must take the recovery through source-changed terminalization")
            return
        }
        await fixture.repository.setReloadOverride(.valid(.init(
            state: state,
            provenance: .init(sourceSchema: 0, sourceBytesSHA256: "normalized", sourceByteCount: 1),
            consistencyIssues: []
        )))
        await fixture.repository.suspendNextSave()
        let reloading = Task { @MainActor in try await fixture.store.reloadExternalSource() }
        await fixture.repository.waitForSaveStart()
        let ordinary = Task { @MainActor in
            try await fixture.store.sendWorkspace(.archiveNote(persisted.id, at: .distantFuture))
        }
        await fixture.repository.resumeSave()

        guard case .transaction(.committed) = try await reloading.value else {
            Issue.record("The legacy-shaped reload must normalize through one adoption save")
            return
        }
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await ordinary.value
        }
        #expect(await fixture.repository.saveCount == 1)
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [candidate.token])
        #expect(fixture.store.state.notes[persisted.id]?.archivedAt == nil)
    }

    @Test func recoveryOriginNormalizedAdoptionKeepsOrdinaryMutationFrozenWhileJournalRescanIsBlocked() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "survives blocked normalized adoption rescan"
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [draft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        await fixture.repository.makeNextSaveUncertain(afterWriting: false)
        await fixture.repository.setReconciliation(.sourceChanged(.init()))
        guard case .externalSourceChanged = try await fixture.store.resolveDraftRecovery(
            candidate.token, action: .restoreAsCurrent
        ) else {
            Issue.record("The setup must retain the exact bare recovery after source change")
            return
        }
        await fixture.repository.setReloadOverride(.valid(.init(
            state: state,
            provenance: .init(sourceSchema: 0, sourceBytesSHA256: "blocked-normalized", sourceByteCount: 1),
            consistencyIssues: []
        )))
        await fixture.repository.suspendNextSave()
        let reloading = Task { @MainActor in try await fixture.store.reloadExternalSource() }
        await fixture.repository.waitForSaveStart()
        let lock = try JournalCurrentLockHolder(journalURL: fixture.journalURL, directory: fixture.directory)
        defer { lock.stop() }
        try await lock.waitUntilLocked()
        await fixture.repository.resumeSave()
        for _ in 0 ..< 1_000 {
            if await fixture.repository.saveCount == 1 { break }
            await Task.yield()
        }
        #expect(await fixture.repository.saveCount == 1)
        #expect(fixture.store.phase == .reconcilingDraftRecovery)

        let unlock = Task { @MainActor [lock] in
            try await Task.sleep(for: .milliseconds(25))
            try lock.release()
        }
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await fixture.store.sendWorkspace(.archiveNote(persisted.id, at: .distantFuture))
        }
        try await unlock.value
        lock.waitUntilExit()

        guard case .transaction(.committed) = try await reloading.value else {
            Issue.record("The normalized reload must finish its one adoption save")
            return
        }
        #expect(await fixture.repository.saveCount == 1)
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [candidate.token])
        #expect(fixture.store.state.notes[persisted.id]?.archivedAt == nil)
    }

    @Test func recoveryOriginDirectReloadKeepsOrdinaryMutationFrozenWhileJournalRescanIsBlocked() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "survives blocked direct reload rescan"
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [draft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))

        await fixture.repository.makeNextSaveUncertain(afterWriting: false)
        await fixture.repository.setReconciliation(.sourceChanged(.init()))
        guard case .externalSourceChanged = try await fixture.store.resolveDraftRecovery(
            candidate.token, action: .restoreAsCurrent
        ) else {
            Issue.record("The setup must retain the exact bare recovery after source change")
            return
        }
        await fixture.repository.setReloadOverride(.valid(.init(
            state: state,
            provenance: .init(
                sourceSchema: WorkspaceDocument.currentSchemaVersion,
                sourceBytesSHA256: "blocked-direct", sourceByteCount: 1
            ),
            consistencyIssues: []
        )))
        let lock = try JournalCurrentLockHolder(journalURL: fixture.journalURL, directory: fixture.directory)
        defer { lock.stop() }
        try await lock.waitUntilLocked()
        let reloading = Task { @MainActor in try await fixture.store.reloadExternalSource() }
        for _ in 0 ..< 1_000 {
            if fixture.store.phase == .reconcilingDraftRecovery || fixture.store.phase == .ready { break }
            await Task.yield()
        }
        #expect(fixture.store.phase == .reconcilingDraftRecovery)

        let unlock = Task { @MainActor [lock] in
            try await Task.sleep(for: .milliseconds(25))
            try lock.release()
        }
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await fixture.store.sendWorkspace(.archiveNote(persisted.id, at: .distantFuture))
        }
        try await unlock.value
        lock.waitUntilExit()

        guard case .source = try await reloading.value else {
            Issue.record("The direct reload must not require a second main save")
            return
        }
        #expect(await fixture.repository.saveCount == 0)
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [candidate.token])
        #expect(fixture.store.state.notes[persisted.id]?.archivedAt == nil)
    }

    @Test func keepDiscardFailureParksOnlyItsExactRecoveryAndRetryLeavesOtherJournalRecordsBare() async throws {
        let fixture = try await twoRecoveryCleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.fixture.directory) }
        fixture.writer.failOnWrite(offsetFromNow: 1)

        let outcome = try await fixture.fixture.store.resolveDraftRecovery(
            fixture.first.token, action: .keepPersisted
        )
        guard case let .noChange(_, journal: .cleanupPending(identity, .discardRecovery(token))) = outcome else {
            Issue.record("Keep must park only the exact bare discard"); return
        }
        #expect(token == fixture.first.token)
        #expect(await fixture.fixture.repository.saveCount == 0)
        #expect(try await fixture.fixture.journal.current()?.records.count == 2)

        fixture.writer.shouldFail = false
        #expect(await fixture.fixture.store.retryJournalCleanup(identity) == .clean)
        #expect(recoveryCandidates(from: fixture.fixture.store.phase)?.map(\.token) == [fixture.second.token])
        #expect(try await fixture.fixture.journal.isCurrentBare(fixture.second.token))
    }

    @Test func markCompletionFailurePublishesOneMainSaveThenRetryDoesNotReplayOrTouchOtherRecord() async throws {
        let fixture = try await twoRecoveryCleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.fixture.directory) }
        fixture.writer.failOnWrite(offsetFromNow: 2)

        let outcome = try await fixture.fixture.store.resolveDraftRecovery(
            fixture.first.token, action: .restoreAsCurrent
        )
        guard case let .committed(_, journal: .cleanupPending(identity, .markRecoveryCompletion(completion))) = outcome else {
            Issue.record("A failed durable mark must park its exact completion"); return
        }
        #expect(completion.token == fixture.first.token)
        #expect(await fixture.fixture.repository.saveCount == 1)
        #expect(fixture.fixture.store.state.notes[fixture.first.draft.id]?.title == fixture.first.draft.title)
        #expect(try await fixture.fixture.journal.isCurrentBare(fixture.second.token))

        fixture.writer.shouldFail = false
        #expect(await fixture.fixture.store.retryJournalCleanup(identity) == .clean)
        #expect(await fixture.fixture.repository.saveCount == 1)
        #expect(recoveryCandidates(from: fixture.fixture.store.phase)?.map(\.token) == [fixture.second.token])
        let fresh = WorkspaceStore(
            initialState: .empty(calendar: fixture.fixture.initialCalendar), repository: fixture.fixture.repository,
            journal: fixture.fixture.journal, clock: { .distantPast }
        )
        await fresh.load()
        #expect(recoveryCandidates(from: fresh.phase)?.map(\.token) == [fixture.second.token])
        #expect(await fixture.fixture.repository.saveCount == 1)
    }

    @Test func discardCompletionFailurePublishesOneMainSaveThenRetryDoesNotReplayOrTouchOtherRecord() async throws {
        let fixture = try await twoRecoveryCleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.fixture.directory) }
        fixture.writer.failOnWrite(offsetFromNow: 3)

        let outcome = try await fixture.fixture.store.resolveDraftRecovery(
            fixture.first.token, action: .restoreAsCurrent
        )
        guard case let .committed(_, journal: .cleanupPending(identity, .discardRecoveryCompletion(completion))) = outcome else {
            Issue.record("A failed exact completion discard must park its exact completion"); return
        }
        #expect(completion.token == fixture.first.token)
        #expect(await fixture.fixture.repository.saveCount == 1)
        #expect(try await fixture.fixture.journal.isCurrentBare(fixture.second.token))

        fixture.writer.shouldFail = false
        #expect(await fixture.fixture.store.retryJournalCleanup(identity) == .clean)
        #expect(await fixture.fixture.repository.saveCount == 1)
        #expect(recoveryCandidates(from: fixture.fixture.store.phase)?.map(\.token) == [fixture.second.token])
    }

    @Test func abandonCompletionFailureKeepsMainUnpublishedAndRetryReopensBothExactBareRecords() async throws {
        let fixture = try await twoRecoveryCleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.fixture.directory) }
        await fixture.fixture.repository.failNextSaveDefinitively()
        fixture.writer.failOnWrite(offsetFromNow: 2)

        let outcome = try await fixture.fixture.store.resolveDraftRecovery(
            fixture.first.token, action: .restoreAsCurrent
        )
        guard case let .notCommitted(_, journal: .cleanupPending(identity, .abandonRecoveryCompletion(completion)), _) = outcome else {
            Issue.record("A definite non-commit with failed abandon must park its exact marker"); return
        }
        #expect(completion.token == fixture.first.token)
        #expect(await fixture.fixture.repository.saveCount == 0)
        #expect(fixture.fixture.store.state.notes[fixture.first.draft.id]?.title != fixture.first.draft.title)
        #expect(try await fixture.fixture.journal.isCurrentBare(fixture.second.token))

        fixture.writer.shouldFail = false
        #expect(await fixture.fixture.store.retryJournalCleanup(identity) == .clean)
        let reopened = try #require(recoveryCandidates(from: fixture.fixture.store.phase))
        #expect(Set(reopened.map(\.token)) == Set([fixture.first.token, fixture.second.token]))
        #expect(await fixture.fixture.repository.saveCount == 0)
        #expect(try await fixture.fixture.journal.isCurrentBare(fixture.first.token))
        #expect(try await fixture.fixture.journal.isCurrentBare(fixture.second.token))
    }

    @Test func durableCompletionSourceChangeKeepsDirectAndNormalizedJournalRescansNonordinaryUntilTheirExactTruthPublishes() async throws {
        func makeSourceChangedCompletion() async throws -> (
            ControlledRecoveryStoreFixture,
            WorkspaceStore,
            Note,
            WorkspaceState
        ) {
            let categoryID = UUID()
            var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
            persisted.revision = 1
            var draft = persisted
            draft.title = "durable completion must gate a later rescan"
            let original = recoveryState(persisted: persisted, categoryID: categoryID)
            let writer = RecoveryToggleJournalWriter()
            let fixture = try await controlledRecoveryFixture(state: original, drafts: [draft], writer: writer)
            let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
            writer.failOnWrite(offsetFromNow: 3)
            guard case .committed = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent) else {
                Issue.record("The setup must leave a durable completion record after one committed recovery")
                throw WorkspaceStoreError.frozen
            }
            writer.shouldFail = false
            await fixture.repository.replacePersistedState(original)
            let fresh = WorkspaceStore(
                initialState: .empty(calendar: original.calendar), repository: fixture.repository,
                journal: fixture.journal, clock: { .distantPast }
            )
            await fresh.load()
            #expect(fresh.phase == .externalSourceChanged(.externalBytesChanged))
            return (fixture, fresh, persisted, original)
        }

        let direct = try await makeSourceChangedCompletion()
        defer { try? FileManager.default.removeItem(at: direct.0.directory) }
        await direct.0.repository.setReloadOverride(.valid(.init(
            state: direct.3,
            provenance: .init(
                sourceSchema: WorkspaceDocument.currentSchemaVersion,
                sourceBytesSHA256: "durable-completion-direct", sourceByteCount: 1
            ),
            consistencyIssues: []
        )))
        let directLock = try JournalCurrentLockHolder(journalURL: direct.0.journalURL, directory: direct.0.directory)
        defer { directLock.stop() }
        try await directLock.waitUntilLocked()
        let directReload = Task { @MainActor in try await direct.1.reloadExternalSource() }
        for _ in 0 ..< 1_000 {
            if direct.1.phase == .reconcilingDraftRecovery { break }
            await Task.yield()
        }
        #expect(direct.1.phase == .reconcilingDraftRecovery)
        let directUnlock = Task { @MainActor [directLock] in
            try await Task.sleep(for: .milliseconds(25))
            try directLock.release()
        }
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await direct.1.sendWorkspace(.archiveNote(direct.2.id, at: .distantFuture))
        }
        try await directUnlock.value
        directLock.waitUntilExit()
        if case .source = try await directReload.value {
            // Expected direct adoption: the observable behavior is asserted below.
        } else {
            Issue.record("A direct adopted source must not add a normalization save")
        }
        #expect(direct.1.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(try await direct.0.journal.current()?.records.count == 1)

        let normalized = try await makeSourceChangedCompletion()
        defer { try? FileManager.default.removeItem(at: normalized.0.directory) }
        await normalized.0.repository.setReloadOverride(.valid(.init(
            state: normalized.3,
            provenance: .init(sourceSchema: 0, sourceBytesSHA256: "durable-completion-normalized", sourceByteCount: 1),
            consistencyIssues: []
        )))
        await normalized.0.repository.suspendNextSave()
        let normalizedReload = Task { @MainActor in try await normalized.1.reloadExternalSource() }
        await normalized.0.repository.waitForSaveStart()
        let normalizedLock = try JournalCurrentLockHolder(journalURL: normalized.0.journalURL, directory: normalized.0.directory)
        defer { normalizedLock.stop() }
        try await normalizedLock.waitUntilLocked()
        await normalized.0.repository.resumeSave()
        for _ in 0 ..< 1_000 {
            if normalized.1.phase == .reconcilingDraftRecovery { break }
            await Task.yield()
        }
        #expect(normalized.1.phase == .reconcilingDraftRecovery)
        let normalizedUnlock = Task { @MainActor [normalizedLock] in
            try await Task.sleep(for: .milliseconds(25))
            try normalizedLock.release()
        }
        let normalizedOrdinary = Task { @MainActor in
            try await normalized.1.sendWorkspace(.archiveNote(normalized.2.id, at: .distantFuture))
        }
        for _ in 0 ..< 100 { await Task.yield() }
        try await normalizedUnlock.value
        normalizedLock.waitUntilExit()
        guard case .transaction(.committed) = try await normalizedReload.value else {
            Issue.record("A normalized adopted source must save exactly once before its Journal rescan")
            return
        }
        await #expect(throws: WorkspaceStoreError.frozen) { _ = try await normalizedOrdinary.value }
        #expect(normalized.1.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(try await normalized.0.journal.current()?.records.count == 1)
    }

    @Test func durableSourceChangeRepairRescansTheNewerBareRecordWithoutOpeningAnOrdinaryMutationWindow() async throws {
        let categoryID = UUID()
        let noteID = NoteID(UUID())
        let blockID = BlockID(UUID())
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.document = .init(blocks: [try .task(id: blockID, text: "repair source", completedAt: nil)])
        var draft = persisted
        draft.title = "completion that will become source changed"
        let original = recoveryState(persisted: persisted, categoryID: categoryID)
        let writer = RecoveryToggleJournalWriter()
        let fixture = try await controlledRecoveryFixture(state: original, drafts: [draft], writer: writer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        writer.failOnWrite(offsetFromNow: 3)
        guard case .committed = try await fixture.store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent) else {
            Issue.record("The setup must write the recovery result before preserving its completion marker")
            return
        }
        writer.shouldFail = false
        await fixture.repository.replacePersistedState(original)
        let fresh = WorkspaceStore(
            initialState: .empty(calendar: original.calendar), repository: fixture.repository,
            journal: fixture.journal, clock: { .distantPast }
        )
        await fresh.load()
        #expect(fresh.phase == .externalSourceChanged(.externalBytesChanged))

        guard case let .editor(session) = candidate.token.identityAndGeneration.identity.editSessionID else {
            Issue.record("The recovery fixture must retain its editor session")
            return
        }
        var newerDraft = draft
        newerDraft.title = "newer exact generation after external source change"
        let durableCompletion = try #require(
            try await fixture.journal.current()?.records.first?.recoveryCompletion
        )
        #expect(
            try await fixture.journal.discardRecoveryCompletion(durableCompletion) == .applied
        )
        let newerToken: DraftRecoveryToken
        switch try await fixture.journal.protect(try recoveryEntry(
            draft: newerDraft, session: session, workspaceRevision: original.revision, generation: 2
        )) {
        case let .protected(value): newerToken = value
        case .superseded, .busy: Issue.record("A newer durable generation must follow the resolved completion marker"); return
        }

        var invalid = original
        invalid.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: UUID())]
        let report = WorkspaceConsistencyInspector.inspect(invalid)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        await fixture.repository.setReloadOverride(.valid(.init(
            state: invalid,
            provenance: .init(
                sourceSchema: WorkspaceDocument.currentSchemaVersion,
                sourceBytesSHA256: "source-change-repair", sourceByteCount: 1
            ),
            consistencyIssues: report.issues
        )))
        _ = try await fresh.reloadExternalSource()
        #expect(fresh.phase == .needsRelationshipRepair)

        await fixture.repository.suspendNextSave()
        let repairing = Task { @MainActor in try await fresh.sendWorkspace(.repairConsistency(repair)) }
        await fixture.repository.waitForSaveStart()
        let ordinary = Task { @MainActor in
            try await fresh.sendWorkspace(.archiveNote(noteID, at: .distantFuture))
        }
        await fixture.repository.resumeSave()
        guard case .committed = try await repairing.value else {
            Issue.record("The consistency repair must persist its current graph before the full Journal rescan")
            return
        }
        await #expect(throws: WorkspaceStoreError.frozen) { _ = try await ordinary.value }
        #expect(recoveryCandidates(from: fresh.phase)?.map(\.token) == [newerToken])
        #expect(fresh.state.notes[noteID]?.archivedAt == nil)
    }

    @Test func aBareJournalRecordAddedBeforeDirectReloadIsNeverBypassedByTheOriginDecision() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-racing-bare-record-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let repository = RecoveryControlledRepository(backing: JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("workspace.json"), seed: { state }
        ))
        let store = WorkspaceStore(
            initialState: .empty(calendar: state.calendar), repository: repository,
            journal: journal, clock: { .distantPast }
        )
        await store.load()
        #expect(store.phase == .ready)

        var draft = persisted
        draft.title = "bare generation written by another process before reload"
        let token: DraftRecoveryToken
        switch try await journal.protect(try recoveryEntry(
            draft: draft, session: UUID(), workspaceRevision: state.revision
        )) {
        case let .protected(value): token = value
        case .superseded, .busy: Issue.record("An empty Journal must accept the external bare generation"); return
        }
        await repository.setReloadOverride(.valid(.init(
            state: state,
            provenance: .init(
                sourceSchema: WorkspaceDocument.currentSchemaVersion,
                sourceBytesSHA256: "race-before-origin", sourceByteCount: 1
            ),
            consistencyIssues: []
        )))
        let lock = try JournalCurrentLockHolder(journalURL: directory.appendingPathComponent("draft.json"), directory: directory)
        defer { lock.stop() }
        try await lock.waitUntilLocked()
        let reloading = Task { @MainActor in try await store.reloadExternalSource() }
        for _ in 0 ..< 1_000 {
            if store.phase == .reconcilingDraftRecovery { break }
            await Task.yield()
        }
        #expect(store.phase == .reconcilingDraftRecovery)
        let unlock = Task { @MainActor [lock] in
            try await Task.sleep(for: .milliseconds(25))
            try lock.release()
        }
        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await store.sendWorkspace(.archiveNote(persisted.id, at: .distantFuture))
        }
        try await unlock.value
        lock.waitUntilExit()
        guard case .source = try await reloading.value else {
            Issue.record("The direct reload must not write a second main source")
            return
        }
        #expect(recoveryCandidates(from: store.phase)?.map(\.token) == [token])
        #expect(store.state.notes[persisted.id]?.archivedAt == nil)
    }

    @Test func completionOnlySourceChangeRejectsRestoreBeforeAnyRestoreCapabilityOrWrite() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "durable completion still owns recovery"
        let original = recoveryState(persisted: persisted, categoryID: categoryID)
        let writer = RecoveryToggleJournalWriter()
        let fixture = try await controlledRecoveryFixture(state: original, drafts: [draft], writer: writer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        writer.failOnWrite(offsetFromNow: 3)
        guard case .committed = try await fixture.store.resolveDraftRecovery(
            candidate.token, action: .restoreAsCurrent
        ) else {
            Issue.record("The setup must preserve a committed recovery marker")
            return
        }

        writer.shouldFail = false
        await fixture.repository.replacePersistedState(original)
        let fresh = WorkspaceStore(
            initialState: .empty(calendar: original.calendar), repository: fixture.repository,
            journal: fixture.journal, clock: { .distantPast }
        )
        await fresh.load()
        #expect(fresh.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(fresh.hasUnresolvedJournalReconciliation)

        var restoreState = original
        restoreState.revision += 1
        var restoredNote = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        restoredNote.title = "must not restore"
        restoredNote.revision = restoreState.revision
        restoreState.notes[restoredNote.id] = restoredNote
        let source = fixture.directory.appendingPathComponent("blocked-restore.json")
        try WorkspaceDocumentCodec.encode(restoreState).write(to: source)
        let preview = try await fresh.inspectRestoreSource(at: source)

        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await fresh.restore(
                preview,
                rollbackDirectoryURL: fixture.directory.appendingPathComponent("rollbacks", isDirectory: true)
            )
        }
        #expect(await fixture.repository.restorePrepareCount == 0)
        #expect(await fixture.repository.restoreCommitCount == 0)
        #expect(fresh.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(try await fixture.journal.current()?.records.count == 1)
    }

    @Test func relationshipRepairWithAnUnscannedBareJournalRejectsRestoreAtAdmission() async throws {
        let categoryID = UUID()
        let noteID = NoteID(UUID())
        let blockID = BlockID(UUID())
        var persisted = Note.empty(id: noteID, categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        persisted.document = .init(blocks: [try .task(id: blockID, text: "dangling", completedAt: nil)])
        var draft = persisted
        draft.title = "bare Journal must be resolved first"
        var invalid = recoveryState(persisted: persisted, categoryID: categoryID)
        invalid.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: UUID())]
        let report = WorkspaceConsistencyInspector.inspect(invalid)
        #expect(!report.issues.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-repair-restore-gate-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        try await journal.persist(try recoveryEntry(draft: draft, session: UUID(), workspaceRevision: invalid.revision))
        let invalidState = invalid
        let validBackingState = recoveryState(persisted: persisted, categoryID: categoryID)
        let repository = RecoveryControlledRepository(
            backing: JSONWorkspaceRepository(
                documentURL: directory.appendingPathComponent("workspace.json"), seed: { validBackingState }
            ),
            loadOverride: .init(
                state: invalidState,
                provenance: .init(
                    sourceSchema: WorkspaceDocument.currentSchemaVersion,
                    sourceBytesSHA256: "repair-load", sourceByteCount: 1
                ),
                consistencyIssues: report.issues
            )
        )
        let store = WorkspaceStore(
            initialState: .empty(calendar: invalid.calendar), repository: repository,
            journal: journal, clock: { .distantPast }
        )
        await store.load()
        #expect(store.phase == .needsRelationshipRepair)
        #expect(store.hasUnresolvedJournalReconciliation)

        var restoreState = recoveryState(persisted: persisted, categoryID: categoryID)
        restoreState.taskBlockLinks.removeAll()
        restoreState.revision += 1
        let source = directory.appendingPathComponent("blocked-repair-restore.json")
        try WorkspaceDocumentCodec.encode(restoreState).write(to: source)
        let preview = try await store.inspectRestoreSource(at: source)

        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await store.restore(
                preview,
                rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true)
            )
        }
        #expect(await repository.restorePrepareCount == 0)
        #expect(await repository.restoreCommitCount == 0)
        #expect(store.phase == .needsRelationshipRepair)
        #expect(try await journal.current()?.records.count == 1)
    }

    @Test func readyReloadReadFailureRestoresAdmissionAndCanRetryIntoExactJournalTruth() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(fixture.store.phase == .ready)
        #expect(!fixture.store.hasUnresolvedJournalReconciliation)

        await fixture.repository.failNextReload()
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await fixture.store.reloadExternalSource()
        }
        #expect(fixture.store.phase == .ready)
        #expect(!fixture.store.hasUnresolvedJournalReconciliation)

        var draft = persisted
        draft.title = "written after the failed read"
        let token: DraftRecoveryToken
        switch try await fixture.journal.protect(try recoveryEntry(
            draft: draft, session: UUID(), workspaceRevision: state.revision
        )) {
        case let .protected(value): token = value
        case .superseded, .busy: Issue.record("The empty Journal must accept the exact new record"); return
        }
        await fixture.repository.setReloadOverride(.valid(.init(
            state: state,
            provenance: .init(
                sourceSchema: WorkspaceDocument.currentSchemaVersion,
                sourceBytesSHA256: "retry-ready-reload", sourceByteCount: 1
            ),
            consistencyIssues: []
        )))

        _ = try await fixture.store.reloadExternalSource()
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [token])
        #expect(!fixture.store.hasUnresolvedJournalReconciliation)
    }

    @Test func recoveryOriginReloadReadFailurePreservesOwnershipAndCanRetryFullScan() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "recovery ownership survives reload read failure"
        draft.document = .init(blocks: [
            .init(
                id: BlockID(UUID()), kind: .paragraph,
                inlineContent: .plain("owned recovery body"), taskState: nil, indentLevel: 0
            )
        ])
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [draft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try #require(recoveryCandidate(from: fixture.store.phase))
        await fixture.repository.makeNextSaveUncertain(afterWriting: false)
        await fixture.repository.setReconciliation(.sourceChanged(.init()))
        guard case .externalSourceChanged = try await fixture.store.resolveDraftRecovery(
            candidate.token, action: .restoreAsCurrent
        ) else {
            Issue.record("The setup must enter recovery-origin source change")
            return
        }

        await fixture.repository.setReloadOverride(.valid(.init(
            state: state,
            provenance: .init(
                sourceSchema: WorkspaceDocument.currentSchemaVersion,
                sourceBytesSHA256: "retry-recovery-reload", sourceByteCount: 1
            ),
            consistencyIssues: []
        )))
        await fixture.repository.failNextReload()
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await fixture.store.reloadExternalSource()
        }
        #expect(fixture.store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(try fixture.store.draftRecoveryMarkdown(candidate.token).contains("owned recovery body"))

        _ = try await fixture.store.reloadExternalSource()
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [candidate.token])
        #expect(!fixture.store.hasUnresolvedJournalReconciliation)
    }

    @Test func staleKeepAfterPeerSupersedesTheCandidateRescansInsteadOfParkingTheOldToken() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var firstDraft = persisted
        firstDraft.title = "generation one"
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [firstDraft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstCandidate = try #require(recoveryCandidate(from: fixture.store.phase))
        guard case let .editor(session) = firstCandidate.token.identityAndGeneration.identity.editSessionID else {
            Issue.record("The fixture must use an editor identity")
            return
        }
        var secondDraft = firstDraft
        secondDraft.title = "generation two"
        let secondToken: DraftRecoveryToken
        switch try await fixture.journal.protect(try recoveryEntry(
            draft: secondDraft, session: session, workspaceRevision: state.revision, generation: 2
        )) {
        case let .protected(value): secondToken = value
        case .superseded, .busy: Issue.record("A peer must supersede an exact bare generation"); return
        }

        let outcome = try await fixture.store.resolveDraftRecovery(
            firstCandidate.token, action: .keepPersisted
        )

        #expect(outcome == .draftSuperseded)
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [secondToken])
        #expect(try await fixture.journal.isCurrentBare(secondToken))
        #expect(await fixture.repository.saveCount == 0)
    }

    @Test func staleRecoverySaveClaimRescansThePeerGenerationBeforeAnyMainSave() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var firstDraft = persisted
        firstDraft.title = "generation one restore"
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let fixture = try await controlledRecoveryFixture(state: state, drafts: [firstDraft])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstCandidate = try #require(recoveryCandidate(from: fixture.store.phase))
        guard case let .editor(session) = firstCandidate.token.identityAndGeneration.identity.editSessionID else {
            Issue.record("The fixture must use an editor identity")
            return
        }
        var secondDraft = firstDraft
        secondDraft.title = "generation two restore"
        let secondToken: DraftRecoveryToken
        switch try await fixture.journal.protect(try recoveryEntry(
            draft: secondDraft, session: session, workspaceRevision: state.revision, generation: 2
        )) {
        case let .protected(value): secondToken = value
        case .superseded, .busy: Issue.record("A peer must supersede the exact bare generation"); return
        }

        let outcome = try await fixture.store.resolveDraftRecovery(
            firstCandidate.token, action: .restoreAsCurrent
        )

        #expect(outcome == .draftSuperseded)
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [secondToken])
        #expect(try await fixture.journal.isCurrentBare(secondToken))
        #expect(await fixture.repository.saveCount == 0)
    }

    @Test func failedRecoveryHeadWriteContinuesAnAlreadyClaimedRecoveryTailExactlyOnce() async throws {
        let categoryID = UUID()
        var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        first.revision = 1
        var firstDraft = first
        firstDraft.title = "head fails before save"
        var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        second.revision = 1
        var secondDraft = second
        secondDraft.title = "queued recovery still saves"
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [first.id: first, second.id: second]
        let writer = RecoveryBlockingOnceFailingWriter()
        let fixture = try await controlledRecoveryFixture(
            state: state, drafts: [firstDraft, secondDraft], writer: writer
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
        let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
        let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })

        writer.blockAndFailNextWrite()
        let firstResolution = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(firstCandidate.token, action: .restoreAsCurrent)
        }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(writer.waitUntilEntered())
        let secondResolution = Task { @MainActor in
            try await fixture.store.resolveDraftRecovery(secondCandidate.token, action: .restoreAsCurrent)
        }
        for _ in 0 ..< 100 { await Task.yield() }
        writer.release()
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await firstResolution.value
        }
        for _ in 0 ..< 1_000 {
            if await fixture.repository.saveCount == 1 { break }
            await Task.yield()
        }
        guard await fixture.repository.saveCount == 1 else {
            secondResolution.cancel()
            Issue.record("The already-claimed recovery tail remained paused after the head error")
            return
        }
        guard case .committed = try await secondResolution.value else {
            Issue.record("The queued recovery tail must commit exactly once")
            return
        }
        #expect(await fixture.repository.saveCount == 1)
        #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [firstCandidate.token])
        #expect(try await fixture.journal.isCurrentBare(firstCandidate.token))
    }

    @Test func nonvalidReloadsReconcileEmptyAndBareJournalTruthBeforeClearingTheFlag() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let reloadCases: [(WorkspaceReloadedSource, WorkspaceStorePhase, Bool)] = [
            (.absent, .externalSourceChanged(.externalBytesChanged), true),
            (.opaqueInvalid(.init(sha256: "opaque", byteCount: 1)), .opaquePrimaryLoadFailed, true),
            (.unreadableUnknown, .unreadablePrimaryLoadFailed, false),
        ]

        for (reloaded, terminalPhase, restoreAllowed) in reloadCases {
            let empty = try await controlledRecoveryFixture(state: state, drafts: [])
            defer { try? FileManager.default.removeItem(at: empty.directory) }
            await empty.repository.setReloadOverride(reloaded)

            _ = try await empty.store.reloadExternalSource()

            #expect(empty.store.phase == terminalPhase)
            #expect(!empty.store.hasUnresolvedJournalReconciliation)
            #expect(BackupRecoveryPolicy.allowsRestore(
                from: empty.store.phase,
                journalReconciliationRequired: empty.store.hasUnresolvedJournalReconciliation
            ) == restoreAllowed)

            var draft = persisted
            draft.title = "nonvalid reload must still scan this bare record"
            let bare = try await controlledRecoveryFixture(state: state, drafts: [])
            defer { try? FileManager.default.removeItem(at: bare.directory) }
            let token: DraftRecoveryToken
            switch try await bare.journal.protect(try recoveryEntry(
                draft: draft,
                session: UUID(),
                workspaceRevision: state.revision,
                generation: 1
            )) {
            case let .protected(value): token = value
            case .superseded, .busy: Issue.record("The peer must publish a fresh bare record"); return
            }
            await bare.repository.setReloadOverride(reloaded)

            _ = try await bare.store.reloadExternalSource()

            #expect(recoveryCandidates(from: bare.store.phase)?.map(\.token) == [token])
            #expect(!bare.store.hasUnresolvedJournalReconciliation)
        }
    }

    @Test func nonvalidRecoveryBatchReturnsToItsExactTerminalAfterMultiCandidateCleanupRetry() async throws {
        let categoryID = UUID()
        var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        first.revision = 1
        var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        second.revision = 1
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [first.id: first, second.id: second]
        let reloadCases: [(WorkspaceReloadedSource, WorkspaceStorePhase)] = [
            (.absent, .externalSourceChanged(.externalBytesChanged)),
            (.opaqueInvalid(.init(sha256: "opaque-batch", byteCount: 1)), .opaquePrimaryLoadFailed),
            (.unreadableUnknown, .unreadablePrimaryLoadFailed),
        ]

        for (reloaded, terminalPhase) in reloadCases {
            let writer = RecoveryToggleJournalWriter()
            let fixture = try await controlledRecoveryFixture(state: state, drafts: [], writer: writer)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            var firstDraft = first
            firstDraft.title = "first nonvalid recovery"
            var secondDraft = second
            secondDraft.title = "second nonvalid recovery"
            let firstEntry = try recoveryEntry(
                draft: firstDraft, session: UUID(), workspaceRevision: state.revision
            )
            let secondEntry = try recoveryEntry(
                draft: secondDraft, session: UUID(), workspaceRevision: state.revision
            )
            try await fixture.journal.persist(firstEntry)
            try await fixture.journal.persist(secondEntry)
            await fixture.repository.setReloadOverride(reloaded)

            _ = try await fixture.store.reloadExternalSource()
            let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
            let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
            let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })
            guard case .noChange = try await fixture.store.resolveDraftRecovery(
                firstCandidate.token, action: .keepPersisted
            ) else {
                Issue.record("The first candidate must resolve without establishing a main source")
                return
            }
            #expect(recoveryCandidates(from: fixture.store.phase)?.map(\.token) == [secondCandidate.token])

            writer.failOnWrite(offsetFromNow: 1)
            guard case let .noChange(_, journal: .cleanupPending(identity, .discardRecovery(token))) =
                try await fixture.store.resolveDraftRecovery(secondCandidate.token, action: .keepPersisted)
            else {
                Issue.record("The last keep must park its exact failed cleanup")
                return
            }
            #expect(token == secondCandidate.token)
            writer.shouldFail = false

            #expect(await fixture.store.retryJournalCleanup(identity) == .clean)
            #expect(fixture.store.phase == terminalPhase)
            #expect(!fixture.store.hasUnresolvedJournalReconciliation)
            #expect(try await fixture.journal.current()?.records.isEmpty == true)
            #expect(await fixture.repository.saveCount == 0)
        }
    }

    @Test func opaqueRecoveryPublishesRawAndDraftActionsWhileAbsentAndUnreadableDoNotFabricateRaw() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "durable draft beside a non-valid primary"
        let state = recoveryState(persisted: persisted, categoryID: categoryID)

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-10a-opaque-draft-actions-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("workspace.json")
            let opaqueBytes = Data("opaque primary with exact recovery evidence".utf8)
            try opaqueBytes.write(to: primary)
            let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
            try await journal.persist(try recoveryEntry(
                draft: draft, session: UUID(), workspaceRevision: state.revision
            ))
            let repository = JSONWorkspaceRepository(documentURL: primary, seed: { state })
            let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)

            await store.load()

            let candidate = try #require(recoveryCandidate(from: store.phase))
            #expect(store.hasRawRecoverySource)
            let actions = BackupRecoveryPolicy.actions(
                for: store.phase,
                rawRecoveryAvailable: store.hasRawRecoverySource
            )
            #expect(actions.contains(.draftRecoveryRequired([candidate.token])))
            #expect(actions.contains(.exportRawRecoveryCopy))
            #expect(try await store.rawRecoveryData().rawData == opaqueBytes)
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-10a-absent-draft-actions-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("workspace.json")
            let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
            try await journal.persist(try recoveryEntry(
                draft: draft, session: UUID(), workspaceRevision: state.revision
            ))
            let repository = JSONWorkspaceRepository(documentURL: primary, seed: { state })
            let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)

            await store.load()

            _ = try #require(recoveryCandidate(from: store.phase))
            #expect(!store.hasRawRecoverySource)
            #expect(!BackupRecoveryPolicy.actions(
                for: store.phase,
                rawRecoveryAvailable: store.hasRawRecoverySource
            ).contains(.exportRawRecoveryCopy))
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-10a-unreadable-draft-actions-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("workspace.json")
            try WorkspaceDocumentCodec.encode(state).write(to: primary)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: primary.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primary.path) }
            let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
            try await journal.persist(try recoveryEntry(
                draft: draft, session: UUID(), workspaceRevision: state.revision
            ))
            let repository = JSONWorkspaceRepository(documentURL: primary, seed: { state })
            let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)

            await store.load()

            _ = try #require(recoveryCandidate(from: store.phase))
            #expect(!store.hasRawRecoverySource)
            #expect(!BackupRecoveryPolicy.actions(
                for: store.phase,
                rawRecoveryAvailable: store.hasRawRecoverySource
            ).contains(.exportRawRecoveryCopy))
        }
    }

    @Test func realOpaqueAndUnreadableRecoveryPrewriteRejectionsReopenBareTokensAcrossRestart() async throws {
        enum SourceMode { case opaque, unreadable }
        for mode in [SourceMode.opaque, .unreadable] {
            let categoryID = UUID()
            var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
            persisted.revision = 1
            var draft = persisted
            draft.title = "rejected recovery must reopen"
            let state = recoveryState(persisted: persisted, categoryID: categoryID)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-10a-recovery-prewrite-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("workspace.json")
            let originalBytes: Data
            switch mode {
            case .opaque:
                originalBytes = Data("opaque primary rejects ordinary recovery save".utf8)
            case .unreadable:
                originalBytes = try WorkspaceDocumentCodec.encode(state)
            }
            try originalBytes.write(to: primary)
            if case .unreadable = mode {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: primary.path)
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primary.path) }
            let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
            try await journal.persist(try recoveryEntry(
                draft: draft, session: UUID(), workspaceRevision: state.revision
            ))
            let repository = JSONWorkspaceRepository(documentURL: primary, seed: { state })
            let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
            await store.load()
            let candidate = try #require(recoveryCandidate(from: store.phase))

            switch mode {
            case .opaque:
                await #expect(throws: WorkspacePersistenceError.invalidDocument) {
                    _ = try await store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)
                }
            case .unreadable:
                let outcome = try await store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)
                guard case let .persistenceBlocked(_, reason, _) = outcome else {
                    Issue.record("Unreadable primary must return a typed persistence block")
                    continue
                }
                #expect(reason == .unreadablePrimary)
            }

            let record = try #require(try await journal.current()?.records.first)
            #expect(record.recoveryCompletion == nil)
            #expect(record.pendingReceipt == nil)
            #expect(record.savedReceipt == nil)

            let freshRepository = JSONWorkspaceRepository(documentURL: primary, seed: { state })
            let freshStore = WorkspaceStore(initialState: state, repository: freshRepository, journal: journal)
            await freshStore.load()
            #expect(recoveryCandidates(from: freshStore.phase)?.map(\.token) == [candidate.token])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primary.path)
            #expect(try Data(contentsOf: primary) == originalBytes)
        }
    }

    @Test func rejectedRecoveryAbandonWriteFailureParksTheExactCompletionForRetry() async throws {
        let categoryID = UUID()
        var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        persisted.revision = 1
        var draft = persisted
        draft.title = "failed abandon remains retryable"
        let state = recoveryState(persisted: persisted, categoryID: categoryID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-rejected-abandon-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("workspace.json")
        let opaqueBytes = Data("opaque primary forces definite prewrite rejection".utf8)
        try opaqueBytes.write(to: primary)
        let writer = RecoveryToggleJournalWriter()
        let journal = DraftJournalRepository(
            fileURL: directory.appendingPathComponent("draft.json"), writer: writer
        )
        try await journal.persist(try recoveryEntry(
            draft: draft, session: UUID(), workspaceRevision: state.revision
        ))
        let initialState = state
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initialState })
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        let candidate = try #require(recoveryCandidate(from: store.phase))
        writer.failOnWrite(offsetFromNow: 2)

        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await store.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent)
        }
        guard case let .parkedJournalCleanup(identity, .abandonRecoveryCompletion(completion)) = store.phase else {
            Issue.record("A failed exact abandon must park its durable completion")
            return
        }
        #expect(identity == candidate.token.identityAndGeneration.identity)
        #expect(completion.token == candidate.token)

        #expect(await store.retryJournalCleanup(identity) == .clean)
        #expect(recoveryCandidates(from: store.phase)?.map(\.token) == [candidate.token])
        #expect(try Data(contentsOf: primary) == opaqueBytes)
    }

    @Test func rejectedRecoveryHeadKeepsAnAlreadyClaimedTailLiveWithoutAThirdKick() async throws {
        let categoryID = UUID()
        var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        first.revision = 1
        var firstDraft = first
        firstDraft.title = "first rejected recovery"
        var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        second.revision = 1
        var secondDraft = second
        secondDraft.title = "already claimed recovery tail"
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
        state.revision = 1
        state.notes = [first.id: first, second.id: second]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-rejected-recovery-tail-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("workspace.json")
        let opaqueBytes = Data("opaque primary rejects both recovery saves".utf8)
        try opaqueBytes.write(to: primary)
        let writer = RecoveryBlockingOnceWriter()
        let journal = DraftJournalRepository(
            fileURL: directory.appendingPathComponent("draft.json"), writer: writer
        )
        try await journal.persist(try recoveryEntry(
            draft: firstDraft, session: UUID(), workspaceRevision: state.revision
        ))
        try await journal.persist(try recoveryEntry(
            draft: secondDraft, session: UUID(), workspaceRevision: state.revision
        ))
        let tailInitialState = state
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { tailInitialState })
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        let candidates = try #require(recoveryCandidates(from: store.phase))
        let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
        let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })
        writer.blockNextWrite()

        let firstResolution = Task { @MainActor in
            await #expect(throws: WorkspacePersistenceError.invalidDocument) {
                _ = try await store.resolveDraftRecovery(firstCandidate.token, action: .restoreAsCurrent)
            }
        }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(writer.waitUntilEntered())
        let queuedSecond = Task { @MainActor in
            await #expect(throws: WorkspacePersistenceError.invalidDocument) {
                _ = try await store.resolveDraftRecovery(secondCandidate.token, action: .restoreAsCurrent)
            }
        }
        writer.release()

        _ = await firstResolution.value
        _ = await queuedSecond.value
        let records = try #require(try await journal.current()?.records)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.recoveryCompletion == nil })
        #expect(try Data(contentsOf: primary) == opaqueBytes)
    }

    @Test func realAbsentRecoverySavesRebaseTheCleanBatchTerminalToReady() async throws {
        do {
            let categoryID = UUID()
            var persisted = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
            persisted.revision = 1
            var draft = persisted
            draft.title = "save absent recovery as a new note"
            let state = recoveryState(persisted: persisted, categoryID: categoryID)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-10a-absent-single-recovery-save-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("workspace.json")
            try WorkspaceDocumentCodec.encode(state).write(to: primary)
            let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
            let repository = JSONWorkspaceRepository(documentURL: primary, seed: { state })
            let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
            await store.load()
            try await journal.persist(try recoveryEntry(
                draft: draft, session: UUID(), workspaceRevision: state.revision
            ))
            try FileManager.default.removeItem(at: primary)

            _ = try await store.reloadExternalSource()
            let candidate = try #require(recoveryCandidate(from: store.phase))
            let newNoteID = NoteID(UUID())
            let blockIDs = draft.document.blocks.map { _ in BlockID(UUID()) }
            guard case .committed = try await store.resolveDraftRecovery(
                candidate.token,
                action: .saveAsNew(noteID: newNoteID, blockIDs: blockIDs)
            ) else {
                Issue.record("Saving an absent recovery as new must establish a valid main source")
                return
            }

            #expect(store.phase == .ready)
            #expect(try await journal.current()?.records.isEmpty == true)
            let readback = try WorkspaceDocumentCodec.decode(Data(contentsOf: primary)).state
            #expect(readback.notes[newNoteID]?.title == draft.title)
        }

        do {
            let categoryID = UUID()
            var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
            first.revision = 1
            var firstDraft = first
            firstDraft.title = "first absent recovery"
            var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
            second.revision = 1
            var secondDraft = second
            secondDraft.title = "second absent recovery"
            var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
            state.revision = 1
            state.notes = [first.id: first, second.id: second]
            let initialState = state
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-10a-absent-multi-recovery-save-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("workspace.json")
            try WorkspaceDocumentCodec.encode(state).write(to: primary)
            let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
            let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initialState })
            let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
            await store.load()
            try await journal.persist(try recoveryEntry(
                draft: firstDraft, session: UUID(), workspaceRevision: state.revision
            ))
            try await journal.persist(try recoveryEntry(
                draft: secondDraft, session: UUID(), workspaceRevision: state.revision
            ))
            try FileManager.default.removeItem(at: primary)

            _ = try await store.reloadExternalSource()
            let candidates = try #require(recoveryCandidates(from: store.phase))
            let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
            let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })
            guard case .committed = try await store.resolveDraftRecovery(
                firstCandidate.token, action: .restoreAsCurrent
            ) else {
                Issue.record("The first absent recovery must establish the valid source")
                return
            }
            #expect(recoveryCandidates(from: store.phase)?.map(\.token) == [secondCandidate.token])
            let firstReadback = try WorkspaceDocumentCodec.decode(Data(contentsOf: primary)).state
            #expect(firstReadback.notes[first.id]?.title == firstDraft.title)
            #expect(firstReadback.notes[second.id]?.title == second.title)

            guard case .committed = try await store.resolveDraftRecovery(
                secondCandidate.token, action: .restoreAsCurrent
            ) else {
                Issue.record("The last absent recovery must commit against the new valid source")
                return
            }
            #expect(store.phase == .ready)
            #expect(try await journal.current()?.records.isEmpty == true)
            let finalReadback = try WorkspaceDocumentCodec.decode(Data(contentsOf: primary)).state
            #expect(finalReadback.notes[first.id]?.title == firstDraft.title)
            #expect(finalReadback.notes[second.id]?.title == secondDraft.title)
        }
    }

    @Test func checksumValidDomainInvalidJournalFailsClosedBeforeStoreCanPublishARecoveryCandidate() async throws {
        let categoryID = UUID()
        var note = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        note.revision = 1
        var state = recoveryState(persisted: note, categoryID: categoryID)
        state.revision = 1
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-domain-invalid-journal-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("workspace.json")
        let journalURL = directory.appendingPathComponent("draft.json")
        try WorkspaceDocumentCodec.encode(state).write(to: primary)
        let invalidEntry = try recoveryEntry(
            draft: domainInvalidRecoveryNote(from: note),
            session: UUID(),
            workspaceRevision: state.revision
        )
        let invalidJournalBytes = try canonicalRecoveryJournalData(entry: invalidEntry)
        try invalidJournalBytes.write(to: journalURL)
        let initialState = state
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initialState })
        let store = WorkspaceStore(
            initialState: .empty(calendar: state.calendar),
            repository: repository,
            journal: DraftJournalRepository(fileURL: journalURL)
        )

        await store.load()

        #expect(store.phase == .unreadablePrimaryLoadFailed)
        #expect(recoveryCandidates(from: store.phase) == nil)
        #expect(store.phase != .needsRelationshipRepair)
        #expect(store.hasUnresolvedJournalReconciliation)
        #expect(try Data(contentsOf: journalURL) == invalidJournalBytes)
    }

    @Test func acceptedValidReloadPlanFailureKeepsOpaquePhaseWithoutFabricatingRawRecovery() async throws {
        let categoryID = UUID()
        var note = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        note.revision = 1
        var current = recoveryState(persisted: note, categoryID: categoryID)
        current.revision = .max
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-reload-plan-raw-truth-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("workspace.json")
        try Data("opaque source accepted before the valid reload".utf8).write(to: primary)
        let currentState = current
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { currentState })
        let store = WorkspaceStore(initialState: current, repository: repository)
        await store.load()
        #expect(store.phase == .opaquePrimaryLoadFailed)
        #expect(store.hasRawRecoverySource)
        var external = current
        external.notes[note.id]?.title = "accepted valid external source"
        try WorkspaceDocumentCodec.encode(external).write(to: primary)

        await #expect(throws: WorkspaceExternalSourceAdoptionError.revisionOverflow) {
            _ = try await store.reloadExternalSource()
        }

        #expect(store.phase == .opaquePrimaryLoadFailed)
        #expect(!store.hasRawRecoverySource)
        #expect(!BackupRecoveryPolicy.actions(
            for: store.phase,
            rawRecoveryAvailable: store.hasRawRecoverySource
        ).contains(.exportRawRecoveryCopy))
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await store.rawRecoveryData()
        }
    }

    @Test func immediateOpaqueRestoreReconciliationClearsRawRecoveryTruthInTheSameCall() async throws {
        let categoryID = UUID()
        let initial = WorkspaceState.empty(
            calendar: .empty(uncategorizedID: categoryID, now: .distantPast)
        )
        var restored = initial
        var note = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
        note.revision = 1
        note.title = "restored after uncertain opaque replacement"
        restored.revision = 1
        restored.notes[note.id] = note
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-10a-opaque-restore-raw-truth-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("workspace.json")
        let backup = directory.appendingPathComponent("restore.json")
        try Data("opaque primary replaced before result certainty".utf8).write(to: primary)
        try WorkspaceDocumentCodec.encode(restored).write(to: backup)
        let repository = JSONWorkspaceRepository(
            documentURL: primary,
            seed: { initial },
            mainFileWriter: RecoveryWriteThenReportUncertainMainWriter()
        )
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        #expect(store.phase == .opaquePrimaryLoadFailed)
        #expect(store.hasRawRecoverySource)
        let preview = try await store.inspectRestoreSource(at: backup)

        guard case .restored = try await store.restore(
            preview,
            rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true)
        ) else {
            Issue.record("Same-call reconciliation must confirm the written restore")
            return
        }

        #expect(store.phase == .ready)
        #expect(!store.hasRawRecoverySource)
        #expect(!BackupRecoveryPolicy.actions(
            for: store.phase,
            rawRecoveryAvailable: store.hasRawRecoverySource
        ).contains(.exportRawRecoveryCopy))
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await store.rawRecoveryData()
        }
        #expect(try WorkspaceDocumentCodec.decode(Data(contentsOf: primary)).state.notes[note.id]?.title == note.title)
    }

    @Test func opaquePendingRestoreRawActionTracksExecutableLifecycleForEveryExactRetryResult() async throws {
        enum FinalResult { case notCommitted, sourceChanged, committed }
        for finalResult in [FinalResult.notCommitted, .sourceChanged, .committed] {
            let categoryID = UUID()
            let initial = WorkspaceState.empty(
                calendar: .empty(uncategorizedID: categoryID, now: .distantPast)
            )
            var restored = initial
            var note = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
            note.revision = 1
            note.title = "pending opaque restore"
            restored.revision = 1
            restored.notes[note.id] = note
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-10a-pending-raw-lifecycle-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("workspace.json")
            let backup = directory.appendingPathComponent("restore.json")
            let opaqueBytes = Data("exact opaque evidence before pending restore".utf8)
            try opaqueBytes.write(to: primary)
            try WorkspaceDocumentCodec.encode(restored).write(to: backup)
            let writer = RecoveryParkedMainWriter(
                writesCandidate: finalResult == .committed
            )
            let repository = JSONWorkspaceRepository(
                documentURL: primary,
                seed: { initial },
                mainFileWriter: writer
            )
            let store = WorkspaceStore(initialState: initial, repository: repository)
            await store.load()
            #expect(store.phase == .opaquePrimaryLoadFailed)
            #expect(store.hasRawRecoverySource)
            let preview = try await store.inspectRestoreSource(at: backup)

            let pending = try await store.restore(
                preview,
                rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true)
            )
            guard case let .commitPending(transactionID, artifacts) = pending else {
                Issue.record("Unreadable uncertain restore must park its exact transaction")
                return
            }
            #expect(store.phase == .parkedCommitUncertain(transactionID))
            #expect(store.hasRawRecoverySource)
            #expect(BackupRecoveryPolicy.actions(
                for: store.phase,
                rawRecoveryAvailable: store.hasRawRecoverySource
            ) == [.retryPendingCommit(transactionID)])
            await #expect(throws: WorkspacePersistenceError.commitUncertain) {
                _ = try await store.rawRecoveryData()
            }

            #expect(try await store.retryPendingCommit(transactionID) == .stillPending(
                transactionID: transactionID,
                artifacts: artifacts
            ))
            #expect(BackupRecoveryPolicy.actions(
                for: store.phase,
                rawRecoveryAvailable: store.hasRawRecoverySource
            ) == [.retryPendingCommit(transactionID)])
            await #expect(throws: WorkspacePersistenceError.commitUncertain) {
                _ = try await store.rawRecoveryData()
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: primary.path
            )
            switch finalResult {
            case .notCommitted:
                #expect(try await store.retryPendingCommit(transactionID) == .notCommitted(
                    transactionID: transactionID,
                    journal: .clean,
                    artifacts: artifacts
                ))
                #expect(store.phase == .ready)
                #expect(store.hasRawRecoverySource)
                #expect(BackupRecoveryPolicy.actions(
                    for: store.phase,
                    rawRecoveryAvailable: store.hasRawRecoverySource
                ) == [.exportRawRecoveryCopy])
                #expect(try await store.rawRecoveryData().rawData == opaqueBytes)
            case .sourceChanged:
                try Data("third-party replacement after pending restore".utf8).write(
                    to: primary, options: .atomic
                )
                #expect(try await store.retryPendingCommit(transactionID) == .sourceChanged(
                    transactionID: transactionID,
                    journal: .clean,
                    artifacts: artifacts
                ))
                #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
                #expect(store.hasRawRecoverySource)
                #expect(BackupRecoveryPolicy.actions(
                    for: store.phase,
                    rawRecoveryAvailable: store.hasRawRecoverySource
                ) == [.exportRawRecoveryCopy])
                #expect(try await store.rawRecoveryData().rawData == opaqueBytes)
            case .committed:
                guard case let .committed(.restore(outcome), journal: .clean) =
                    try await store.retryPendingCommit(transactionID)
                else {
                    Issue.record("The exact pending restore must publish its committed result")
                    return
                }
                #expect(outcome.rollback == artifacts.rollback)
                #expect(store.phase == .ready)
                #expect(!store.hasRawRecoverySource)
                #expect(BackupRecoveryPolicy.actions(
                    for: store.phase,
                    rawRecoveryAvailable: store.hasRawRecoverySource
                ).isEmpty)
                await #expect(throws: WorkspacePersistenceError.invalidDocument) {
                    _ = try await store.rawRecoveryData()
                }
            }
        }
    }
}

private struct RecoveryStoreFixture {
    let store: WorkspaceStore
    let journal: DraftJournalRepository
    let directory: URL
}

private struct ControlledRecoveryStoreFixture {
    let store: WorkspaceStore
    let journal: DraftJournalRepository
    let repository: RecoveryControlledRepository
    let directory: URL
    let initialCalendar: CalendarState

    var journalURL: URL { directory.appendingPathComponent("draft.json") }
}

private struct TwoRecoveryCleanupFixture {
    let fixture: ControlledRecoveryStoreFixture
    let first: DraftRecoveryCandidate
    let second: DraftRecoveryCandidate
    let writer: RecoveryToggleJournalWriter
}

@MainActor
private func twoRecoveryCleanupFixture() async throws -> TwoRecoveryCleanupFixture {
    let categoryID = UUID()
    var first = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
    first.revision = 1
    var firstDraft = first
    firstDraft.title = "first cleanup candidate"
    var second = Note.empty(id: NoteID(UUID()), categoryID: categoryID, now: .distantPast)
    second.revision = 1
    var secondDraft = second
    secondDraft.title = "unrelated cleanup candidate"
    var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
    state.revision = 1
    state.notes = [first.id: first, second.id: second]
    let writer = RecoveryToggleJournalWriter()
    let fixture = try await controlledRecoveryFixture(
        state: state, drafts: [firstDraft, secondDraft], writer: writer
    )
    let candidates = try #require(recoveryCandidates(from: fixture.store.phase))
    let firstCandidate = try #require(candidates.first { $0.draft.id == first.id })
    let secondCandidate = try #require(candidates.first { $0.draft.id == second.id })
    return .init(fixture: fixture, first: firstCandidate, second: secondCandidate, writer: writer)
}

@MainActor
private func recoveryFixture(
    persisted: Note,
    draft: Note,
    categoryID: UUID,
    writer: any AtomicFileWriting = FoundationAtomicFileWriter()
) async throws -> RecoveryStoreFixture {
    var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
    state.revision = persisted.revision
    state.notes[persisted.id] = persisted
    return try await recoveryFixture(state: state, draft: draft, writer: writer)
}

@MainActor
private func controlledRecoveryFixture(
    state: WorkspaceState,
    drafts: [Note],
    writer: any AtomicFileWriting = FoundationAtomicFileWriter()
) async throws -> ControlledRecoveryStoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "jelly-10a-controlled-recovery-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
    for draft in drafts {
        try await journal.persist(recoveryEntry(draft: draft, session: UUID(), workspaceRevision: state.revision))
    }
    let initialState = state
    let repository = RecoveryControlledRepository(backing: JSONWorkspaceRepository(
        documentURL: directory.appendingPathComponent("workspace.json"), seed: { initialState }
    ))
    let store = WorkspaceStore(
        initialState: .empty(calendar: state.calendar), repository: repository,
        journal: journal, clock: { .distantPast }
    )
    await store.load()
    return .init(
        store: store, journal: journal, repository: repository,
        directory: directory, initialCalendar: state.calendar
    )
}

private func recoveryState(persisted: Note, categoryID: UUID) -> WorkspaceState {
    var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: categoryID, now: .distantPast))
    state.revision = persisted.revision
    state.notes[persisted.id] = persisted
    return state
}

@MainActor
private func recoveryFixture(
    state: WorkspaceState,
    draft: Note,
    writer: any AtomicFileWriting = FoundationAtomicFileWriter()
) async throws -> RecoveryStoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-10a-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
    let session = UUID()
    let entry = try recoveryEntry(draft: draft, session: session, workspaceRevision: state.revision)
    try await journal.persist(entry)
    let initialState = state
    let repository = JSONWorkspaceRepository(
        documentURL: directory.appendingPathComponent("workspace.json"),
        seed: { initialState }
    )
    let store = WorkspaceStore(
        initialState: .empty(calendar: state.calendar),
        repository: repository,
        journal: journal,
        clock: { .distantPast }
    )
    await store.load()
    return .init(store: store, journal: journal, directory: directory)
}

private func recoveryEntry(
    draft: Note,
    session: UUID,
    workspaceRevision: Int64,
    generation: UInt64 = 1
) throws -> DraftJournalEntry {
    let checksum = try WorkspaceChecksum.noteSnapshotChecksum(draft)
    let unsigned = DraftJournalEntry(
        noteID: draft.id,
        editSessionID: .editor(session),
        baseWorkspaceRevision: workspaceRevision,
        baseNoteRevision: max(0, draft.revision - 1),
        draftGeneration: generation,
        noteSnapshot: draft,
        updatedAt: .distantPast,
        noteSnapshotChecksum: checksum,
        journalChecksum: ""
    )
    return .init(
        noteID: unsigned.noteID,
        editSessionID: unsigned.editSessionID,
        baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
        baseNoteRevision: unsigned.baseNoteRevision,
        draftGeneration: unsigned.draftGeneration,
        noteSnapshot: unsigned.noteSnapshot,
        updatedAt: unsigned.updatedAt,
        noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
        journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
    )
}

private func domainInvalidRecoveryNote(from note: Note) -> Note {
    var invalid = note
    let duplicate = BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000adff")!)
    invalid.document = .init(blocks: [
        .init(
            id: duplicate, kind: .paragraph, inlineContent: .plain("first"),
            taskState: nil, indentLevel: 0
        ),
        .init(
            id: duplicate, kind: .paragraph, inlineContent: .plain("second"),
            taskState: nil, indentLevel: 0
        ),
    ])
    return invalid
}

private func canonicalRecoveryJournalData(entry: DraftJournalEntry) throws -> Data {
    let record = StoredDraftJournalRecord(
        entry: entry,
        pendingReceipt: nil,
        savedReceipt: nil,
        recordChecksum: try DraftJournal.recordChecksum(
            entry: entry, pendingReceipt: nil, savedReceipt: nil, recoveryCompletion: nil
        )
    )
    let records = DraftJournal.canonicalRecords([record])
    let envelope = DraftJournalEnvelope(
        schemaVersion: DraftJournalEnvelope.currentSchemaVersion,
        records: records,
        envelopeChecksum: try DraftJournal.envelopeChecksum(records: records)
    )
    return try WorkspaceDocumentCodec.canonicalPersistentData(envelope)
}

private struct RecoveryWriteThenReportUncertainMainWriter: MainFileCompareAndReplaceWriting {
    private let backing = FoundationMainFileCompareAndReplaceWriter()

    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try uncertainAfterWriting(backing.createIfAbsent(candidate: candidate, at: destination))
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try uncertainAfterWriting(backing.replaceIfSHA256Matches(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        ))
    }

    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try uncertainAfterWriting(backing.createIfAbsentUnlocked(candidate: candidate, at: destination))
    }

    func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try uncertainAfterWriting(backing.replaceIfSHA256MatchesUnlocked(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        ))
    }

    private func uncertainAfterWriting(
        _ result: MainFileCompareAndReplaceResult
    ) throws -> MainFileCompareAndReplaceResult {
        switch result {
        case .replaced:
            return .commitUncertain
        case .commitUncertain, .sourceChanged:
            return result
        }
    }
}

private struct RecoveryParkedMainWriter: MainFileCompareAndReplaceWriting {
    let writesCandidate: Bool
    private let backing = FoundationMainFileCompareAndReplaceWriter()

    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try park(
            result: writesCandidate
                ? backing.createIfAbsent(candidate: candidate, at: destination)
                : nil,
            destination: destination
        )
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try park(
            result: writesCandidate
                ? backing.replaceIfSHA256Matches(
                    expectedSHA256: expectedSHA256,
                    candidate: candidate,
                    at: destination
                )
                : nil,
            destination: destination
        )
    }

    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try park(
            result: writesCandidate
                ? backing.createIfAbsentUnlocked(candidate: candidate, at: destination)
                : nil,
            destination: destination
        )
    }

    func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try park(
            result: writesCandidate
                ? backing.replaceIfSHA256MatchesUnlocked(
                    expectedSHA256: expectedSHA256,
                    candidate: candidate,
                    at: destination
                )
                : nil,
            destination: destination
        )
    }

    private func park(
        result: MainFileCompareAndReplaceResult?,
        destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        if let result, case .replaced = result {
            // The exact candidate was written; visibility is made uncertain
            // only long enough for Store to publish the retry transaction.
        } else if let result {
            return result
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: destination.path
        )
        return .commitUncertain
    }
}

private func recoveryCandidate(from phase: WorkspaceStorePhase) -> DraftRecoveryCandidate? {
    guard case let .needsDraftRecovery(candidates) = phase else { return nil }
    return candidates.first
}

private func recoveryCandidates(from phase: WorkspaceStorePhase) -> [DraftRecoveryCandidate]? {
    guard case let .needsDraftRecovery(candidates) = phase else { return nil }
    return candidates
}

private final class RecoveryToggleJournalWriter: AtomicFileWriting, @unchecked Sendable {
    var shouldFail = false
    private var writeCount = 0
    private var failingWrite: Int?

    func replaceAtomically(data: Data, at destination: URL) throws {
        writeCount += 1
        if shouldFail || failingWrite == writeCount { throw WorkspacePersistenceError.atomicWriteFailed }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }

    func failOnWrite(offsetFromNow: Int) {
        failingWrite = writeCount + offsetFromNow
    }
}

private final class RecoveryBlockingOnceFailingWriter: AtomicFileWriting, @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var entered = false
    private var released = false

    func replaceAtomically(data: Data, at destination: URL) throws {
        condition.lock()
        if armed {
            armed = false
            entered = true
            condition.broadcast()
            while released == false { condition.wait() }
            released = false
            condition.unlock()
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        condition.unlock()
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }

    func blockAndFailNextWrite() {
        condition.lock()
        armed = true
        entered = false
        released = false
        condition.unlock()
    }

    func waitUntilEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while entered == false {
            if condition.wait(until: deadline) == false { return entered }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class RecoveryBlockingOnceWriter: AtomicFileWriting, @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var entered = false
    private var released = false

    func replaceAtomically(data: Data, at destination: URL) throws {
        condition.lock()
        if armed {
            armed = false
            entered = true
            condition.broadcast()
            while released == false { condition.wait() }
            released = false
        }
        condition.unlock()
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }

    func blockNextWrite() {
        condition.lock()
        armed = true
        entered = false
        released = false
        condition.unlock()
    }

    func waitUntilEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while entered == false {
            if condition.wait(until: deadline) == false { return entered }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class JournalCurrentLockHolder {
    private let process: Process
    private let lockedSignalURL: URL
    private let releaseSignalURL: URL

    init(journalURL: URL, directory: URL) throws {
        lockedSignalURL = directory.appendingPathComponent("journal-current-locked-\(UUID().uuidString)")
        releaseSignalURL = directory.appendingPathComponent("journal-current-release-\(UUID().uuidString)")
        let lockURL = journalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(journalURL.lastPathComponent).jelly.lock")
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl, os, sys, time\nlock = open(sys.argv[1], 'a+b')\nfcntl.flock(lock, fcntl.LOCK_EX)\nopen(sys.argv[2], 'wb').close()\nwhile not os.path.exists(sys.argv[3]):\n    time.sleep(0.001)\nfcntl.flock(lock, fcntl.LOCK_UN)\nlock.close()",
            lockURL.path,
            lockedSignalURL.path,
            releaseSignalURL.path,
        ]
        try process.run()
    }

    func waitUntilLocked() async throws {
        for _ in 0 ..< 1_000 {
            if FileManager.default.fileExists(atPath: lockedSignalURL.path) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw WorkspacePersistenceError.atomicWriteFailed
    }

    func release() throws {
        try Data().write(to: releaseSignalURL, options: .atomic)
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func stop() {
        if process.isRunning {
            try? release()
            process.waitUntilExit()
        }
    }
}

private actor RecoveryControlledRepository: WorkspaceRepository {
    private enum UncertainSaveMode { case none, writeThenUncertain, uncertainWithoutWrite }
    private let backing: JSONWorkspaceRepository
    private let loadOverride: WorkspaceLoadResult?
    private var saveCountStorage = 0
    private var suspendSave = false
    private var saveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var uncertainSaveMode: UncertainSaveMode = .none
    private var failAtomicSave = false
    private var reconciliationOverride: WorkspaceCommitReconciliation?
    private var reloadOverride: WorkspaceReloadedSource?
    private var failReload = false
    private var restorePrepareCountStorage = 0
    private var restoreCommitCountStorage = 0

    init(backing: JSONWorkspaceRepository, loadOverride: WorkspaceLoadResult? = nil) {
        self.backing = backing
        self.loadOverride = loadOverride
    }

    func load() async throws -> WorkspaceLoadResult {
        if let loadOverride { return loadOverride }
        return try await backing.load()
    }
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt {
        if suspendSave {
            saveStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        if failAtomicSave {
            failAtomicSave = false
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        switch uncertainSaveMode {
        case .writeThenUncertain:
            uncertainSaveMode = .none
            _ = try await backing.save(state, draft: draft)
            saveCountStorage += 1
            throw WorkspacePersistenceError.commitUncertain
        case .uncertainWithoutWrite:
            uncertainSaveMode = .none
            throw WorkspacePersistenceError.commitUncertain
        case .none:
            let receipt = try await backing.save(state, draft: draft)
            saveCountStorage += 1
            return receipt
        }
    }
    func verifyPersistedDraft(_ context: PersistableDraftContext) async throws -> WorkspaceDraftPersistenceVerification {
        try await backing.verifyPersistedDraft(context)
    }
    func prepareRestore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) async throws -> PreparedWorkspaceRestore {
        restorePrepareCountStorage += 1
        return try await backing.prepareRestore(preview, rollbackDirectoryURL: rollbackDirectoryURL)
    }
    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) async -> Bool {
        await backing.discardPreparedRestore(prepared)
    }
    func commitRestore(_ prepared: PreparedWorkspaceRestore, state: WorkspaceState) async throws -> WorkspaceRestoreOutcome {
        restoreCommitCountStorage += 1
        return try await backing.commitRestore(prepared, state: state)
    }
    func currentDocumentData() async throws -> Data { try await backing.currentDocumentData() }
    func reloadCurrentSourceAfterExternalChange() async throws -> WorkspaceReloadedSource {
        if failReload {
            failReload = false
            throw WorkspacePersistenceError.invalidDocument
        }
        if let reloadOverride { return reloadOverride }
        return try await backing.reloadCurrentSourceAfterExternalChange()
    }
    func currentRawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact {
        try await backing.currentRawRecoveryData()
    }
    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation {
        if let reconciliationOverride { return reconciliationOverride }
        return try await backing.reconcilePendingCommit()
    }

    func suspendNextSave() { suspendSave = true }
    func waitForSaveStart() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resumeSave() {
        suspendSave = false
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func makeNextSaveUncertain(afterWriting: Bool) {
        uncertainSaveMode = afterWriting ? .writeThenUncertain : .uncertainWithoutWrite
    }
    func failNextSaveDefinitively() { failAtomicSave = true }
    func setReconciliation(_ reconciliation: WorkspaceCommitReconciliation) { reconciliationOverride = reconciliation }
    func setReloadOverride(_ result: WorkspaceReloadedSource?) { reloadOverride = result }
    func failNextReload() { failReload = true }
    func replacePersistedState(_ state: WorkspaceState) async {
        _ = try? await backing.save(state, draft: nil)
    }
    var saveCount: Int { saveCountStorage }
    var restorePrepareCount: Int { restorePrepareCountStorage }
    var restoreCommitCount: Int { restoreCommitCountStorage }
}

private actor RecoveryRepairRepository: WorkspaceRepository {
    private var state: WorkspaceState
    private var saveCountStorage = 0
    private var suspendSave = false
    private var saveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(initial: WorkspaceState) { state = initial }

    func load() -> WorkspaceLoadResult {
        .init(
            state: state,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "recovery-repair", sourceByteCount: 1),
            consistencyIssues: []
        )
    }
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async -> WorkspaceSaveReceipt {
        if suspendSave {
            saveStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        self.state = state
        saveCountStorage += 1
        return .init(workspaceRevision: state.revision, persistedDraft: nil)
    }
    func verifyPersistedDraft(_ context: PersistableDraftContext) -> WorkspaceDraftPersistenceVerification { .notPersisted }
    func prepareRestore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) throws -> PreparedWorkspaceRestore {
        throw WorkspacePersistenceError.invalidRestoreCapability
    }
    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) -> Bool { false }
    func commitRestore(_ prepared: PreparedWorkspaceRestore, state: WorkspaceState) throws -> WorkspaceRestoreOutcome {
        throw WorkspacePersistenceError.invalidRestoreCapability
    }
    func currentDocumentData() throws -> Data { Data() }
    func reloadCurrentSourceAfterExternalChange() -> WorkspaceReloadedSource {
        .valid(load())
    }
    func currentRawRecoveryData() throws -> WorkspaceRawRecoveryArtifact { throw WorkspacePersistenceError.invalidDocument }
    func reconcilePendingCommit() -> WorkspaceCommitReconciliation { .notCommitted(.init()) }
    func suspendNextSave() { suspendSave = true }
    func waitForSaveStart() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resumeSave() {
        suspendSave = false
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    var saveCount: Int { saveCountStorage }
}
