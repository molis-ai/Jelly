import SwiftUI
import UniformTypeIdentifiers
import CalendarDomain
import CalendarPersistence
import WorkspaceDomain

struct MobileSettingsView: View {
    @Bindable var workspace: MobileWorkspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jelly.ios.appearance") private var appearance = "system"
    @State private var importing = false
    @State private var exported: MobileShareFile?
    @State private var confirmingRestore = false
    @State private var busy = false
    @State private var showingAI = false

    var body: some View {
        NavigationStack {
            Form {
                Section("工作空间") {
                    NavigationLink("分类管理") { MobileCategoriesView(workspace: workspace) }
                    NavigationLink("同步") { MobileSyncSettingsView(sync: workspace.sync) }
                    Button("摘要") { showingAI = true }
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }
                Section("MCP 连接") {
                    Toggle("启用前台本机服务", isOn: Binding(get: { workspace.mcp.isEnabled }, set: { workspace.mcp.isEnabled = $0 }))
                        .disabled(!workspace.isReady)
                    Text("只在 Jelly 位于前台时接受这台 iPhone 上的客户端连接。电脑无法通过此地址连接手机；桌面 stdio 桥接不适用于 iOS。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let endpoint = workspace.mcp.endpointDescription {
                        LabeledContent("地址", value: endpoint).textSelection(.enabled)
                    }
                    if let token = workspace.mcp.token {
                        DisclosureGroup("连接令牌") {
                            Text(token).font(.caption.monospaced()).textSelection(.enabled)
                            Text("客户端使用 Authorization: Bearer 令牌。服务每次启动会更换令牌。").font(.caption)
                        }
                    }
                    if let error = workspace.mcp.lastError { Text(error).foregroundStyle(.red) }
                }
                Section("备份与恢复") {
                    Button("导出完整备份", systemImage: "square.and.arrow.up") {
                        Task {
                            busy = true
                            defer { busy = false }
                            if let url = await workspace.prepareBackupExport() { exported = .init(url: url) }
                        }
                    }.disabled(busy || !workspace.canExportBackup)
                    Button("从文件恢复…", systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(busy || !workspace.canRestore)
                    if let preview = workspace.restorePreview {
                        let state = preview.loadResult.state
                        VStack(alignment: .leading, spacing: 8) {
                            Text("备份预览").font(.headline)
                            Text(preview.sourceURL.lastPathComponent).font(.caption).textSelection(.enabled)
                            Text("\(state.calendar.items.count) 件事项 · \(state.calendar.recurrence.series.count) 组重复事项 · \(state.notes.count) 篇笔记 · \(state.inspirations.count) 条灵感")
                            Text("恢复会替换当前手机工作空间。替换前会保存当前数据副本；桌面端数据不会随此操作改变。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("使用这份备份恢复", role: .destructive) { confirmingRestore = true }
                                .disabled(busy || !workspace.canRestore)
                            Button("取消预览") { workspace.cancelRestorePreview() }
                        }.padding(.vertical, 8)
                    }
                    NavigationLink("恢复中心") { MobileRecoveryView(workspace: workspace) }
                }
                if let status = workspace.statusMessage { Section { Text(status).textSelection(.enabled) } }
                if let error = workspace.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    LabeledContent("版本", value: "Jelly iOS 开发版")
                    Text("日历、笔记和灵感保存在本机。完整备份保留桌面 Jelly 的数据格式。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.jellySurface().navigationTitle("设置")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    switch result {
                    case let .success(urls):
                        if let url = urls.first { Task { busy = true; _ = await workspace.inspectBackup(at: url); busy = false } }
                    case let .failure(error): workspace.errorMessage = error.localizedDescription
                    }
                }
                .sheet(item: $exported) { MobileShareSheet(url: $0.url) }
                .sheet(isPresented: $showingAI) { MobileAISettingsView(services: workspace.ai) }
                .confirmationDialog("确认恢复手机工作空间？", isPresented: $confirmingRestore, titleVisibility: .visible) {
                    Button("保存当前副本并恢复", role: .destructive) {
                        guard let preview = workspace.restorePreview else { return }
                        Task { busy = true; await workspace.restore(preview); busy = false }
                    }
                } message: { Text("将使用已预览的备份替换当前内容。API 密钥不包含在备份中。") }
        }
    }
}

struct MobileShareFile: Identifiable { let id = UUID(); let url: URL }
struct MobileShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.badge.checkmark").font(.largeTitle)
                Text("文件已准备好").font(.title2.bold())
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                ShareLink(item: url) { Label("保存到文件或分享", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).jellySurface()
                .navigationTitle("导出").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium])
    }
}

