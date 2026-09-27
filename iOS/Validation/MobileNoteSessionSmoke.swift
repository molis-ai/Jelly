import Foundation
import CalendarDomain
import CalendarPersistence
import WorkspaceDomain

// Every repository operation and receipt comes from the production JSON actor.
// The gate controls only when its first protected draft save is allowed to run.
private actor MobileNoteSmokeGatedRepository: WorkspaceRepository {
    let backing: JSONWorkspaceRepository
    private var armed = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(_ backing: JSONWorkspaceRepository) { self.backing = backing }
    func arm() { armed = true; entered = false }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func load() async throws -> WorkspaceLoadResult { try await backing.load() }
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt {
        if armed, draft != nil {
            armed = false; entered = true
            let waiters = entryWaiters; entryWaiters.removeAll(); waiters.forEach { $0.resume() }
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return try await backing.save(state, draft: draft)
    }
    func verifyPersistedDraft(_ context: PersistableDraftContext) async throws -> WorkspaceDraftPersistenceVerification { try await backing.verifyPersistedDraft(context) }
    func prepareRestore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) async throws -> PreparedWorkspaceRestore { try await backing.prepareRestore(preview, rollbackDirectoryURL: rollbackDirectoryURL) }
    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) async -> Bool { await backing.discardPreparedRestore(prepared) }
    func commitRestore(_ prepared: PreparedWorkspaceRestore, state: WorkspaceState) async throws -> WorkspaceRestoreOutcome { try await backing.commitRestore(prepared, state: state) }
    func currentDocumentData() async throws -> Data { try await backing.currentDocumentData() }
    func reloadCurrentSourceAfterExternalChange() async throws -> WorkspaceReloadedSource { try await backing.reloadCurrentSourceAfterExternalChange() }
    func currentRawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact { try await backing.currentRawRecoveryData() }
    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation { try await backing.reconcilePendingCommit() }
}

