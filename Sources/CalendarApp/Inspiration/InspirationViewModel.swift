import Foundation
import WorkspaceDomain

struct InspirationPermanentDeleteRequest: Equatable, Sendable {
    let inspirationID: InspirationID
    let deletedAt: Date
    let preview: PermanentDeletePreview
}

private struct PendingInspirationNoteWrite {
    let inspirationID: InspirationID
    let noteID: NoteID
    let transactionID: UUID
    let isNewNote: Bool
}

enum InspirationTextSaveState: Equatable {
    case idle
    case waiting
    case saving
    case saved
    case invalid
    case failed
}

@MainActor
@Observable final class InspirationViewModel {
    private let store: WorkspaceStore
    private let clock: @Sendable () -> Date
    private let metadataResolver: any URLMetadataResolving
    private let digestOperator: (any MaterialDigestOperating)?
    private let isDigestConfigured: @MainActor () -> Bool
    private let searchIndex: WorkspaceSearchIndex
    private let textSaveDelay: Duration
    private var textDrafts: [InspirationID: String] = [:]
    private var textSaveStates: [InspirationID: InspirationTextSaveState] = [:]
    private var pendingTextSaveTasks: [InspirationID: Task<Void, Never>] = [:]
    private var dirtyTextDraftIDs: Set<InspirationID> = []
    private var textDraftGenerations: [InspirationID: UInt64] = [:]
    private var pendingNoteWrite: PendingInspirationNoteWrite?

    var captureText = ""
    var searchText = "" { didSet { refresh() } }
    var categoryFilterID: UUID? { didSet { refresh() } }
    private(set) var pending: [Inspiration] = []
    private(set) var converted: [Inspiration] = []
    private(set) var archived: [Inspiration] = []
    private(set) var selectedID: InspirationID?
    private(set) var statusMessage: String?

    init(
        store: WorkspaceStore,
        metadataResolver: any URLMetadataResolving = URLMetadataResolver(),
        digestOperator: (any MaterialDigestOperating)? = nil,
        isDigestConfigured: @escaping @MainActor () -> Bool = { true },
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex(),
        textSaveDelay: Duration = .milliseconds(450),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.metadataResolver = metadataResolver
        self.digestOperator = digestOperator
        self.isDigestConfigured = isDigestConfigured
        self.searchIndex = searchIndex
        self.textSaveDelay = textSaveDelay
        self.clock = clock
        refresh()
    }

    var selected: Inspiration? {
        selectedID.flatMap { store.state.inspirations[$0] }
    }

    var selectedDigest: MaterialDigest? {
        guard let selectedID else { return nil }
        return store.state.materialDigests[selectedID]
    }

    var selectedDigestPresentation: MaterialDigestPresentation {
        guard let selected else { return .hidden }
        return MaterialDigestPresentation.project(
            inspiration: selected,
            digest: selectedDigest,
            operatorAvailable: digestOperator != nil,
            modelConfigured: isDigestConfigured(),
            progressFraction: digestOperator?.progress(for: selected.id)
        )
    }

    func startSelectedDigest() async {
        guard let selectedID else { return }
        await digestOperator?.start(inspirationID: selectedID)
        refresh()
    }

    func confirmSelectedModelDownload() async {
        guard let selectedID else { return }
        await digestOperator?.confirmModelDownload(inspirationID: selectedID)
        refresh()
    }

    func cancelSelectedDigest() async {
        guard let selectedID else { return }
        await digestOperator?.cancel(inspirationID: selectedID)
        refresh()
    }

    func retrySelectedDigest() async {
        await startSelectedDigest()
    }

    func refreshSelectedDigest() async {
        guard let selectedID else { return }
        await digestOperator?.start(inspirationID: selectedID, mode: .refreshSource)
        refresh()
    }

    var selectedConvertedNoteID: NoteID? {
        guard let selectedID else { return nil }
        return store.state.inspirationNoteLinks.first(where: { link in
            if case let .live(id) = link.source { return id == selectedID }
            return false
        })?.noteID
    }