struct MobileCategoriesView: View {
    let workspace: MobileWorkspace
    @Environment(\.colorScheme) private var colorScheme
    @State private var editing: MobileCategoryDraft?
    @State private var deleting: CalendarCategory?
    private var categories: [CalendarCategory] { workspace.store.calendarState.categories.values.sorted { $0.sortIndex < $1.sortIndex } }
    var body: some View {
        List {
            ForEach(categories) { category in
                Button { editing = .init(category: category) } label: {
                    HStack {
                        Circle().fill(CalendarTheme.categoryColor(category.colorHex)).frame(width: 14, height: 14)
                        Text(category.name).foregroundStyle(.primary)
                        Spacer()
                        Text("\(usage(category.id))").foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
                .swipeActions(allowsFullSwipe: false) {
                    if category.id != workspace.store.calendarState.uncategorizedID {
                        Button("删除", role: .destructive) { deleting = category }
                    }
                }
            }.onMove { offsets, destination in
                var reordered = categories
                reordered.move(fromOffsets: offsets, toOffset: destination)
                Task { await workspace.send(.reorderCategories(reordered.map(\.id)), label: "调整分类顺序") }
            }
        }.jellySurface().navigationTitle("分类")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .bottomBar) {
                    Button("新建分类", systemImage: "plus") {
                        editing = .init(category: .init(id: UUID(), name: "", colorHex: "#6B8177", sortIndex: categories.count, createdAt: Date(), updatedAt: Date()))
                    }
                }
            }
            .sheet(item: $editing) { draft in MobileCategoryEditor(workspace: workspace, category: draft.category) }
            .confirmationDialog("删除分类并迁移内容？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("移入未分类并删除分类", role: .destructive) {
                    if let deleting { Task { await workspace.send(.deleteCategory(deleting.id), label: "删除分类") } }
                    deleting = nil
                }
            } message: { Text("日历、笔记和灵感里的相关内容将一起移入未分类，不会删除内容。可以撤销整个操作。") }
    }
    private func usage(_ id: UUID) -> Int {
        let state = workspace.store.state
        return state.calendar.items.values.filter { $0.categoryID == id }.count
            + state.calendar.recurrence.series.values.filter { $0.categoryID == id }.count
            + state.notes.values.filter { $0.categoryID == id }.count
            + state.inspirations.values.filter { $0.categoryID == id }.count
    }
}
struct MobileCategoryDraft: Identifiable { var id: UUID { category.id }; let category: CalendarCategory }
struct MobileCategoryEditor: View {
    let workspace: MobileWorkspace
    @State private var category: CalendarCategory
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var message: String?
    @State private var familyID = CategoryColorFamilyID.basic
    @Environment(\.colorScheme) private var colorScheme
    init(workspace: MobileWorkspace, category: CalendarCategory) { self.workspace = workspace; _category = State(initialValue: category) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("分类名称", text: $category.name)
                    .disabled(category.id == workspace.store.calendarState.uncategorizedID)
                Section("颜色") {
                    Picker("色系", selection: $familyID) {
                        ForEach(CategoryPalette.families) { family in Text(family.name).tag(family.id) }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                        ForEach(CategoryPalette.family(id: familyID).presets) { preset in
                            Button { category.colorHex = preset.hex } label: {
                                Circle().fill(CalendarTheme.categoryColor(preset.hex)).frame(width: 30, height: 30)
                                    .overlay { if category.colorHex.uppercased() == preset.hex { Image(systemName: "checkmark.circle.fill").foregroundStyle(.primary, .background) } }
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(preset.accessibilityName)
                                .accessibilityAddTraits(category.colorHex.uppercased() == preset.hex ? .isSelected : [])
                        }
                    }
                    TextField("自定义颜色 #RRGGBB", text: $category.colorHex).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    HStack {
                        Circle().fill(CalendarTheme.categoryAccent(category.colorHex, appearance: colorScheme == .dark ? .dark : .light)).frame(width: 12, height: 12)
                        Text(category.name.isEmpty ? "分类预览" : category.name)
                    }.padding(10)
                        .foregroundStyle(CalendarTheme.categoryText(category.colorHex, appearance: colorScheme == .dark ? .dark : .light))
                        .background(CalendarTheme.categorySoftBackground(category.colorHex, appearance: colorScheme == .dark ? .dark : .light), in: RoundedRectangle(cornerRadius: 8))
                }
                if let message { Text(message).foregroundStyle(.red) }
            }.jellySurface().navigationTitle("编辑分类").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saving = true
                            category.updatedAt = Date()
                            let command: WorkspaceCommand = workspace.store.calendarState.categories[category.id] == nil ? .createCategory(category) : .updateCategory(category)
                            Task {
                                if await workspace.send(command, label: "保存分类") { dismiss() }
                                else { message = workspace.errorMessage }
                                saving = false
                            }
                        }.disabled(saving || category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.interactiveDismissDisabled(saving)
            .onAppear {
                familyID = CategoryPalette.families.first { $0.colors.contains(category.colorHex.uppercased()) }?.id ?? .basic
            }
    }
}

