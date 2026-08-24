import AppKit
import CalendarDomain
import CalendarPersistence
import Combine
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

/// Real repository vertical slice for Task 10D: V2 bytes → migrate → create note
/// → protect/commit → restart Store and reload exact note.
@Suite("NotesVerticalIntegrationTests", .serialized)
@MainActor
struct NotesVerticalIntegrationTests {
    @Test func v2UpgradeCreateNoteProtectCommitAndRestartPreservesNoteAndCalendar() async throws {
        let directory = try NotesVerticalTempDirectory()
        defer { directory.remove() }

        let main = directory.file("calendar-v1.json")
        let snapshots = directory.file("snapshots")
        let manifest = directory.file("recovery-manifest.json")
        let journalURL = directory.file("draft-journal.json")
        let v2 = try NotesVerticalFixtures.v2CalendarDocument()
        try v2.write(to: main)

        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: NotesVerticalFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        let journal = DraftJournalRepository(fileURL: journalURL)
        let store = WorkspaceStore(
            initialState: .empty(calendar: NotesVerticalFixtures.calendarState),
            repository: repository,
            journal: journal
        )
        await store.load()
        switch store.phase {
        case .ready, .needsDraftRecovery:
            break
        default:
            Issue.record("unexpected phase after V2 load: \(store.phase)")
        }

        let originalCalendar = store.calendarState
        let note = Note.empty(
            id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-00000000A101")!),
            categoryID: originalCalendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 1_754_100_000)
        )
        var authored = note
        authored.title = "竖切笔记"
        authored.document = BlockDocument(blocks: [
            .init(
                id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000A102")!),
                kind: .paragraph,
                inlineContent: .plain("第一段正文"),
                taskState: nil,
                indentLevel: 0
            ),
            try .task(
                id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000A103")!),
                text: "待办块"
            )
        ])

        let autosave = NoteAutosaveCoordinator(store: store, scheduler: VerticalImmediateScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave)
        #expect(try await viewModel.create(authored))
        #expect(viewModel.selectedNoteID == authored.id)

        // Title + body edits through the production autosave path.
        _ = try autosave.update(title: "竖切笔记-已编辑")
        _ = try autosave.update(document: authored.document)
        let evidence = await autosave.flushLatest()
        #expect(evidence == .persisted(try #require(autosave.currentTriple)))

