import AppKit
import CalendarDomain
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceDomain

enum NotesNewItemCategoryPolicy {
    static func resolve(
        explicitCategoryID: UUID?,
        currentCategoryFilterID: UUID?,
        calendarState: CalendarState
    ) -> UUID {
        if let explicitCategoryID,
           calendarState.categories[explicitCategoryID] != nil {
            return explicitCategoryID
        }
        if let currentCategoryFilterID,
           calendarState.categories[currentCategoryFilterID] != nil {
            return currentCategoryFilterID
        }
        return calendarState.uncategorizedID
    }
}

@MainActor
enum NotesNewItemAdmission {
    case proceed
    case presentRecovery(DraftRecoveryCandidate)

    static func decision(for store: WorkspaceStore) -> Self {
        guard let candidate = DraftRecoveryPresentation.candidates(from: store).first else {
            return .proceed
        }
        return .presentRecovery(candidate)
    }
}

private struct RecoveryUndoNotice: Equatable {
    let message: String
    let stateGeneration: UInt
}

private struct NoteActionUndoNotice: Equatable {
    let message: String
    let noteID: NoteID
    let stateGeneration: UInt
}

@MainActor
enum NotesRecoverySelectionUndo {
    static func perform(
        store: WorkspaceStore,
        autosave: NoteAutosaveCoordinator,
        preferredNoteID: NoteID?
    ) async throws -> NoteEditorIdentity? {
        _ = try await store.undo()
        let noteID = preferredNoteID.flatMap { store.state.notes[$0]?.id }
            ?? store.state.notes.keys.first
        guard let noteID, let note = store.state.notes[noteID] else { return nil }
        let identity = NoteEditorIdentity(noteID: noteID, editSessionID: UUID())
        try autosave.beginSession(
            note,
            linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == noteID }),
            editSessionID: identity.editSessionID,
            activeHostToken: UUID()
        )
        return identity
    }
}

@MainActor
struct NotesOwnedBlockEditorSession {
    let ownerIdentity: NoteEditorIdentity
    let session: BlockEditorSession
}

@MainActor
enum NotesLiveEditorSessionRouting {
    static func receive(
        ownerIdentity: NoteEditorIdentity,
        currentOwnerIdentity: NoteEditorIdentity?,
        current: NotesOwnedBlockEditorSession?,
        incoming: BlockEditorSession?
    ) -> NotesOwnedBlockEditorSession? {
        guard currentOwnerIdentity == ownerIdentity else {
            return current
        }
        guard let incoming else {
            return nil
        }
        guard incoming.noteID == ownerIdentity.noteID else {
            return current
        }
        return NotesOwnedBlockEditorSession(ownerIdentity: ownerIdentity, session: incoming)
    }

    static func matchingSession(
        currentOwnerIdentity: NoteEditorIdentity?,
        current: NotesOwnedBlockEditorSession?,
        noteID: NoteID
    ) -> BlockEditorSession? {
        guard let currentOwnerIdentity,
              currentOwnerIdentity.noteID == noteID,
              let current,
              current.ownerIdentity == currentOwnerIdentity,
              current.session.noteID == noteID
        else { return nil }
        return current.session
    }
}

/// Production Notes module host. Keeps one autosave coordinator and one
/// ViewModel for the module lifetime (AppShell host token).
@MainActor
struct NotesSplitView: View {
    let store: WorkspaceStore
    let focusRegistry: EditorFocusRegistry
    let transitionCoordinator: WorkspaceRouteTransitionCoordinator?
    @ObservedObject var deepLinkRouter: WorkspaceDeepLinkRouter
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    let searchIndex: WorkspaceSearchIndex
    let terminationCoordinator: NotesApplicationTerminationCoordinator?
    let clock: @Sendable () -> Date
    let decompositionPlanner: any DecompositionPlanning

