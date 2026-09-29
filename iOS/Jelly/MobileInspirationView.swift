import CalendarDomain
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WorkspaceDomain

struct MobileInspirationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var workspace: MobileWorkspace
    @State private var model: InspirationViewModel
    @State private var scope = MobileInspirationScope.pending
    @State private var showingCapture = false
    @State private var capturedID: InspirationID?

    init(workspace: MobileWorkspace) {
        self.workspace = workspace
        _model = State(initialValue: InspirationViewModel(store: workspace.store,
            digestOperator: workspace.ai.digest, followUp: workspace.ai.followUp, isDigestConfigured: { workspace.ai.isConfigured }))
    }

    private var items: [Inspiration] {
        switch scope {
        case .pending: model.pending
        case .converted: model.converted
        case .archived: model.archived
        }
    }

    var body: some View {
        List {
            Picker("灵感范围", selection: $scope) {
                ForEach(MobileInspirationScope.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).listRowBackground(Color.clear)
            if items.isEmpty {
                MobileEmptyState(title: model.searchText.isEmpty ? "把灵感先收下来" : "没有找到灵感",
                    symbol: "lightbulb", message: "保存文字、网页和文件，稍后再整理成笔记。")
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { inspiration in
                NavigationLink {
                    MobileInspirationDetailView(workspace: workspace, inspiration: inspiration)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: mobileInspirationSymbol(inspiration)).font(.title3).frame(width: 30, height: 34)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.displayTitle(for: inspiration)).font(.headline).lineLimit(3)
                            if let url = inspiration.rawURL { Text(url.host ?? url.absoluteString).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            HStack {
                                Text(workspace.store.calendarState.categories[inspiration.categoryID]?.name ?? "未分类")
                                Spacer()
                                Text(inspiration.createdAt, style: .date)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
                .swipeActions {
                    Button(scope == .archived ? "恢复" : "归档", systemImage: scope == .archived ? "arrow.uturn.backward" : "archivebox") {
                        Task {
                            _ = await workspace.send(scope == .archived ? .restoreInspiration(inspiration.id, at: Date()) : .archiveInspiration(inspiration.id, at: Date()), label: scope == .archived ? "恢复灵感" : "归档灵感")
                            model.refresh()
                        }
                    }.tint(.brown)
                }
            }
        }
        .jellySurface().navigationTitle("灵感")
        .searchable(text: $model.searchText, prompt: "搜索文字、链接与材料")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("全部分类") { model.categoryFilterID = nil }
                    ForEach(workspace.store.calendarState.categories.values.sorted { $0.sortIndex < $1.sortIndex }) { category in
                        Button(category.name) { model.categoryFilterID = category.id }
                    }
                } label: {
                    Image(systemName: model.categoryFilterID == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }.accessibilityLabel("筛选灵感分类")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("收下灵感", systemImage: "plus.circle.fill") { showingCapture = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }.padding(.horizontal, 20).padding(.vertical, 8)
                .background(CalendarTheme.appearance(for: colorScheme).canvas)
        }
        .sheet(isPresented: $showingCapture) {
            MobileInspirationCaptureSheet(workspace: workspace) { id in
                scope = .pending
                capturedID = id
                model.refresh()
            }
        }
        .navigationDestination(item: $capturedID) { id in
            if let inspiration = workspace.store.state.inspirations[id] {
                MobileInspirationDetailView(workspace: workspace, inspiration: inspiration)
            }
        }
        .onChange(of: workspace.store.statePublicationGeneration) { _, _ in model.refresh() }
    }
}

private enum MobileInspirationScope: String, CaseIterable, Identifiable {
    case pending, converted, archived
    var id: Self { self }
    var title: String {
        switch self {
        case .pending: "待整理"
        case .converted: "已成笔记"
        case .archived: "已归档"
        }
    }
}

struct MobileInspirationDetailView: View {
    @Bindable var workspace: MobileWorkspace
    @State private var model: InspirationViewModel
    @State private var noteID: NoteID?
    @State private var busy = false
    @State private var actionError: String?
    @State private var composingText = false
    @State private var deleteRequest: InspirationPermanentDeleteRequest?
    @State private var recoveryCapture: MobileCaptureRecovery?
    @State private var replacementID: InspirationID?
    @State private var editorBarrierID = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(workspace: MobileWorkspace, inspiration: Inspiration) {
        self.workspace = workspace
        let model = InspirationViewModel(store: workspace.store, digestOperator: workspace.ai.digest,
            followUp: workspace.ai.followUp, isDigestConfigured: { workspace.ai.isConfigured })
        model.select(inspiration.id)
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if let inspiration = model.selected {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: mobileInspirationSymbol(inspiration)).font(.title2)
                            Text(model.displayTitle(for: inspiration)).font(.title3.weight(.semibold)).textSelection(.enabled)
                        }.padding(.vertical, 5)
                        Picker("分类", selection: Binding(get: { inspiration.categoryID }, set: { category in
                            Task {
                                do {
                                    if try await !model.changeSelectedCategory(to: category) { actionError = model.statusMessage ?? "分类没有修改成功。" }
                                } catch { actionError = error.localizedDescription }
                            }
                        })) {
                            ForEach(workspace.store.calendarState.categories.values.sorted { $0.sortIndex < $1.sortIndex }) { category in
                                Text(category.name).tag(category.id)
                            }
                        }
                        Text(inspiration.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    if inspiration.inputKind == .text {
                        Section("原始内容") {
                            if model.selectedTextIsEditable {
                                MobileCommittedPlainTextView(text: $model.selectedTextDraft, accessibilityName: "灵感内容",
                                    onCompositionChange: { composingText = $0 }).frame(minHeight: 220)
                                HStack {
                                    Text(textSaveCaption).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if model.selectedTextSaveState == .failed || model.selectedTextSaveState == .invalid {
                                        Button("重试保存") { Task { _ = await flush() } }
                                    }
                                }
                            } else {
                                Text(inspiration.rawText ?? "").textSelection(.enabled)
                                Text(model.selectedConvertedNoteID == nil ? "灵感已归档，恢复后可以继续补写。" : "已生成笔记，后续内容请在笔记中继续。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    MobileExpansionSection(inspiration: inspiration, followUp: workspace.ai.followUp)
                    if let url = inspiration.rawURL {
                        Section("来源") {
                            Link(destination: url) { Label(url.absoluteString, systemImage: "arrow.up.right.square").lineLimit(3) }
                            ShareLink(item: url) { Label("分享链接", systemImage: "square.and.arrow.up") }
                            if inspiration.resolvedMetadata?.fetchStatus == .loading {
                                ProgressView("正在读取来源信息…")
                            }
                            if inspiration.resolvedMetadata?.fetchStatus == .failed {
                                Button("重试读取来源信息") { Task { await model.retrySelectedMetadata() } }
                            }
                        }
                    }
                    if let file = inspiration.rawFile {
                        Section("来源文件") {
                            Label(file.displayName, systemImage: "doc")
                            Text("提炼时会检查本机是否仍可读取这个文件。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if inspiration.supportsMaterialDigest {
                        Section {
                            MobileDigestSection(workspace: workspace, inspirationID: inspiration.id,
                                onPasteRecovery: { recoveryCapture = .init(chooseFile: false) },
                                onChooseFileRecovery: { recoveryCapture = .init(chooseFile: true) })
                        }
                    }
                    Section {
                        Button {
                            Task { await convertToNote() }
                        } label: {
                            Label(model.selectedPrimaryActionTitle, systemImage: "doc.text")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(busy)
                        if inspiration.lifecycle == .active {
                            MobileScheduleMenu { choice in
                                Task {
                                    if await model.scheduleSelected(choice) { actionError = choice.confirmation }
                                    else { actionError = "没能变成待办，这条灵感还在。" }
                                }
                            }.disabled(busy)
                        }
                        Button(inspiration.lifecycle == .archived ? "恢复灵感" : "归档灵感",
                               systemImage: inspiration.lifecycle == .archived ? "arrow.uturn.backward" : "archivebox") {
                            Task { await changeLifecycle() }
                        }.disabled(busy)
                        if inspiration.lifecycle == .archived {
                            Button("永久删除", systemImage: "trash", role: .destructive) {
                                do { deleteRequest = try model.permanentDeleteRequest(for: inspiration.id) }
                                catch { actionError = error.localizedDescription }
                            }
                        }
                        if let message = actionError ?? model.statusMessage { Text(message).font(.caption).foregroundStyle(.red) }
                    }
                }.jellySurface().scrollDismissesKeyboard(.interactively)
            } else {
                MobileEmptyState(title: "灵感已不存在", symbol: "lightbulb", message: "返回灵感列表查看其他内容。")
            }
        }
        .navigationTitle("灵感详情").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回", systemImage: "chevron.left") { Task { if await flush() { dismiss() } } }
            }
        }
        .navigationDestination(item: $noteID) { id in
            if let note = workspace.store.state.notes[id] { MobileNoteDetailView(workspace: workspace, note: note) }
        }
        .navigationDestination(item: $replacementID) { id in
            if let inspiration = workspace.store.state.inspirations[id] { MobileInspirationDetailView(workspace: workspace, inspiration: inspiration) }
        }
        .sheet(item: $recoveryCapture) { request in
            MobileInspirationCaptureSheet(workspace: workspace, chooseFileInitially: request.chooseFile) { id in
                replacementID = id
            }
        }
        .confirmationDialog("永久删除这条灵感？", isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } }), titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { Task { await permanentlyDelete() } }
            Button("取消", role: .cancel) { deleteRequest = nil }
        } message: {
            Text("原始灵感将被删除；已经生成的笔记保留，\(deleteRequest?.preview.effects.count ?? 0) 处来源关联会标记为来源已删除。")
        }
        .onAppear { workspace.registerEditorBarrier(id: editorBarrierID) { await flush() } }
        .onDisappear {
            Task { if await flush() { workspace.unregisterEditorBarrier(id: editorBarrierID) } }
        }
        .onChange(of: workspace.store.statePublicationGeneration) { _, _ in model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { _ = await flush() } } }
    }

    private var textSaveCaption: String {
        switch model.selectedTextSaveState {
        case .idle: "原始内容已保留"
        case .waiting, .saving: "正在保存…"
        case .saved: "已保存"
        case .invalid: "内容不能为空，原内容仍保留"
        case .failed: "保存失败，输入仍保留"
        }
    }

    private func flush() async -> Bool {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        await Task.yield()
        guard !composingText else { actionError = "请先确认正在输入的文字。"; return false }
        await model.flushSelectedTextEdit()
        let succeeded = model.selectedTextSaveState != .invalid && model.selectedTextSaveState != .failed
        actionError = succeeded ? nil : "内容尚未保存，请检查或重试后再离开。"
        return succeeded
    }

    private func convertToNote() async {
        busy = true
        defer { busy = false }
        guard await flush() else { return }
        do {
            if let id = try await model.convertSelectedToNote() { noteID = id; actionError = nil }
            else { actionError = model.statusMessage ?? "笔记写入没有完成，原始灵感保留。" }
        } catch { actionError = "无法写入笔记：\(error.localizedDescription)" }
    }

    private func changeLifecycle() async {
        guard let inspiration = model.selected, await flush() else { return }
        busy = true
        defer { busy = false }
        do {
            let succeeded = try await (inspiration.lifecycle == .archived ? model.restoreSelected() : model.archiveSelected())
            if !succeeded { actionError = model.statusMessage ?? "操作没有完成，请稍后重试。" }
            else { actionError = nil }
        } catch { actionError = error.localizedDescription }
    }

    private func permanentlyDelete() async {
        guard let request = deleteRequest else { return }
        let preview = request.preview
        let authorization = PermanentDeleteAuthorization(subject: preview.subject,
            sourceWorkspaceRevision: preview.sourceWorkspaceRevision, impactChecksum: preview.checksum)
        do {
            if try await model.permanentlyDelete(request, authorization: authorization) {
                deleteRequest = nil
                dismiss()
            } else { actionError = "内容已变化，删除没有执行。请重新检查后再删除。" }
        } catch { actionError = error.localizedDescription }
    }
}

