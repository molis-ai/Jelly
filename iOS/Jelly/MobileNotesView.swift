import CalendarDomain
import Foundation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WorkspaceDomain

struct MobileNotesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var workspace: MobileWorkspace
    @State private var query = ""
    @State private var archived = false
    @State private var categoryID: UUID?
    @State private var createdNoteID: NoteID?

    private var notes: [Note] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return workspace.store.state.notes.values.filter { note in
            (note.archivedAt != nil) == archived
                && (categoryID == nil || note.categoryID == categoryID)
                && (needle.isEmpty || ([note.title] + note.document.blocks.flatMap { block in
                    block.inlineContent.spans.flatMap { [$0.text, $0.linkURL?.absoluteString ?? ""] }
                }).joined(separator: "\n").lowercased().contains(needle))
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        List {
            Picker("笔记范围", selection: $archived) {
                Text("全部笔记").tag(false)
                Text("已归档").tag(true)
            }.pickerStyle(.segmented).listRowBackground(Color.clear)
            if notes.isEmpty {
                MobileEmptyState(title: query.isEmpty ? "写下一个想法" : "没有找到笔记",
                                 symbol: "doc.text", message: query.isEmpty ? "笔记中的待办可以直接安排到日历。" : "试试正文、标题或链接中的文字。")
                    .listRowBackground(Color.clear)
            }
            ForEach(notes) { note in
                NavigationLink {
                    MobileNoteDetailView(workspace: workspace, note: note)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if note.isPinned { Image(systemName: "pin.fill").font(.caption) }
                            Text(note.title.isEmpty ? "无标题笔记" : note.title).font(.headline).lineLimit(2)
                        }
                        Text(note.document.blocks.map { $0.inlineContent.spans.map(\.text).joined() }.joined(separator: " "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            Text(workspace.store.calendarState.categories[note.categoryID]?.name ?? "未分类")
                            Spacer()
                            Text(note.updatedAt, style: .date)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
                .swipeActions {
                    Button(archived ? "恢复" : "归档", systemImage: archived ? "arrow.uturn.backward" : "archivebox") {
                        Task { _ = await workspace.send(archived ? .restoreNote(note.id, at: Date()) : .archiveNote(note.id, at: Date()), label: archived ? "恢复笔记" : "归档笔记") }
                    }.tint(.brown)
                }
                .contextMenu {
                    Button(note.isPinned ? "取消置顶" : "置顶", systemImage: "pin") {
                        Task { _ = await workspace.send(.setNotePinned(note.id, !note.isPinned, at: Date()), label: "笔记置顶") }
                    }
                }
            }
        }
        .jellySurface()
        .navigationTitle("笔记")
        .searchable(text: $query, prompt: "搜索标题、正文和链接")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("全部分类") { categoryID = nil }
                    ForEach(workspace.store.calendarState.categories.values.sorted { $0.sortIndex < $1.sortIndex }) { category in
                        Button(category.name) { categoryID = category.id }
                    }
                } label: { Image(systemName: categoryID == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                .accessibilityLabel("筛选笔记分类")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("新建笔记", systemImage: "square.and.pencil") {
                    Task {
                        let note = Note.empty(categoryID: categoryID ?? workspace.store.calendarState.uncategorizedID, now: Date())
                        if await workspace.send(.createNote(.init(note: note)), label: "新建笔记") {
                            createdNoteID = note.id
                        }
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }.padding(.horizontal, 20).padding(.vertical, 8)
                .background(CalendarTheme.appearance(for: colorScheme).canvas)
        }
        .navigationDestination(item: $createdNoteID) { id in
            if let note = workspace.store.state.notes[id] { MobileNoteDetailView(workspace: workspace, note: note) }
        }
    }
}

struct MobileNoteDetailView: View {
    @Bindable var workspace: MobileWorkspace
    @State private var session: MobileNoteSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var scheduleRequest: MobileNoteScheduleRequest?
    @State private var calendarRequest: MobileItemEditorRequest?
    @State private var deletePreview: PermanentDeletePreview?
    @State private var showingImport = false
    @State private var imported: MobileNoteImportPreview?
    @State private var exportDocument: MobileNoteFile?
    @State private var showingExport = false
    @State private var exportType = UTType.plainText
    @State private var addingLink = false
    @State private var linkDraft = "https://"
    @State private var showingDecomposition = false
    @State private var showingRecoveryReview = false
    @State private var resolvingRecovery = false
    @State private var editorBarrierID = UUID()
    @State private var linkedNoteID: NoteID?
    @State private var noteLinkRequest: MobileNoteLinkRequest?

    init(workspace: MobileWorkspace, note: Note) {
        self.workspace = workspace
        _session = State(initialValue: MobileNoteSession(note: note, store: workspace.store))
    }

    private var categories: [CalendarCategory] {
        workspace.store.calendarState.categories.values.sorted { $0.sortIndex < $1.sortIndex }
    }
    private var isArchived: Bool { session.draft.archivedAt != nil }
    private var backlinks: [NoteBacklink] {
        NoteLinkIndex.backlinks(to: session.draft.id, in: workspace.store.state)
    }
    private var arrangements: [NoteCalendarArrangement] {
        NoteCalendarArrangementProjection.make(noteID: session.draft.id, state: workspace.store.state)
    }

    var body: some View {
        List {
            Section {
                MobileCommittedPlainTextView(text: Binding(get: { session.draft.title }, set: { value in session.mutate { $0.title = value } }),
                    textStyle: .title2, editable: !isArchived && !session.reviewingRecovery, accessibilityName: "笔记标题",
                    onCompositionChange: { session.isComposingText = $0 })
                    .frame(minHeight: 44)
                    .overlay(alignment: .leading) {
                        if session.draft.title.isEmpty && !session.isComposingText {
                            Text("无标题笔记").font(.title2).foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
                Picker("分类", selection: Binding(get: { session.draft.categoryID }, set: { value in session.mutate { $0.categoryID = value } })) {
                    ForEach(categories) { Text($0.name).tag($0.id) }
                }.disabled(isArchived || session.reviewingRecovery)
                HStack {
                    Label(session.status, systemImage: session.saving ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    Spacer()
                    if session.dirty { Button("重试保存") { Task { _ = await session.flush() } } }
                }.font(.caption).foregroundStyle(.secondary)
                if let error = session.error { Text(error).font(.caption).foregroundStyle(.red) }
                if session.dirty && session.error != nil || session.reviewingRecovery {
                    Button("比较并处理两个版本", systemImage: "doc.on.doc") {
                        Task { if await session.prepareRecoveryReview() { showingRecoveryReview = true } }
                    }.disabled(session.saving || resolvingRecovery)
                }
                if isArchived { Text("笔记已归档，恢复后可以继续编辑。").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                MobileDocumentTextView(
                    session: session,
                    editable: !isArchived && !session.reviewingRecovery,
                    onRequestNoteLink: { insert in noteLinkRequest = MobileNoteLinkRequest(insert: insert) },
                    onOpenNote: openLinkedNote
                )
                    .frame(minHeight: 220)
                DisclosureGroup("待办与内容块操作") {
                    ForEach(session.draft.document.blocks) { block in blockRow(block) }
                }
                if !isArchived {
                    Menu {
                        ForEach(MobileBlockKindChoice.all, id: \.kind) { choice in
                            Button(choice.title) { session.append(kind: choice.kind) }
                        }
                        Button("链接") { addingLink = true }
                    } label: { Label("添加内容", systemImage: "plus.circle").frame(minHeight: 44) }
                }
            }
            if !backlinks.isEmpty {
                Section("反向链接") {
                    ForEach(backlinks) { backlink in
                        Button { openLinkedNote(backlink.sourceNoteID) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(backlink.sourceTitle).font(.subheadline.weight(.medium))
                                    if backlink.sourceIsArchived { Text("已归档").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(backlink.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(minHeight: 44, alignment: .leading)
                        }
                        .accessibilityLabel("打开 \(backlink.sourceTitle)")
                    }
                }
            }
            if !arrangements.isEmpty {
                Section("日历安排") {
                    ForEach(arrangements) { arrangement in
                        Button {
                            Task {
                                guard await session.flush() else { return }
                                openArrangement(arrangement.target)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "calendar")
                                VStack(alignment: .leading) {
                                    Text(arrangement.title)
                                    Text(arrangement.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped).jellySurface().scrollDismissesKeyboard(.interactively)
        .navigationDestination(item: $linkedNoteID) { id in
            if let note = workspace.store.state.notes[id] { MobileNoteDetailView(workspace: workspace, note: note) }
        }
        .sheet(item: $noteLinkRequest) { request in
            MobileNoteLinkPicker(state: workspace.store.state, excluding: session.draft.id) { note in
                noteLinkRequest = nil
                request.insert(note.id, note.title.isEmpty ? "无标题" : note.title)
            }
        }
        .navigationTitle("笔记").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回", systemImage: "chevron.left") {
                    Task { if await session.flush() { dismiss() } }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(session.draft.isPinned ? "取消置顶" : "置顶", systemImage: "pin") {
                        Task {
                            guard await session.flush() else { return }
                            _ = await workspace.send(.setNotePinned(session.draft.id, !session.draft.isPinned, at: Date()), label: "笔记置顶")
                            session.refreshFromStore()
                        }
                    }
                    if !isArchived {
                        Button("安排这篇笔记", systemImage: "calendar.badge.plus") { beginSchedule(nil) }
                        Button("拆开并安排", systemImage: "sparkles") {
                            Task { if await session.flush() { showingDecomposition = true } }
                        }
                        Button("导入 Markdown / HTML", systemImage: "square.and.arrow.down") { showingImport = true }
                    }
                    Menu("导出笔记") {
                        Button("Markdown") { export(html: false) }
                        Button("HTML") { export(html: true) }
                    }
                    Button(isArchived ? "恢复笔记" : "归档笔记", systemImage: isArchived ? "arrow.uturn.backward" : "archivebox") {
                        Task {
                            guard await session.flush() else { return }
                            _ = await workspace.send(isArchived ? .restoreNote(session.draft.id, at: Date()) : .archiveNote(session.draft.id, at: Date()), label: isArchived ? "恢复笔记" : "归档笔记")
                            session.refreshFromStore()
                        }
                    }
                    if isArchived {
                        Button("永久删除", systemImage: "trash", role: .destructive) {
                            do { deletePreview = try PermanentDeletePlanner.preview(.note(session.draft.id), in: workspace.store.state) }
                            catch { workspace.errorMessage = error.localizedDescription }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("笔记操作")
            }
        }
        .sheet(item: $scheduleRequest, onDismiss: { session.refreshFromStore() }) { request in
            MobileNoteScheduleSheet(workspace: workspace, noteID: session.draft.id, blockID: request.blockID)
        }
        .sheet(item: $calendarRequest, onDismiss: { session.refreshFromStore() }) { request in
            MobileItemEditor(workspace: workspace, request: request)
        }
        .sheet(isPresented: $showingDecomposition, onDismiss: { session.refreshFromStore() }) {
            MobileDecompositionView(workspace: workspace, noteID: session.draft.id, selection: session.selection)
        }
        .sheet(isPresented: $showingRecoveryReview) {
            NavigationStack {
                List {
                    if let candidate = session.recoveryCandidate {
                        Section("已保存版本") {
                            if let persisted = candidate.persisted {
                                Text(persisted.title.isEmpty ? "无标题笔记" : persisted.title).font(.headline)
                                Text(versionPreview(persisted)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            } else { Text("原笔记已不存在。可以将当前输入保留为新笔记。") }
                        }
                        Section("当前输入") {
                            Text(candidate.draft.title.isEmpty ? "无标题笔记" : candidate.draft.title).font(.headline)
                            Text(versionPreview(candidate.draft)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                        Section {
                            Button("两个版本都保留：当前输入另存为笔记") {
                                resolveRecovery(.saveAsNew(noteID: NoteID(), blockIDs: candidate.draft.document.blocks.map { _ in BlockID() }))
                            }
                            if candidate.persisted != nil {
                                Button("使用当前输入替换已保存版本") { resolveRecovery(.restoreAsCurrent) }
                                Button("保留已保存版本，放弃当前输入", role: .destructive) { resolveRecovery(.keepPersisted) }
                            }
                        }.disabled(resolvingRecovery)
                        Section {
                            Text("选择后会保留你指定的版本。另存为笔记不会重复创建已有的日历事项；联动待办的完成状态沿用日历中已保存的状态。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = session.error { Text(error).foregroundStyle(.red) }
                        }
                    }
                }.jellySurface().navigationTitle("比较笔记版本")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后处理") { showingRecoveryReview = false }.disabled(resolvingRecovery) } }
            }.interactiveDismissDisabled(resolvingRecovery)
        }
        .confirmationDialog("这次编辑会解除待办的日历联动", isPresented: Binding(
            get: { session.pendingStructuralEdit != nil },
            set: { if !$0 { session.resolveStructuralEdit(nil) } }
        ), titleVisibility: .visible) {
            Button("继续编辑，保留独立日历事项") { session.resolveStructuralEdit(.keepCalendarItem) }
            Button("继续编辑，一起删除日历事项", role: .destructive) { session.resolveStructuralEdit(.deleteCalendarItem) }
            Button("取消", role: .cancel) { session.resolveStructuralEdit(nil) }
        } message: { Text("合并或转换内容块后，被移除待办所关联的日历事项如何处理？") }
        .confirmationDialog("永久删除这篇笔记？", isPresented: Binding(get: { deletePreview != nil }, set: { if !$0 { deletePreview = nil } }), titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { Task { await permanentlyDelete() } }
            Button("取消", role: .cancel) { deletePreview = nil }
        } message: {
            Text("将解除 \(deletePreview?.effects.count ?? 0) 处日历或来源关联，已有日历事项保留。请确认已保存需要的内容。")
        }
        .alert("添加链接", isPresented: $addingLink) {
            TextField("https://", text: $linkDraft).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("添加") {
                guard let url = URL(string: linkDraft), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    workspace.errorMessage = "请输入有效的网页链接。"
                    return
                }
                session.append(kind: .link, url: url)
                linkDraft = "https://"
            }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.plainText, .html, UTType(filenameExtension: "md") ?? .plainText]) { result in
            do { try inspectImport(try result.get()) }
            catch { workspace.errorMessage = "无法导入文件：\(error.localizedDescription)" }
        }
        .sheet(item: $imported) { preview in
            NavigationStack {
                List {
                    Section("导入预览") {
                        Text("共 \(preview.document.blocks.count) 个内容块")
                        ForEach(Array(preview.document.blocks.prefix(20).enumerated()), id: \.offset) { _, block in
                            Text(block.inlineContent.spans.map(\.text).joined()).lineLimit(4)
                        }
                    }
                    if !preview.diagnostics.isEmpty {
                        Section("格式转换说明") { ForEach(preview.diagnostics, id: \.self) { Text($0) } }
                    }
                    Section {
                        Button("追加到笔记") { session.importDocument(preview.document, replace: false); imported = nil }
                        Button("替换正文，保留已有日历事项", role: .destructive) {
                            session.importDocument(preview.document, replace: true); imported = nil
                        }
                        if workspace.store.state.taskBlockLinks.contains(where: { $0.noteID == session.draft.id }) {
                            Button("替换正文并删除已联动的日历事项", role: .destructive) {
                                session.importDocument(preview.document, replace: true, disposition: .deleteCalendarItem); imported = nil
                            }
                        }
                    }
                }.jellySurface().navigationTitle("确认导入")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { imported = nil } } }
            }
        }
        .fileExporter(isPresented: $showingExport, document: exportDocument, contentType: exportType,
                      defaultFilename: session.draft.title.isEmpty ? "Jelly笔记" : session.draft.title) { result in
            if case let .failure(error) = result { workspace.errorMessage = "导出未完成：\(error.localizedDescription)" }
        }
        .onChange(of: workspace.store.phase) { _, _ in
            if session.reconcileReviewedRecovery() { showingRecoveryReview = false }
        }
        .onChange(of: workspace.store.state.notes[session.draft.id]?.revision) { _, _ in session.refreshFromStore() }
        .onAppear {
            session.commitNativeInput = {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                await Task.yield()
                return !session.isComposingText
            }
            workspace.registerEditorBarrier(id: editorBarrierID) { await session.flush() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { _ = await session.flush() } }
        }
        .onDisappear {
            Task {
                let saved = await session.flush()
                if saved || session.canHandOffCurrentDraft { workspace.unregisterEditorBarrier(id: editorBarrierID) }
            }
        }
    }

    @ViewBuilder private func blockRow(_ block: DocumentBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if block.kind == .task {
                Button {
                    Task {
                        let complete = block.taskState?.completedAt == nil
                        if workspace.store.state.taskBlockLinks.contains(where: { $0.noteID == session.draft.id && $0.blockID == block.id }) {
                            guard await session.flush() else { return }
                            _ = await workspace.send(.setTaskCompletion(.taskBlock(noteID: session.draft.id, blockID: block.id), value: complete ? .complete(ifTransitioningAt: Date()) : .incomplete), label: "完成待办")
                            session.refreshFromStore()
                        } else {
                            session.updateBlock(block.id) { $0.taskState?.completedAt = complete ? Date() : nil }
                        }
                    }
                } label: {
                    Image(systemName: block.taskState?.completedAt == nil ? "circle" : "checkmark.circle.fill")
                        .font(.title3).frame(width: 32, height: 44)
                }.buttonStyle(.plain).disabled(isArchived || session.reviewingRecovery).accessibilityLabel(block.taskState?.completedAt == nil ? "完成待办" : "重新打开待办")
            } else if block.kind == .bullet || block.kind == .ordered {
                Text(block.kind == .bullet ? "•" : "\(orderedNumber(for: block)).")
                    .frame(width: 24, height: 36, alignment: .topTrailing).padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 5) {
                if block.kind == .divider { Divider().frame(minHeight: 32) }
                else {
                    Text(block.inlineContent.spans.map(\.text).joined().isEmpty ? "空内容块" : block.inlineContent.spans.map(\.text).joined())
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)

                }
                if let completion = block.taskState?.completionDescription {
                    Text("完成标准：\(completion)").font(.caption).foregroundStyle(.secondary)
                }
                if let link = workspace.store.state.taskBlockLinks.first(where: { $0.noteID == session.draft.id && $0.blockID == block.id }),
                   let item = workspace.store.calendarState.items[link.calendarItemID] {
                    Button {
                        Task {
                            guard await session.flush() else { return }
                            calendarRequest = .init(mode: .editItem(item), draft: .init(item: item))
                        }
                    } label: { Label(mobileScheduleCaption(item.schedule), systemImage: "calendar").font(.caption).frame(minHeight: 32) }
                }
            }
            if !isArchived {
                Menu {
                    if block.kind == .task {
                        Button("安排到日历", systemImage: "calendar.badge.plus") { beginSchedule(block.id) }
                        if workspace.store.state.taskBlockLinks.contains(where: { $0.blockID == block.id }) {
                            Button("解除日历联动") {
                                Task {
                                    guard await session.flush() else { return }
                                    _ = await workspace.send(.unlinkTaskBlock(noteID: session.draft.id, blockID: block.id), label: "解除日历联动")
                                    session.refreshFromStore()
                                }
                            }
                        }
                    }
                    if !workspace.store.state.taskBlockLinks.contains(where: { $0.blockID == block.id }) {
                        Menu("转换类型") {
                            ForEach(MobileBlockKindChoice.all.filter { $0.kind != .divider }, id: \.kind) { choice in
                                Button(choice.title) { session.changeKind(block.id, to: choice.kind) }
                            }
                        }
                    }
                    if [BlockKind.bullet, .ordered, .task].contains(block.kind) {
                        Button("增加缩进") { session.indent(block.id, by: 1) }
                        Button("减少缩进") { session.indent(block.id, by: -1) }
                    }
                    Button("上移") { session.move(block.id, by: -1) }
                    Button("下移") { session.move(block.id, by: 1) }
                    Button("删除内容块", role: .destructive) {
                        session.deleteBlock(block.id, disposition: nil)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }
                .accessibilityLabel("内容块操作")
            }
        }.padding(.leading, CGFloat(block.indentLevel) * 16)
    }

    private func orderedNumber(for block: DocumentBlock) -> Int {
        guard let index = session.draft.document.blocks.firstIndex(where: { $0.id == block.id }) else { return 1 }
        return session.draft.document.blocks.prefix(index + 1).reversed().prefix(while: { $0.kind == .ordered }).count
    }

    private func versionPreview(_ note: Note) -> String {
        (try? BlockMarkdownCodec.exportMarkdown(note.document))
            ?? note.document.blocks.map { $0.inlineContent.spans.map(\.text).joined() }.joined(separator: "\n")
    }

    private func resolveRecovery(_ action: DraftRecoveryAction) {
        Task {
            resolvingRecovery = true
            defer { resolvingRecovery = false }
            if await session.resolveRecovery(action) { showingRecoveryReview = false }
        }
    }

    private func openLinkedNote(_ id: NoteID) {
        guard id != session.draft.id, workspace.store.state.notes[id] != nil else { return }
        Task {
            guard await session.flush() else { return }
            linkedNoteID = id
        }
    }

    private func openArrangement(_ target: WorkspaceDeepLinkTarget) {
        switch target {
        case let .calendarItem(id):
            guard let item = workspace.store.calendarState.items[id] else { return }
            calendarRequest = .init(mode: .editItem(item), draft: .init(item: item))
        case let .calendarOccurrence(key):
            guard let occurrence = CalendarDeepLinkTargetResolver.occurrence(for: key, calendar: workspace.store.calendarState),
                  let series = workspace.store.calendarState.recurrence.series[key.seriesID] else { return }
            calendarRequest = .init(mode: .editOccurrence(series: series, key: key, scope: .onlyThis), draft: .init(occurrence: occurrence, series: series))
        case let .calendarSeries(id):
            guard let occurrence = CalendarDeepLinkTargetResolver.representativeOccurrence(for: id, calendar: workspace.store.calendarState,
                today: .localDay(containing: Date(), in: .current)), let series = workspace.store.calendarState.recurrence.series[id] else { return }
            calendarRequest = .init(mode: .editOccurrence(series: series, key: occurrence.key, scope: .thisAndFuture), draft: .init(occurrence: occurrence, series: series))
        default: break
        }
    }

    private func beginSchedule(_ blockID: BlockID?) {
        Task {
            guard await session.flush() else { return }
            scheduleRequest = .init(blockID: blockID)
        }
    }

    private func permanentlyDelete() async {
        guard let preview = deletePreview else { return }
        let authorization = PermanentDeleteAuthorization(subject: preview.subject,
            sourceWorkspaceRevision: preview.sourceWorkspaceRevision, impactChecksum: preview.checksum)
        if await workspace.send(.permanentlyDeleteNote(session.draft.id, authorization: authorization), label: "永久删除笔记") {
            deletePreview = nil
            dismiss()
        }
    }

    private func inspectImport(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let source = try String(contentsOf: url, encoding: .utf8)
        if ["html", "htm"].contains(url.pathExtension.lowercased()) {
            let result = try BlockHTMLCodec.importHTML(source, checkedTaskCompletedAt: Date())
            imported = .init(document: result.document, diagnostics: result.diagnostics.map(\.message))
        } else {
            let result = try BlockMarkdownCodec.importMarkdown(source, checkedTaskCompletedAt: Date())
            imported = .init(document: result.document, diagnostics: result.diagnostics.map { "第\($0.lineNumber)行：\($0.message)" })
        }
    }

    private func export(html: Bool) {
        Task {
            guard await session.flush() else { return }
            do {
                let content = try html ? BlockHTMLCodec.exportHTML(session.draft.document, title: session.draft.title) : BlockMarkdownCodec.exportMarkdown(session.draft.document)
                exportType = html ? .html : (UTType(filenameExtension: "md") ?? .plainText)
                exportDocument = MobileNoteFile(text: content)
                showingExport = true
            } catch { workspace.errorMessage = "无法导出笔记：\(error.localizedDescription)" }
        }
    }
}

private struct MobileNoteLinkRequest: Identifiable {
    let id = UUID()
    let insert: (NoteID, String) -> Void
}

/// Searchable list of notes to link from the editor toolbar.
private struct MobileNoteLinkPicker: View {
    let state: WorkspaceState
    let excluding: NoteID
    let onPick: (Note) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let notes = NoteLinkIndex.candidates(matching: query, in: state, excluding: excluding, limit: 50)
                if notes.isEmpty {
                    Text(query.isEmpty ? "还没有其他笔记" : "没有标题包含这些字的笔记").foregroundStyle(.secondary)
                }
                ForEach(notes) { note in
                    Button { onPick(note) } label: {
                        HStack {
                            Text(note.title.isEmpty ? "无标题" : note.title)
                            Spacer()
                            if note.archivedAt != nil { Text("已归档").font(.caption).foregroundStyle(.secondary) }
                        }.frame(minHeight: 44)
                    }
                }
            }
            .searchable(text: $query, prompt: "按标题查找")
            .navigationTitle("链接到笔记").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MobileBlockKindChoice {
    let kind: BlockKind
    let title: String
    static let all: [Self] = [
        .init(kind: .paragraph, title: "正文"), .init(kind: .heading1, title: "一级标题"),
        .init(kind: .heading2, title: "二级标题"), .init(kind: .heading3, title: "三级标题"),
        .init(kind: .bullet, title: "无序列表"), .init(kind: .ordered, title: "有序列表"),
        .init(kind: .task, title: "待办"), .init(kind: .quote, title: "引用"),
        .init(kind: .code, title: "代码"), .init(kind: .divider, title: "分割线")
    ]
}

private struct MobileNoteScheduleRequest: Identifiable {
    let id = UUID()
    let blockID: BlockID?
}

private struct MobileNoteImportPreview: Identifiable {
    let id = UUID()
    let document: BlockDocument
    let diagnostics: [String]
}

private struct MobileNoteFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .html] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct MobileNoteScheduleSheet: View {
    @Bindable var workspace: MobileWorkspace
    let noteID: NoteID
    let blockID: BlockID?
    @Environment(\.dismiss) private var dismiss
    @State private var starts = Date()
    @State private var ends = Date().addingTimeInterval(3600)
    @State private var timed = true
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if let note = workspace.store.state.notes[noteID] {
                    Text(blockID.flatMap { id in note.document.blocks.first { $0.id == id }?.inlineContent.spans.map(\.text).joined() } ?? (note.title.isEmpty ? "无标题笔记" : note.title))
                        .font(.headline)
                }
                Toggle("设置时间", isOn: $timed)
                DatePicker("开始", selection: $starts, displayedComponents: timed ? [.date, .hourAndMinute] : [.date])
                DatePicker("结束", selection: $ends, in: starts..., displayedComponents: timed ? [.date, .hourAndMinute] : [.date])
                if let failure { Text(failure).foregroundStyle(.red) }
            }.jellySurface().navigationTitle("安排到日历").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("安排") { Task { await save() } }.disabled(busy) }
                }
        }
        .task {
            if let blockID, let link = workspace.store.state.taskBlockLinks.first(where: { $0.noteID == noteID && $0.blockID == blockID }),
               let item = workspace.store.calendarState.items[link.calendarItemID] {
                timed = item.schedule.startTime != nil
                starts = mobileDate(item.schedule.startDate, minute: item.schedule.startTime)
                ends = mobileDate(item.schedule.endDate, minute: item.schedule.endTime)
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        guard let note = workspace.store.state.notes[noteID] else { failure = "笔记不存在。"; return }
        do {
            let calendar = Calendar.current
            let startTime = timed ? MinuteOfDay(hour: calendar.component(.hour, from: starts), minute: calendar.component(.minute, from: starts)) : nil
            let endTime = timed ? MinuteOfDay(hour: calendar.component(.hour, from: ends), minute: calendar.component(.minute, from: ends)) : nil
            let schedule = try CalendarSchedule(startDate: .localDay(containing: starts, in: .current),
                endDate: .localDay(containing: ends, in: .current), startTime: startTime, endTime: endTime)
            let block = blockID.flatMap { id in note.document.blocks.first { $0.id == id && $0.kind == .task } }
            if blockID != nil && block == nil { failure = "待办已改变，请重新打开。"; return }
            let title = block.map { $0.inlineContent.spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? (note.title.isEmpty ? "无标题笔记" : note.title)
            guard !title.isEmpty else { failure = "请先填写待办内容。"; return }
            let existing = blockID.flatMap { blockID in workspace.store.state.taskBlockLinks.first { $0.noteID == noteID && $0.blockID == blockID } }
            let now = Date()
            var item: CalendarItem
            if let id = existing?.calendarItemID, let original = workspace.store.calendarState.items[id] {
                item = original
                item.schedule = schedule
            } else {
                item = try CalendarItem(id: UUID(), kind: .unifiedTODO, title: title,
                    categoryID: note.categoryID, schedule: schedule, completedAt: block?.taskState?.completedAt, createdAt: now, updatedAt: now)
            }
            let command: WorkspaceCommand
            if let blockID { command = .scheduleTaskBlock(.init(noteID: noteID, blockID: blockID, item: item)) }
            else { command = .scheduleNoteOnCalendar(.init(noteID: noteID, item: item)) }
            if await workspace.send(command, label: "安排到日历") { dismiss() }
            else { failure = workspace.errorMessage ?? "安排没有完成，原数据保持不变。" }
        } catch { failure = "无法安排：请检查起止日期和时间。\(error.localizedDescription)" }
    }
}

private func mobileDate(_ date: CalendarDate, minute: MinuteOfDay?) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day,
        hour: minute.map { $0.value / 60 } ?? 12, minute: minute.map { $0.value % 60 } ?? 0)) ?? Date()
}

private func mobileScheduleCaption(_ schedule: CalendarSchedule) -> String {
    let start = "\(schedule.startDate.month)月\(schedule.startDate.day)日"
    let end = schedule.startDate == schedule.endDate ? "" : "—\(schedule.endDate.month)月\(schedule.endDate.day)日"
    if let time = schedule.startTime, let endTime = schedule.endTime {
        return "\(start)\(end) \(String(format: "%02d:%02d", time.value / 60, time.value % 60))—\(String(format: "%02d:%02d", endTime.value / 60, endTime.value % 60))"
    }
    return "\(start)\(end) · 全天"
}
