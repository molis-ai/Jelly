import Foundation
import WorkspaceDomain

struct InspirationPermanentDeleteRequest: Equatable, Sendable {
    let inspirationID: InspirationID
    let deletedAt: Date
    let preview: PermanentDeletePreview
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
    private let searchIndex: WorkspaceSearchIndex
    private let textSaveDelay: Duration
    private var textDrafts: [InspirationID: String] = [:]
    private var textSaveStates: [InspirationID: InspirationTextSaveState] = [:]
    private var pendingTextSaveTasks: [InspirationID: Task<Void, Never>] = [:]
    private var dirtyTextDraftIDs: Set<InspirationID> = []
    private var textDraftGenerations: [InspirationID: UInt64] = [:]

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
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex(),
        textSaveDelay: Duration = .milliseconds(450),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.metadataResolver = metadataResolver
        self.searchIndex = searchIndex
        self.textSaveDelay = textSaveDelay
        self.clock = clock
        refresh()
    }

    var selected: Inspiration? {
        selectedID.flatMap { store.state.inspirations[$0] }
    }

    var selectedConvertedNoteID: NoteID? {
        guard let selectedID else { return nil }
        return store.state.inspirationNoteLinks.first(where: { link in
            if case let .live(id) = link.source { return id == selectedID }
            return false
        })?.noteID
    }

    var selectedPrimaryActionTitle: String {
        selectedConvertedNoteID == nil ? "继续写成笔记" : "打开笔记"
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
        selectedID = id
        if let id, textDrafts[id] == nil {
            textDrafts[id] = store.state.inspirations[id]?.rawText ?? ""
        }
    }

    func alignSelection(with visibleIDs: [InspirationID]) {
        if let selectedID, visibleIDs.contains(selectedID) { return }
        selectedID = visibleIDs.first
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
            inspiration = Inspiration(
                id: id,
                inputKind: .url,
                rawText: nil,
                rawURL: url,
                rawFile: nil,
                resolvedSourceKind: .unknown,
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
    func convertSelectedToNote() async throws -> NoteID? {
        await flushSelectedTextEdit()
        guard selectedTextSaveState != .invalid, selectedTextSaveState != .failed else { return nil }
        guard let inspiration = selected else { return nil }
        if let existing = store.state.inspirationNoteLinks.first(where: {
            if case let .live(id) = $0.source { return id == inspiration.id }
            return false
        }) {
            return existing.noteID
        }
        let now = clock()
        var note = Note.empty(id: NoteID(), categoryID: inspiration.categoryID, now: now)
        note.title = suggestedTitle(for: inspiration)
        note.document = document(for: inspiration)
        let outcome = try await store.sendWorkspace(
            .convertInspirationToNote(.init(inspirationID: inspiration.id, proposedNote: note)),
            undoLabel: "转成笔记"
        )
        refresh()
        switch outcome {
        case .committed:
            return note.id
        case let .noChange(reason, _):
            if case let .inspirationAlreadyConverted(noteID) = reason { return noteID }
            return nil
        default:
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
        do {
            let outcome = try await store.sendWorkspace(
                .updateInspirationText(id, rawText: draft, at: clock()),
                undoLabel: "编辑灵感"
            )
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
            statusMessage = nil
            refresh()
        } catch {
            statusMessage = "链接元数据获取失败，原文已保存。"
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
                    statusMessage = "链接元数据获取失败，原文已保存；失败状态未能写入。"
                }
            } else {
                statusMessage = nil
            }
            refresh()
        }
    }

    private func suggestedTitle(for inspiration: Inspiration) -> String {
        if let title = inspiration.resolvedMetadata?.title, !title.isEmpty { return title }
        if let text = inspiration.rawText { return String(text.prefix(40)) }
        return inspiration.rawURL?.host ?? "灵感笔记"
    }

    private func document(for inspiration: Inspiration) -> BlockDocument {
        if let url = inspiration.rawURL {
            let title = inspiration.resolvedMetadata?.title ?? url.absoluteString
            return .init(blocks: [
                .init(
                    id: BlockID(),
                    kind: .link,
                    inlineContent: .init(spans: [.init(text: title, marks: [], linkURL: url)]),
                    taskState: nil,
                    indentLevel: 0
                )
            ])
        }
        return .init(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain(inspiration.rawText ?? ""),
                taskState: nil,
                indentLevel: 0
            )
        ])
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
