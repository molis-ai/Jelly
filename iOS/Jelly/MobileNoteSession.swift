import Foundation
import Observation
import WorkspaceDomain

/// The editor retains structured blocks and submits the same journal-protected
/// draft contract as the desktop. A single worker serializes local generations.
@MainActor @Observable
final class MobileNoteSession {
    private(set) var draft: Note
    private(set) var dirty = false
    private(set) var saving = false
    private(set) var status = "已保存"
    private(set) var error: String?
    private(set) var pendingStructuralEdit: MobilePendingBlockEdit?
    private var base: Note
    private var baseLinks: Set<TaskBlockCalendarLink>
    private var editSessionID = UUID()
    private(set) var recoveryCandidate: DraftRecoveryCandidate?
    private(set) var reviewingRecovery = false
    private var reviewedRecoveryResult: (noteID: NoteID, checksum: String, token: DraftRecoveryToken)?
    private var generation: UInt64 = 0
    private var barrierEvidence: NoteAutosaveBarrierEvidence = .clean
    private var deletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition] = [:]
    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored var commitNativeInput: @MainActor () async -> Bool = { true }
    var isComposingText = false
    var selection: BlockEditorSelection?
    private(set) var selectionRequest: MobileDocumentSelectionRequest?
    private(set) var clipboardRequest: MobileClipboardRequest?
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(note: Note, store: WorkspaceStore) {
        draft = note
        base = note
        self.store = store
        baseLinks = Set(store.state.taskBlockLinks.filter { $0.noteID == note.id })
    }

    func mutate(_ change: (inout Note) -> Void) {
        guard draft.archivedAt == nil, !reviewingRecovery else { return }
        change(&draft)
        generation &+= 1
        dirty = true
        barrierEvidence = .unsafeLatestUnprotected
        error = nil
        status = "正在保护草稿…"
        startWorker()
    }

    func updateBlock(_ id: BlockID, _ change: (inout DocumentBlock) -> Void) {
        guard let index = draft.document.blocks.firstIndex(where: { $0.id == id }) else { return }
        mutate { change(&$0.document.blocks[index]) }
    }

    @discardableResult
    func dispatch(selection: BlockEditorSelection, command: BlockInputCommand) -> BlockInputResult? {
        guard !isComposingText, !reviewingRecovery else { return nil }
        do {
            let result = try BlockInputReducer.reduce(draft.document, selection: selection, command: command,
                environment: .init(isComposingText: false, idSource: .random))
            let removed = baseLinks.filter { link in
                !result.document.blocks.contains { $0.id == link.blockID && $0.kind == .task }
            }.map(\.blockID)
            if !removed.isEmpty {
                pendingStructuralEdit = .init(result: result, removedLinkedBlockIDs: removed, generation: generation)
                return nil
            }
            applyStructuralResult(result)
            return result
        } catch {
            self.error = "内容块操作没有完成，原文保留。\(error.localizedDescription)"
            return nil
        }
    }

    func resolveStructuralEdit(_ disposition: LinkedTaskBlockDeletionDisposition?) {
        guard let pending = pendingStructuralEdit else { return }
        pendingStructuralEdit = nil
        guard let disposition else { return }
        guard pending.generation == generation else {
            error = "正文已变化，请重新操作。"
            return
        }
        for id in pending.removedLinkedBlockIDs { deletionDispositions[id] = disposition }
        applyStructuralResult(pending.result)
    }

    private func applyStructuralResult(_ result: BlockInputResult) {
        if result.document != draft.document { mutate { $0.document = result.document } }
        selection = result.selection
        selectionRequest = .init(selection: result.selection)
        if case let .writeClipboard(payload) = result.effect { clipboardRequest = .init(payload: payload) }

    }

    func deleteBlock(_ id: BlockID, disposition: LinkedTaskBlockDeletionDisposition?) {
        let selection = BlockEditorSelection.blocks(anchor: id, focus: id)
        if let disposition {
            do {
                let result = try BlockInputReducer.reduce(draft.document, selection: selection, command: .deleteSelection,
                    environment: .init(isComposingText: false, idSource: .random))
                for link in baseLinks where !result.document.blocks.contains(where: { $0.id == link.blockID && $0.kind == .task }) {
                    deletionDispositions[link.blockID] = disposition
                }
                applyStructuralResult(result)
            } catch { self.error = "内容块未删除，原文保留。\(error.localizedDescription)" }
        } else { _ = dispatch(selection: selection, command: .deleteSelection) }
    }

    func append(kind: BlockKind, url: URL? = nil) {
        guard let last = draft.document.blocks.last else { return }
        let block = DocumentBlock(id: BlockID(), kind: kind,
            inlineContent: .init(spans: [.init(text: url?.absoluteString ?? "", linkURL: url)]),
            taskState: kind == .task ? .init(completedAt: nil) : nil, indentLevel: 0)
        _ = dispatch(selection: .blocks(anchor: last.id, focus: last.id), command: .applyDocumentBlocks(blocks: [block], mode: .append))
    }

    func changeKind(_ id: BlockID, to kind: BlockKind) {
        let caret = BlockTextPosition(blockID: id, graphemeOffset: 0)
        _ = dispatch(selection: .text(anchor: caret, focus: caret, preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)), command: .convert(kind))
    }

    func indent(_ id: BlockID, by offset: Int) {
        _ = dispatch(selection: .blocks(anchor: id, focus: id), command: offset > 0 ? .indent : .outdent)
    }

    func move(_ id: BlockID, by offset: Int) {
        guard let index = draft.document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let blocks = draft.document.blocks
        let level = blocks[index].indentLevel
        var end = index + 1
        while end < blocks.count, blocks[end].indentLevel > level { end += 1 }
        let target: BlockID?
        if offset < 0 {
            guard index > 0 else { return }
            var previous = index - 1
            while previous > 0, blocks[previous].indentLevel > level { previous -= 1 }
            target = blocks[previous].id
        } else {
            guard end < blocks.count else { return }
            var afterNext = end + 1
            while afterNext < blocks.count, blocks[afterNext].indentLevel > blocks[end].indentLevel { afterNext += 1 }
            target = afterNext < blocks.count ? blocks[afterNext].id : nil
        }
        _ = dispatch(selection: .blocks(anchor: id, focus: id), command: .moveBlockRoots([id], before: target))
    }

    func importDocument(_ document: BlockDocument, replace: Bool,
                        disposition: LinkedTaskBlockDeletionDisposition = .keepCalendarItem) {
        guard let first = draft.document.blocks.first else { return }
        do {
            let result = try BlockInputReducer.reduce(draft.document, selection: .blocks(anchor: first.id, focus: first.id),
                command: .applyDocumentBlocks(blocks: document.blocks, mode: replace ? .replace : .append),
                environment: .init(isComposingText: false, idSource: .random))
            if replace {
                for link in baseLinks where !result.document.blocks.contains(where: { $0.id == link.blockID && $0.kind == .task }) {
                    deletionDispositions[link.blockID] = disposition
                }
            }
            applyStructuralResult(result)
        } catch { self.error = "导入未完成，原文保留。\(error.localizedDescription)" }
    }

    func refreshFromStore() {
        guard !dirty, !saving, !isComposingText, let note = store.state.notes[draft.id] else { return }
        draft = note
        base = note
        baseLinks = Set(store.state.taskBlockLinks.filter { $0.noteID == note.id })
        error = nil
        status = "已保存"
    }

    func flush() async -> Bool {
        guard await commitNativeInput(), !isComposingText else {
            error = "输入法仍在确认文字，请完成输入后再离开。"
            return false
        }
        if reviewingRecovery { return reconcileReviewedRecovery() || !dirty }
        if dirty, worker == nil { startWorker() }
        await worker?.value
        return !dirty && pendingStructuralEdit == nil
    }

    /// A disappeared host can transfer responsibility only with the same
    /// evidence the desktop accepts. Conflict/pending/source-changed outcomes
    /// intentionally remain unsafe even if protection happened earlier.
    var canHandOffCurrentDraft: Bool {
        let triple: NoteAutosaveTriple
        switch barrierEvidence {
        case let .persisted(value), let .protectedOnly(value): triple = value
        case .clean: return !dirty
        case .unsafeLatestUnprotected: return false
        }
        return triple.identityAndGeneration.draftGeneration == generation
            && triple.noteSnapshotChecksum == (try? WorkspaceChecksum.noteSnapshotChecksum(draft))
    }

    /// Freeze only this native host, protect its latest content, then ask the
    /// existing Store startup reconciler for an exact durable review token.
    /// This is a recovery entry point, never an implicit choice of a version.
    func prepareRecoveryReview() async -> Bool {
        guard await commitNativeInput(), !isComposingText, pendingStructuralEdit == nil else { return false }
        reviewingRecovery = true
        await worker?.value
        if case let .needsDraftRecovery(candidates) = store.phase {
            recoveryCandidate = matchingRecoveryCandidate(in: candidates)
            if recoveryCandidate == nil {
                reviewingRecovery = false
                error = "恢复记录中的版本与当前输入不匹配。请保留当前页面，并在恢复中心检查其他版本后重试。"
                return false
            }
            return true
        }
        guard dirty, store.phase == .ready else {
            reviewingRecovery = false
            error = "请先在恢复中心确认当前保存状态，当前输入仍保留。"
            return false
        }
        do {
            // A fresh generation avoids reusing a Journal identity captured
            // before the external edit which caused the conflict.
            generation &+= 1
            let submission = try makeSubmission(snapshot: draft, generation: generation)
            guard case let .protected(capability) = try await store.protectDraft(submission),
                  !capability.journalChecksum.isEmpty else {
                reviewingRecovery = false
                error = "当前输入尚未写入恢复记录，原文仍在编辑器中。"
                return false
            }
            await store.load()
            guard case let .needsDraftRecovery(candidates) = store.phase,
                  let candidate = matchingRecoveryCandidate(in: candidates) else {
                reviewingRecovery = false
                error = "未取得这份输入对应的恢复版本，请保留当前页面并检查恢复中心。"
                return false
            }
            recoveryCandidate = candidate
            error = nil
            return true
        } catch {
            reviewingRecovery = false
            self.error = "无法准备版本比较，当前输入仍保留：\(error.localizedDescription)"
            return false
        }
    }

    func resolveRecovery(_ action: DraftRecoveryAction) async -> Bool {
        guard let candidate = recoveryCandidate, reviewingRecovery else { return false }
        do {
            let outcome = try await store.resolveDraftRecovery(candidate.token, action: action)
            let resultID: NoteID
            if case let .saveAsNew(noteID, _) = action { resultID = noteID } else { resultID = candidate.draft.id }
            let journalIsClean: Bool
            switch outcome {
            case let .committed(_, journal): journalIsClean = journal == .clean
            case let .noChange(_, journal):
                guard action == .keepPersisted else { return false }
                journalIsClean = journal == .clean
            default:
                error = WorkspaceMutationOutcomePresenter.presentation(for: outcome).message ?? "恢复选择没有完成，请检查后重试。"
                return false
            }
            guard let result = store.state.notes[resultID] else {
                error = "当前保存版本已不存在，请先将当前输入另存为笔记。"
                return false
            }
            reviewedRecoveryResult = (resultID, try WorkspaceChecksum.noteSnapshotChecksum(result), candidate.token)
            if journalIsClean { return finishReviewedRecovery() }
            error = "版本选择已写入，恢复记录仍需确认；请在恢复中心继续处理。"
            return false
        } catch {
            self.error = "恢复选择未完成，两个版本仍保留：\(error.localizedDescription)"
            return false
        }
    }

    /// A parked cleanup can be completed from the root recovery banner. Adopt
    /// its reviewed result only after the Store is ready and its checksum still
    /// matches; a later writer cannot silently replace the version reviewed.
    @discardableResult
    func reconcileReviewedRecovery() -> Bool {
        guard store.phase == .ready, reviewedRecoveryResult != nil else { return false }
        return finishReviewedRecovery()
    }

    private func finishReviewedRecovery() -> Bool {
        guard let review = reviewedRecoveryResult,
              let note = store.state.notes[review.noteID],
              (try? WorkspaceChecksum.noteSnapshotChecksum(note)) == review.checksum else { return false }
        if case let .needsDraftRecovery(candidates) = store.phase,
           candidates.contains(where: { $0.token == review.token }) { return false }
        draft = note
        base = note
        baseLinks = Set(store.state.taskBlockLinks.filter { $0.noteID == note.id })
        editSessionID = UUID()
        generation = 0
        deletionDispositions.removeAll()
        pendingStructuralEdit = nil
        reviewedRecoveryResult = nil
        recoveryCandidate = nil
        reviewingRecovery = false
        dirty = false
        error = nil
        barrierEvidence = .clean
        status = "已按你的选择保留版本"
        selection = nil
        selectionRequest = nil
        return true
    }

    private func matchingRecoveryCandidate(in candidates: [DraftRecoveryCandidate]) -> DraftRecoveryCandidate? {
        let checksum = try? WorkspaceChecksum.noteSnapshotChecksum(draft)
        return candidates.first {
            $0.token.identityAndGeneration.identity == .init(noteID: draft.id, editSessionID: .editor(editSessionID))
                && $0.token.identityAndGeneration.draftGeneration == generation
                && $0.token.noteSnapshotChecksum == checksum
        }
    }

    private func makeSubmission(snapshot: Note, generation: UInt64) throws -> NoteDraftSubmission {
        try BlockDocumentValidator.validate(snapshot.document)
        var fields = Set<NoteDraftField>()
        if snapshot.title != base.title { fields.insert(.title) }
        if snapshot.document != base.document { fields.insert(.document) }
        if snapshot.categoryID != base.categoryID { fields.insert(.categoryID) }
        return NoteDraftSubmission(noteID: snapshot.id, editSessionID: editSessionID,
            baseNoteRevision: base.revision, baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base, baseLinkedTaskBlockLinks: baseLinks, draftGeneration: generation, snapshot: snapshot,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot), modifiedFields: fields,
            linkedBlockDeletionDispositions: deletionDispositions)
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            await persistPending()
            worker = nil
            if dirty, error == nil { startWorker() }
        }
    }

    private func persistPending() async {
        saving = true
        defer { saving = false }
        while dirty {
            let sentGeneration = generation
            var snapshot = draft
            snapshot.updatedAt = Date()
            var fields = Set<NoteDraftField>()
            if snapshot.title != base.title { fields.insert(.title) }
            if snapshot.document != base.document { fields.insert(.document) }
            if snapshot.categoryID != base.categoryID { fields.insert(.categoryID) }
            if fields.isEmpty {
                dirty = false
                error = nil
                status = "已保存"
                return
            }
            do {
                try BlockDocumentValidator.validate(snapshot.document)
                let submission = NoteDraftSubmission(
                    noteID: snapshot.id, editSessionID: editSessionID,
                    baseNoteRevision: base.revision,
                    baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
                    baseSnapshot: base, baseLinkedTaskBlockLinks: baseLinks,
                    draftGeneration: sentGeneration, snapshot: snapshot,
                    noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
                    modifiedFields: fields, linkedBlockDeletionDispositions: deletionDispositions
                )
                let protected = try await store.protectDraft(submission)
                guard case let .protected(capability) = protected else {
                    error = "已有更新的草稿版本。当前输入仍保留，请检查后重试。"
                    status = "尚未保存"
                    return
                }
                status = "草稿已保护，正在保存…"
                let outcome = try await store.commitProtectedDraft(capability)
                let presentation = WorkspaceMutationOutcomePresenter.presentation(for: outcome)
                let proof = NoteAutosaveOutcomeMapping.workspace(outcome, triple: .init(submission: submission), hasDurableProtection: true)
                barrierEvidence = proof.evidence
                guard case .persisted = proof.evidence else {
                    error = presentation.message ?? "保存未完成，草稿保留在恢复记录中。"
                    status = "草稿已保护，保存待处理"
                    return
                }
                guard let stored = store.state.notes[draft.id] else {
                    error = "笔记已不存在。当前编辑内容仍保留。"
                    return
                }
                // Keep a newer local generation's original base. The Store's
                // accepted-generation rebase planner can then detect edits made
                // by another writer between commits instead of masking them.
                if sentGeneration == generation {
                    base = stored
                    baseLinks = Set(store.state.taskBlockLinks.filter { $0.noteID == stored.id })
                    deletionDispositions.removeAll()
                    draft = stored
                    dirty = false
                    error = presentation.message
                    status = proof.state.statusMessage ?? "已保存"
                } else {
                    // Rebase ONLY onto fields acknowledged by this receipt,
                    // never onto a newer Store snapshot. A user may even have
                    // reverted to the original text while this save was in
                    // flight; that is still a new delta from the accepted save.
                    if fields.contains(.title) { base.title = snapshot.title }
                    if fields.contains(.document) { base.document = snapshot.document }
                    if fields.contains(.categoryID) { base.categoryID = snapshot.categoryID }
                    switch outcome {
                    case let .committed(receipt, _):
                        if let revision = receipt.persistedDraft?.persistedNoteRevision { base.revision = revision }
                    case let .draftAlreadyPersisted(receipt, _):
                        base.revision = receipt.persistedNoteRevision
                    default: break
                    }
                    baseLinks = baseLinks.filter { link in
                        snapshot.document.blocks.contains { $0.id == link.blockID && $0.kind == .task }
                    }
                    deletionDispositions = deletionDispositions.filter { key, _ in baseLinks.contains { $0.blockID == key } }
                    if proof.state.blocksSuccessorSubmission {
                        error = proof.state.statusMessage ?? "保存状态尚待确认，请先处理恢复提示。"
                        return
                    }
                }
            } catch {
                self.error = "保存未完成：\(error.localizedDescription)"
                status = "尚未保存"
                return
            }
        }
    }


}

struct MobilePendingBlockEdit {
    let result: BlockInputResult
    let removedLinkedBlockIDs: [BlockID]
    let generation: UInt64
}


struct MobileDocumentSelectionRequest {
    let id = UUID()
    let selection: BlockEditorSelection
}

struct MobileClipboardRequest {
    let id = UUID()
    let payload: BlockClipboardPayload
}