    var selectedPrimaryActionTitle: String {
        if pendingNoteWrite != nil { return "继续确认写入" }
        if selectedConvertedNoteID != nil {
            guard selectedDigestNeedsWriting else { return "打开笔记" }
            return selectedDigest?.noteWrite == nil ? "写入笔记" : "更新笔记摘要"
        }
        return selectedDigest?.result == nil ? "继续写成笔记" : "写入笔记"
    }

    private var selectedDigestNeedsWriting: Bool {
        guard selectedConvertedNoteID != nil,
              let result = selectedDigest?.result,
              let fingerprint = try? WorkspaceChecksum.materialDigestResultFingerprint(result)
        else { return false }
        return selectedDigest?.noteWrite?.resultFingerprint != fingerprint
    }

    var selectedTextIsEditable: Bool {
        guard let selected else { return false }
        return selected.inputKind == .text
            && selected.lifecycle == .active
            && selectedConvertedNoteID == nil
    }

    var selectedTextDraft: String {
        get {
            guard let selected else { return "" }
            return textDrafts[selected.id] ?? selected.rawText ?? ""
        }
        set {
            guard let id = selectedID, selectedTextIsEditable else { return }
            textDrafts[id] = newValue
            dirtyTextDraftIDs.insert(id)
            textDraftGenerations[id, default: 0] &+= 1
            textSaveStates[id] = .waiting
            scheduleTextSave(for: id, generation: textDraftGenerations[id, default: 0])
        }
    }

    var selectedTextSaveState: InspirationTextSaveState {
        guard let selectedID else { return .idle }
        return textSaveStates[selectedID] ?? .idle
    }

    var pendingCount: Int { pending.count }

    func refresh() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let all: [Inspiration]
        if query.isEmpty {
            all = Array(store.state.inspirations.values)
        } else {
            let records: [WorkspaceSearchRecord]
            do {
                records = try searchIndex.search(
                    query: query,
                    kind: .inspiration,
                    includeArchived: true,
                    in: store.state
                )
            } catch {
                records = WorkspaceSearchProjection.build(from: store.state)
                    .search(query: query, kind: .inspiration, includeArchived: true)
            }
            let ids = Set(records.compactMap { record -> InspirationID? in
                if case let .inspiration(id) = record.objectID { return id }
                return nil
            })
            all = store.state.inspirations.values.filter { ids.contains($0.id) }
        }
        let filtered = all.filter { inspiration in
            categoryFilterID == nil || inspiration.categoryID == categoryFilterID
        }
        let linked = Set(store.state.inspirationNoteLinks.compactMap { link -> InspirationID? in
            if case let .live(id) = link.source { return id }
            return nil
        })
        pending = filtered.filter { $0.lifecycle == .active && !linked.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        converted = filtered.filter { $0.lifecycle == .active && linked.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        archived = filtered.filter { $0.lifecycle == .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func select(_ id: InspirationID?) {
        if selectedID != id {
            statusMessage = nil
        }
        selectedID = id
        if let id, textDrafts[id] == nil {
            textDrafts[id] = store.state.inspirations[id]?.rawText ?? ""
        }
    }

    func alignSelection(with visibleIDs: [InspirationID]) {
        if let selectedID, visibleIDs.contains(selectedID) { return }
        select(visibleIDs.first)
    }

    @discardableResult
    func changeSelectedCategory(to categoryID: UUID) async throws -> Bool {
        guard let id = selectedID else { return false }
        let outcome = try await store.sendWorkspace(
            .changeInspirationCategory(id, categoryID: categoryID, at: clock()),
            undoLabel: "调整灵感分类"
        )
        refresh()
        if case .committed = outcome { return true }
        return false
    }

    @discardableResult
    func capture(_ raw: String) async throws -> InspirationID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InspirationCaptureError.empty }
        let now = clock()
        let id = InspirationID()
        let inspiration: Inspiration
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            let classifiedKind = SourceKindClassifier.classify(url) ?? .unknown
            inspiration = Inspiration(
                id: id,
                inputKind: .url,
                rawText: nil,
                rawURL: url,
                rawFile: nil,
                resolvedSourceKind: classifiedKind,
                resolvedMetadata: SourceMetadata(
                    title: nil, siteName: nil, domain: url.host, thumbnailURL: nil, fetchStatus: .loading
                ),
                categoryID: store.calendarState.uncategorizedID,
                lifecycle: .active,
                createdAt: now,
                updatedAt: now
            )
        } else {
            inspiration = Inspiration.text(
                id: id,
                rawText: trimmed,
                categoryID: store.calendarState.uncategorizedID,
                now: now
            )
        }
        let categoryName = store.calendarState.categories[inspiration.categoryID]?.name ?? "未分类"
        let outcome = try await store.sendWorkspace(
            .createInspiration(.init(inspiration: inspiration)),
            undoLabel: WorkspaceCreationFeedback.inspiration(
                text: trimmed,
                categoryName: categoryName
            )
        )
        guard case .committed = outcome else { throw InspirationCaptureError.notCommitted }
        captureText = ""
        select(id)
        refresh()
        if inspiration.inputKind == .url, let url = inspiration.rawURL {
            Task { await enrichURL(id: id, url: url) }
        }
        return id
    }

