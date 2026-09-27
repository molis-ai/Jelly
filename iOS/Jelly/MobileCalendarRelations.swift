import SwiftUI
import CalendarDomain
import WorkspaceDomain

/// Relationships are edited through the same workspace commands as the Mac.
/// The editor owns a specific occurrence; series scope is never inferred.
struct MobileCalendarRelations: View {
    let workspace: MobileWorkspace
    let target: CalendarTargetID
    @State private var model: CalendarNoteIntegrationModel
    @State private var pickerPrimary: Bool?
    @State private var replacing: Note?
    @State private var detaching: Note?
    @State private var message: String?
    @State private var busy = false

    init(workspace: MobileWorkspace, target: CalendarTargetID) {
        self.workspace = workspace; self.target = target
        _model = State(initialValue: CalendarNoteIntegrationModel(target: target, store: workspace.store))
    }

    var body: some View {
        Section("关联笔记") {
            if case .occurrence = target { Text("这里的关联仅应用于当前这次重复事项。").font(.caption).foregroundStyle(.secondary) }
            if let primary = model.primaryNote {
                HStack {
                    NavigationLink { MobileNoteDetailView(workspace: workspace, note: primary) } label: {
                        Label(primary.title.isEmpty ? "未命名主笔记" : primary.title, systemImage: "doc.text.fill")
                    }
                    Button("取消关联", systemImage: "link.badge.minus") { detaching = primary }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
            }
            ForEach(model.referenceNotes) { note in
                HStack {
                    NavigationLink { MobileNoteDetailView(workspace: workspace, note: note) } label: {
                        Label(note.title.isEmpty ? "未命名参考笔记" : note.title, systemImage: "doc.text")
                    }
                    Button("取消关联", systemImage: "link.badge.minus") { detaching = note }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
            }
            if model.primaryNote == nil {
                if model.hasLegacyMarkdown {
                    Button("预览随记并转成新笔记", systemImage: "doc.badge.plus") {
                        do { try model.previewLegacyForNewPrimary() }
                        catch { message = WorkspaceMutationOutcomePresenter.message(for: error) }
                    }
                } else {
                    Button("新建主笔记", systemImage: "doc.badge.plus") {
                        run { try await model.createPrimaryNote() }
                    }
                }
            }
            Button(model.primaryNote == nil ? "关联已有主笔记" : "更换主笔记", systemImage: "link") { pickerPrimary = true }
            Button("添加参考笔记", systemImage: "plus") { pickerPrimary = false }
            if model.hasLegacyMarkdown, model.primaryNote == nil {
                Text("随记已有内容。关联主笔记时会先预览迁移，原内容不会被静默丢弃。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = message ?? model.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(busy)
        .onChange(of: workspace.store.statePublicationGeneration) { _, _ in model.refresh() }
        .sheet(isPresented: Binding(get: { pickerPrimary != nil }, set: { if !$0 { pickerPrimary = nil } })) {
            NavigationStack {
                List(workspace.state.notes.values.filter { $0.archivedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }) { note in
                    Button(note.title.isEmpty ? "未命名笔记" : note.title) {
                        let primary = pickerPrimary == true
                        pickerPrimary = nil
                        if primary, model.primaryNote != nil { replacing = note }
                        else if primary { run { try await model.chooseExistingPrimary(note.id) } }
                        else { run { try await model.attachReference(note.id) } }
                    }.frame(minHeight: 44)
                }.jellySurface().navigationTitle("选择笔记")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { pickerPrimary = nil } } }
            }
        }
        .sheet(isPresented: Binding(get: { model.legacyMigrationPreview != nil }, set: { if !$0 { model.dismissSheet() } })) {
            legacyPreview
        }
        .confirmationDialog("更换主笔记？", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), titleVisibility: .visible) {
            Button("保留旧笔记为参考并更换") {
                guard let replacement = replacing else { return }
                replacing = nil
                run {
                    let linked = model.primaryNote.map { model.requiresTaskUnlinkBeforeDetaching($0.id) } ?? false
                    return await workspace.send(.attachPrimaryNote(.init(scope: model.scopeForItemActions(), noteID: replacement.id, legacyResolution: nil, replacing: .demoteOldPrimaryToReference, linkedTaskDisposition: linked ? .unlinkPreservingCompletion : nil)), label: "更换主笔记")
                }
            }
        } message: { Text("旧笔记保留为参考；原主笔记待办与此事项的联动会解除，双方内容和完成状态保留。") }
        .confirmationDialog("取消笔记关联？", isPresented: Binding(get: { detaching != nil }, set: { if !$0 { detaching = nil } }), titleVisibility: .visible) {
            Button("取消关联") {
                guard let note = detaching else { return }
                detaching = nil
                run { try await model.detach(note.id, linkedTaskDisposition: model.requiresTaskUnlinkBeforeDetaching(note.id) ? .unlinkPreservingCompletion : nil) }
            }
        } message: { Text("笔记和事项都会保留；若有待办联动，将解除联动并保留双方完成状态。") }
    }

    private var legacyPreview: some View {
        NavigationStack {
            List {
                Section("将迁移的随记") { Text(model.legacyMarkdown).textSelection(.enabled) }
                if let preview = model.legacyMigrationPreview {
                    Section("格式转换说明") {
                        if preview.diagnostics.isEmpty { Text("没有发现有损转换。") }
                        ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in Text(diagnostic.message) }
                    }
                }
                Section {
                    if case let .legacyNotesResolution(noteID) = model.presentedSheet {
                        Button("确认合并到所选笔记") { run { try await model.mergeLegacyIntoExistingPrimary(noteID) } }
                    }
                    Button("确认新建主笔记") { run { try await model.createPrimaryNoteFromLegacyPreview() } }
                }
            }.jellySurface().navigationTitle("随记迁移预览")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { model.dismissSheet() } } }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Bool) {
        busy = true
        Task {
            defer { busy = false; model.refresh() }
            do {
                let succeeded = try await operation()
                message = succeeded ? nil : model.statusMessage ?? workspace.errorMessage
            } catch { message = WorkspaceMutationOutcomePresenter.message(for: error) }
        }
    }
}