struct MobileRecoveryBanner: View {
    let workspace: MobileWorkspace
    @State private var showing = false
    var body: some View {
        switch workspace.store.phase {
        case .notLoaded, .loading: ProgressView("正在读取本地数据…").padding(8)
        case .mutating: EmptyView()
        default:
            Button { showing = true } label: {
                Label("数据需要处理 · 打开恢复中心", systemImage: "exclamationmark.triangle")
                    .font(.callout).frame(maxWidth: .infinity, minHeight: 44)
            }.background(.orange.opacity(0.15))
                .sheet(isPresented: $showing) { NavigationStack { MobileRecoveryView(workspace: workspace) } }
        }
    }
}

struct MobileRecoveryView: View {
    @Bindable var workspace: MobileWorkspace
    @State private var share: MobileShareFile?
    @State private var keeping: DraftRecoveryCandidate?
    private var canRetry: Bool {
        if workspace.recoveryAction != nil { return true }
        return workspace.recoveryActions.contains {
            switch $0 { case .retryPendingCommit, .retryJournalCleanup: true; default: false }
        }
    }
    var body: some View {
        List {
            Section { Text(phaseDescription) }
            if let message = workspace.errorMessage { Section { Text(message).foregroundStyle(.red) } }
            if let message = workspace.statusMessage { Section { Text(message) } }
            if canRetry {
                Section { Button("继续确认保存结果") { Task { await workspace.retryRecovery() } } }
            }
            if case let .needsDraftRecovery(candidates) = workspace.store.phase {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    Section(candidate.draft.title.isEmpty ? "未命名笔记草稿" : candidate.draft.title) {
                        Text(candidate.draft.document.blocks.flatMap(\.inlineContent.spans).map(\.text).joined(separator: "\n"))
                            .lineLimit(10).textSelection(.enabled)
                        Button("恢复草稿为当前版本") { Task { await workspace.resolveDraftRecovery(candidate.token, action: .restoreAsCurrent) } }
                        Button("保留当前已保存版本") { keeping = candidate }
                        Button("将草稿另存为笔记") {
                            Task {
                                await workspace.resolveDraftRecovery(candidate.token, action: .saveAsNew(noteID: NoteID(), blockIDs: candidate.draft.document.blocks.map { _ in BlockID() }))
                            }
                        }
                        Button("导出草稿") {
                            do {
                                let text = try workspace.store.draftRecoveryMarkdown(candidate.token)
                                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-draft-\(UUID().uuidString).md")
                                try text.write(to: url, atomically: true, encoding: .utf8)
                                share = .init(url: url)
                            } catch { workspace.report(error) }
                        }
                    }
                }
            }
            Section {
                if workspace.store.phase == .loadFailed || workspace.store.phase == .unreadablePrimaryLoadFailed {
                    Button("重试读取本地数据") { Task { await workspace.load() } }
                }
                if case .externalSourceChanged = workspace.store.phase {
                    Button("重新读取外部数据") { Task { await workspace.reloadExternalSource() } }
                }
                if workspace.recoveryActions.contains(.exportRawRecoveryCopy) {
                  Button("导出原始恢复副本") {
                    Task {
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-recovery-\(UUID().uuidString).bin")
                            _ = try await workspace.store.exportRawRecoveryCopy(to: url)
                            share = .init(url: url)
                        } catch { workspace.report(error) }
                    }
                  }
                }
                if workspace.isReady { Label("本地数据可以正常读写", systemImage: "checkmark.circle") }
            }
        }.jellySurface().navigationTitle("恢复中心")
            .sheet(item: $share) { MobileShareSheet(url: $0.url) }
            .confirmationDialog("保留当前已保存版本？", isPresented: Binding(get: { keeping != nil }, set: { if !$0 { keeping = nil } }), titleVisibility: .visible) {
                Button("保留当前版本") {
                    if let keeping { Task { await workspace.resolveDraftRecovery(keeping.token, action: .keepPersisted) } }
                    keeping = nil
                }
                Button("取消", role: .cancel) { keeping = nil }
            } message: { Text("这份退出前草稿将不再作为待恢复版本。也可以先导出草稿，或选择将草稿另存为笔记。") }
    }
    private var phaseDescription: String {
        switch workspace.store.phase {
        case .ready: "工作空间就绪"
        case .notLoaded, .loading: "正在读取本地数据"
        case .mutating: "正在保存"
        case .resolvingDraftRecovery, .reconcilingDraftRecovery: "正在核对草稿恢复结果"
        case .parkedCommitUncertain: "尚不能确认此前操作是否保存，请继续确认"
        case .parkedJournalCleanup: "保存回执仍需确认，请继续处理"
        case let .needsDraftRecovery(candidates): "有 \(candidates.count) 份草稿需要选择恢复方式"
        case .needsRelationshipRepair: "内容关联需要修复。可先导出原始恢复副本，再从有效备份恢复。"
        case .externalSourceChanged: "本地文件已在外部改变，尚未覆盖外部内容"
        case .opaquePrimaryLoadFailed: "数据无法解析。请先导出原始恢复副本，再从备份恢复。"
        case .unreadablePrimaryLoadFailed: "本地文件暂时不可读，请稍后重试"
        case .loadFailed: "读取本地数据失败，请重试"
        }
    }
}