    @discardableResult
    func captureFile(
        _ reference: FileReference,
        kind: ResolvedSourceKind
    ) async throws -> InspirationID {
        guard !reference.bookmarkData.isEmpty,
              !reference.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw InspirationCaptureError.empty
        }
        let now = clock()
        let id = InspirationID()
        let inspiration = Inspiration(
            id: id,
            inputKind: .file,
            rawText: nil,
            rawURL: nil,
            rawFile: reference,
            resolvedSourceKind: kind,
            resolvedMetadata: nil,
            categoryID: store.calendarState.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        let categoryName = store.calendarState.categories[inspiration.categoryID]?.name ?? "未分类"
        let outcome = try await store.sendWorkspace(
            .createInspiration(.init(inspiration: inspiration)),
            undoLabel: WorkspaceCreationFeedback.inspiration(
                text: reference.displayName,
                categoryName: categoryName
            )
        )
        guard case .committed = outcome else { throw InspirationCaptureError.notCommitted }
        select(id)
        refresh()
        return id
    }

    func captureFile(
        at url: URL,
        kind: ResolvedSourceKind,
        bookmarker: any MaterialFileBookmarking = LocalMaterialFileAccess()
    ) async -> InspirationID? {
        do {
            let reference = try bookmarker.makeReference(for: url)
            let id = try await captureFile(reference, kind: kind)
            statusMessage = nil
            return id
        } catch {
            statusMessage = "无法保存这个文件的访问权限，原文件没有被改动。"
            return nil
        }
    }