        // Main file must now be current schema and recovery snapshot of original V2 exists.
        let mainBytes = try Data(contentsOf: main)
        #expect(
            try WorkspaceDocumentCodec.decode(mainBytes).provenance.sourceSchema
                == WorkspaceDocument.currentSchemaVersion
        )
        let recovery = try RecoveryManifestStore(manifestURL: manifest, snapshotDirectoryURL: snapshots).load()
        #expect(recovery.entries.isEmpty == false)

        // Fresh Store/repository/journal must reload the exact Note.
        let repository2 = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: NotesVerticalFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        let journal2 = DraftJournalRepository(fileURL: journalURL)
        let store2 = WorkspaceStore(
            initialState: .empty(calendar: NotesVerticalFixtures.calendarState),
            repository: repository2,
            journal: journal2
        )
        await store2.load()
        let reloaded = try #require(store2.state.notes[authored.id])
        #expect(reloaded.title == "竖切笔记-已编辑")
        #expect(reloaded.document.blocks.count == 2)
        #expect(store2.calendarState.uncategorizedID == originalCalendar.uncategorizedID)
        #expect(store2.calendarState.categories.keys.sorted(by: { $0.uuidString < $1.uuidString })
            == originalCalendar.categories.keys.sorted(by: { $0.uuidString < $1.uuidString }))
    }

    @Test func productionAppShellBuildsNotesHostWithoutFatalPlaceholder() {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        let routeState = WorkspaceRouteState(
            features: .production,
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "calendar")
        )
        let router = WorkspaceNewItemRouter()
        let focus = EditorFocusRegistry()
        let transition = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: .production)
        let shell = AppShellView(
            store: store,
            features: .production,
            routeState: routeState,
            newItemRouter: router,
            focusRegistry: focus,
            transitionCoordinator: transition
        )
        // Host store is built in init; notes must be present, inspiration absent.
        #expect(WorkspaceRoute.visibleRoutes(.production) == [.calendar, .notes, .inspiration])
        _ = shell
    }

    @Test func entryFinalizesNativeInputFlushesLatestAndCapturesPersistedRevision() async throws {
        let host = try await productionNoteEditorHost(
            document: BlockDocument(blocks: [
                .init(
                    id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000A201")!),
                    kind: .paragraph,
                    inlineContent: .plain("预约牙医"),
                    taskState: nil,
                    indentLevel: 0
                )
            ])
        )
        defer { host.close() }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        textView.selectedRange = NSRange(location: 2, length: 2)
        textView.setMarkedText(
            "牙",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: 0, length: 0)
        )
        #expect(textView.hasMarkedText())
        #expect(textView.string == "牙预约牙医")
        await host.tapAccessibilityButton("拆开并安排")
        #expect(await waitUntil {
            host.sync()
            return host.presentedWorkbenchSnapshot != nil
        })
        let snapshot = try #require(host.presentedWorkbenchSnapshot)
        #expect(snapshot.noteRevision == host.store.state.notes[host.noteID]?.revision)
        let persisted = try #require(host.store.state.notes[host.noteID])
        let firstBlockText = persisted.document.blocks[0].inlineContent.spans.map(\.text).joined()
        #expect(textView.hasMarkedText() == false)
        #expect(firstBlockText == "牙预约牙医")
        #expect(snapshot.normalizedText == "牙预约牙医")
        #expect(snapshot.sourceBlockID == nil)
        #expect(snapshot.selectedRange == nil)
        #expect(textView.selectedRange == NSRange(location: 1, length: 0))
        #expect(host.entryNotice == nil)
    }

    @Test func emptySourceKeepsFocusAndExplainsTheNextStep() async throws {
        let host = try await productionNoteEditorHost(document: .empty())
        defer { host.close() }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        await host.tapAccessibilityButton("拆开并安排")
        #expect(await waitUntil {
            host.sync()
            return host.entryNotice != nil
        })
        #expect(host.presentedWorkbenchSnapshot == nil)
        #expect(host.entryNotice == "这段内容还不够拆开，请先写下要处理的事情。")
        #expect(host.window.firstResponder === textView)
    }

    @Test func crossBlockSelectionKeepsFocusAndDoesNotOpenTheWorkbench() async throws {
        let first = BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000A211")!)
        let second = BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000A212")!)
        let host = try await productionNoteEditorHost(
            document: BlockDocument(blocks: [
                .init(id: first, kind: .paragraph, inlineContent: .plain("第一段事情"), taskState: nil, indentLevel: 0),
                .init(id: second, kind: .paragraph, inlineContent: .plain("第二段事情"), taskState: nil, indentLevel: 0)
            ])
        )
        defer { host.close() }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        textView.selectedRange = NSRange(location: 0, length: ("第一段事情\n第二段事情" as NSString).length)
        await host.tapAccessibilityButton("拆开并安排")
        #expect(await waitUntil {
            host.sync()
            return host.entryNotice != nil
        })
        #expect(host.presentedWorkbenchSnapshot == nil)
        #expect(host.entryNotice == "请只选中同一段里的文字，或取消选区后用整篇笔记拆开。")
        #expect(host.window.firstResponder === textView)
    }

    @Test func protectedOnlyFlushKeepsFocusAndAsksToFinishSaving() async throws {
        let directory = try NotesVerticalTempDirectory()
        defer { directory.remove() }
        let host = try await productionNoteEditorHost(
            document: BlockDocument(blocks: [
                .init(
                    id: BlockID(),
                    kind: .paragraph,
                    inlineContent: .plain("需要保存后再拆开"),
                    taskState: nil,
                    indentLevel: 0
                )
            ]),
            journalURL: directory.file("draft.json")
        )
        defer { host.close() }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        _ = try host.autosave.update(title: "尚未写入主文件")
        await host.repository.failNextSave()
        await host.tapAccessibilityButton("拆开并安排")
        #expect(await waitUntil {
            host.sync()
            return host.entryNotice != nil
        })
        #expect(host.presentedWorkbenchSnapshot == nil)
        #expect(host.entryNotice == "请先完成当前笔记的保存，再拆开并安排。")
        #expect(host.window.firstResponder === textView)
    }

    @Test func unsafeFlushKeepsFocusAndDoesNotOpenTheWorkbench() async throws {
        let host = try await productionNoteEditorHost(
            document: BlockDocument(blocks: [
                .init(
                    id: BlockID(),
                    kind: .paragraph,
                    inlineContent: .plain("无法保护的草稿"),
                    taskState: nil,
                    indentLevel: 0
                )
            ])
        )
        defer { host.close() }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        _ = try host.autosave.update(title: "无法保护")
        await host.repository.failNextSave()
        await host.tapAccessibilityButton("拆开并安排")
        #expect(await waitUntil {
            host.sync()
            return host.entryNotice != nil
        })
        #expect(host.presentedWorkbenchSnapshot == nil)
        #expect(host.entryNotice == "这次修改还没有安全保存，请先处理保存问题，再拆开并安排。")
        #expect(host.window.firstResponder === textView)
    }

    @Test func successfulWorkbenchUndoClickRemovesCreatedPlanAndRebuildsEditor() async throws {
        let host = try await productionNoteEditorHost(document: scheduledWorkbenchSourceDocument())
        defer { host.close() }
        let created = try await commitScheduledWorkbenchPlan(on: host)
        let undo = try #require(await waitUntilValue { host.identifiedButton("notes-workbench-undo") })
        #expect(undo.isEnabled)
        undo.performClick(undo)
        #expect(await waitUntil {
            host.sync()
            return createdPlanRemoved(created, on: host)
                && originalSourceRemains(created, on: host)
                && host.feedbackMessage == nil
                && host.identifiedButton("notes-workbench-undo") == nil
        })
    }

    @Test func successfulWorkbenchCommitClearsFeedbackAfterUnrelatedStoreWrite() async throws {
        let host = try await productionNoteEditorHost(document: scheduledWorkbenchSourceDocument())
        defer { host.close() }
        let created = try await commitScheduledWorkbenchPlan(on: host)
        let undo = try #require(await waitUntilValue { host.identifiedButton("notes-workbench-undo") })
        #expect(undo.isEnabled)
        let unrelated = try makeItem(
            categoryID: host.store.calendarState.uncategorizedID,
            title: "无关事项"
        )
        _ = try await host.store.sendCalendar(.createItem(unrelated), undoLabel: "无关事项")
        #expect(await waitUntil {
            host.sync()
            return host.identifiedButton("notes-workbench-undo") == nil
                && host.feedbackMessage == nil
        })
        #expect(host.store.calendarState.items[unrelated.id] != nil)
        #expect(createdPlanStillPresent(created, on: host))
    }

    @Test func workbenchCommitKeepsStorePlanWhenEditorRebuildFails() async throws {
        let host = try await productionNoteEditorHost(document: scheduledWorkbenchSourceDocument())
        defer { host.close() }
        let executed = try await executeScheduledWorkbenchCommit(on: host)
        #expect(createdPlanStillPresent(executed.created, on: host))
        #expect(host.nativeTextView?.string.contains(executed.created.actionTitle) != true)

        let gate = PausingNativeInputFinalizerGate()
        let flushTask = Task { await host.autosave.flushLatest(finalizer: gate.finalize) }
        defer { gate.release() }
        #expect(await waitUntil {
            if case .finalizingNativeInput = host.autosave.autosaveState { return true }
            return false
        })
        try host.completeWorkbenchCommit(executed.result)
        host.sync()
        let refreshFailure = "行动已创建，但当前笔记没有刷新。请重新打开这篇笔记查看。"
        let successCopy = DecompositionWorkbenchCopy.completionMessage(created: 1, scheduled: 1)
        #expect(host.feedbackMessage == refreshFailure)
        #expect(host.feedbackMessage != successCopy)
        #expect(host.presentedWorkbenchSnapshot == nil)
        #expect(createdPlanStillPresent(executed.created, on: host))
        #expect(originalSourceRemains(executed.created, on: host))
        #expect(host.nativeTextView?.string.contains(executed.created.actionTitle) != true)
        if case let .committed(_, _, generation) = executed.result {
            if host.store.statePublicationGeneration == generation {
                let undo = try #require(await waitUntilValue { host.identifiedButton("notes-workbench-undo") })
                #expect(undo.isEnabled)
            }
        } else {
            Issue.record("expected a real committed workbench result")
        }
        gate.release()
        _ = await flushTask.value
    }

    @Test func staleWorkbenchCommitAfterParentRekeyDoesNotHijackAutosaveOrWriteParagraphDraft() async throws {
        let directory = try NotesVerticalTempDirectory()
        defer { directory.remove() }
        let journalURL = directory.file("draft.json")
        let host = try await productionNoteEditorHost(
            document: scheduledWorkbenchSourceDocument(),
            journalURL: journalURL
        )
        defer { host.close() }

        let staleSession = try #require(await waitUntilValue { host.box.session })
        let executed = try await executeScheduledWorkbenchCommit(on: host)
        let persistedAfterCommit = try #require(host.store.state.notes[host.noteID])
        #expect(persistedAfterCommit.document.blocks.contains { $0.kind == .task })
        #expect(staleSession.document.blocks.contains { $0.kind == .task } == false)
        #expect(staleSession.editSessionID == host.parentIdentity.editSessionID)

        let parentReplacementID = UUID()
        try host.autosave.beginSession(
            persistedAfterCommit,
            linkedTaskBlockLinks: Set(host.store.state.taskBlockLinks.filter {
                $0.noteID == host.noteID
            }),
            editSessionID: parentReplacementID,
            activeHostToken: UUID()
        )
        #expect(host.autosave.currentEditSessionID == parentReplacementID)
        let staleFinalizer = try #require(host.box.finalizer)

        try host.completeWorkbenchCommit(executed.result)
        host.sync()

        #expect(host.autosave.currentEditSessionID == parentReplacementID)
        #expect(
            host.feedbackMessage
                == DecompositionWorkbenchCopy.completionMessage(created: 1, scheduled: 1)
        )
        #expect(createdPlanStillPresent(executed.created, on: host))
        #expect(staleSession.document.blocks.contains { $0.kind == .task } == false)

        #expect(await host.autosave.finalizeNativeInputForRoute(staleFinalizer) == false)
        #expect(host.autosave.autosaveState == .editable)

        let journal = DraftJournalRepository(fileURL: journalURL)
        #expect((try await journal.current()?.records ?? []).isEmpty)

        let persistedFinal = try #require(host.store.state.notes[host.noteID])
        #expect(persistedFinal.document == persistedAfterCommit.document)
        #expect(createdPlanStillPresent(executed.created, on: host))
        #expect(host.autosave.currentEditSessionID == parentReplacementID)
    }

    @Test func staleWorkbenchCommitAfterSwitchingNotesDoesNotPublishNoticeOrHijackAutosave() async throws {
        let directory = try NotesVerticalTempDirectory()
        defer { directory.remove() }
        let journalURL = directory.file("draft.json")
        let host = try await productionNoteEditorHost(
            document: scheduledWorkbenchSourceDocument(),
            journalURL: journalURL
        )
        defer { host.close() }

        let firstNoteID = host.noteID
        let executed = try await executeScheduledWorkbenchCommit(on: host)
        let firstNoteAfterCommit = try #require(host.store.state.notes[firstNoteID])
        #expect(firstNoteAfterCommit.document.blocks.contains { $0.kind == .task })
        #expect(createdPlanStillPresent(executed.created, on: host))
        let staleHandler = try #require(host.box.commitHandler)

        var second = Note.empty(
            id: NoteID(),
            categoryID: host.store.calendarState.uncategorizedID,
            now: .distantPast
        )
        second.title = "第二篇笔记"
        second.document = BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain("另一篇笔记正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        _ = try await host.store.sendWorkspace(.createNote(.init(note: second)))
        let persistedSecond = try #require(host.store.state.notes[second.id])
        let secondSessionID = UUID()
        try host.autosave.beginSession(
            persistedSecond,
            linkedTaskBlockLinks: Set(host.store.state.taskBlockLinks.filter {
                $0.noteID == persistedSecond.id
            }),
            editSessionID: secondSessionID,
            activeHostToken: UUID()
        )
        #expect(host.autosave.currentNoteID == persistedSecond.id)
        #expect(host.autosave.currentEditSessionID == secondSessionID)

        host.box.workbenchNotice = nil
        host.box.feedback = nil
        host.box.feedbackGeneration = nil

        staleHandler(executed.result)
        host.sync()

        #expect(host.box.workbenchNotice == nil)
        #expect(host.feedbackMessage == nil)
        #expect(host.identifiedButton("notes-workbench-undo") == nil)
        #expect(host.identifiedAccessibilityNode("notes-workbench-feedback") == nil)
        #expect(host.autosave.currentNoteID == persistedSecond.id)
        #expect(host.autosave.currentEditSessionID == secondSessionID)
        #expect(createdPlanStillPresent(executed.created, on: host))

        let secondAfterStale = try #require(host.store.state.notes[persistedSecond.id])
        #expect(secondAfterStale.document == persistedSecond.document)
        #expect(secondAfterStale.title == persistedSecond.title)

        let journal = DraftJournalRepository(fileURL: journalURL)
        #expect((try await journal.current()?.records ?? []).isEmpty)
    }

    @Test func sharedWorkbenchNoticeSurvivesReplacementHostAndUndoRemovesCreatedPlan() async throws {
        let directory = try NotesVerticalTempDirectory()
        defer { directory.remove() }
        let journalURL = directory.file("draft.json")
        let host = try await productionNoteEditorHost(
            document: scheduledWorkbenchSourceDocument(),
            journalURL: journalURL
        )
        defer { host.close() }

        let executed = try await executeScheduledWorkbenchCommit(on: host)
        let persistedAfterCommit = try #require(host.store.state.notes[host.noteID])
        #expect(createdPlanStillPresent(executed.created, on: host))
        #expect(persistedAfterCommit.document.blocks.contains { $0.kind == .task })

        let parentReplacementID = UUID()
        let replacementIdentity = NoteEditorIdentity(
            noteID: host.noteID,
            editSessionID: parentReplacementID
        )
        try host.autosave.beginSession(
            persistedAfterCommit,
            linkedTaskBlockLinks: Set(host.store.state.taskBlockLinks.filter {
                $0.noteID == host.noteID
            }),
            editSessionID: parentReplacementID,
            activeHostToken: UUID()
        )
        #expect(host.autosave.currentEditSessionID == parentReplacementID)

        try host.completeWorkbenchCommit(executed.result)
        host.sync()
        let successCopy = DecompositionWorkbenchCopy.completionMessage(created: 1, scheduled: 1)
        #expect(host.box.workbenchNotice?.message == successCopy)
        #expect(host.box.workbenchNotice?.stateGeneration != nil)

        host.remountReplacement(identity: replacementIdentity, note: persistedAfterCommit)
        let feedback = try #require(await waitUntilValue(timeout: .seconds(3)) { () -> NSView? in
            host.sync()
            return host.identifiedAccessibilityNode("notes-workbench-feedback")
        })
        #expect(feedback.accessibilityIdentifier() == "notes-workbench-feedback")
        #expect(feedback.accessibilityLabel() == successCopy)
        #expect(feedback.accessibilityValue() as? String == successCopy)
        let undo = try #require(await waitUntilValue(timeout: .seconds(3)) { () -> NSButton? in
            host.sync()
            return host.identifiedButton("notes-workbench-undo")
        })
        #expect(undo.isEnabled)
        #expect(undo.accessibilityIdentifier() == "notes-workbench-undo")
        undo.performClick(undo)
        #expect(await waitUntil(timeout: .seconds(3)) {
            host.sync()
            return createdPlanRemoved(executed.created, on: host)
                && originalSourceRemains(executed.created, on: host)
                && host.box.workbenchNotice == nil
                && host.identifiedButton("notes-workbench-undo") == nil
                && host.identifiedAccessibilityNode("notes-workbench-feedback") == nil
        })
        let remainingBlockIDs = Set(host.store.state.notes[host.noteID]?.document.blocks.map(\.id) ?? [])
        #expect(executed.created.taskBlockIDs.isDisjoint(with: remainingBlockIDs))
        #expect(executed.created.links.isDisjoint(with: host.store.state.taskBlockLinks))
        #expect(executed.created.calendarItemIDs.allSatisfy { host.store.calendarState.items[$0] == nil })
        #expect(originalSourceRemains(executed.created, on: host))
        let journal = DraftJournalRepository(fileURL: journalURL)
        #expect((try await journal.current()?.records ?? []).isEmpty)
        #expect(host.box.workbenchNotice == nil)
    }

    @Test func cleanupPendingRetryKeepsFocusAndDoesNotOpenTheWorkbench() async throws {
        let directory = try NotesVerticalTempDirectory()
        defer { directory.remove() }
        let writer = PersistentCleanupFailingJournalWriter(failOnWrite: 4)
        let host = try await productionNoteEditorHost(
            document: BlockDocument(blocks: [
                .init(
                    id: BlockID(),
                    kind: .paragraph,
                    inlineContent: .plain("今天下午要给诊所打电话"),
                    taskState: nil,
                    indentLevel: 0
                )
            ]),
            journalURL: directory.file("draft.json"),
            journalWriter: writer
        )
        defer { host.close() }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        textView.selectedRange = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.insertText("确认预约时间", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(await waitUntil {
            textView.string.contains("确认预约时间")
        })
        let triple = try #require(await waitUntilValue { host.autosave.currentTriple })
        #expect(await host.autosave.flushLatest() == .persisted(triple))
        guard case .cleanupPending = host.autosave.autosaveState else {
            Issue.record("failed journal cleanup must remain typed cleanupPending")
            return
        }
        writer.failAllSubsequentWrites()
        #expect(host.window.firstResponder === textView)
        let writesAfterFlush = writer.writeCount
        await host.tapAccessibilityButton("拆开并安排")
        #expect(await waitUntil {
            host.sync()
            return host.entryNotice != nil
        })
        #expect(writer.writeCount > writesAfterFlush)
        guard case .cleanupPending = host.autosave.autosaveState else {
            Issue.record("retryLatest must still leave cleanupPending when writes keep failing")
            return
        }
        #expect(host.presentedWorkbenchSnapshot == nil)
        #expect(host.attachedWorkbenchModel == nil)
        #expect(host.entryNotice == "内容已保存，但保存清理尚未完成，请重试保存后再拆开并安排。")
        #expect(host.window.firstResponder === textView)
        let persisted = try #require(host.store.state.notes[host.noteID])
        let firstBlockText = persisted.document.blocks[0].inlineContent.spans.map(\.text).joined()
        #expect(firstBlockText == "今天下午要给诊所打电话确认预约时间")
    }

    @Test func localBodyEditInvalidatesWorkbenchUndoBeforeSaveAndStaleUndoDoesNotRollback() async throws {
        let host = try await productionNoteEditorHost(document: scheduledWorkbenchSourceDocument())
        defer { host.close() }
        let created = try await commitScheduledWorkbenchPlan(on: host)
        let staleUndo = try #require(await waitUntilValue { host.identifiedButton("notes-workbench-undo") })
        #expect(staleUndo.isEnabled)
        #expect(host.feedbackMessage != nil)
        let savedTarget = try #require(staleUndo.target)
        let savedAction = try #require(staleUndo.action)

        let chineseEdit = "，今天下午再确认一次"
        await host.repository.suspendNextSave()
        defer {
            Task { await host.repository.resumeSave() }
        }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        let originalNS = created.originalBody as NSString
        #expect(textView.string.contains(created.originalBody))
        textView.selectedRange = NSRange(location: originalNS.length, length: 0)
        textView.insertText(chineseEdit, replacementRange: .init(location: NSNotFound, length: 0))
        #expect(await waitUntil {
            textView.string.contains(created.originalBody + chineseEdit)
        })
        host.sync()
        #expect(host.identifiedButton("notes-workbench-undo") == nil)
        #expect(host.feedbackMessage == nil)

        #expect(NSApplication.shared.sendAction(savedAction, to: savedTarget, from: staleUndo))
        try? await Task.sleep(for: .milliseconds(50))
        host.sync()
        #expect(createdPlanStillPresent(created, on: host))
        #expect(textView.string.contains(created.originalBody + chineseEdit))

        await host.repository.resumeSave()
        let flushed = await host.flushLatestWithProductionFinalizer()
        guard case .persisted = flushed else {
            Issue.record("chinese edit must persist after resume: \(flushed)")
            return
        }
        let persisted = try #require(host.store.state.notes[host.noteID])
        let body = persisted.document.blocks
            .map { $0.inlineContent.spans.map(\.text).joined() }
            .joined(separator: "\n")
        #expect(body.contains(created.originalBody + chineseEdit))
        #expect(body.contains(created.actionTitle))
        #expect(createdPlanStillPresent(created, on: host))
        #expect(host.identifiedButton("notes-workbench-undo") == nil)
        #expect(host.feedbackMessage == nil)
    }

    @Test func scheduledPlanChineseEditFlushThenUnlinkThenAppendKeepsStoreAndMutationResult() async throws {
        let host = try await productionNoteEditorHost(document: scheduledWorkbenchSourceDocument())
        defer { host.close() }
        let created = try await commitScheduledWorkbenchPlan(on: host)
        #expect(created.taskBlockIDs.count == 1)
        #expect(created.calendarItemIDs.count == 1)
        #expect(created.links.count == 1)

        let chineseEdit = "，并把身份证放进包里"
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        let originalNS = created.originalBody as NSString
        #expect(textView.string.contains(created.originalBody))
        textView.selectedRange = NSRange(location: originalNS.length, length: 0)
        textView.insertText(chineseEdit, replacementRange: .init(location: NSNotFound, length: 0))
        #expect(await waitUntil {
            textView.string.contains(created.originalBody + chineseEdit)
        })
        let afterChinese = await host.flushLatestWithProductionFinalizer()
        guard case .persisted = afterChinese else {
            Issue.record("chinese edit must persist through the production finalizer: \(afterChinese)")
            return
        }
        let persistedAfterChinese = try #require(host.store.state.notes[host.noteID])
        let bodyAfterChinese = persistedAfterChinese.document.blocks
            .map { $0.inlineContent.spans.map(\.text).joined() }
            .joined(separator: "\n")
        #expect(bodyAfterChinese.contains(created.originalBody + chineseEdit))
        #expect(bodyAfterChinese.contains(created.actionTitle))
        #expect(createdPlanStillPresent(created, on: host))

        let taskRange = (textView.string as NSString).range(of: created.actionTitle)
        #expect(taskRange.location != NSNotFound)
        textView.selectedRange = NSRange(location: taskRange.location, length: 0)
        host.sync()
        let unlink = try #require(await waitUntilValue {
            host.sync()
            return host.identifiedButton("task-block-unlink-calendar")
        })
        unlink.performClick(unlink)
        #expect(await waitUntil {
            host.sync()
            return created.links.isDisjoint(with: host.store.state.taskBlockLinks)
        })
        let remainingBlockIDs = Set(host.store.state.notes[host.noteID]?.document.blocks.map(\.id) ?? [])
        #expect(created.taskBlockIDs.isSubset(of: remainingBlockIDs))
        #expect(created.calendarItemIDs.allSatisfy { host.store.calendarState.items[$0] != nil })
        #expect(created.links.isDisjoint(with: host.store.state.taskBlockLinks))

        let confirmation = "已核对"
        let textViewAfterUnlink = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textViewAfterUnlink))
        let appendPoint = (textViewAfterUnlink.string as NSString).range(of: created.originalBody + chineseEdit)
        #expect(appendPoint.location != NSNotFound)
        textViewAfterUnlink.selectedRange = NSRange(
            location: appendPoint.location + appendPoint.length,
            length: 0
        )
        textViewAfterUnlink.insertText(confirmation, replacementRange: .init(location: NSNotFound, length: 0))
        #expect(await waitUntil {
            textViewAfterUnlink.string.contains(created.originalBody + chineseEdit + confirmation)
        })
        let afterConfirmation = await host.flushLatestWithProductionFinalizer()
        guard case .persisted = afterConfirmation else {
            Issue.record("confirmation edit must persist after unlink: \(afterConfirmation)")
            return
        }
        let persistedFinal = try #require(host.store.state.notes[host.noteID])
        let finalBody = persistedFinal.document.blocks
            .map { $0.inlineContent.spans.map(\.text).joined() }
            .joined(separator: "\n")
        #expect(finalBody.contains(created.originalBody + chineseEdit + confirmation))
        #expect(finalBody.contains(created.actionTitle))
        #expect(created.taskBlockIDs.isSubset(of: Set(persistedFinal.document.blocks.map(\.id))))
        #expect(created.calendarItemIDs.allSatisfy { host.store.calendarState.items[$0] != nil })
        #expect(created.links.isDisjoint(with: host.store.state.taskBlockLinks))
    }

    @Test func ownerAwareRoutingAcceptsRebuiltSameNoteSessionAndIgnoresStaleOwner() {
        let noteID = NoteID()
        let parentIdentity = NoteEditorIdentity(noteID: noteID, editSessionID: UUID())
        let rebuiltSession = makeRoutingEditorSession(noteID: noteID, editSessionID: UUID())
        var owned: NotesOwnedBlockEditorSession?
        owned = NotesLiveEditorSessionRouting.receive(
            ownerIdentity: parentIdentity,
            currentOwnerIdentity: parentIdentity,
            current: owned,
            incoming: rebuiltSession
        )
        let matching = NotesLiveEditorSessionRouting.matchingSession(
            currentOwnerIdentity: parentIdentity,
            current: owned,
            noteID: noteID
        )
        #expect(matching === rebuiltSession)
        #expect(matching?.editSessionID != parentIdentity.editSessionID)

        let replacementIdentity = NoteEditorIdentity(noteID: noteID, editSessionID: UUID())
        owned = NotesLiveEditorSessionRouting.receive(
            ownerIdentity: parentIdentity,
            currentOwnerIdentity: replacementIdentity,
            current: owned,
            incoming: makeRoutingEditorSession(noteID: noteID, editSessionID: UUID())
        )
        #expect(owned?.session === rebuiltSession)
        owned = NotesLiveEditorSessionRouting.receive(
            ownerIdentity: parentIdentity,
            currentOwnerIdentity: replacementIdentity,
            current: owned,
            incoming: nil
        )
        #expect(owned?.session === rebuiltSession)

        let replacementSession = makeRoutingEditorSession(noteID: noteID, editSessionID: UUID())
        owned = NotesLiveEditorSessionRouting.receive(
            ownerIdentity: replacementIdentity,
            currentOwnerIdentity: replacementIdentity,
            current: owned,
            incoming: replacementSession
        )
        #expect(owned?.session === replacementSession)
        owned = NotesLiveEditorSessionRouting.receive(
            ownerIdentity: parentIdentity,
            currentOwnerIdentity: replacementIdentity,
            current: owned,
            incoming: nil
        )
        #expect(owned?.session === replacementSession)

        owned = NotesLiveEditorSessionRouting.receive(
            ownerIdentity: replacementIdentity,
            currentOwnerIdentity: replacementIdentity,
            current: owned,
            incoming: nil
        )
        #expect(owned == nil)
        #expect(
            NotesLiveEditorSessionRouting.matchingSession(
                currentOwnerIdentity: replacementIdentity,
                current: owned,
                noteID: noteID
            ) == nil
        )
    }

    @Test func workbenchRebuildKeepsParentIdentityAndExportUsesLiveDocument() async throws {
        let host = try await productionNoteEditorHost(document: scheduledWorkbenchSourceDocument())
        defer { host.close() }
        let staleSession = try #require(await waitUntilValue { host.box.session })
        let created = try await commitScheduledWorkbenchPlan(on: host)
        let rebuiltSession = try #require(await waitUntilValue { () -> BlockEditorSession? in
            guard let session = host.box.session, session !== staleSession else { return nil }
            return session
        })
        let persistedAfterRebuild = try #require(host.store.state.notes[host.noteID])
        #expect(rebuiltSession.document == persistedAfterRebuild.document)
        #expect(created.taskBlockIDs.isSubset(of: Set(rebuiltSession.document.blocks.map(\.id))))
        #expect(rebuiltSession.noteID == host.parentIdentity.noteID)
        #expect(rebuiltSession.editSessionID != host.parentIdentity.editSessionID)
        #expect(rebuiltSession !== staleSession)
        #expect(host.autosave.latestEvidence == .clean)
        #expect(host.autosave.canReplaceSessionWithPersistedStoreSnapshot)

        _ = try staleSession.dispatch(.insertText("迟到旧回调"))
        #expect(staleSession.document.blocks.contains { block in
            block.inlineContent.spans.map(\.text).joined().contains("迟到旧回调")
        })
        #expect(host.autosave.latestEvidence == .clean)
        #expect(host.autosave.canReplaceSessionWithPersistedStoreSnapshot)
        #expect(createdPlanStillPresent(created, on: host))
        let persistedAfterStaleCallback = try #require(host.store.state.notes[host.noteID])
        #expect(
            persistedAfterStaleCallback.document.blocks.contains { block in
                created.taskBlockIDs.contains(block.id)
            }
        )
        #expect(
            persistedAfterStaleCallback.document.blocks.contains { block in
                block.inlineContent.spans.map(\.text).joined().contains("迟到旧回调")
            } == false
        )

        let chineseEdit = "，导出前再改一句"
        await host.repository.suspendNextSave()
        defer {
            Task { await host.repository.resumeSave() }
        }
        let textView = try #require(await waitUntilValue { host.nativeTextView })
        #expect(host.window.makeFirstResponder(textView))
        let originalNS = created.originalBody as NSString
        textView.selectedRange = NSRange(location: originalNS.length, length: 0)
        textView.insertText(chineseEdit, replacementRange: .init(location: NSNotFound, length: 0))
        #expect(await waitUntil {
            textView.string.contains(created.originalBody + chineseEdit)
        })
        await host.repository.waitForSaveToStart()
        host.sync()
        let liveSession = try #require(host.box.session)
        #expect(liveSession.document.blocks.contains { block in
            block.inlineContent.spans.map(\.text).joined().contains(created.originalBody + chineseEdit)
        })

        var owned: NotesOwnedBlockEditorSession?
        owned = NotesLiveEditorSessionRouting.receive(
            ownerIdentity: host.parentIdentity,
            currentOwnerIdentity: host.parentIdentity,
            current: owned,
            incoming: liveSession
        )
        let matching = try #require(
            NotesLiveEditorSessionRouting.matchingSession(
                currentOwnerIdentity: host.parentIdentity,
                current: owned,
                noteID: host.noteID
            )
        )
        #expect(matching === liveSession)
        #expect(matching.document.blocks.contains { block in
            block.inlineContent.spans.map(\.text).joined().contains(chineseEdit)
        })

        let persisted = try #require(host.store.state.notes[host.noteID])
        #expect(
            persisted.document.blocks.contains { block in
                block.inlineContent.spans.map(\.text).joined().contains(chineseEdit)
            } == false
        )
        let exported = NoteMarkdownExportSource.document(
            persistedNoteID: persisted.id,
            persistedDocument: persisted.document,
            editorIdentity: host.parentIdentity,
            liveSnapshot: .init(
                noteID: matching.noteID,
                editSessionID: matching.editSessionID,
                document: matching.document
            )
        )
        #expect(exported == matching.document)
        #expect(
            exported.blocks.contains {
                $0.inlineContent.spans.map(\.text).joined().contains(created.originalBody + chineseEdit)
            }
        )

        await host.repository.resumeSave()
        let flushed = await host.flushLatestWithProductionFinalizer()
        guard case .persisted = flushed else {
            Issue.record("chinese edit must persist after resume: \(flushed)")
            return
        }
        let persistedAfterFlush = try #require(host.store.state.notes[host.noteID])
        #expect(
            persistedAfterFlush.document.blocks.contains { block in
                block.inlineContent.spans.map(\.text).joined().contains(created.originalBody + chineseEdit)
            }
        )
    }
}

