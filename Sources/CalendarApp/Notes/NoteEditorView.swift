import AppKit
import CalendarDomain
import SwiftUI
import WorkspaceDomain

typealias DecompositionWorkbenchCommitHandler = @MainActor (DecompositionCommitResult) -> Void

struct NoteEditorIdentity: Hashable, Sendable {
    let noteID: NoteID
    let editSessionID: UUID
}

enum NoteInitialFocus: Equatable, Sendable {
    case title
    case bodyStart
}

enum NoteEditorLayout {
    static let maximumContentWidth: CGFloat = 720
    static let horizontalSafetyMargin: CGFloat = 28
    static let bodyPointSize: CGFloat = 16
    static let verticalContentPadding: CGFloat = 40

    static func blockEditorMinimumHeight(for viewportHeight: CGFloat) -> CGFloat {
        max(80, viewportHeight - verticalContentPadding)
    }
}

internal struct NoteWorkbenchNotice: Equatable {
    let message: String
    let stateGeneration: UInt
}

/// Right-hand Notes editor surface. Ordinary Store publications keep the same
/// `EditorKey`; selection changes and recovery/save-as-new mint a new one.
struct NoteEditorView: View {
    private struct FocusedTaskScheduleRequest: Identifiable {
        let id = UUID()
        let blockID: BlockID
    }

    private struct ScheduleNotice: Equatable {
        let itemID: UUID
        let message: String
        let stateGeneration: UInt
    }

    /// Child editor identity plus the document it must be created with.
    /// One value so a workbench rebuild cannot mint a new session ID against a stale document.
    private struct EditorMount: Equatable {
        let editSessionID: UUID
        let initialDocument: BlockDocument
    }

    struct DecompositionWorkbenchRequest: Identifiable {
        let id = UUID()
        let snapshot: DecompositionSourceSnapshot
        let model: DecompositionWorkbenchModel
    }
    let identity: NoteEditorIdentity
    let initialFocus: NoteInitialFocus?
    let note: Note
    let focusRegistry: EditorFocusRegistry
    let autosave: NoteAutosaveCoordinator
    let store: WorkspaceStore
    let categories: [CalendarCategory]
    var onDocumentCommitted: (BlockDocument) -> Void
    var onTitleCommitted: (String) -> Void
    var onCategoryChanged: (UUID) -> Void
    var onRequestMarkdownImport: () -> Void
    var onRequestMarkdownExport: () -> Void
    var onArchive: () -> Void
    var onRestore: () -> Void
    var onPermanentDelete: () -> Void
    var onOpenCalendarItem: (UUID) -> Void
    var onOpenCalendarTarget: (WorkspaceDeepLinkTarget) -> Void
    var showsBrowserButton: Bool
    var onToggleBrowser: () -> Void
    var sessionSink: (BlockEditorSession?) -> Void
    var nativeFinalizerHook: Binding<NoteNativeInputFinalizer?>
    var onInitialFocusApplied: () -> Void
    var decompositionPlanner: any DecompositionPlanning
    var onWorkbenchSnapshotChange: (DecompositionSourceSnapshot?) -> Void
    var onWorkbenchEntryNoticeChange: (String?) -> Void
    var onWorkbenchModelChange: (DecompositionWorkbenchModel?) -> Void
    var onWorkbenchFeedbackChange: (String?, UInt?) -> Void
    var onWorkbenchCommitHandlerChange: (DecompositionWorkbenchCommitHandler?) -> Void
    var workbenchNotice: Binding<NoteWorkbenchNotice?>?