    @discardableResult
    func convertSelectedToNote() async throws -> NoteID? {
        if let pendingNoteWrite {
            return try await retryPendingNoteWrite(pendingNoteWrite)
        }
        await flushSelectedTextEdit()
        guard selectedTextSaveState != .invalid, selectedTextSaveState != .failed else { return nil }
        guard let inspiration = selected else { return nil }
        if let existing = store.state.inspirationNoteLinks.first(where: {
            if case let .live(id) = $0.source { return id == inspiration.id }
            return false
        }) {
            guard selectedDigestNeedsWriting,
                  let note = store.state.notes[existing.noteID],
                  let result = selectedDigest?.result,
                  let fingerprint = try? WorkspaceChecksum.materialDigestResultFingerprint(result)
            else { return existing.noteID }
            let blocks = InspirationNoteDocumentBuilder.summaryBlocks(
                for: result,
                snapshot: selectedDigest?.preparedSnapshot,
                sourceKind: inspiration.resolvedSourceKind
            )
            let outcome = try await store.sendWorkspace(
                .writeMaterialDigestToNote(.init(
                    inspirationID: inspiration.id,
                    noteID: existing.noteID,
                    expectedNoteRevision: note.revision,
                    resultFingerprint: fingerprint,
                    proposedBlocks: blocks
                )),
                undoLabel: selectedDigest?.noteWrite == nil ? "写入提炼摘要" : "更新提炼摘要"
            )
            refresh()
            switch outcome {
            case .committed:
                statusMessage = "笔记摘要已更新。"
                return existing.noteID
            case let .noChange(reason, _):
                if case .materialDigestAlreadyWritten = reason { return existing.noteID }
                statusMessage = WorkspaceMutationOutcomePresenter.presentation(for: outcome).message
                return nil
            case let .commitPending(transactionID, _):
                pendingNoteWrite = .init(
                    inspirationID: inspiration.id,
                    noteID: existing.noteID,
                    transactionID: transactionID,
                    isNewNote: false
                )
                statusMessage = "写入结果尚未确认，原始灵感仍保留。请继续确认。"
                return nil
            default:
                statusMessage = WorkspaceMutationOutcomePresenter.presentation(for: outcome).message
                return nil
            }
        }
        let now = clock()
        var note = Note.empty(id: NoteID(), categoryID: inspiration.categoryID, now: now)
        note.title = suggestedTitle(for: inspiration)
        note.document = InspirationNoteDocumentBuilder.document(
            for: inspiration,
            digest: store.state.materialDigests[inspiration.id]
        )
        let digestWrite: MaterialDigestNoteWritePlan?
        if let result = store.state.materialDigests[inspiration.id]?.result,
           let fingerprint = try? WorkspaceChecksum.materialDigestResultFingerprint(result) {
            digestWrite = MaterialDigestNoteWritePlan(
                resultFingerprint: fingerprint,
                blockIDs: Array(note.document.blocks.dropFirst()).map(\.id)
            )
        } else {
            digestWrite = nil
        }
        let outcome = try await store.sendWorkspace(
            .convertInspirationToNote(.init(
                inspirationID: inspiration.id,
                proposedNote: note,
                digestWrite: digestWrite
            )),
            undoLabel: "转成笔记"
        )
        refresh()
        switch outcome {
        case .committed:
            statusMessage = "提炼摘要已写入笔记。"
            return note.id
        case let .noChange(reason, _):
            if case let .inspirationAlreadyConverted(noteID) = reason { return noteID }
            statusMessage = WorkspaceMutationOutcomePresenter.presentation(for: outcome).message
            return nil
        case let .commitPending(transactionID, _):
            pendingNoteWrite = .init(
                inspirationID: inspiration.id,
                noteID: note.id,
                transactionID: transactionID,
                isNewNote: true
            )
            statusMessage = "写入结果尚未确认，原始灵感仍保留。请继续确认。"
            return nil
        default:
            statusMessage = WorkspaceMutationOutcomePresenter.presentation(for: outcome).message
            return nil
        }
    }

    private func retryPendingNoteWrite(_ pending: PendingInspirationNoteWrite) async throws -> NoteID? {
        let outcome = try await store.retryPendingCommit(pending.transactionID)
        switch outcome {
        case .committed:
            pendingNoteWrite = nil
            select(pending.inspirationID)
            refresh()
            guard store.state.inspirationNoteLinks.contains(where: {
                $0.noteID == pending.noteID && $0.source == .live(pending.inspirationID)
            }) else {
                statusMessage = "写入已确认，但没有找到对应笔记；请在恢复与备份中检查。"
                return nil
            }
            statusMessage = pending.isNewNote ? "提炼摘要已写入笔记。" : "笔记摘要已更新。"
            return pending.noteID
        case .stillPending:
            statusMessage = "写入结果仍未确认，请稍后继续确认。"
            return nil
        case .notCommitted:
            pendingNoteWrite = nil
            refresh()
            statusMessage = "已确认没有写入笔记，原始灵感仍保留。"
            return nil
        case .sourceChanged:
            pendingNoteWrite = nil
            refresh()
            statusMessage = "本地数据已经变化，没有覆盖现有内容；请检查后重试。"
            return nil
        }
    }

    @discardableResult
    func archiveSelected() async throws -> Bool {
        await flushSelectedTextEdit()
        guard selectedTextSaveState != .invalid, selectedTextSaveState != .failed else { return false }
        guard let id = selectedID else { return false }
        let outcome = try await store.sendWorkspace(.archiveInspiration(id, at: clock()), undoLabel: "归档灵感")
        refresh()
        if case .committed = outcome { return true }
        return false
    }