/// `sendWorkspace` reaches the MainActor FIFO enqueue without performing I/O.
/// The started signal and that enqueue run in the same actor turn, so the test
/// resumes the gated save only after the external command has entered the FIFO.
@MainActor
private final class MobileNoteSmokeCommandAdmission {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func markStarted() { started = true; waiter?.resume(); waiter = nil }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

enum MobileNoteSessionSmoke {
    struct Failure: Error { let message: String }
    static let instant = Date(timeIntervalSince1970: 1_790_000_000)
    @MainActor static func require(_ okay: Bool, _ message: String) throws {
        if !okay { throw Failure(message: message) }
    }
    @MainActor private static func environment(_ name: String) async throws -> (URL, WorkspaceStore, MobileNoteSmokeGatedRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-Session-Review-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seed = WorkspaceState.empty(calendar: .empty(uncategorizedID: UUID(), now: instant))
        let backing = JSONWorkspaceRepository(documentURL: root.appendingPathComponent("workspace.json"), seed: { seed })
        let repository = MobileNoteSmokeGatedRepository(backing)
        let store = WorkspaceStore(initialState: seed, repository: repository, journal: DraftJournalRepository(fileURL: root.appendingPathComponent("drafts.json")))
        await store.load()
        try require(store.phase == .ready, "real store must load")
        return (root, store, repository)
    }
    @MainActor static func makeNote(_ store: WorkspaceStore, linked: Bool = false) async throws -> (Note, BlockID, UUID?) {
        let block = BlockID()
        var note = Note.empty(categoryID: store.calendarState.uncategorizedID, now: instant)
        note.title = "concurrency"
        note.document = BlockDocument(blocks: [try DocumentBlock.task(id: block, text: "original", completionDescription: "done")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        var itemID: UUID?
        if linked {
            let day = CalendarDate(year: 2026, month: 9, day: 27)!
            let item = try CalendarItem(id: UUID(), kind: .task, title: "original", categoryID: note.categoryID,
                schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
                completedAt: nil, createdAt: instant, updatedAt: instant)
            _ = try await store.sendWorkspace(.scheduleTaskBlock(.init(noteID: note.id, blockID: block, item: item)))
            itemID = item.id
        }
        return (store.state.notes[note.id]!, block, itemID)
    }
    static func text(_ note: Note, _ id: BlockID) -> String {
        note.document.blocks.first { $0.id == id }!.inlineContent.spans.map(\.text).joined()
    }
    @MainActor static func inputDuringSave(finalText: String) async throws {
        let (root, store, repository) = try await environment(finalText == "original" ? "revert" : "successor")
        defer { try? FileManager.default.removeItem(at: root) }
        let (note, block, _) = try await makeNote(store)
        let session = MobileNoteSession(note: note, store: store)
        await repository.arm()
        session.updateBlock(block) { $0.inlineContent = .plain("first generation") }
        await repository.waitUntilEntered()
        try require(session.saving, "draft save must be suspended")
        session.updateBlock(block) { $0.inlineContent = .plain(finalText) }
        let firstFlush = Task { @MainActor in await session.flush() }
        let secondFlush = Task { @MainActor in await session.flush() }
        await repository.release()
        let firstResult = await firstFlush.value, secondResult = await secondFlush.value
        try require(firstResult && secondResult && !session.dirty, "both concurrent flush calls must complete latest generation")
        let disk = try WorkspaceDocumentCodec.decode(Data(contentsOf: root.appendingPathComponent("workspace.json"))).state
        try require(text(session.draft, block) == finalText && text(store.state.notes[note.id]!, block) == finalText && text(disk.notes[note.id]!, block) == finalText, "latest generation must agree in local draft, store, and real JSON")
        let reload = JSONWorkspaceRepository(documentURL: root.appendingPathComponent("workspace.json"), seed: { .empty(calendar: .empty(uncategorizedID: UUID(), now: instant)) })
        let loaded = try await reload.load()
        try require(text(loaded.state.notes[note.id]!, block) == finalText, "restart must preserve latest generation")
        print("PASS: suspended save -> \(finalText) -> concurrent flush -> JSON and reload")
    }
    enum RecoveryChoice: String, CaseIterable { case saveAsNew, keepPersisted, restoreAsCurrent }
    @MainActor static func linkedExternalCompletion(recovery choice: RecoveryChoice) async throws {
        let (root, store, repository) = try await environment("external-completion-\(choice.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (note, block, itemID) = try await makeNote(store, linked: true)
        let item = itemID!
        let session = MobileNoteSession(note: note, store: store)
        await repository.arm()
        session.updateBlock(block) { $0.inlineContent = .plain("accepted title") }
        await repository.waitUntilEntered()
        session.updateBlock(block) { $0.inlineContent = .plain("new local title") }
        let externalAdmission = MobileNoteSmokeCommandAdmission()
        let completion = Task { @MainActor in
            externalAdmission.markStarted()
            return try await store.sendWorkspace(.setTaskCompletion(.calendarItem(item), value: .complete(ifTransitioningAt: instant)))
        }
        await externalAdmission.waitUntilStarted()
        await repository.release()
        _ = try await completion.value
        let flushed = await session.flush()
        try require(!flushed && session.dirty && session.error != nil, "external completion must conflict with newer stale document, retaining local input")
        let disk = try WorkspaceDocumentCodec.decode(Data(contentsOf: root.appendingPathComponent("workspace.json"))).state
        try require(text(session.draft, block) == "new local title", "conflicting local title must remain editable")
        try require(text(disk.notes[note.id]!, block) == "accepted title" && disk.calendar.items[item]?.title == "accepted title", "only acknowledged first title must remain on disk")
        try require(disk.calendar.items[item]?.completedAt == instant && disk.notes[note.id]?.document.blocks.first?.taskState?.completedAt == instant, "external completion must survive on both linked sides")
        print("PASS: in-flight linked title + newer local title + queued external completion => conflict, local input retained, JSON completion preserved")

        let prepared = await session.prepareRecoveryReview()
        try require(prepared, "latest local input must receive its exact real recovery candidate: \(session.error ?? "none")")
        guard let candidate = session.recoveryCandidate else { throw Failure(message: "prepared recovery has no candidate") }
        try require(candidate.draft.id == note.id && text(candidate.draft, block) == "new local title", "review must protect latest input, not the earlier acknowledged title")
        try require(candidate.token.noteSnapshotChecksum == WorkspaceChecksum.noteSnapshotChecksum(session.draft), "review token must match the exact local snapshot")
        let recoveredID = choice == .saveAsNew ? NoteID() : note.id
        let recoveredBlockIDs = choice == .saveAsNew ? candidate.draft.document.blocks.map { _ in BlockID() } : candidate.draft.document.blocks.map(\.id)
        let action: DraftRecoveryAction = switch choice {
        case .saveAsNew: .saveAsNew(noteID: recoveredID, blockIDs: recoveredBlockIDs)
        case .keepPersisted: .keepPersisted
        case .restoreAsCurrent: .restoreAsCurrent
        }
        let resolved = await session.resolveRecovery(action)
        try require(resolved, "\(choice.rawValue) must resolve its reviewed candidate: \(session.error ?? "none"), phase: \(store.phase)")
        let cleanFlush = await session.flush()
        try require(!session.dirty && session.canHandOffCurrentDraft && cleanFlush, "reviewed choice must release the editor barrier")
        try require(session.draft.id == recoveredID, "session must adopt the selected note identity")
        let recoveredDisk = try WorkspaceDocumentCodec.decode(Data(contentsOf: root.appendingPathComponent("workspace.json"))).state
        let expectedRecoveredText = choice == .keepPersisted ? "accepted title" : "new local title"
        try require(text(recoveredDisk.notes[recoveredID]!, recoveredBlockIDs[0]) == expectedRecoveredText, "selected recovery content must be durable")
        let expectedCalendarTitle = choice == .restoreAsCurrent ? "new local title" : "accepted title"
        try require(recoveredDisk.calendar.items[item]?.title == expectedCalendarTitle, "recovery must synchronize the restored linked title without changing the original item when saving a copy")
        try require(recoveredDisk.calendar.items[item]?.completedAt == instant && recoveredDisk.notes[note.id]?.document.blocks.first?.taskState?.completedAt == instant, "recovery must preserve existing linked completion")
        if choice == .saveAsNew {
            try require(recoveredDisk.notes.count == 2 && text(recoveredDisk.notes[note.id]!, block) == "accepted title", "save as new must preserve both local and acknowledged versions")
            try require(!recoveredDisk.taskBlockLinks.contains { $0.noteID == recoveredID }, "new note must not inherit the original calendar link")
        }
        let journal = DraftJournalRepository(fileURL: root.appendingPathComponent("drafts.json"))
        let remaining = try await journal.current()?.records ?? []
        try require(remaining.isEmpty, "resolved candidate must leave no stale Journal protection")
        let reload = JSONWorkspaceRepository(documentURL: root.appendingPathComponent("workspace.json"), seed: { .empty(calendar: .empty(uncategorizedID: UUID(), now: instant)) })
        let restarted = try await reload.load()
        try require(restarted.state == recoveredDisk, "restart must preserve selected recovery and original calendar state")
        session.updateBlock(recoveredBlockIDs[0]) { $0.inlineContent = .plain("edited after review") }
        let savedAgain = await session.flush()
        try require(savedAgain && !session.dirty, "recovered session must accept a new generation with its new baseline")
        let continued = try WorkspaceDocumentCodec.decode(Data(contentsOf: root.appendingPathComponent("workspace.json"))).state
        try require(text(continued.notes[recoveredID]!, recoveredBlockIDs[0]) == "edited after review", "post-recovery editing must persist")
        try require(continued.calendar.items[item]?.title == (choice == .saveAsNew ? "accepted title" : "edited after review"), "later linked edits must synchronize the original calendar title; copy edits must remain independent")
        try require(continued.calendar.items[item]?.completedAt == instant, "post-recovery editing must retain prior completion")
        print("PASS: \(choice.rawValue) => exact review, clean editor barrier, real JSON restart and later editing")
    }
    @MainActor static func verifyTextMap() throws {
        func block(_ kind: BlockKind, _ text: String) -> DocumentBlock {
            DocumentBlock(id: BlockID(), kind: kind, inlineContent: .plain(text), taskState: nil, indentLevel: 0)
        }
        let paragraph = block(.paragraph, "A👨‍👩‍👧‍👦e\u{301}中")
        let blank = block(.paragraph, "")
        let task = try DocumentBlock.task(id: BlockID(), text: "尾巴", completionDescription: "done")
        let divider = block(.divider, ""), final = block(.paragraph, "Z")
        let document = BlockDocument(blocks: [paragraph, blank, task, divider, final])
        try BlockDocumentValidator.validate(document)
        let map = MobileDocumentTextMap(document), attributes = BlockTypingAttributes(marks: [], linkURL: nil)
        try require(map.entries[0].range == NSRange(location: 0, length: 15), "Unicode graphemes must retain their UTF16 lengths")
        try require(map.position(at: 2) == .init(blockID: paragraph.id, graphemeOffset: 1), "interior emoji offsets must snap to its start")
        try require(map.position(at: 13) == .init(blockID: paragraph.id, graphemeOffset: 2), "combining character must stay intact")
        try require(map.offset(of: .init(blockID: paragraph.id, graphemeOffset: 3)) == 14, "grapheme position must map back to UTF16")
        for entry in map.entries where entry.block.kind != .divider {
            for offset in 0...entry.text.count {
                let position = BlockTextPosition(blockID: entry.block.id, graphemeOffset: offset)
                guard let nativeOffset = map.offset(of: position) else { throw Failure(message: "valid text position did not map") }
                try require(map.position(at: nativeOffset) == position, "text position must roundtrip, including blank paragraphs")
            }
        }
        guard let newline = map.selection(in: NSRange(location: 15, length: 1), attributes: attributes) else {
            throw Failure(message: "newline selection did not map")
        }
        try require(map.range(of: newline) == NSRange(location: 15, length: 1), "newline must remain a structural boundary")
        let joined = try BlockInputReducer.reduce(document, selection: newline, command: .deleteSelection,
            environment: .init(isComposingText: false, idSource: .random))
        try require(joined.document.blocks.count == 4 && !joined.document.blocks.contains { $0.id == blank.id }, "deleting a newline must join the adjacent paragraphs")
        guard let crossBlock = map.selection(in: NSRange(location: 1, length: 17), attributes: attributes) else {
            throw Failure(message: "cross-block selection did not map")
        }
        let removed = try BlockInputReducer.reduce(document, selection: crossBlock, command: .deleteSelection,
            environment: .init(isComposingText: false, idSource: .random))
        try require(removed.document.blocks.first?.inlineContent.spans.map(\.text).joined() == "A巴", "cross-block deletion must retain the unselected text")
        let replacementText = map.text.replacingOccurrences(of: "👨‍👩‍👧‍👦", with: "🧑🏽‍💻")
        guard let replacement = map.replacement(to: replacementText) else { throw Failure(message: "replacement not detected") }
        try require(replacement.range == NSRange(location: 1, length: 11) && replacement.text == "🧑🏽‍💻", "replacement must use whole graphemes and exact UTF16 range")
        guard let dividerRange = map.entries.first(where: { $0.block.id == divider.id })?.range,
              let dividerSelection = map.selection(in: dividerRange, attributes: attributes) else {
            throw Failure(message: "divider selection did not map")
        }
        try require(map.range(of: dividerSelection) == dividerRange, "divider attachment selection must roundtrip")
        let withoutDivider = try BlockInputReducer.reduce(document, selection: dividerSelection, command: .deleteSelection,
            environment: .init(isComposingText: false, idSource: .random))
        try require(withoutDivider.document.blocks.map(\.id) == [paragraph.id, blank.id, task.id, final.id], "deleting the attachment must remove exactly the divider block")
        print("PASS: Unicode UTF16/grapheme mapping, blank paragraph, cross-block deletion, newline join and divider deletion")
    }
    @MainActor static func run() async throws {
        try verifyTextMap()
        try await inputDuringSave(finalText: "second generation 👨‍👩‍👧‍👦")
        try await inputDuringSave(finalText: "original")
        for choice in RecoveryChoice.allCases { try await linkedExternalCompletion(recovery: choice) }
    }
}