    @State private var title: String
    @State private var titleOwnerID = UUID()
    @State private var titleCoordinator: NoteTitleTextField.Coordinator?
    @State private var editorSession: BlockEditorSession?
    @State private var showCalendarLinks = false
    @State private var showScheduleSheet = false
    @State private var lastAcceptedDocument: BlockDocument
    @State private var editorMount: EditorMount
    @State private var pendingLinkedTaskDeletion: PendingLinkedTaskDeletion?
    @State private var didApplyInitialFocus = false
    @State private var scheduleNotice: ScheduleNotice?
    @State private var focusedTaskScheduleRequest: FocusedTaskScheduleRequest?
    @State private var decompositionRequest: DecompositionWorkbenchRequest?
    @State private var workbenchModel: DecompositionWorkbenchModel?
    @State private var localWorkbenchNotice: NoteWorkbenchNotice?
    @State private var entryNotice: String?
    @State private var isOpeningWorkbench = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspaceActiveRoute) private var activeWorkspaceRoute

    private var activeWorkbenchNotice: NoteWorkbenchNotice? {
        get {
            if let workbenchNotice {
                return workbenchNotice.wrappedValue
            }
            return localWorkbenchNotice
        }
        nonmutating set {
            if let workbenchNotice {
                workbenchNotice.wrappedValue = newValue
            } else {
                localWorkbenchNotice = newValue
            }
        }
    }

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var activeEditSessionID: UUID { editorMount.editSessionID }

    private var ownsCurrentAutosaveSession: Bool {
        guard let current = autosave.currentEditSessionID else { return false }
        return current == identity.editSessionID || current == editorMount.editSessionID
    }

    private func sessionBelongsToThisEditor(_ session: BlockEditorSession) -> Bool {
        session.editSessionID == editorMount.editSessionID
    }

    init(
        identity: NoteEditorIdentity,
        initialFocus: NoteInitialFocus? = nil,
        note: Note,
        focusRegistry: EditorFocusRegistry,
        autosave: NoteAutosaveCoordinator,
        store: WorkspaceStore,
        categories: [CalendarCategory],
        onDocumentCommitted: @escaping (BlockDocument) -> Void,
        onTitleCommitted: @escaping (String) -> Void,
        onCategoryChanged: @escaping (UUID) -> Void,
        onRequestMarkdownImport: @escaping () -> Void,
        onRequestMarkdownExport: @escaping () -> Void,
        onArchive: @escaping () -> Void = {},
        onRestore: @escaping () -> Void = {},
        onPermanentDelete: @escaping () -> Void = {},
        onOpenCalendarItem: @escaping (UUID) -> Void = { _ in },
        onOpenCalendarTarget: @escaping (WorkspaceDeepLinkTarget) -> Void = { _ in },
        showsBrowserButton: Bool = false,
        onToggleBrowser: @escaping () -> Void = {},
        sessionSink: @escaping (BlockEditorSession?) -> Void,
        nativeFinalizerHook: Binding<NoteNativeInputFinalizer?>,
        onInitialFocusApplied: @escaping () -> Void = {},
        decompositionPlanner: any DecompositionPlanning = UnavailableDecompositionPlanner(
            reason: .systemVersionUnsupported
        ),
        onWorkbenchSnapshotChange: @escaping (DecompositionSourceSnapshot?) -> Void = { _ in },
        onWorkbenchEntryNoticeChange: @escaping (String?) -> Void = { _ in },
        onWorkbenchModelChange: @escaping (DecompositionWorkbenchModel?) -> Void = { _ in },
        onWorkbenchFeedbackChange: @escaping (String?, UInt?) -> Void = { _, _ in },
        onWorkbenchCommitHandlerChange: @escaping (DecompositionWorkbenchCommitHandler?) -> Void = { _ in },
        workbenchNotice: Binding<NoteWorkbenchNotice?>? = nil
    ) {
        self.identity = identity
        self.initialFocus = initialFocus
        self.note = note
        self.focusRegistry = focusRegistry
        self.autosave = autosave
        self.store = store
        self.categories = categories
        self.onDocumentCommitted = onDocumentCommitted
        self.onTitleCommitted = onTitleCommitted
        self.onCategoryChanged = onCategoryChanged
        self.onRequestMarkdownImport = onRequestMarkdownImport
        self.onRequestMarkdownExport = onRequestMarkdownExport
        self.onArchive = onArchive
        self.onRestore = onRestore
        self.onPermanentDelete = onPermanentDelete
        self.onOpenCalendarItem = onOpenCalendarItem
        self.onOpenCalendarTarget = onOpenCalendarTarget
        self.showsBrowserButton = showsBrowserButton
        self.onToggleBrowser = onToggleBrowser
        self.sessionSink = sessionSink
        self.nativeFinalizerHook = nativeFinalizerHook
        self.onInitialFocusApplied = onInitialFocusApplied
        self.decompositionPlanner = decompositionPlanner
        self.onWorkbenchSnapshotChange = onWorkbenchSnapshotChange
        self.onWorkbenchEntryNoticeChange = onWorkbenchEntryNoticeChange
        self.onWorkbenchModelChange = onWorkbenchModelChange
        self.onWorkbenchFeedbackChange = onWorkbenchFeedbackChange
        self.onWorkbenchCommitHandlerChange = onWorkbenchCommitHandlerChange
        self.workbenchNotice = workbenchNotice
        _title = State(initialValue: note.title)
        _lastAcceptedDocument = State(initialValue: note.document)
        _editorMount = State(initialValue: EditorMount(
            editSessionID: identity.editSessionID,
            initialDocument: note.document
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if showsBrowserButton {
                    Button(action: onToggleBrowser) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .help("显示笔记列表")
                    .accessibilityLabel("显示笔记列表")
                }
                NoteTitleTextField(
                    title: $title,
                    focusRegistry: focusRegistry,
                    ownerID: titleOwnerID,
                    onCommit: { value in
                        title = value
                        onTitleCommitted(value)
                    },
                    onEditingChanged: { value in
                        guard ownsCurrentAutosaveSession else { return }
                        invalidateWorkbenchUndoForLocalEdit()
                        title = value
                        _ = try? autosave.update(title: value)
                    },
                    onReturn: { editorSession?.focusDocumentStart() },
                    coordinatorSink: { coordinator in
                        titleCoordinator = coordinator
                        installNativeFinalizer()
                        applyInitialFocusIfReady()
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("导入文件…", action: onRequestMarkdownImport)
                    Button("导出笔记…", action: onRequestMarkdownExport)
                    Divider()
                    if note.archivedAt == nil {
                        Button("归档", action: onArchive)
                    } else {
                        Button("恢复", action: onRestore)
                        Button("永久删除…", role: .destructive, action: onPermanentDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("笔记更多操作")
            }
            .padding(.horizontal, 20)
            .frame(height: CalendarTheme.toolbarHeight)

            HStack(spacing: 8) {
                Picker("分类", selection: Binding(
                    get: { note.categoryID },
                    set: {
                        invalidateWorkbenchUndoForLocalEdit()
                        onCategoryChanged($0)
                    }
                )) {
                    ForEach(categories, id: \.id) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180, alignment: .leading)
                .accessibilityLabel("笔记分类")

                Spacer(minLength: 12)

                DecompositionIdentifiedButton(
                    title: "拆开并安排",
                    identifier: "notes-plan-and-schedule",
                    accessibilityName: "拆开并安排",
                    helpText: "把这篇笔记或选中的文字拆成可安排的行动",
                    enabled: !isOpeningWorkbench && decompositionRequest == nil,
                    isBordered: true
                ) {
                    Task { @MainActor in
                        await presentDecompositionWorkbench()
                    }
                }
                .frame(minWidth: 88, minHeight: 22)
                .fixedSize()

                Button("安排这篇笔记…") { showScheduleSheet = true }
                    .accessibilityLabel("安排这篇笔记到日历")

                if calendarArrangementCount > 0 {
                    Button("日历安排 · \(calendarArrangementCount)") { showCalendarLinks = true }
                    .popover(isPresented: $showCalendarLinks) {
                        NoteCalendarLinksPopover(
                            store: store,
                            noteID: identity.noteID,
                            onOpenTarget: onOpenCalendarTarget
                        )
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
            }

            if let status = autosave.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(status)
            }
            if let entryNotice {
                Text(entryNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.error)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .accessibilityLabel(entryNotice)
            }

            GeometryReader { viewport in
                ScrollView {
                    let mount = editorMount
                    BlockEditorView(
                        noteID: identity.noteID,
                        editSessionID: mount.editSessionID,
                        initialDocument: mount.initialDocument,
                        initialSelection: defaultSelection(in: mount.initialDocument),
                        focusRegistry: focusRegistry,
                        onDocumentChange: { [sessionID = mount.editSessionID] document in
                            handleDocumentChange(document, originatingEditSessionID: sessionID)
                        },
                        sessionSink: { session in
                            guard sessionBelongsToThisEditor(session) else { return }
                            editorSession = session
                            sessionSink(session)
                            guard ownsCurrentAutosaveSession else { return }
                            installNativeFinalizer()
                            applyInitialFocusIfReady()
                        }
                    )
                    .frame(
                        maxWidth: NoteEditorLayout.maximumContentWidth,
                        minHeight: NoteEditorLayout.blockEditorMinimumHeight(for: viewport.size.height),
                        alignment: .topLeading
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, NoteEditorLayout.horizontalSafetyMargin)
                    .padding(.vertical, 20)
                }
            }

            HStack(spacing: 8) {
                BlockFormattingBar(session: editorSession)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let editorSession {
                    NoteEditorTaskCalendarAction(
                        session: editorSession,
                        store: store,
                        noteID: identity.noteID,
                        onSchedule: { blockID in
                            focusedTaskScheduleRequest = .init(blockID: blockID)
                        },
                        onUnlink: { blockID in
                            Task { await unlinkTaskBlockFromCalendar(blockID) }
                        },
                        onOpenItem: onOpenCalendarItem
                    )
                    .padding(.trailing, 12)
                }
            }
            .background(theme.elevatedSurface)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
            }
        }
        .overlay(alignment: .top) {
            if let scheduleNotice {
                HStack(spacing: 10) {
                    Label(scheduleNotice.message, systemImage: "calendar.badge.checkmark")
                    Button("打开日历") {
                        self.scheduleNotice = nil
                        onOpenCalendarItem(scheduleNotice.itemID)
                    }
                    Button("撤销") {
                        Task { await undoScheduledItem(scheduleNotice) }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.top, 8)
            }
            if let notice = activeWorkbenchNotice {
                HStack(spacing: 10) {
                    NoteWorkbenchFeedbackText(
                        message: notice.message,
                        identifier: "notes-workbench-feedback"
                    )
                    .fixedSize()
                    if store.statePublicationGeneration == notice.stateGeneration {
                        DecompositionIdentifiedButton(
                            title: "撤销",
                            identifier: "notes-workbench-undo",
                            accessibilityName: "撤销本次拆开并安排",
                            helpText: "只撤销本次创建的行动和日历安排",
                            enabled: true
                        ) {
                            Task { await undoWorkbench(notice) }
                        }
                        .frame(minWidth: 44, minHeight: 22)
                        .fixedSize()
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.top, scheduleNotice == nil ? 8 : 52)
            }
        }
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .sheet(isPresented: $showScheduleSheet) {
            NoteScheduleSheet(
                store: store,
                noteID: identity.noteID,
                onCancel: { showScheduleSheet = false },
                onScheduled: { itemID in
                    showScheduleSheet = false
                    guard let item = store.calendarState.items[itemID] else { return }
                    scheduleNotice = ScheduleNotice(
                        itemID: itemID,
                        message: "已创建 \(item.schedule.startDate.month) 月 \(item.schedule.startDate.day) 日全天事项",
                        stateGeneration: store.statePublicationGeneration
                    )
                }
            )
        }
        .sheet(item: $focusedTaskScheduleRequest) { request in
            TaskBlockScheduleSheet(
                store: store,
                noteID: identity.noteID,
                blockID: request.blockID,
                now: Date(),
                prepareForMutation: prepareForTaskCalendarMutation,
                onCancel: { focusedTaskScheduleRequest = nil },
                onScheduled: {
                    rebaseAutosaveAfterTaskCalendarMutation()
                    focusedTaskScheduleRequest = nil
                }
            )
        }
        .sheet(item: $decompositionRequest) { request in
            DecompositionWorkbenchSessionView(
                model: request.model,
                onCancel: { decompositionRequest = nil },
                onCommitted: { result in
                    handleWorkbenchCommitted(result)
                }
            )
            .frame(
                minWidth: DecompositionWorkbenchMetrics.minimumSize.width,
                idealWidth: DecompositionWorkbenchMetrics.targetSize.width,
                maxWidth: DecompositionWorkbenchMetrics.targetSize.width,
                minHeight: DecompositionWorkbenchMetrics.minimumSize.height,
                idealHeight: DecompositionWorkbenchMetrics.targetSize.height,
                maxHeight: DecompositionWorkbenchMetrics.targetSize.height
            )
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("拆开并安排")
        }
        .onChange(of: decompositionRequest?.id) { _, newID in
            guard newID == nil else { return }
            workbenchModel?.cancelRequest()
            workbenchModel = nil
            onWorkbenchModelChange(nil)
            onWorkbenchSnapshotChange(nil)
            onWorkbenchCommitHandlerChange(nil)
        }
        .confirmationDialog(
            "删除已关联待办？",
            isPresented: Binding(
                get: { pendingLinkedTaskDeletion != nil },
                set: { if !$0 { cancelLinkedTaskDeletion() } }
            ),
            titleVisibility: .visible
        ) {
            Button("保留独立日历事项") {
                confirmLinkedTaskDeletion(.keepCalendarItem)
            }
            Button("一起删除", role: .destructive) {
                confirmLinkedTaskDeletion(.deleteCalendarItem)
            }
            Button("取消", role: .cancel) {
                cancelLinkedTaskDeletion()
            }
        } message: {
            let count = pendingLinkedTaskDeletion?.blockIDs.count ?? 0
            Text(count > 1
                ? "这次删除包含 \(count) 个已关联待办。请选择对应日历事项的处理方式。"
                : "这个待办已关联日历事项。请选择日历事项的处理方式。")
        }
        .onAppear {
            installNativeFinalizer()
            applyInitialFocusIfReady()
            Task { @MainActor in
                await Task.yield()
                applyInitialFocusIfReady()
            }
        }
        .onChange(of: identity) { oldIdentity, newIdentity in
            let mountedDocument = note.document
            editorMount = EditorMount(
                editSessionID: newIdentity.editSessionID,
                initialDocument: mountedDocument
            )
            lastAcceptedDocument = mountedDocument
            title = note.title
            entryNotice = nil
            if oldIdentity.noteID != newIdentity.noteID {
                activeWorkbenchNotice = nil
            }
            installNativeFinalizer()
        }
        .onChange(of: store.statePublicationGeneration) { _, generation in
            guard let notice = activeWorkbenchNotice, notice.stateGeneration != generation else { return }
            activeWorkbenchNotice = nil
            onWorkbenchFeedbackChange(nil, nil)
        }
        .onChange(of: activeWorkspaceRoute) { _, route in
            guard route != .notes else { return }
            showCalendarLinks = false
            showScheduleSheet = false
            focusedTaskScheduleRequest = nil
            workbenchModel?.cancelRequest()
            decompositionRequest = nil
            onWorkbenchCommitHandlerChange(nil)
        }
        .onDisappear {
            workbenchModel?.cancelRequest()
            onWorkbenchCommitHandlerChange(nil)
            guard ownsCurrentAutosaveSession else { return }
            sessionSink(nil)
            nativeFinalizerHook.wrappedValue = nil
        }
    }

    private var calendarArrangementCount: Int {
        NoteCalendarArrangementProjection.make(noteID: identity.noteID, state: store.state).count
    }

    private func presentDecompositionWorkbench() async {
        guard !isOpeningWorkbench, decompositionRequest == nil else { return }
        isOpeningWorkbench = true
        defer { isOpeningWorkbench = false }
        let flushEvidence = await autosave.flushLatest(finalizer: nativeFinalizerHook.wrappedValue)
        switch flushEvidence {
        case .clean, .persisted:
            break
        case .protectedOnly:
            publishEntryNotice("请先完成当前笔记的保存，再拆开并安排。")
            onWorkbenchSnapshotChange(nil)
            return
        case .unsafeLatestUnprotected:
            publishEntryNotice("这次修改还没有安全保存，请先处理保存问题，再拆开并安排。")
            onWorkbenchSnapshotChange(nil)
            return
        }
        guard await canCapturePersistedWorkbenchSnapshot(afterFlush: flushEvidence) else {
            publishEntryNotice("内容已保存，但保存清理尚未完成，请重试保存后再拆开并安排。")
            onWorkbenchSnapshotChange(nil)
            return
        }
        guard let persisted = store.state.notes[identity.noteID] else {
            publishEntryNotice("找不到这篇笔记，请重新打开后再试。")
            onWorkbenchSnapshotChange(nil)
            return
        }
        let selection = editorSession?.selection ?? defaultSelection(in: persisted.document)
        do {
            let snapshot = try DecompositionSourceCapture.capture(
                note: persisted,
                workspaceRevision: store.state.revision,
                selection: selection
            )
            let model = DecompositionWorkbenchModel(
                snapshot: snapshot,
                planner: decompositionPlanner,
                store: store
            )
            publishEntryNotice(nil)
            workbenchModel = model
            onWorkbenchModelChange(model)
            decompositionRequest = DecompositionWorkbenchRequest(snapshot: snapshot, model: model)
            onWorkbenchSnapshotChange(snapshot)
            onWorkbenchCommitHandlerChange { [self] result in
                handleWorkbenchCommitted(result)
            }
        } catch let error as DecompositionSourceCaptureError {
            onWorkbenchSnapshotChange(nil)
            publishEntryNotice(captureMessage(error))
        } catch {
            onWorkbenchSnapshotChange(nil)
            publishEntryNotice("现在不能拆开这段内容，请调整选区后重试。")
        }
    }

    private func canCapturePersistedWorkbenchSnapshot(
        afterFlush evidence: NoteAutosaveBarrierEvidence
    ) async -> Bool {
        var evidence = evidence
        if case .cleanupPending = autosave.autosaveState {
            evidence = await autosave.retryLatest()
        }
        switch evidence {
        case .clean, .persisted:
            break
        case .protectedOnly, .unsafeLatestUnprotected:
            return false
        }
        switch autosave.autosaveState {
        case .cleanupPending, .commitPending, .finalizingNativeInput, .nativeInputUnresolved, .sealed:
            return false
        default:
            break
        }
        return autosave.canReplaceSessionWithPersistedStoreSnapshot
    }

    private func captureMessage(_ error: DecompositionSourceCaptureError) -> String {
        switch error {
        case .emptySource:
            "这段内容还不够拆开，请先写下要处理的事情。"
        case .crossBlockSelection:
            "请只选中同一段里的文字，或取消选区后用整篇笔记拆开。"
        case .blockSelectionUnsupported:
            "请改用文字选区，或取消选区后用整篇笔记拆开。"
        case .invalidSelection:
            "当前选区无法拆开，请重新选择文字后再试。"
        }
    }

    private func publishEntryNotice(_ message: String?) {
        entryNotice = message
        onWorkbenchEntryNoticeChange(message)
    }

    private func handleWorkbenchCommitted(_ result: DecompositionCommitResult) {
        guard autosave.currentNoteID == identity.noteID else { return }
        switch result {
        case let .committed(created, scheduled, generation):
            decompositionRequest = nil
            let rebuilt = rebuildEditorAfterWorkbench()
            let message = rebuilt
                ? DecompositionWorkbenchCopy.completionMessage(
                    created: created,
                    scheduled: scheduled
                )
                : "行动已创建，但当前笔记没有刷新。请重新打开这篇笔记查看。"
            activeWorkbenchNotice = NoteWorkbenchNotice(message: message, stateGeneration: generation)
            onWorkbenchFeedbackChange(message, generation)
        case .sourceChanged, .calendarConflict, .notCommitted:
            break
        }
    }

    private func rebuildEditorAfterWorkbench() -> Bool {
        guard let persisted = store.state.notes[identity.noteID] else { return false }
        guard ownsCurrentAutosaveSession else {
            // Parent already re-keyed onto the persisted document. Treat that
            // as a successful adoption rather than minting a competing session.
            // A late callback after autosave moved to another note must not
            // count as adoption for this editor.
            return autosave.currentNoteID == identity.noteID
        }
        let newID = UUID()
        do {
            try autosave.beginSession(
                persisted,
                linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter {
                    $0.noteID == identity.noteID
                }),
                editSessionID: newID,
                activeHostToken: UUID()
            )
            editorSession = nil
            sessionSink(nil)
            installNativeFinalizer()
            lastAcceptedDocument = persisted.document
            editorMount = EditorMount(
                editSessionID: newID,
                initialDocument: persisted.document
            )
            return true
        } catch {
            editorSession?.autosaveDidResolve(.failed("无法刷新拆开后的保存基线。"))
            return false
        }
    }

    private func invalidateWorkbenchUndoForLocalEdit() {
        activeWorkbenchNotice = nil
        onWorkbenchFeedbackChange(nil, nil)
    }

    private func undoWorkbench(_ notice: NoteWorkbenchNotice) async {
        guard activeWorkbenchNotice == notice,
              store.statePublicationGeneration == notice.stateGeneration else {
            activeWorkbenchNotice = nil
            onWorkbenchFeedbackChange(nil, nil)
            return
        }
        do {
            _ = try await store.undo()
            activeWorkbenchNotice = nil
            onWorkbenchFeedbackChange(nil, nil)
            _ = rebuildEditorAfterWorkbench()
        } catch {
            activeWorkbenchNotice = nil
            onWorkbenchFeedbackChange(nil, nil)
        }
    }

    private func undoScheduledItem(_ notice: ScheduleNotice) async {
        guard scheduleNotice == notice,
              store.statePublicationGeneration == notice.stateGeneration else {
            scheduleNotice = nil
            return
        }
        do {
            _ = try await store.undo()
            scheduleNotice = nil
        } catch {
            scheduleNotice = nil
        }
    }

    private func applyInitialFocusIfReady() {
        guard !didApplyInitialFocus, let initialFocus else { return }
        switch initialFocus {
        case .title:
            guard titleCoordinator?.focus() == true else { return }
        case .bodyStart:
            guard let editorSession else { return }
            guard editorSession.focusDocumentStart() else { return }
        }
        didApplyInitialFocus = true
        onInitialFocusApplied()
    }

    private func installNativeFinalizer() {
        guard ownsCurrentAutosaveSession else { return }
        if let editorSession, !sessionBelongsToThisEditor(editorSession) {
            return
        }
        let ownedSessionID = autosave.currentEditSessionID ?? activeEditSessionID
        nativeFinalizerHook.wrappedValue = { [titleCoordinator, editorSession] permit, accept in
            guard permit.editSessionID == ownedSessionID else { return false }
            if let editorSession, editorSession.editSessionID != ownedSessionID {
                return false
            }
            // Title field first — at most one focused field-editor may consume.
            if let titleCoordinator, titleCoordinator.terminallyFinalizeNativeComposition() == false {
                return false
            }
            if let editorSession, editorSession.terminallyFinalizeNativeComposition() == false {
                return false
            }
            let edit = NoteNativeInputEdit(
                title: titleCoordinator?.field?.stringValue,
                document: editorSession?.document
            )
            // No pending candidate after successful unmark is still success.
            if edit.title == nil, edit.document == nil {
                return true
            }
            return accept(permit, edit)
        }
    }

    private func prepareForTaskCalendarMutation() async -> Bool {
        switch await autosave.flushLatest(finalizer: nativeFinalizerHook.wrappedValue) {
        case .clean, .persisted:
            true
        case .protectedOnly, .unsafeLatestUnprotected:
            false
        }
    }

    private func rebaseAutosaveAfterTaskCalendarMutation() {
        guard ownsCurrentAutosaveSession else { return }
        guard let persisted = store.state.notes[identity.noteID] else { return }
        do {
            try autosave.beginSession(
                persisted,
                linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter {
                    $0.noteID == identity.noteID
                }),
                editSessionID: activeEditSessionID,
                activeHostToken: UUID()
            )
        } catch {
            editorSession?.autosaveDidResolve(.failed("无法刷新待办联动后的保存基线。"))
        }
    }

    private func unlinkTaskBlockFromCalendar(_ blockID: BlockID) async {
        guard await prepareForTaskCalendarMutation() else { return }
        let outcome = try? await TaskBlockCalendarIntegration.unlinkFromBlock(
            store: store,
            noteID: identity.noteID,
            blockID: blockID
        )
        if case .committed? = outcome {
            rebaseAutosaveAfterTaskCalendarMutation()
        }
    }

    private func handleDocumentChange(
        _ document: BlockDocument,
        originatingEditSessionID: UUID
    ) {
        guard originatingEditSessionID == autosave.currentEditSessionID else { return }
        guard document != lastAcceptedDocument else { return }
        invalidateWorkbenchUndoForLocalEdit()
        guard pendingLinkedTaskDeletion == nil else { return }
        let linkedBlocks = TaskBlockDeletionConfirmation.requiredLinkedBlocks(
            noteID: identity.noteID,
            before: lastAcceptedDocument,
            after: document,
            links: store.state.taskBlockLinks
        )
        guard !linkedBlocks.isEmpty else {
            acceptDocument(document, dispositions: [:])
            return
        }
        pendingLinkedTaskDeletion = .init(document: document, blockIDs: linkedBlocks)
    }

    private func confirmLinkedTaskDeletion(_ disposition: LinkedTaskBlockDeletionDisposition) {
        guard let pending = pendingLinkedTaskDeletion else { return }
        pendingLinkedTaskDeletion = nil
        acceptDocument(
            pending.document,
            dispositions: Dictionary(uniqueKeysWithValues: pending.blockIDs.map { ($0, disposition) })
        )
    }

    private func cancelLinkedTaskDeletion() {
        guard pendingLinkedTaskDeletion != nil else { return }
        pendingLinkedTaskDeletion = nil
        editorSession?.undoManager.undo()
    }

    private func acceptDocument(
        _ document: BlockDocument,
        dispositions: [BlockID: LinkedTaskBlockDeletionDisposition]
    ) {
        if document == lastAcceptedDocument, dispositions.isEmpty {
            return
        }
        do {
            _ = try autosave.update(
                document: document,
                linkedBlockDeletionDispositions: dispositions
            )
            lastAcceptedDocument = document
            onDocumentCommitted(document)
        } catch {
            editorSession?.autosaveDidResolve(.failed("无法保存这次正文修改。"))
        }
    }

    private func defaultSelection(in document: BlockDocument) -> BlockEditorSelection {
        let block = document.blocks.first ?? DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain(""),
            taskState: nil,
            indentLevel: 0
        )
        return .text(
            anchor: .init(blockID: block.id, graphemeOffset: 0),
            focus: .init(blockID: block.id, graphemeOffset: 0),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
    }
}

private struct NoteEditorTaskCalendarAction: View {
    @ObservedObject var session: BlockEditorSession
    let store: WorkspaceStore
    let noteID: NoteID
    let onSchedule: (BlockID) -> Void
    let onUnlink: (BlockID) -> Void
    let onOpenItem: (UUID) -> Void

    var body: some View {
        if let blockID = session.focusedTaskBlockID {
            TaskBlockCalendarBadge(
                store: store,
                noteID: noteID,
                blockID: blockID,
                onSchedule: { onSchedule(blockID) },
                onUnlink: { onUnlink(blockID) },
                onOpenItem: onOpenItem
            )
        }
    }
}

private struct PendingLinkedTaskDeletion {
    let document: BlockDocument
    let blockIDs: [BlockID]
}

/// AppKit static text so VoiceOver and in-process collectors share one node.
private final class NoteWorkbenchFeedbackField: NSTextField {
    var feedbackIdentifier = "notes-workbench-feedback"

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityIdentifier() -> String { feedbackIdentifier }
    override func accessibilityLabel() -> String? { stringValue }
    override func accessibilityValue() -> String? { stringValue }
}

private struct NoteWorkbenchFeedbackText: NSViewRepresentable {
    var message: String
    var identifier: String

    func makeNSView(context: Context) -> NoteWorkbenchFeedbackField {
        let field = NoteWorkbenchFeedbackField(labelWithString: message)
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.refusesFirstResponder = true
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(field)
        return field
    }

    func updateNSView(_ field: NoteWorkbenchFeedbackField, context: Context) {
        apply(field)
    }

    static func dismantleNSView(_ field: NoteWorkbenchFeedbackField, coordinator: ()) {
        field.feedbackIdentifier = ""
        field.stringValue = ""
        field.isHidden = true
        field.identifier = nil
        field.setAccessibilityElement(false)
        field.setAccessibilityIdentifier("")
        field.setAccessibilityLabel(nil)
        field.setAccessibilityValue(nil)
        field.removeFromSuperview()
    }

    private func apply(_ field: NoteWorkbenchFeedbackField) {
        field.feedbackIdentifier = identifier
        if field.stringValue != message {
            field.stringValue = message
        }
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityElement(true)
        field.setAccessibilityRole(.staticText)
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(message)
        field.setAccessibilityValue(message)
        field.setAccessibilityTitle(message)
    }
}