    @discardableResult
    func restoreSelected() async throws -> Bool {
        guard let id = selectedID else { return false }
        let outcome = try await store.sendWorkspace(.restoreInspiration(id, at: clock()), undoLabel: "恢复灵感")
        refresh()
        if case .committed = outcome { return true }
        return false
    }

    func flushSelectedTextEdit() async {
        guard let selectedID, dirtyTextDraftIDs.contains(selectedID) else { return }
        pendingTextSaveTasks[selectedID]?.cancel()
        pendingTextSaveTasks[selectedID] = nil
        await saveTextDraft(
            for: selectedID,
            generation: textDraftGenerations[selectedID, default: 0]
        )
    }

    private func scheduleTextSave(for id: InspirationID, generation: UInt64) {
        pendingTextSaveTasks[id]?.cancel()
        let delay = textSaveDelay
        pendingTextSaveTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.saveTextDraft(for: id, generation: generation)
        }
    }

    private func saveTextDraft(for id: InspirationID, generation: UInt64) async {
        guard textDraftGenerations[id, default: 0] == generation else { return }
        guard let draft = textDrafts[id] else { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            textSaveStates[id] = .invalid
            return
        }
        guard let inspiration = store.state.inspirations[id],
              inspiration.inputKind == .text,
              inspiration.lifecycle == .active,
              !store.state.inspirationNoteLinks.contains(where: { link in
                  if case let .live(sourceID) = link.source { return sourceID == id }
                  return false
              }) else {
            textSaveStates[id] = .failed
            return
        }
        guard inspiration.rawText != draft else {
            dirtyTextDraftIDs.remove(id)
            textSaveStates[id] = .saved
            return
        }
        textSaveStates[id] = .saving
        let hadDigest = store.state.materialDigests[id] != nil
        do {
            let outcome = try await store.sendWorkspace(
                .updateInspirationText(id, rawText: draft, at: clock()),
                undoLabel: "编辑灵感"
            )
            if case .committed = outcome, hadDigest {
                await digestOperator?.stopExternalWork(inspirationID: id)
            }
            refresh()
            guard textDraftGenerations[id, default: 0] == generation else { return }
            switch outcome {
            case .committed, .noChange:
                dirtyTextDraftIDs.remove(id)
                textSaveStates[id] = .saved
            default:
                textSaveStates[id] = .failed
            }
        } catch {
            guard textDraftGenerations[id, default: 0] == generation else { return }
            textSaveStates[id] = .failed
        }
        if textDraftGenerations[id, default: 0] == generation {
            pendingTextSaveTasks[id] = nil
        }
    }

    func permanentDeleteRequest(
        for id: InspirationID
    ) throws -> InspirationPermanentDeleteRequest {
        let deletedAt = clock()
        let preview = try PermanentDeletePlanner.preview(
            .inspiration(id, deletedAt: deletedAt),
            in: store.state
        )
        return .init(inspirationID: id, deletedAt: deletedAt, preview: preview)
    }

    @discardableResult
    func permanentlyDelete(
        _ request: InspirationPermanentDeleteRequest,
        authorization: PermanentDeleteAuthorization
    ) async throws -> Bool {
        let outcome = try await store.sendWorkspace(
            .permanentlyDeleteInspiration(
                request.inspirationID,
                at: request.deletedAt,
                authorization: authorization
            ),
            undoLabel: "永久删除灵感"
        )
        guard case .committed = outcome else { return false }
        await digestOperator?.stopExternalWork(inspirationID: request.inspirationID)
        if selectedID == request.inspirationID { selectedID = nil }
        statusMessage = nil
        refresh()
        return true
    }

    func retrySelectedMetadata() async {
        guard let id = selectedID,
              let current = store.state.inspirations[id],
              let url = current.rawURL,
              current.resolvedMetadata?.fetchStatus == .failed
        else { return }

        var loadingMetadata = current.resolvedMetadata ?? SourceMetadata(
            title: nil,
            siteName: nil,
            domain: url.host,
            thumbnailURL: nil,
            fetchStatus: .loading
        )
        loadingMetadata.fetchStatus = .loading
        let checksum = WorkspaceChecksum.inspirationSourceChecksum(current)
        do {
            _ = try await store.sendWorkspace(
                .updateInspirationMetadata(
                    id,
                    expectedSource: .init(sourceChecksum: checksum),
                    metadata: loadingMetadata,
                    resolvedKind: current.resolvedSourceKind
                )
            )
            statusMessage = nil
            refresh()
            Task { await enrichURL(id: id, url: url) }
        } catch {
            statusMessage = "重试未能启动，请稍后再试。"
            refresh()
        }
    }

    private func enrichURL(id: InspirationID, url: URL) async {
        guard let current = store.state.inspirations[id] else { return }
        let sourceChecksum = WorkspaceChecksum.inspirationSourceChecksum(current)
        do {
            let result = try await metadataResolver.resolve(url)
            _ = try await store.sendWorkspace(
                .updateInspirationMetadata(
                    id,
                    expectedSource: .init(sourceChecksum: sourceChecksum),
                    metadata: result.metadata,
                    resolvedKind: result.resolvedKind
                )
            )
            updateStatusMessage(nil, for: id)
            refresh()
        } catch {
            updateStatusMessage("链接元数据获取失败，原文已保存。", for: id)
            if let latest = store.state.inspirations[id],
               WorkspaceChecksum.inspirationSourceChecksum(latest) == sourceChecksum {
                var failedMetadata = latest.resolvedMetadata ?? SourceMetadata(
                    title: nil,
                    siteName: nil,
                    domain: latest.rawURL?.host,
                    thumbnailURL: nil,
                    fetchStatus: .failed
                )
                failedMetadata.fetchStatus = .failed
                // 解析失败也要留下域名能判定的 kind，B 站 / 小宇宙播放页常不是规整 HTML。
                let failedKind = SourceKindClassifier.classify(url) ?? latest.resolvedSourceKind
                do {
                    _ = try await store.sendWorkspace(
                        .updateInspirationMetadata(
                            id,
                            expectedSource: .init(sourceChecksum: sourceChecksum),
                            metadata: failedMetadata,
                            resolvedKind: failedKind
                        )
                    )
                } catch {
                    updateStatusMessage(
                        "链接元数据获取失败，原文已保存；失败状态未能写入。",
                        for: id
                    )
                }
            } else {
                updateStatusMessage(nil, for: id)
            }
            refresh()
        }
    }

    private func updateStatusMessage(_ message: String?, for id: InspirationID) {
        guard selectedID == id else { return }
        statusMessage = message
    }

    private func suggestedTitle(for inspiration: Inspiration) -> String {
        if let title = inspiration.resolvedMetadata?.title, !title.isEmpty { return title }
        if let text = inspiration.rawText { return String(text.prefix(40)) }
        return inspiration.rawURL?.host ?? "灵感笔记"
    }

}