private struct MobileCaptureRecovery: Identifiable {
    let id = UUID()
    let chooseFile: Bool
}

private struct MobileInspirationCaptureSheet: View {
    @Bindable var workspace: MobileWorkspace
    let chooseFileInitially: Bool
    let onCaptured: (InspirationID) -> Void
    @State private var text = ""
    @State private var model: InspirationViewModel
    @State private var choosingFile = false
    @State private var busy = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(workspace: MobileWorkspace, chooseFileInitially: Bool = false, onCaptured: @escaping (InspirationID) -> Void) {
        self.workspace = workspace
        self.chooseFileInitially = chooseFileInitially
        self.onCaptured = onCaptured
        _model = State(initialValue: InspirationViewModel(store: workspace.store,
            digestOperator: workspace.ai.digest, followUp: workspace.ai.followUp, isDigestConfigured: { workspace.ai.isConfigured }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("文字或网页链接") {
                    TextEditor(text: $text).frame(minHeight: 190).focused($focused)
                        .scrollContentBackground(.hidden).accessibilityLabel("输入灵感文字或链接")
                    Text("先保存原始内容，之后再决定是否整理或提炼。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("从文件导入副本", systemImage: "doc.badge.plus") { choosingFile = true }
                        .disabled(busy)
                    Text("支持文字、HTML、图片、PDF、音频和视频。文件会复制到 Jelly 本机空间，不修改原文件。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }.jellySurface().navigationTitle("收下灵感").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await captureText() } }
                            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .interactiveDismissDisabled(busy || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .html, .image, .pdf, .audio, .movie, UTType(filenameExtension: "md") ?? .plainText]) { result in
            Task {
                do { await captureFile(try result.get()) }
                catch { failure = "文件没有导入：\(error.localizedDescription)" }
            }
        }
        .onAppear {
            if chooseFileInitially { choosingFile = true }
            else { focused = true }
        }
    }

    private func captureText() async {
        busy = true
        defer { busy = false }
        do {
            let id = try await model.capture(text)
            onCaptured(id)
            dismiss()
        } catch { failure = "没有保存成功，输入仍保留。\(error.localizedDescription)" }
    }

    private func captureFile(_ original: URL) async {
        busy = true
        defer { busy = false }
        let access = original.startAccessingSecurityScopedResource()
        defer { if access { original.stopAccessingSecurityScopedResource() } }
        do {
            let materialsRoot = workspace.rootURL.appendingPathComponent("Materials", isDirectory: true)
            let (reference, kind) = try await Task.detached(priority: .userInitiated) {
                let kind = try mobileMaterialKind(original)
                let directory = materialsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(original.lastPathComponent)
                try FileManager.default.copyItem(at: original, to: destination)
                let bookmark = try destination.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: [.contentTypeKey, .fileSizeKey], relativeTo: nil)
                return (FileReference(bookmarkData: bookmark, displayName: original.lastPathComponent), kind)
            }.value
            let id = try await model.captureFile(reference, kind: kind)
            onCaptured(id)
            dismiss()
        } catch {
            // Retain any copied source if a transaction's outcome is uncertain.
            // Removing it here could invalidate a successfully persisted bookmark.
            failure = "文件没有完成导入，原文件未修改。\(error.localizedDescription)"
        }
    }
}

private func mobileMaterialKind(_ url: URL) throws -> ResolvedSourceKind {
    let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
        ?? UTType(filenameExtension: url.pathExtension)
    if type?.conforms(to: .image) == true { return .image }
    if type?.conforms(to: .pdf) == true { return .document }
    if type?.conforms(to: .audio) == true { return .audio }
    if type?.conforms(to: .movie) == true { return .video }
    if type?.conforms(to: .html) == true { return .article }
    if type?.conforms(to: .plainText) == true || ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) { return .plainText }
    throw CocoaError(.fileReadUnsupportedScheme)
}

private func mobileInspirationSymbol(_ inspiration: Inspiration) -> String {
    switch inspiration.resolvedSourceKind {
    case .video: "play.rectangle"
    case .audio: "waveform"
    case .image: "photo"
    case .document: "doc.richtext"
    case .article: "doc.text"
    case .socialPost: "text.bubble"
    case .plainText: "text.alignleft"
    case .unknown: inspiration.inputKind == .url ? "link" : "doc"
    }
}