    @State private var viewModel: NotesWorkspaceViewModel
    @State private var autosave: NoteAutosaveCoordinator
    @State private var closeBridge: NoteCloseProtectionBridge
    @State private var editorIdentity: NoteEditorIdentity?
    @State private var editorInitialFocus: NoteInitialFocus?
    @State private var nativeFinalizer: NoteNativeInputFinalizer?
    @State private var categoryManagerPresentation: CategoryManagerPresentation?
    @State private var browserCollapsed = false
    @State private var recoveryCandidate: DraftRecoveryCandidate?
    @State private var pendingImportPlan: NoteFileImportPlan?
    @State private var showsExportSheet = false
    @State private var statusBanner: String?
    @State private var ownedEditorSession: NotesOwnedBlockEditorSession?
    @State private var pendingPermanentDelete: PendingNotePermanentDelete?
    @State private var pendingNewNoteInputRequestID: UUID?
    @State private var availableWidth: CGFloat = .infinity
    @State private var recoveryUndoNotice: RecoveryUndoNotice?
    @State private var noteActionUndoNotice: NoteActionUndoNotice?
    @State private var browserLocation: NotesBrowserLocation = .all
    @State private var expandedBrowserLocations: Set<NotesBrowserLocation> = []
    @Environment(\.workspaceActiveRoute) private var activeWorkspaceRoute

    enum NotesAdaptiveLayoutMode: Equatable {
        case browserOnly
        case editorOnly
        case split
    }

    init(
        store: WorkspaceStore,
        focusRegistry: EditorFocusRegistry,
        transitionCoordinator: WorkspaceRouteTransitionCoordinator? = nil,
        deepLinkRouter: WorkspaceDeepLinkRouter = WorkspaceDeepLinkRouter(),
        newItemRouter: WorkspaceNewItemRouter = WorkspaceNewItemRouter(),
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex(),
        terminationCoordinator: NotesApplicationTerminationCoordinator? = nil,
        clock: @escaping @Sendable () -> Date = Date.init,
        decompositionPlanner: any DecompositionPlanning = UnavailableDecompositionPlanner(
            reason: .systemVersionUnsupported
        )
    ) {
        self.store = store
        self.focusRegistry = focusRegistry
        self.transitionCoordinator = transitionCoordinator
        self.deepLinkRouter = deepLinkRouter
        self.newItemRouter = newItemRouter
        self.searchIndex = searchIndex
        self.terminationCoordinator = terminationCoordinator
        self.clock = clock
        self.decompositionPlanner = decompositionPlanner
        let autosave = NoteAutosaveCoordinator(store: store)
        let viewModel = NotesWorkspaceViewModel(
            store: store,
            autosave: autosave,
            searchIndex: searchIndex,
            clock: clock
        )
        _autosave = State(initialValue: autosave)
        _viewModel = State(initialValue: viewModel)
        _closeBridge = State(initialValue: NoteCloseProtectionBridge(coordinator: autosave))
    }

