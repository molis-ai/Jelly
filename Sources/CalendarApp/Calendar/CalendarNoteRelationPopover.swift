import CalendarDomain
import SwiftUI
import WorkspaceDomain

/// One action cluster at a time: convert, associate, or manage a linked note.
enum CalendarNoteRelationLayout: Equatable, Sendable {
    case convertLegacy
    case empty
    case linked

    static func make(hasPrimary: Bool, hasLegacyMarkdown: Bool) -> Self {
        if hasPrimary { return .linked }
        if hasLegacyMarkdown { return .convertLegacy }
        return .empty
    }

    var caption: String? {
        switch self {
        case .convertLegacy:
            "随记还在事项里。转成笔记后才能关联。"
        case .empty, .linked:
            nil
        }
    }
}

/// Compact 笔记 section for item detail: primary first, references below.
struct CalendarNoteRelationPopover: View {
    @Bindable var model: CalendarNoteIntegrationModel
    let store: WorkspaceStore
    var onOpenNote: (NoteID) -> Void
    @State private var pendingLinkedTaskDetach: NoteID?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var layout: CalendarNoteRelationLayout {
        .make(hasPrimary: model.primaryNote != nil, hasLegacyMarkdown: model.hasLegacyMarkdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("笔记")
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)

            if let primary = model.primaryNote {
                noteRow(primary, badge: "主笔记") {
                    if model.requiresTaskUnlinkBeforeDetaching(primary.id) {
                        pendingLinkedTaskDetach = primary.id
                    } else {
                        Task { _ = try? await model.detach(primary.id) }
                    }
                }
            }

            if !model.referenceNotes.isEmpty {
                ForEach(model.referenceNotes) { note in
                    noteRow(note, badge: note.archivedAt == nil ? "参考" : "已归档") {
                        Task { _ = try? await model.detach(note.id) }
                    }
                }
            }

            if let caption = layout.caption {
                Text(caption)
                    .font(EditorFormStyle.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions

            if let status = model.statusMessage {
                Text(status)
                    .font(EditorFormStyle.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .sheet(item: legacySheetBinding) { noteID in
            LegacyNotesMigrationSheet(
                model: model,
                noteID: noteID,
                onCancel: { model.dismissSheet() }
            )
        }
        .sheet(isPresented: notePickerPresented) {
            CalendarNotePicker(
                store: store,
                title: model.primaryNote == nil ? "选择主笔记" : "添加参考笔记"
            ) { noteID in
                Task {
                    if model.primaryNote == nil {
                        _ = try? await model.chooseExistingPrimary(noteID)
                    } else {
                        _ = try? await model.attachReference(noteID)
                        model.dismissSheet()
                    }
                }
            } onCancel: {
                model.dismissSheet()
            }
        }
        .confirmationDialog(
            "先解除待办与日历的联动？",
            isPresented: Binding(
                get: { pendingLinkedTaskDetach != nil },
                set: { if !$0 { pendingLinkedTaskDetach = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("解除联动并取消主笔记", role: .destructive) {
                guard let noteID = pendingLinkedTaskDetach else { return }
                pendingLinkedTaskDetach = nil
                Task {
                    _ = try? await model.detach(
                        noteID,
                        linkedTaskDisposition: .unlinkPreservingCompletion
                    )
                }
            }
            Button("取消", role: .cancel) { pendingLinkedTaskDetach = nil }
        } message: {
            Text("这篇主笔记里有待办与当前日历事项联动。解除后两边内容和完成状态都会保留，但之后各自独立。")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch layout {
        case .convertLegacy:
            Button("转成笔记") {
                model.openNotePicker(isPrimary: true)
            }
            .controlSize(.small)
            .disabled(store.phase != .ready)
        case .empty:
            HStack(spacing: 8) {
                Button("新建") {
                    Task { _ = try? await model.createPrimaryNote() }
                }
                Button("添加已有") {
                    model.openNotePicker(isPrimary: true)
                }
            }
            .controlSize(.small)
            .disabled(store.phase != .ready)
        case .linked:
            Button("添加参考") {
                model.openNotePicker(isPrimary: false)
            }
            .controlSize(.small)
            .disabled(store.phase != .ready)
        }
    }

    private func noteRow(
        _ note: Note,
        badge: String?,
        onDetach: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title.isEmpty ? "无标题" : note.title)
                    .font(EditorFormStyle.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(EditorFormStyle.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button("打开") { onOpenNote(note.id) }
                .controlSize(.small)
            Button("取消关联", role: .destructive, action: onDetach)
                .controlSize(.small)
        }
    }

    private var legacySheetBinding: Binding<NoteID?> {
        Binding(
            get: {
                if case let .legacyNotesResolution(id) = model.presentedSheet { return id }
                return nil
            },
            set: { if $0 == nil { model.dismissSheet() } }
        )
    }

    private var notePickerPresented: Binding<Bool> {
        Binding(
            get: {
                if case .notePicker = model.presentedSheet { return true }
                return false
            },
            set: { if !$0 { model.dismissSheet() } }
        )
    }
}

extension NoteID: Identifiable {
    public var id: NoteID { self }
}