struct MobileSearchView: View {
    let workspace: MobileWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var includeArchived = false
    @State private var selectedItem: MobileItemEditorRequest?
    private var results: [WorkspaceSearchRecord] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return WorkspaceSearchProjection.build(from: workspace.state).search(query: query, kind: nil, includeArchived: includeArchived)
    }
    var body: some View {
        NavigationStack {
            List {
                Toggle("包含归档", isOn: $includeArchived)
                if query.isEmpty { MobileEmptyState(title: "搜索整个工作空间", symbol: "magnifyingglass", message: "查找事项、笔记正文和灵感来源。") }
                else if results.isEmpty { ContentUnavailableView.search(text: query) }
                ForEach(results, id: \.objectID) { result in
                    switch result.objectID {
                    case let .calendarItem(id):
                        if let item = workspace.state.calendar.items[id] {
                            Button { selectedItem = .init(mode: .editItem(item), draft: .init(item: item)) } label: { Label(item.title, systemImage: "calendar") }
                        }
                    case let .note(id):
                        if let note = workspace.state.notes[id] {
                            NavigationLink { MobileNoteDetailView(workspace: workspace, note: note) } label: { Label(note.title.isEmpty ? "未命名笔记" : note.title, systemImage: "doc.text") }
                        }
                    case let .inspiration(id):
                        if let inspiration = workspace.state.inspirations[id] {
                            NavigationLink { MobileInspirationDetailView(workspace: workspace, inspiration: inspiration) } label: {
                                Label(inspiration.rawText ?? inspiration.resolvedMetadata?.title ?? inspiration.rawURL?.absoluteString ?? inspiration.rawFile?.displayName ?? "灵感", systemImage: "lightbulb").lineLimit(3)
                            }
                        }
                    }
                }
            }.jellySurface().navigationTitle("搜索")
                .searchable(text: $query, prompt: "事项、笔记、灵感")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { Task { if await workspace.flushEditors() { dismiss() } } }
                } }
                .sheet(item: $selectedItem) { MobileItemEditor(workspace: workspace, request: $0) }
        }
        .interactiveDismissDisabled()
    }
}