    var body: some View {
        GeometryReader { proxy in
            notesContent(mode: NotesAdaptiveLayout.mode(
                width: proxy.size.width,
                browserCollapsed: browserCollapsed
            ))
            .onAppear { availableWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let recoveryUndoNotice {
                    HStack(spacing: 12) {
                        Label(recoveryUndoNotice.message, systemImage: "checkmark.circle.fill")
                        Button("撤销") {
                            Task { await undoRecoverySelection(recoveryUndoNotice) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                if let noteActionUndoNotice {
                    HStack(spacing: 12) {
                        Label(noteActionUndoNotice.message, systemImage: "archivebox.fill")
                        Button("撤销") {
                            Task { await undoNoteAction(noteActionUndoNotice) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                if let statusBanner {
                    Text(statusBanner)
                        .padding(8)
                        .background(.yellow.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.top, 8)
        }
        .sheet(item: $recoveryCandidate, onDismiss: {
            Task { @MainActor in
                await Task.yield()
                refreshRecoveryPresentation()
            }
        }) { candidate in
            DraftRecoverySheet(
                candidate: candidate,
                statusMessage: DraftRecoveryPresentation.statusMessage(for: store),
                isResolving: DraftRecoveryPresentation.isResolving(store),
                onRestoreAsCurrent: {
                    Task { await resolveRecovery(candidate, action: .restoreAsCurrent) }
                },
                onKeepPersisted: {
                    Task { await resolveRecovery(candidate, action: .keepPersisted) }
                },
                onSaveAsNew: {
                    Task {
                        let newID = NoteID()
                        let blockIDs = DraftRecoveryPresentation.replacementBlockIDs(
                            for: candidate.draft.document
                        )
                        await resolveRecovery(
                            candidate,
                            action: .saveAsNew(noteID: newID, blockIDs: blockIDs)
                        )
                    }
                }
            )
        }
        .sheet(item: $categoryManagerPresentation) { presentation in
            CategoryManagerView(
                store: store,
                initialCategoryID: presentation.initialCategoryID
            )
        }
        .sheet(item: $pendingImportPlan) { plan in
            NoteFileImportSheet(
                plan: plan,
                onCancel: { pendingImportPlan = nil },
                onImport: applyPendingImport
            )
        }
        .sheet(isPresented: $showsExportSheet) {
            NoteFileExportSheet(
                onCancel: { showsExportSheet = false },
                onExport: { format in
                    showsExportSheet = false
                    exportFile(format)
                }
            )
        }
        .confirmationDialog(
            "永久删除这篇笔记？",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                guard let request = pendingPermanentDelete else { return }
                pendingPermanentDelete = nil
                Task { await confirmPermanentDelete(request) }
            }
            Button("取消", role: .cancel) { pendingPermanentDelete = nil }
        } message: {
            if let request = pendingPermanentDelete {
                Text(request.preview.effects.isEmpty
                    ? "删除后无法恢复。"
                    : "删除后无法恢复，并会解除 \(request.preview.effects.count) 条关联。")
            }
        }
        .onAppear {
            registerRouteBridge()
            refreshRecoveryPresentation()
            consumeNoteDeepLink(deepLinkRouter.pendingRequest)
            consumeNoteNewItemRequest(newItemRouter.pendingRequest)
        }
        .onChange(of: editorIdentity) { _, _ in
            registerRouteBridge()
        }
        .onChange(of: store.statePublicationGeneration) { _, _ in
            if let notice = recoveryUndoNotice,
               notice.stateGeneration != store.statePublicationGeneration {
                recoveryUndoNotice = nil
            }
            refreshRecoveryPresentation()
            syncEditorNoteIfNeeded()
        }
        .onChange(of: store.phase) { _, _ in
            refreshRecoveryPresentation()
        }
        .onChange(of: deepLinkRouter.pendingRequest) { _, request in
            consumeNoteDeepLink(request)
        }
        .onChange(of: newItemRouter.pendingRequest) { _, request in
            consumeNoteNewItemRequest(request)
        }
        .onChange(of: activeWorkspaceRoute) { _, route in
            guard route != .notes else { return }
            categoryManagerPresentation = nil
            pendingImportPlan = nil
            showsExportSheet = false
            pendingPermanentDelete = nil
        }
        .background(NotesWindowCloseMonitor(bridge: closeBridge, finalizer: nativeFinalizer))
    }

    @ViewBuilder
    private func notesContent(mode: NotesAdaptiveLayoutMode) -> some View {
        switch mode {
        case .browserOnly:
            browserColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editorOnly:
            editorColumn(showsBrowserButton: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            HSplitView {
                browserColumn
                    .frame(minWidth: 248, idealWidth: 280, maxWidth: 340)
                editorColumn(showsBrowserButton: false)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var browserColumn: some View {
        NoteBrowserView(
            viewModel: viewModel,
            categories: sortedCategories,
            location: $browserLocation,
            expandedLocations: $expandedBrowserLocations,
            onSelect: { await selectNote($0) },
            onCreate: { await createNote(categoryID: $0) },
            onMoveToCategory: moveNote,
            onActivateLocation: activateBrowserLocation,
            onToggleBrowser: { browserCollapsed = true },
            onShowCategoryManager: { categoryID in
                categoryManagerPresentation = CategoryManagerPresentation(
                    initialCategoryID: categoryID
                )
            },
            noteCount: noteCount
        )
    }

    private func activateBrowserLocation(_ location: NotesBrowserLocation) async -> Bool {
        let selectionFallsOutsideLocation = viewModel.selectedNote.map { !location.contains($0) } ?? false
        if selectionFallsOutsideLocation {
            let decision = await closeBridge.decision(for: .selection, finalizer: nativeFinalizer)
            guard decision == .allow, await viewModel.clearSelection() else {
                statusBanner = "请先完成当前笔记的保存。"
                return false
            }
            editorInitialFocus = nil
            editorIdentity = nil
        }

        switch location {
        case .all, .archived:
            viewModel.categoryFilterID = nil
        case let .category(categoryID):
            viewModel.categoryFilterID = categoryID
        }
        statusBanner = nil
        return true
    }

    private func noteCount(at location: NotesBrowserLocation) -> Int {
        switch location {
        case .all:
            store.state.notes.values.filter { $0.archivedAt == nil }.count
        case let .category(categoryID):
            store.state.notes.values.filter { $0.archivedAt == nil && $0.categoryID == categoryID }.count
        case .archived:
            store.state.notes.values.filter { $0.archivedAt != nil }.count
        }
    }

    private func moveNote(_ noteID: NoteID, toCategoryID categoryID: UUID) async -> Bool {
        do {
            let moved = try await viewModel.move(noteID, toCategoryID: categoryID)
            if moved {
                statusBanner = "笔记已移动到“\(store.calendarState.categories[categoryID]?.name ?? "分类")”。"
            }
            return moved
        } catch {
            statusBanner = "移动笔记未完成，请重试。"
            return false
        }
    }

    @ViewBuilder
    private func editorColumn(showsBrowserButton: Bool) -> some View {
        if let identity = editorIdentity, let note = store.state.notes[identity.noteID] {
            NoteEditorView(
                identity: identity,
                initialFocus: editorInitialFocus,
                note: note,
                focusRegistry: focusRegistry,
                autosave: autosave,
                store: store,
                categories: sortedCategories,
                onDocumentCommitted: { _ in recoveryUndoNotice = nil },
                onTitleCommitted: { _ in recoveryUndoNotice = nil },
                onCategoryChanged: { categoryID in
                    recoveryUndoNotice = nil
                    _ = try? autosave.update(categoryID: categoryID)
                },
                onRequestMarkdownImport: importFile,
                onRequestMarkdownExport: presentExportOptions,
                onArchive: { Task { await archiveSelected() } },
                onRestore: { Task { await restoreSelected() } },
                onPermanentDelete: requestPermanentDeleteSelected,
                onOpenCalendarItem: openCalendarItem,
                onOpenCalendarTarget: openCalendarTarget,
                showsBrowserButton: showsBrowserButton,
                onToggleBrowser: { browserCollapsed = false },
                sessionSink: { session in
                    ownedEditorSession = NotesLiveEditorSessionRouting.receive(
                        ownerIdentity: identity,
                        currentOwnerIdentity: editorIdentity,
                        current: ownedEditorSession,
                        incoming: session
                    )
                },
                nativeFinalizerHook: $nativeFinalizer,
                onInitialFocusApplied: {
                    guard initialFocusIsTitle,
                          let requestID = pendingNewNoteInputRequestID
                    else { return }
                    pendingNewNoteInputRequestID = nil
                    newItemRouter.deliverCapturedTyping(for: requestID)
                },
                decompositionPlanner: decompositionPlanner
            )
            .id(identity)
        } else {
            VStack(spacing: 0) {
                if showsBrowserButton {
                    HStack {
                        Button { browserCollapsed = false } label: {
                            Image(systemName: "sidebar.left")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("显示笔记列表")
                        .accessibilityLabel("显示笔记列表")
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(height: CalendarTheme.toolbarHeight)
                }
                ContentUnavailableView(
                    "选择或新建笔记",
                    systemImage: "note.text",
                    description: Text("打开笔记列表进行选择，或新建一篇笔记。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sortedCategories: [CalendarCategory] {
        Array(store.calendarState.categories.values).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var initialFocusIsTitle: Bool {
        editorInitialFocus == .title
    }

    private func registerRouteBridge() {
        transitionCoordinator?.attachNotesCloseBridge(closeBridge, finalizer: nativeFinalizer)
        terminationCoordinator?.updateDecision {
            await closeBridge.decision(for: .termination, finalizer: nativeFinalizer)
        }
    }

    private func selectNote(_ noteID: NoteID, initialFocus: NoteInitialFocus? = nil) async {
        let decision = await closeBridge.decision(for: .selection, finalizer: nativeFinalizer)
        guard decision == .allow else {
            statusBanner = "请先完成当前笔记的保存。"
            return
        }
        let sessionID = UUID()
        let host = UUID()
        guard (try? await viewModel.select(noteID, editSessionID: sessionID, activeHostToken: host)) == true else {
            return
        }
        editorInitialFocus = initialFocus
        editorIdentity = .init(noteID: noteID, editSessionID: sessionID)
        if NotesAdaptiveLayout.isCompact(width: availableWidth) { browserCollapsed = true }
        statusBanner = nil
    }

    private func openCalendarItem(_ itemID: UUID) {
        openCalendarTarget(.calendarItem(itemID))
    }

    private func openCalendarTarget(_ target: WorkspaceDeepLinkTarget) {
        guard let transitionCoordinator else { return }
        Task {
            guard await transitionCoordinator.requestActivation(.calendar) else { return }
            deepLinkRouter.request(target)
        }
    }

    private func consumeNoteDeepLink(_ request: WorkspaceDeepLinkRequest?) {
        guard let request,
              case let .note(noteID) = request.target,
              store.state.notes[noteID] != nil,
              deepLinkRouter.consume(request.id, target: request.target) != nil else { return }
        Task { await selectNote(noteID, initialFocus: .bodyStart) }
    }

    private func consumeNoteNewItemRequest(_ request: WorkspaceNewItemRequest?) {
        guard let request,
              request.route == .notes,
              newItemRouter.consume(request.id, route: .notes) != nil else { return }
        Task { await createNote(inputRequestID: request.id) }
    }

    private func createNote(inputRequestID: UUID? = nil, categoryID: UUID? = nil) async {
        if case let .presentRecovery(candidate) = NotesNewItemAdmission.decision(for: store) {
            if let inputRequestID { newItemRouter.discardCapturedTyping(for: inputRequestID) }
            recoveryCandidate = candidate
            statusBanner = "请先处理待恢复草稿，再新建笔记。"
            return
        }
        let decision = await closeBridge.decision(for: .selection, finalizer: nativeFinalizer)
        guard decision == .allow else {
            if let inputRequestID { newItemRouter.cancelCapturedTyping(for: inputRequestID) }
            statusBanner = "请先完成当前笔记的保存。"
            return
        }
        let resolvedCategoryID = NotesNewItemCategoryPolicy.resolve(
            explicitCategoryID: categoryID,
            currentCategoryFilterID: viewModel.categoryFilterID,
            calendarState: store.calendarState
        )
        let note = Note.empty(id: NoteID(), categoryID: resolvedCategoryID, now: clock())
        let created: Bool
        do {
            created = try await viewModel.create(note)
        } catch {
            created = false
        }
        guard created else {
            if let inputRequestID { newItemRouter.cancelCapturedTyping(for: inputRequestID) }
            statusBanner = "新建笔记未完成，请重试。"
            return
        }
        statusBanner = nil
        if let selected = viewModel.selectedNoteID {
            pendingNewNoteInputRequestID = inputRequestID
            editorInitialFocus = .title
            editorIdentity = .init(noteID: selected, editSessionID: UUID())
            if NotesAdaptiveLayout.isCompact(width: availableWidth) { browserCollapsed = true }
            if let created = store.state.notes[selected] {
                try? autosave.beginSession(
                    created,
                    linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == selected }),
                    editSessionID: editorIdentity!.editSessionID,
                    activeHostToken: UUID()
                )
            }
        }
    }

    private func archiveSelected() async {
        guard let noteID = viewModel.selectedNoteID else { return }
        let decision = await closeBridge.decision(for: .archive, finalizer: nativeFinalizer)
        guard decision == .allow else {
            statusBanner = "归档前需要完成主文件保存。"
            return
        }
        guard (try? await viewModel.archive(noteID)) == true else {
            statusBanner = "归档笔记未完成。"
            return
        }
        if let selected = viewModel.selectedNoteID {
            editorInitialFocus = nil
            editorIdentity = .init(noteID: selected, editSessionID: UUID())
        } else {
            editorInitialFocus = nil
            editorIdentity = nil
        }
        noteActionUndoNotice = NoteActionUndoNotice(
            message: "笔记已归档",
            noteID: noteID,
            stateGeneration: store.statePublicationGeneration
        )
    }

    private func undoNoteAction(_ notice: NoteActionUndoNotice) async {
        guard noteActionUndoNotice == notice,
              store.statePublicationGeneration == notice.stateGeneration else {
            noteActionUndoNotice = nil
            statusBanner = "内容已经继续变化，无法撤销这次归档。"
            return
        }
        do {
            _ = try await store.undo()
            viewModel.refreshBrowser()
            noteActionUndoNotice = nil
            await selectNote(notice.noteID)
        } catch {
            noteActionUndoNotice = nil
            statusBanner = "撤销归档未完成。"
        }
    }

    private func restoreSelected() async {
        guard let noteID = viewModel.selectedNoteID else { return }
        do {
            _ = try await viewModel.restore(noteID)
            if let selected = viewModel.selectedNoteID {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: selected, editSessionID: UUID())
            }
        } catch {
            statusBanner = "恢复笔记未完成。"
        }
    }

    private func requestPermanentDeleteSelected() {
        guard let noteID = viewModel.selectedNoteID else { return }
        do {
            let preview = try viewModel.permanentDeletePreview(for: noteID)
            pendingPermanentDelete = .init(noteID: noteID, preview: preview)
        } catch {
            statusBanner = "无法生成删除影响预览。"
        }
    }

    private func confirmPermanentDelete(_ request: PendingNotePermanentDelete) async {
        do {
            let authorization = PermanentDeleteAuthorization(
                subject: request.preview.subject,
                sourceWorkspaceRevision: request.preview.sourceWorkspaceRevision,
                impactChecksum: request.preview.checksum
            )
            _ = try await viewModel.permanentlyDelete(request.noteID, authorization: authorization)
            if let selected = viewModel.selectedNoteID {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: selected, editSessionID: UUID())
            } else {
                editorInitialFocus = nil
                editorIdentity = nil
            }
        } catch {
            statusBanner = "永久删除未完成。"
        }
    }

    private func resolveRecovery(
        _ candidate: DraftRecoveryCandidate,
        action: DraftRecoveryAction
    ) async {
        do {
            _ = try await store.resolveDraftRecovery(candidate.token, action: action)
            recoveryCandidate = nil
            if store.canUndoRecoverySelection {
                let notice = RecoveryUndoNotice(
                    message: recoveryResolutionMessage(for: action),
                    stateGeneration: store.statePublicationGeneration
                )
                recoveryUndoNotice = notice
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(12))
                    if recoveryUndoNotice == notice { recoveryUndoNotice = nil }
                }
            }
            // Recovery and save-as-new always create a new editor key.
            if case let .saveAsNew(noteID, _) = action {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: noteID, editSessionID: UUID())
            } else if let noteID = viewModel.selectedNoteID ?? store.state.notes.keys.first {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: noteID, editSessionID: UUID())
            }
        } catch {
            statusBanner = "草稿恢复操作已过期，请重新选择。"
            refreshRecoveryPresentation()
        }
    }

    private func recoveryResolutionMessage(for action: DraftRecoveryAction) -> String {
        switch action {
        case .keepPersisted: "已保留当前笔记，可撤销改用退出前版本"
        case .restoreAsCurrent: "已改用退出前版本，可撤销回当前笔记"
        case .saveAsNew: "两个版本都已保留，可撤销新建副本"
        }
    }

    private func undoRecoverySelection(_ notice: RecoveryUndoNotice) async {
        guard recoveryUndoNotice == notice,
              notice.stateGeneration == store.statePublicationGeneration,
              store.canUndoRecoverySelection else {
            recoveryUndoNotice = nil
            statusBanner = "内容已经继续变化，无法再撤销这次恢复选择。"
            return
        }
        do {
            let replacement = try await NotesRecoverySelectionUndo.perform(
                store: store,
                autosave: autosave,
                preferredNoteID: viewModel.selectedNoteID
            )
            editorInitialFocus = nil
            editorIdentity = replacement
            recoveryUndoNotice = nil
            statusBanner = "已撤销恢复选择。"
        } catch {
            recoveryUndoNotice = nil
            statusBanner = "撤销恢复选择未完成。"
        }
    }

    private func refreshRecoveryPresentation() {
        recoveryCandidate = DraftRecoveryPresentation.candidates(from: store).first
    }

    private func syncEditorNoteIfNeeded() {
        guard let identity = editorIdentity else { return }
        guard let note = store.state.notes[identity.noteID] else {
            editorInitialFocus = nil
            editorIdentity = nil
            return
        }
        guard let activeEditorSession = NotesLiveEditorSessionRouting.matchingSession(
            currentOwnerIdentity: identity,
            current: ownedEditorSession,
            noteID: identity.noteID
        ),
              activeEditorSession.document != note.document,
              autosave.canReplaceSessionWithPersistedStoreSnapshot
        else { return }
        // A route transition has already sealed native input and proved the
        // current editor generation. Re-keying avoids stale undo/autosave
        // bases after Calendar changes the same Task Block document.
        let replacement = NoteEditorIdentity(noteID: note.id, editSessionID: UUID())
        do {
            try autosave.beginSession(
                note,
                linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == note.id }),
                editSessionID: replacement.editSessionID,
                activeHostToken: UUID()
            )
            editorInitialFocus = nil
            editorIdentity = replacement
            statusBanner = nil
        } catch {
            statusBanner = "笔记已在其他页面更新，请完成当前输入后重试。"
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "导入笔记内容"
        panel.message = "选择 Markdown 或 HTML 文件。"
        panel.allowedContentTypes = ["md", "markdown", "html", "htm"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    guard let format = NoteFileFormat.detect(from: url) else {
                        statusBanner = "请选择 Markdown 或 HTML 文件。"
                        return
                    }
                    let contents = try String(contentsOf: url, encoding: .utf8)
                    let plan = try NoteFileCommands.planImport(
                        contents: contents,
                        format: format,
                        fileName: url.lastPathComponent,
                        mode: .replace,
                        checkedTaskCompletedAt: clock()
                    )
                    pendingImportPlan = plan
                } catch {
                    statusBanner = "无法读取这个文件，请确认它是 UTF-8 编码的 Markdown 或 HTML。"
                }
            }
        }
    }

    private func applyPendingImport(_ mode: BlockDocumentIngestMode) {
        guard let plan = pendingImportPlan else { return }
        pendingImportPlan = nil
        guard let selectedNote = viewModel.selectedNote,
              let session = NotesLiveEditorSessionRouting.matchingSession(
                currentOwnerIdentity: editorIdentity,
                current: ownedEditorSession,
                noteID: selectedNote.id
              ) else {
            // Fall back through autosave document update when session sink not yet wired.
            let document = plan.result.document
            switch mode {
            case .replace:
                _ = try? autosave.update(document: document)
            case .append:
                if let current = viewModel.selectedNote?.document {
                    let merged = BlockDocument(
                        schemaVersion: current.schemaVersion,
                        blocks: current.blocks + document.blocks
                    )
                    _ = try? autosave.update(document: merged)
                } else {
                    _ = try? autosave.update(document: document)
                }
            }
            statusBanner = plan.result.diagnostics.isEmpty
                ? "已导入 \(plan.format.displayName) 内容。"
                : "已导入；部分内容已转换为正文。"
            return
        }
        do {
            _ = try session.dispatch(.applyDocumentBlocks(blocks: plan.result.document.blocks, mode: mode))
            statusBanner = plan.result.diagnostics.isEmpty
                ? "已导入 \(plan.format.displayName) 内容。"
                : "已导入；部分内容已转换为正文。"
        } catch {
            statusBanner = "导入被拒绝：文档或 ID 无效。"
        }
    }

    private func presentExportOptions() {
        guard viewModel.selectedNote != nil else { return }
        showsExportSheet = true
    }

    private func exportFile(_ format: NoteFileFormat) {
        guard let note = viewModel.selectedNote else { return }
        let matchingSession = NotesLiveEditorSessionRouting.matchingSession(
            currentOwnerIdentity: editorIdentity,
            current: ownedEditorSession,
            noteID: note.id
        )
        guard matchingSession?.terminallyFinalizeNativeComposition() != false else {
            statusBanner = "请先完成当前输入，再导出笔记。"
            return
        }
        let liveSnapshot = matchingSession.map {
            NoteMarkdownLiveSnapshot(
                noteID: $0.noteID,
                editSessionID: $0.editSessionID,
                document: $0.document
            )
        }
        let document = NoteMarkdownExportSource.document(
            persistedNoteID: note.id,
            persistedDocument: note.document,
            editorIdentity: editorIdentity,
            liveSnapshot: liveSnapshot
        )
        let contents: String
        do {
            contents = try NoteFileCommands.export(
                document,
                format: format,
                title: note.title.isEmpty ? "未命名笔记" : note.title
            )
        } catch {
            statusBanner = "导出失败。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出为 \(format.displayName)"
        panel.message = format.exportDescription
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension)].compactMap { $0 }
        panel.nameFieldStringValue = (note.title.isEmpty ? "未命名笔记" : note.title) + ".\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try NoteFileCommands.writeExport(contents: contents, to: url)
                    statusBanner = "已导出为 \(format.displayName)。"
                } catch {
                    statusBanner = "导出失败。"
                }
            }
        }
    }
}

enum NotesAdaptiveLayout {
    static let compactThreshold: CGFloat = 760

    static func isCompact(width: CGFloat) -> Bool {
        width < compactThreshold
    }

    static func mode(
        width: CGFloat,
        browserCollapsed: Bool
    ) -> NotesSplitView.NotesAdaptiveLayoutMode {
        if browserCollapsed { return .editorOnly }
        return isCompact(width: width) ? .browserOnly : .split
    }
}

extension DraftRecoveryCandidate: Identifiable {
    var id: DraftRecoveryToken { token }
}

private struct PendingNotePermanentDelete {
    let noteID: NoteID
    let preview: PermanentDeletePreview
}
