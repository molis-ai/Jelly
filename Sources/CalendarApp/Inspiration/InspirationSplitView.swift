import AppKit
import CalendarDomain
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceDomain

struct InspirationSplitView: View {
    private struct ConversionNotice: Equatable {
        let noteID: NoteID
        let title: String
        let stateGeneration: UInt
    }
    private struct LifecycleNotice: Equatable {
        let message: String
        let stateGeneration: UInt
    }
    let store: WorkspaceStore
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    let transitionCoordinator: WorkspaceRouteTransitionCoordinator?
    @ObservedObject var deepLinkRouter: WorkspaceDeepLinkRouter
    @State private var model: InspirationViewModel
    @State private var categoryManagerPresentation: CategoryManagerPresentation?
    @State private var inboxScope: InspirationInboxScope = .pending
    @FocusState private var captureFocused: Bool
    @State private var inboxCollapsed = false
    @State private var availableWidth: CGFloat = .infinity
    @State private var conversionNotice: ConversionNotice?
    @State private var lifecycleNotice: LifecycleNotice?
    @Environment(\.workspaceActiveRoute) private var activeWorkspaceRoute

    init(
        store: WorkspaceStore,
        newItemRouter: WorkspaceNewItemRouter = WorkspaceNewItemRouter(),
        transitionCoordinator: WorkspaceRouteTransitionCoordinator? = nil,
        deepLinkRouter: WorkspaceDeepLinkRouter = WorkspaceDeepLinkRouter(),
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex(),
        digestOperator: (any MaterialDigestOperating)? = nil,
        isDigestConfigured: @escaping @MainActor () -> Bool = { true }
    ) {
        self.store = store
        self.newItemRouter = newItemRouter
        self.transitionCoordinator = transitionCoordinator
        self.deepLinkRouter = deepLinkRouter
        _model = State(initialValue: InspirationViewModel(
            store: store,
            digestOperator: digestOperator,
            isDigestConfigured: isDigestConfigured,
            searchIndex: searchIndex
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            inspirationContent(mode: NotesAdaptiveLayout.mode(
                width: proxy.size.width,
                browserCollapsed: inboxCollapsed
            ))
            .onAppear { availableWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
        .sheet(item: $categoryManagerPresentation) { presentation in
            CategoryManagerView(
                store: store,
                initialCategoryID: presentation.initialCategoryID
            )
        }
        .overlay(alignment: .top) {
            if let conversionNotice {
                HStack(spacing: 10) {
                    Label("已生成《\(conversionNotice.title)》", systemImage: "checkmark.circle.fill")
                    Button("打开笔记") {
                        self.conversionNotice = nil
                        openNote(conversionNotice.noteID)
                    }
                    Button("撤销") {
                        Task { await undoConversion(conversionNotice) }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.top, 8)
            } else if let lifecycleNotice {
                HStack(spacing: 10) {
                    Label(lifecycleNotice.message, systemImage: "checkmark.circle.fill")
                    Button("撤销") {
                        Task { await undoLifecycleChange(lifecycleNotice) }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.top, 8)
            }
        }
        .onChange(of: store.statePublicationGeneration) { _, _ in
            model.refresh()
        }
        .onAppear {
            consumeNewItemRequest(newItemRouter.pendingRequest)
            consumeDeepLink(deepLinkRouter.pendingRequest)
        }
        .onChange(of: newItemRouter.pendingRequest) { _, request in
            consumeNewItemRequest(request)
        }
        .onChange(of: deepLinkRouter.pendingRequest) { _, request in
            consumeDeepLink(request)
        }
        .onChange(of: activeWorkspaceRoute) { _, route in
            if route != .inspiration { categoryManagerPresentation = nil }
        }
    }

    @ViewBuilder
    private func inspirationContent(mode: NotesSplitView.NotesAdaptiveLayoutMode) -> some View {
        switch mode {
        case .browserOnly:
            inboxColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editorOnly:
            detailColumn(showsInboxButton: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            HSplitView {
                inboxColumn
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                detailColumn(showsInboxButton: false)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inboxColumn: some View {
        InspirationInboxView(
            model: model,
            categories: store.calendarState.categories.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            captureFocused: $captureFocused,
            scope: $inboxScope,
            onSelect: { id in
                model.select(id)
                if NotesAdaptiveLayout.isCompact(width: availableWidth) { inboxCollapsed = true }
            },
            onCaptured: { _ in
                if NotesAdaptiveLayout.isCompact(width: availableWidth) { inboxCollapsed = true }
            },
            onToggleInbox: { inboxCollapsed = true },
            onShowCategoryManager: {
                categoryManagerPresentation = CategoryManagerPresentation(
                    initialCategoryID: model.selected?.categoryID
                )
            }
        )
    }

    private func detailColumn(showsInboxButton: Bool) -> some View {
        InspirationDetailView(
            model: model,
            store: store,
            showsInboxButton: showsInboxButton,
            showsSelectionPrompt: InspirationDetailEmptyStatePolicy.showsSelectionPrompt(
                visibleItemCount: visibleInspirationCount,
                showsInboxButton: showsInboxButton
            ),
            onToggleInbox: { inboxCollapsed = false },
            onOpenNote: openNote,
            onConverted: { noteID, title in
                lifecycleNotice = nil
                conversionNotice = ConversionNotice(
                    noteID: noteID,
                    title: title,
                    stateGeneration: store.statePublicationGeneration
                )
            },
            onLifecycleChanged: { message in
                conversionNotice = nil
                lifecycleNotice = LifecycleNotice(
                    message: message,
                    stateGeneration: store.statePublicationGeneration
                )
            },
            onPasteRecovery: preparePasteRecovery,
            onChooseFileRecovery: chooseRecoveryFile
        )
    }

    private func preparePasteRecovery() {
        if let text = NSPasteboard.general.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.captureText = text
        }
        inboxCollapsed = false
        captureFocused = true
    }

    private func chooseRecoveryFile() {
        guard let selection = InspirationMaterialFilePicker.choose() else { return }
        Task {
            _ = await model.captureFile(at: selection.url, kind: selection.kind)
            if NotesAdaptiveLayout.isCompact(width: availableWidth) { inboxCollapsed = true }
        }
    }

    private var visibleInspirationCount: Int {
        switch inboxScope {
        case .pending: model.pending.count
        case .converted: model.converted.count
        case .archived: model.archived.count
        }
    }

    private func consumeNewItemRequest(_ request: WorkspaceNewItemRequest?) {
        guard let request,
              request.route == .inspiration,
              newItemRouter.consume(request.id, route: .inspiration) != nil else { return }
        captureFocused = true
    }

    private func consumeDeepLink(_ request: WorkspaceDeepLinkRequest?) {
        guard let request,
              case let .inspiration(id) = request.target,
              store.state.inspirations[id] != nil,
              deepLinkRouter.consume(request.id, target: request.target) != nil else { return }
        model.select(id)
        if NotesAdaptiveLayout.isCompact(width: availableWidth) { inboxCollapsed = true }
    }

    private func openNote(_ noteID: NoteID) {
        guard let transitionCoordinator else { return }
        Task {
            guard await transitionCoordinator.requestActivation(.notes) else { return }
            deepLinkRouter.request(.note(noteID))
        }
    }

    private func undoConversion(_ notice: ConversionNotice) async {
        guard conversionNotice == notice,
              store.statePublicationGeneration == notice.stateGeneration else {
            conversionNotice = nil
            return
        }
        do {
            _ = try await store.undo()
            model.refresh()
        } catch {
            // The notice disappears instead of offering an unsafe second undo.
        }
        conversionNotice = nil
    }

    private func undoLifecycleChange(_ notice: LifecycleNotice) async {
        guard lifecycleNotice == notice,
              store.statePublicationGeneration == notice.stateGeneration else {
            lifecycleNotice = nil
            return
        }
        do {
            _ = try await store.undo()
            model.refresh()
        } catch {
            // Do not keep an undo affordance once its exact mutation is stale.
        }
        lifecycleNotice = nil
    }
}

struct InspirationInboxView: View {
    @Bindable var model: InspirationViewModel
    let categories: [CalendarCategory]
    var captureFocused: FocusState<Bool>.Binding
    @Binding var scope: InspirationInboxScope
    let onSelect: (InspirationID) -> Void
    let onCaptured: (InspirationID) -> Void
    let onToggleInbox: () -> Void
    let onShowCategoryManager: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("灵感")
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onToggleInbox) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("隐藏灵感列表")
                .accessibilityLabel("隐藏灵感列表")
            }
            .padding(.horizontal, 14)
            .frame(height: CalendarTheme.toolbarHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
            }

            InspirationCaptureView(model: model, isFocused: captureFocused) { id in
                scope = .pending
                onCaptured(id)
            }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    TextField("搜索内容、标题或域名", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索灵感")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    theme.canvas.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.subtleBorder.opacity(0.5), lineWidth: 0.5)
                }
                categoryMenu
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Picker("灵感范围", selection: $scope) {
                ForEach(InspirationInboxScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .tint(theme.controlAccent)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            List {
                rows(items, empty: scope.emptyMessage)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.elevatedSurface)
        }
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            model.alignSelection(with: visibleItemIDs)
        }
        .onChange(of: visibleItemIDs) { _, ids in
            model.alignSelection(with: ids)
        }
        .onChange(of: model.selected?.lifecycle) { _, lifecycle in
            guard let lifecycle else { return }
            scope = .preferred(
                lifecycle: lifecycle,
                isConverted: model.selectedConvertedNoteID != nil
            )
        }
        .onChange(of: model.selectedConvertedNoteID) { _, noteID in
            guard model.selected?.lifecycle == .active else { return }
            scope = noteID == nil ? .pending : .converted
        }
    }

    private var items: [Inspiration] {
        switch scope {
        case .pending: model.pending
        case .converted: model.converted
        case .archived: model.archived
        }
    }

    private var visibleItemIDs: [InspirationID] {
        items.map(\.id)
    }

    private var categoryMenu: some View {
        Menu {
            Button("全部分类") { model.categoryFilterID = nil }
            ForEach(categories) { category in
                Button(category.name) { model.categoryFilterID = category.id }
            }
            Divider()
            Button("管理分类…", action: onShowCategoryManager)
        } label: {
            Image(systemName: model.categoryFilterID == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(model.categoryFilterID == nil ? theme.secondaryText : theme.controlAccent)
                .frame(width: 30, height: 30)
                .background(
                    theme.canvas.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("按分类筛选；也可管理分类")
        .accessibilityLabel("筛选灵感分类")
    }

    @ViewBuilder
    private func rows(_ items: [Inspiration], empty: String) -> some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: scope == .archived ? "archivebox" : "lightbulb")
                    .font(.system(size: 20))
                Text(empty).font(.caption)
                Text(scope.emptyDescription)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rowTitle(item))
                            .lineLimit(1)
                            .font(.system(
                                size: 13,
                                weight: model.selectedID == item.id ? .semibold : .regular
                            ))
                            .foregroundStyle(theme.primaryText)
                        if let preview = rowPreview(item) {
                            Text(preview)
                                .lineLimit(1)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText.opacity(0.82))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        if model.selectedID == item.id {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.rangePreviewFill)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityLabel(rowTitle(item))
                .accessibilityAddTraits(model.selectedID == item.id ? .isSelected : [])
            }
        }
    }

    private func rowTitle(_ item: Inspiration) -> String {
        if let title = item.resolvedMetadata?.title, !title.isEmpty { return title }
        if let text = item.rawText, !text.isEmpty { return text }
        if let file = item.rawFile { return file.displayName }
        return item.rawURL?.absoluteString ?? "灵感"
    }

    private func rowPreview(_ item: Inspiration) -> String? {
        if let domain = item.resolvedMetadata?.domain, !domain.isEmpty { return domain }
        if item.resolvedMetadata?.title != nil,
           let url = item.rawURL?.absoluteString {
            return url
        }
        return nil
    }
}

struct InspirationCaptureView: View {
    @Bindable var model: InspirationViewModel
    var isFocused: FocusState<Bool>.Binding
    var onCaptured: (InspirationID) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.controlAccent)
            TextField("记下一闪而过的想法，或粘贴链接", text: $model.captureText)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit { capture() }
            Button {
                chooseFile()
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("选择一份材料文件")
            .accessibilityLabel("选择材料文件")
            .accessibilityIdentifier("inspiration-capture-file")
            Button {
                capture()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(canCapture ? theme.controlAccent : theme.secondaryText.opacity(0.38))
            }
            .buttonStyle(.plain)
            .disabled(!canCapture)
            .help("收下这条灵感")
            .accessibilityLabel("收下灵感")
            .accessibilityIdentifier("inspiration-capture-action")
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(theme.canvas.opacity(0.84), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.subtleBorder.opacity(0.58), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("灵感快速捕获")
    }

    private var canCapture: Bool {
        !model.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func capture() {
        Task {
            if let id = try? await model.capture(model.captureText) { onCaptured(id) }
        }
    }

    private func chooseFile() {
        guard let selection = InspirationMaterialFilePicker.choose() else { return }
        Task {
            if let id = await model.captureFile(at: selection.url, kind: selection.kind) {
                onCaptured(id)
            }
        }
    }
}

private struct InspirationMaterialFileSelection {
    let url: URL
    let kind: ResolvedSourceKind
}

@MainActor
private enum InspirationMaterialFilePicker {
    static func choose() -> InspirationMaterialFileSelection? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .plainText,
            .html,
            .pdf,
            .image,
            .audio,
            .movie,
            UTType(filenameExtension: "md")
        ].compactMap { $0 }
        panel.message = "选择 TXT、Markdown、HTML、图片、PDF、音频或视频。"
        panel.prompt = "收下材料"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let kind: ResolvedSourceKind
        if contentType?.conforms(to: .image) == true {
            kind = .image
        } else if contentType?.conforms(to: .audio) == true {
            kind = .audio
        } else if contentType?.conforms(to: .movie) == true {
            kind = .video
        } else if contentType?.conforms(to: .html) == true {
            kind = .article
        } else if contentType?.conforms(to: .plainText) == true
                    || url.pathExtension.lowercased() == "md" {
            kind = .plainText
        } else {
            kind = .document
        }
        return InspirationMaterialFileSelection(url: url, kind: kind)
    }
}

enum InspirationInboxScope: String, CaseIterable, Identifiable {
    case pending
    case converted
    case archived

    var id: Self { self }
    var title: String {
        switch self {
        case .pending: "待处理"
        case .converted: "已成笔记"
        case .archived: "归档"
        }
    }
    var emptyMessage: String {
        switch self {
        case .pending: "暂无待处理灵感"
        case .converted: "还没有转成笔记的灵感"
        case .archived: "归档为空"
        }
    }
    var emptyDescription: String {
        switch self {
        case .pending: "在上方记下一闪而过的想法，保存后会立即出现在这里。"
        case .converted: "从待处理灵感中选择“继续写成笔记”，完成后会移到这里。"
        case .archived: "归档的灵感会保留在这里，之后仍可恢复。"
        }
    }

    static func preferred(
        lifecycle: InspirationLifecycle,
        isConverted: Bool
    ) -> InspirationInboxScope {
        if lifecycle == .archived { return .archived }
        return isConverted ? .converted : .pending
    }
}

enum InspirationDetailEmptyStatePolicy {
    static func showsSelectionPrompt(
        visibleItemCount: Int,
        showsInboxButton: Bool
    ) -> Bool {
        showsInboxButton || visibleItemCount > 0
    }
}

enum InspirationDetailAction: String, CaseIterable {
    case primary = "inspiration-primary-action"
    case archive = "inspiration-archive-action"
    case copyLink = "inspiration-copy-link-action"
}

struct InspirationDetailView: View {
    @Bindable var model: InspirationViewModel
    let store: WorkspaceStore
    var showsInboxButton = false
    var showsSelectionPrompt = true
    var onToggleInbox: () -> Void = {}
    var onOpenNote: (NoteID) -> Void = { _ in }
    var onConverted: (NoteID, String) -> Void = { _, _ in }
    var onLifecycleChanged: (String) -> Void = { _ in }
    var onPasteRecovery: () -> Void = {}
    var onChooseFileRecovery: () -> Void = {}
    @State private var pendingPermanentDelete: InspirationPermanentDeleteRequest?
    @State private var deleteStatus: String?
    @FocusState private var contentEditorFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        if let inspiration = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                detailToolbar(inspiration)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        contentSection(inspiration)
                        if let metadata = inspiration.resolvedMetadata {
                            sourceSection(inspiration, metadata: metadata)
                        }
                        MaterialDigestSection(
                            presentation: model.selectedDigestPresentation,
                            onStart: { Task { await model.startSelectedDigest() } },
                            onCancel: { Task { await model.cancelSelectedDigest() } },
                            onRetry: { Task { await model.retrySelectedDigest() } },
                            onRefresh: { Task { await model.refreshSelectedDigest() } },
                            onConfirmDownload: { Task { await model.confirmSelectedModelDownload() } },
                            onPasteRecovery: onPasteRecovery,
                            onChooseFileRecovery: onChooseFileRecovery
                        )
                        statusSection
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 30)
                    .padding(.bottom, 36)
                }
                detailActions(inspiration)
            }
            .background(theme.canvas)
            .foregroundStyle(theme.primaryText)
            .confirmationDialog(
                "永久删除这条灵感？",
                isPresented: Binding(
                    get: { pendingPermanentDelete != nil },
                    set: { if !$0 { pendingPermanentDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("永久删除", role: .destructive) {
                    guard let request = pendingPermanentDelete else { return }
                    pendingPermanentDelete = nil
                    Task {
                        let authorization = PermanentDeleteAuthorization(
                            subject: request.preview.subject,
                            sourceWorkspaceRevision: request.preview.sourceWorkspaceRevision,
                            impactChecksum: request.preview.checksum
                        )
                        do {
                            let deleted = try await model.permanentlyDelete(
                                request,
                                authorization: authorization
                            )
                            if !deleted { deleteStatus = "删除影响已变化，请重新确认。" }
                        } catch {
                            deleteStatus = "永久删除未完成，原始灵感仍然保留。"
                        }
                    }
                }
                Button("取消", role: .cancel) { pendingPermanentDelete = nil }
            } message: {
                if let request = pendingPermanentDelete {
                    Text(request.preview.effects.isEmpty
                        ? "删除后无法恢复。"
                        : "删除后无法恢复，并会把 \(request.preview.effects.count) 条笔记来源关系改为“原始灵感已删除”。")
                }
            }
            .onChange(of: model.selectedID) { _, _ in
                contentEditorFocused = false
            }
            .onChange(of: contentEditorFocused) { _, isFocused in
                guard !isFocused else { return }
                Task { await model.flushSelectedTextEdit() }
            }
            .onDisappear {
                Task { await model.flushSelectedTextEdit() }
            }
        } else {
            VStack(spacing: 0) {
                if showsInboxButton {
                    HStack {
                        Button(action: onToggleInbox) { Image(systemName: "sidebar.left").frame(width: 28, height: 28) }
                            .buttonStyle(.plain)
                            .help("显示灵感列表")
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(height: CalendarTheme.toolbarHeight)
                }
                if showsSelectionPrompt {
                    ContentUnavailableView(
                        "选择一条灵感",
                        systemImage: "lightbulb",
                        description: Text("打开灵感列表进行选择，或捕获一条新灵感。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
            }
            .background(theme.canvas)
        }
    }

    private func detailToolbar(_ inspiration: Inspiration) -> some View {
        HStack(spacing: 10) {
            if showsInboxButton {
                Button(action: onToggleInbox) {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("显示灵感列表")
                .accessibilityLabel("显示灵感列表")
            }
            Text("灵感详情")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 12)
            categoryMenu(inspiration)
        }
        .padding(.horizontal, 20)
        .frame(height: CalendarTheme.toolbarHeight)
        .background(theme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
    }

    private func categoryMenu(_ inspiration: Inspiration) -> some View {
        Menu {
            ForEach(sortedCategories, id: \.id) { category in
                Button {
                    Task { _ = try? await model.changeSelectedCategory(to: category.id) }
                } label: {
                    HStack {
                        Text(category.name)
                        if category.id == inspiration.categoryID { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label(categoryName(for: inspiration.categoryID), systemImage: "tag")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(theme.elevatedSurface.opacity(0.82), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("分类会与日历和笔记共用")
        .accessibilityLabel("灵感分类：\(categoryName(for: inspiration.categoryID))")
    }

    private func contentSection(_ inspiration: Inspiration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("内容")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 12)
                if model.selectedTextIsEditable {
                    textSaveStatus
                } else {
                    Text(inspiration.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            if model.selectedTextIsEditable {
                TextEditor(text: Binding(
                    get: { model.selectedTextDraft },
                    set: { model.selectedTextDraft = $0 }
                ))
                .font(.system(size: 18, weight: .regular))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .focused($contentEditorFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minHeight: 150, maxHeight: 320)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.elevatedSurface.opacity(contentEditorFocused ? 0.72 : 0.38))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            contentEditorFocused
                                ? theme.controlAccent.opacity(0.72)
                                : theme.separator.opacity(0.38),
                            lineWidth: contentEditorFocused ? 1.5 : 0.5
                        )
                }
                .accessibilityLabel("灵感内容")
                .accessibilityHint("可直接补写，内容会自动保存")
                .accessibilityIdentifier("inspiration-content-editor")
            } else {
                Text(primaryContent(inspiration))
                    .font(.system(size: 18, weight: .regular))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("inspiration-content")
                readOnlyExplanation(for: inspiration)
            }
        }
    }

    @ViewBuilder
    private var textSaveStatus: some View {
        switch model.selectedTextSaveState {
        case .idle:
            Label("可直接补写 · 自动保存", systemImage: "pencil")
                .foregroundStyle(theme.secondaryText)
        case .waiting, .saving:
            Label("正在保存…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(theme.secondaryText)
        case .saved:
            Label("已保存", systemImage: "checkmark.circle")
                .foregroundStyle(theme.secondaryText)
        case .invalid:
            Label("内容不能为空，原内容仍保留", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .failed:
            Label("保存失败，原内容仍保留", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func readOnlyExplanation(for inspiration: Inspiration) -> some View {
        if model.selectedConvertedNoteID != nil {
            Label("已生成笔记，后续内容请在笔记中继续。", systemImage: "note.text")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 4)
        } else if inspiration.lifecycle == .archived, inspiration.inputKind == .text {
            Label("这条灵感已归档，恢复后可以继续补写。", systemImage: "archivebox")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 4)
        }
    }

    private func sourceSection(
        _ inspiration: Inspiration,
        metadata: SourceMetadata
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .overlay(theme.separator.opacity(0.7))
                .padding(.vertical, 24)
            Text("来源")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.controlAccent)
                    .frame(width: 30, height: 30)
                    .background(theme.controlAccent.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(metadata.title ?? inspiration.rawURL?.absoluteString ?? "链接")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let domain = metadata.domain, !domain.isEmpty {
                            Text(domain)
                        }
                        Text(metadata.fetchStatus.presentationTitle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 12)
                if inspiration.rawURL != nil, metadata.fetchStatus == .failed {
                    Button("重试") { Task { await model.retrySelectedMetadata() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let status = model.statusMessage {
            Text(status)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 18)
        }
        if let deleteStatus {
            Text(deleteStatus)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 8)
        }
    }

    private func detailActions(_ inspiration: Inspiration) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    let existingNoteID = model.selectedConvertedNoteID
                    if let noteID = try? await model.convertSelectedToNote() {
                        if existingNoteID != nil {
                            onOpenNote(noteID)
                        } else {
                            let title = store.state.notes[noteID]?.title ?? "无标题"
                            onConverted(noteID, title)
                        }
                    }
                }
            } label: {
                Label(
                    model.selectedPrimaryActionTitle,
                    systemImage: model.selectedConvertedNoteID == nil
                        ? "note.text.badge.plus"
                        : "arrow.up.right"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.controlAccent)
            .controlSize(.regular)
            .accessibilityLabel(model.selectedPrimaryActionTitle)
            .accessibilityIdentifier(InspirationDetailAction.primary.rawValue)

            Button(inspiration.lifecycle == .archived ? "恢复" : "归档") {
                Task {
                    if inspiration.lifecycle == .archived {
                        if (try? await model.restoreSelected()) == true {
                            onLifecycleChanged("灵感已恢复")
                        }
                    } else {
                        if (try? await model.archiveSelected()) == true {
                            onLifecycleChanged("灵感已归档")
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier(InspirationDetailAction.archive.rawValue)

            if let url = inspiration.rawURL {
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier(InspirationDetailAction.copyLink.rawValue)
            }

            Spacer(minLength: 0)

            if inspiration.lifecycle == .archived {
                Button("永久删除…", role: .destructive) {
                    do {
                        pendingPermanentDelete = try model.permanentDeleteRequest(for: inspiration.id)
                        deleteStatus = nil
                    } catch {
                        deleteStatus = "无法生成删除影响预览。"
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.error)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(theme.elevatedSurface.opacity(0.82))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
    }

    private var sortedCategories: [CalendarCategory] {
        store.calendarState.categories.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func categoryName(for id: UUID) -> String {
        store.calendarState.categories[id]?.name ?? "未分类"
    }

    private func primaryContent(_ inspiration: Inspiration) -> String {
        if let text = inspiration.rawText, !text.isEmpty { return text }
        if let url = inspiration.rawURL { return url.absoluteString }
        if let file = inspiration.rawFile { return file.displayName }
        return "（没有可显示的内容）"
    }
}

extension MetadataFetchStatus {
    var presentationTitle: String {
        switch self {
        case .notRequested: "未请求"
        case .loading: "获取中…"
        case .succeeded: "已获取"
        case .failed: "获取失败"
        }
    }
}