@MainActor
private final class VerticalImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

private enum NotesVerticalFixtures {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    static let calendarState = CalendarState.empty(uncategorizedID: categoryID, now: Date(timeIntervalSince1970: 0))

    static func v2CalendarDocument() throws -> Data {
        try JSONEncoder.workspaceDeterministic.encode(CalendarDocument(state: calendarState))
    }
}

private final class NotesVerticalTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-notes-vertical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
private final class WorkbenchPresentationBox: ObservableObject {
    var snapshot: DecompositionSourceSnapshot?
    var notice: String?
    var session: BlockEditorSession?
    var workbenchModel: DecompositionWorkbenchModel?
    var feedback: String?
    var feedbackGeneration: UInt?
    var finalizer: NoteNativeInputFinalizer?
    var commitHandler: DecompositionWorkbenchCommitHandler?
    @Published var workbenchNotice: NoteWorkbenchNotice?
}

@MainActor
private func makeRoutingEditorSession(noteID: NoteID, editSessionID: UUID) -> BlockEditorSession {
    let document = BlockDocument(blocks: [
        .init(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("路由会话"),
            taskState: nil,
            indentLevel: 0
        )
    ])
    return BlockEditorSession(
        noteID: noteID,
        editSessionID: editSessionID,
        initialDocument: document,
        initialSelection: .text(
            anchor: BlockTextPosition(blockID: document.blocks[0].id, graphemeOffset: 0),
            focus: BlockTextPosition(blockID: document.blocks[0].id, graphemeOffset: 0),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        ),
        focusRegistry: EditorFocusRegistry(),
        onDocumentChange: { _ in }
    )
}