enum InspirationNoteDocumentBuilder {
    static func document(
        for inspiration: Inspiration,
        digest: MaterialDigest?
    ) -> BlockDocument {
        var blocks: [DocumentBlock]
        switch inspiration.inputKind {
        case .url:
            if let url = inspiration.rawURL {
                blocks = [linkBlock(
                    title: inspiration.resolvedMetadata?.title ?? url.absoluteString,
                    url: url
                )]
            } else {
                blocks = [paragraph("原始链接不可用")]
            }
        case .text:
            blocks = [paragraph(inspiration.rawText ?? "")]
        case .file:
            blocks = [paragraph("材料文件：\(inspiration.rawFile?.displayName ?? "未命名材料")")]
        }
        let checksum = WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        if let result = digest?.result, digest?.sourceChecksum == checksum {
            blocks.append(contentsOf: summaryBlocks(
                for: result,
                snapshot: digest?.preparedSnapshot,
                sourceKind: inspiration.resolvedSourceKind
            ))
        }
        return .init(blocks: blocks)
    }

    static func summaryBlocks(
        for result: MaterialDigestResult,
        snapshot: MaterialSnapshot?,
        sourceKind: ResolvedSourceKind
    ) -> [DocumentBlock] {
        let blocksByID = Dictionary(uniqueKeysWithValues: (snapshot?.blocks ?? []).map { ($0.id, $0) })
        var blocks = [
            heading2("核心观点"),
            paragraph(labeled(
                result.summary.thesisClaim.text,
                ids: result.summary.thesisClaim.evidenceBlockIDs,
                blocksByID: blocksByID
            )),
            heading2("主要观点")
        ]
        blocks.append(contentsOf: result.summary.takeawayClaims.map { claim in
            bullet(labeled(claim.text, ids: claim.evidenceBlockIDs, blocksByID: blocksByID))
        })
        if !result.summary.chapters.isEmpty {
            blocks.append(heading2("章节"))
            for chapter in result.summary.chapters {
                let location = chapter.anchorBlockID.flatMap { blocksByID[$0]?.locator.displayLabel }
                    ?? timestamp(chapter.startSeconds)
                blocks.append(bullet("\(location) \(chapter.title)"))
                blocks.append(contentsOf: chapter.pointClaims.map { claim in
                    bullet(labeled(claim.text, ids: claim.evidenceBlockIDs, blocksByID: blocksByID))
                })
            }
        }
        if !result.summary.quotes.isEmpty {
            blocks.append(heading2("引用"))
            blocks.append(contentsOf: result.summary.quotes.map { quote in
                let location = quote.evidenceBlockID.flatMap { blocksByID[$0]?.locator.displayLabel }
                    ?? timestamp(quote.startSeconds)
                let body: String
                if let speaker = quote.speaker, !speaker.isEmpty {
                    body = "\(speaker)：\(quote.text)"
                } else {
                    body = quote.text
                }
                return bullet("\(location) \(body)")
            })
        }
        if !result.summary.droppedClaims.isEmpty {
            blocks.append(heading2(MaterialDigestCopy.excludedContentTitle(for: sourceKind)))
            blocks.append(contentsOf: result.summary.droppedClaims.map { claim in
                bullet(labeled(claim.text, ids: claim.evidenceBlockIDs, blocksByID: blocksByID))
            })
        }
        if case let .partial(processed, expected, _)? = snapshot?.coverage {
            if let expected {
                blocks.append(paragraph("基于部分内容：\(processed)/\(expected) 项已读取"))
            } else {
                blocks.append(paragraph("基于部分内容：\(processed) 项已读取"))
            }
        }
        return blocks
    }