@MainActor
private final class ProductionNoteEditorHost {
    let store: WorkspaceStore
    let autosave: NoteAutosaveCoordinator
    let repository: InMemoryWorkspaceRepository
    let noteID: NoteID
    private(set) var parentIdentity: NoteEditorIdentity
    let window: NSWindow
    let box: WorkbenchPresentationBox
    private var hosting: NSHostingView<ProductionNoteEditorRoot>

    var presentedWorkbenchSnapshot: DecompositionSourceSnapshot? { box.snapshot }
    var entryNotice: String? { box.notice }
    var attachedWorkbenchModel: DecompositionWorkbenchModel? { box.workbenchModel }
    var feedbackMessage: String? { box.feedback }
    var nativeTextView: ContinuousBlockEditorTextView? {
        verticalDescendants(of: hosting, as: ContinuousBlockEditorTextView.self).first
    }

    func identifiedButton(_ identifier: String) -> NSButton? {
        sync()
        return verticalDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    func identifiedAccessibilityNode(_ identifier: String) -> NSView? {
        sync()
        if let field = verticalDescendants(of: hosting, as: NSTextField.self).first(where: {
            $0.accessibilityIdentifier() == identifier
        }) {
            return field
        }
        return verticalDescendants(of: hosting, as: NSView.self).first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    func flushLatestWithProductionFinalizer() async -> NoteAutosaveBarrierEvidence {
        await autosave.flushLatest(finalizer: box.finalizer)
    }

    init(
        store: WorkspaceStore,
        autosave: NoteAutosaveCoordinator,
        repository: InMemoryWorkspaceRepository,
        note: Note,
        parentIdentity: NoteEditorIdentity
    ) {
        self.store = store
        self.autosave = autosave
        self.repository = repository
        noteID = note.id
        self.parentIdentity = parentIdentity
        let box = WorkbenchPresentationBox()
        self.box = box
        let hosting = NSHostingView(
            rootView: ProductionNoteEditorRoot(
                identity: parentIdentity,
                note: note,
                autosave: autosave,
                store: store,
                box: box
            )
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 620)
        self.hosting = hosting
        self.window = SharedVerticalHostWindow.install(hosting)
    }

    func remountReplacement(identity: NoteEditorIdentity, note: Note) {
        parentIdentity = identity
        let hosting = NSHostingView(
            rootView: ProductionNoteEditorRoot(
                identity: identity,
                note: note,
                autosave: autosave,
                store: store,
                box: box
            )
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 620)
        self.hosting = hosting
        _ = SharedVerticalHostWindow.install(hosting)
        sync()
    }

    func completeWorkbenchCommit(_ result: DecompositionCommitResult) throws {
        let handler = try #require(box.commitHandler)
        handler(result)
    }

    func sync() {
        hosting.layoutSubtreeIfNeeded()
    }

    func tapAccessibilityButton(_ label: String) async {
        let button = await waitUntilValue {
            sync()
            return verticalDescendants(of: hosting, as: NSButton.self).first {
                $0.title == label
                    || $0.accessibilityLabel() == label
                    || $0.accessibilityIdentifier() == "notes-plan-and-schedule"
            }
        }
        button?.performClick(button)
        for _ in 0..<40 {
            sync()
            if box.snapshot != nil || box.notice != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() {
        SharedVerticalHostWindow.endSheets(on: window)
    }
}

@MainActor
private func productionNoteEditorHost(
    document: BlockDocument,
    journalURL: URL? = nil,
    journalWriter: (any AtomicFileWriting)? = nil
) async throws -> ProductionNoteEditorHost {
    let calendar = makeEmptyState()
    let repository = InMemoryWorkspaceRepository(initialState: calendar)
    let journal = journalURL.map { url in
        if let journalWriter {
            DraftJournalRepository(fileURL: url, writer: journalWriter)
        } else {
            DraftJournalRepository(fileURL: url)
        }
    }
    let store = WorkspaceStore(
        initialState: .empty(calendar: calendar),
        repository: repository,
        journal: journal
    )
    await store.load()
    var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
    note.document = document
    _ = try await store.sendWorkspace(.createNote(.init(note: note)))
    let persisted = try #require(store.state.notes[note.id])
    let autosave = NoteAutosaveCoordinator(store: store, scheduler: VerticalImmediateScheduler())
    let parentIdentity = NoteEditorIdentity(noteID: persisted.id, editSessionID: UUID())
    try autosave.beginSession(
        persisted,
        linkedTaskBlockLinks: [],
        editSessionID: parentIdentity.editSessionID,
        activeHostToken: UUID()
    )
    let host = ProductionNoteEditorHost(
        store: store,
        autosave: autosave,
        repository: repository,
        note: persisted,
        parentIdentity: parentIdentity
    )
    host.sync()
    return host
}

@MainActor
private struct ProductionNoteEditorRoot: View {
    let identity: NoteEditorIdentity
    let note: Note
    let autosave: NoteAutosaveCoordinator
    let store: WorkspaceStore
    @ObservedObject var box: WorkbenchPresentationBox
    let focusRegistry: EditorFocusRegistry = EditorFocusRegistry()

    var body: some View {
        NoteEditorView(
            identity: identity,
            note: note,
            focusRegistry: focusRegistry,
            autosave: autosave,
            store: store,
            categories: Array(store.calendarState.categories.values),
            onDocumentCommitted: { _ in },
            onTitleCommitted: { _ in },
            onCategoryChanged: { _ in },
            onRequestMarkdownImport: {},
            onRequestMarkdownExport: {},
            sessionSink: { box.session = $0 },
            nativeFinalizerHook: Binding(
                get: { box.finalizer },
                set: { box.finalizer = $0 }
            ),
            onWorkbenchSnapshotChange: { box.snapshot = $0 },
            onWorkbenchEntryNoticeChange: { box.notice = $0 },
            onWorkbenchModelChange: { box.workbenchModel = $0 },
            onWorkbenchFeedbackChange: { message, generation in
                box.feedback = message
                box.feedbackGeneration = generation
            },
            onWorkbenchCommitHandlerChange: { box.commitHandler = $0 },
            workbenchNotice: $box.workbenchNotice
        )
    }
}

private func scheduledWorkbenchSourceDocument() -> BlockDocument {
    BlockDocument(blocks: [
        .init(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("预约牙医"),
            taskState: nil,
            indentLevel: 0
        )
    ])
}

private struct CreatedWorkbenchPlan: Equatable {
    let originalBody: String
    let actionTitle: String
    let taskBlockIDs: Set<BlockID>
    let calendarItemIDs: Set<UUID>
    let links: Set<TaskBlockCalendarLink>
}

private struct ExecutedWorkbenchCommit {
    let result: DecompositionCommitResult
    let created: CreatedWorkbenchPlan
}

private final class PersistentCleanupFailingJournalWriter: AtomicFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedWriteCount = 0
    private var failOnWrite: Int?
    private var failAllSubsequent = false

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedWriteCount
    }

    init(failOnWrite: Int? = nil) {
        self.failOnWrite = failOnWrite
    }

    func failAllSubsequentWrites() {
        lock.lock()
        defer { lock.unlock() }
        failAllSubsequent = true
        failOnWrite = nil
    }

    func replaceAtomically(data: Data, at destination: URL) throws {
        lock.lock()
        recordedWriteCount += 1
        let current = recordedWriteCount
        let shouldFail = failAllSubsequent || (failOnWrite == current)
        lock.unlock()
        if shouldFail {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

@MainActor
private final class PausingNativeInputFinalizerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func finalize(
        _ permit: NoteNativeInputPermit,
        _ apply: @escaping @MainActor (NoteNativeInputPermit, NoteNativeInputEdit) -> Bool
    ) async -> Bool {
        if !released {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
        return true
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func executeScheduledWorkbenchCommit(
    on host: ProductionNoteEditorHost,
    title: String = "打电话确认",
    completion: String = "拿到明确上门时间"
) async throws -> ExecutedWorkbenchCommit {
    let originalBody = "预约牙医"
    let blocksBefore = Set(host.store.state.notes[host.noteID]?.document.blocks.map(\.id) ?? [])
    let itemsBefore = Set(host.store.calendarState.items.keys)
    let linksBefore = host.store.state.taskBlockLinks
    #expect(await waitUntilValue { host.nativeTextView } != nil)
    await host.tapAccessibilityButton("拆开并安排")
    #expect(await waitUntil {
        host.sync()
        return host.presentedWorkbenchSnapshot != nil
    })
    let model = try #require(host.attachedWorkbenchModel)
    model.addManualCandidate()
    let candidateID = try #require(model.draft.candidates.first?.id)
    model.updateTitle(id: candidateID, value: title)
    model.updateCompletion(id: candidateID, value: completion)
    let filled = try #require(model.draft.candidates.first(where: { $0.id == candidateID }))
    #expect(filled.title == title && filled.titleLockedByUser)
    #expect(filled.completionDescription == completion && filled.completionLockedByUser)
    model.setSelectedForCalendar(id: candidateID, selected: true)
    model.advanceToSchedule()
    let scheduled = try #require(model.draft.candidates.first(where: { $0.id == candidateID }))
    #expect(scheduled.selectedForCalendar && scheduled.proposal != nil)
    let result = await model.commit()
    guard case .committed = result else {
        Issue.record("workbench commit did not persist to Store")
        struct WorkbenchStoreCommitFailed: Error {}
        throw WorkbenchStoreCommitFailed()
    }
    let note = try #require(host.store.state.notes[host.noteID])
    let created = CreatedWorkbenchPlan(
        originalBody: originalBody,
        actionTitle: title,
        taskBlockIDs: Set(note.document.blocks.compactMap { block in
            guard block.kind == .task, !blocksBefore.contains(block.id) else { return nil }
            return block.id
        }),
        calendarItemIDs: Set(host.store.calendarState.items.keys).subtracting(itemsBefore),
        links: host.store.state.taskBlockLinks.subtracting(linksBefore)
    )
    #expect(!created.taskBlockIDs.isEmpty)
    #expect(!created.calendarItemIDs.isEmpty)
    #expect(!created.links.isEmpty)
    return ExecutedWorkbenchCommit(result: result, created: created)
}

@MainActor
private func commitScheduledWorkbenchPlan(
    on host: ProductionNoteEditorHost,
    title: String = "打电话确认",
    completion: String = "拿到明确上门时间"
) async throws -> CreatedWorkbenchPlan {
    let executed = try await executeScheduledWorkbenchCommit(on: host, title: title, completion: completion)
    try host.completeWorkbenchCommit(executed.result)
    let committed = await waitUntil {
        host.sync()
        let noteContainsAction = host.store.state.notes[host.noteID]?.document.blocks.contains {
            $0.inlineContent.spans.map(\.text).joined().contains(title)
        } == true
        return host.presentedWorkbenchSnapshot == nil
            && host.feedbackMessage == "已创建 1 个行动，并安排其中 1 个"
            && noteContainsAction
            && host.nativeTextView?.string.contains(title) == true
            && createdPlanStillPresent(executed.created, on: host)
    }
    #expect(committed)
    let undo = try #require(await waitUntilValue { host.identifiedButton("notes-workbench-undo") })
    #expect(undo.isEnabled)
    return executed.created
}

@MainActor
private func createdPlanRemoved(_ created: CreatedWorkbenchPlan, on host: ProductionNoteEditorHost) -> Bool {
    let remainingBlockIDs = Set(host.store.state.notes[host.noteID]?.document.blocks.map(\.id) ?? [])
    return created.taskBlockIDs.isDisjoint(with: remainingBlockIDs)
        && created.calendarItemIDs.allSatisfy { host.store.calendarState.items[$0] == nil }
        && created.links.isDisjoint(with: host.store.state.taskBlockLinks)
}

@MainActor
private func createdPlanStillPresent(_ created: CreatedWorkbenchPlan, on host: ProductionNoteEditorHost) -> Bool {
    let remainingBlockIDs = Set(host.store.state.notes[host.noteID]?.document.blocks.map(\.id) ?? [])
    return created.taskBlockIDs.isSubset(of: remainingBlockIDs)
        && created.calendarItemIDs.allSatisfy { host.store.calendarState.items[$0] != nil }
        && created.links.isSubset(of: host.store.state.taskBlockLinks)
}

@MainActor
private func originalSourceRemains(_ created: CreatedWorkbenchPlan, on host: ProductionNoteEditorHost) -> Bool {
    let body = host.store.state.notes[host.noteID]?.document.blocks
        .map { $0.inlineContent.spans.map(\.text).joined() }
        .joined(separator: "\n") ?? ""
    return body.contains(created.originalBody)
        && host.nativeTextView != nil
        && host.nativeTextView?.string.contains(created.originalBody) == true
        && host.nativeTextView?.string.contains(created.actionTitle) != true
}

@MainActor
private func verticalDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { verticalDescendants(of: $0, as: type) }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1.5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func waitUntilValue<T>(
    timeout: Duration = .seconds(1.5),
    _ read: @MainActor () -> T?
) async -> T? {
    _ = await waitUntil(timeout: timeout) { read() != nil }
    return read()
}

/// Suite-owned host window. Never order it front: the first `orderFront` /
/// `makeKeyAndOrderFront` in this helper makes `__swiftPMEntryPoint` return
/// before remaining tests run.
@MainActor
private enum SharedVerticalHostWindow {
    private static var window: NSWindow?

    static func install(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = existing()
        endSheets(on: window)
        content.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }

    static func endSheets(on window: NSWindow) {
        for sheet in window.sheets {
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
    }

    private static func existing() -> NSWindow {
        if let window {
            return window
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        self.window = window
        return window
    }
}