    private static func labeled(
        _ text: String,
        ids: [MaterialBlockID],
        blocksByID: [MaterialBlockID: MaterialBlock]
    ) -> String {
        let labels = ids.compactMap { blocksByID[$0]?.locator.displayLabel }
        guard !labels.isEmpty else { return text }
        return "\(text)（\(labels.joined(separator: "、"))）"
    }

    private static func linkBlock(title: String, url: URL) -> DocumentBlock {
        .init(
            id: BlockID(),
            kind: .link,
            inlineContent: .init(spans: [.init(text: title, marks: [], linkURL: url)]),
            taskState: nil,
            indentLevel: 0
        )
    }

    private static func heading2(_ text: String) -> DocumentBlock {
        .init(id: BlockID(), kind: .heading2, inlineContent: .plain(text), taskState: nil, indentLevel: 0)
    }

    private static func paragraph(_ text: String) -> DocumentBlock {
        .init(id: BlockID(), kind: .paragraph, inlineContent: .plain(text), taskState: nil, indentLevel: 0)
    }

    private static func bullet(_ text: String) -> DocumentBlock {
        .init(id: BlockID(), kind: .bullet, inlineContent: .plain(text), taskState: nil, indentLevel: 0)
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= MaterialDigestContentLimits.maximumTimestampSeconds
        else { return "--:--" }
        let total = max(0, Int(seconds.rounded(.towardZero)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum InspirationCaptureError: Error, Equatable {
    case empty
    case notCommitted
}

struct URLMetadataResolveResult: Sendable {
    let metadata: SourceMetadata
    let resolvedKind: ResolvedSourceKind
}

protocol URLMetadataResolving: AnyObject, Sendable {
    func resolve(_ url: URL) async throws -> URLMetadataResolveResult
}
