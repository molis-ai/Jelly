import CalendarDomain
import Foundation
import WorkspaceDomain

enum CalendarNotePresentedSheet: Equatable, Sendable {
    case legacyNotesResolution(NoteID)
    case notePicker(isPrimary: Bool)
    case scheduleNote(NoteID)
}

/// Main-actor integration surface between calendar items and Notes relations.
@MainActor
@Observable final class CalendarNoteIntegrationModel {
    private let store: WorkspaceStore
    private let clock: @Sendable () -> Date
    let target: CalendarTargetID

    private(set) var resolved: ResolvedCalendarNoteRelation?
    private(set) var presentedSheet: CalendarNotePresentedSheet?
    private(set) var statusMessage: String?
    private(set) var legacyMigrationPreview: LegacyMarkdownMigrationPreview?
    private var legacyPreviewNoteRevision: Int64?
    private var legacyPreviewCheckedTaskCompletedAt: Date?

    init(
        target: CalendarTargetID,
        store: WorkspaceStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.target = target
        self.store = store
        self.clock = clock
        refresh()
    }

    var primaryNote: Note? {
        resolved.flatMap { set in
            set.noteSet.primaryNoteID.flatMap { store.state.notes[$0] }
        }
    }

    var referenceNotes: [Note] {
        guard let set = resolved?.noteSet else { return [] }
        return set.referenceNoteIDs
            .compactMap { store.state.notes[$0] }
            .sorted {
                $0.updatedAt != $1.updatedAt
                    ? $0.updatedAt > $1.updatedAt
                    : $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
    }

    var hasLegacyMarkdown: Bool {
        legacyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var legacyMarkdown: String {
        switch target {
        case let .item(id):
            return store.calendarState.items[id]?.notes ?? ""
        case let .series(id):
            return store.calendarState.recurrence.series[id]?.notes ?? ""
        case let .occurrence(key):
            return store.calendarState.recurrence.series[key.seriesID]?.notes ?? ""
        }
    }

    func refresh() {
        do {
            resolved = try CalendarNoteRelationResolver.resolve(
                target,
                calendar: store.calendarState,
                relations: store.state.calendarNoteRelations
            )
            statusMessage = nil
        } catch {
            resolved = nil
            statusMessage = "无法解析笔记关系。"
        }
    }

    func scopeForItemActions() -> CalendarRelationScope {
        switch target {
        case let .item(id): .item(id)
        case let .series(id): .series(id)
        case let .occurrence(key): .occurrenceOnly(key)
        }
    }

    @discardableResult
    func createPrimaryNote() async throws -> Bool {
        let now = clock()
        let metadata = suggestedPrimaryNoteMetadata
        var note = Note.empty(
            id: NoteID(),
            categoryID: metadata?.categoryID ?? store.calendarState.uncategorizedID,
            now: now
        )
        note.title = metadata?.title ?? ""
        if hasLegacyMarkdown {
            // Domain requires explicit legacy authorization for nonempty legacy
            // notes; without a preview authorization we refuse rather than drop text.
            presentedSheet = nil
            statusMessage = "存在旧随记，请先选择预览并合并或另建主笔记。"
            return false
        }
        let payload = CreatePrimaryNoteForCalendarPayload(
            scope: scopeForItemActions(),
            note: note,
            legacyImportAuthorization: nil
        )
        let outcome = try await store.sendWorkspace(
            .createPrimaryNoteForCalendar(payload),
            undoLabel: "新建主笔记"
        )
        refresh()
        return isCommitted(outcome)
    }

    private var suggestedPrimaryNoteMetadata: (title: String, categoryID: UUID)? {
        switch target {
        case let .item(id):
            guard let item = store.calendarState.items[id] else { return nil }
            return (item.title, item.categoryID)
        case let .series(id):
            guard let series = store.calendarState.recurrence.series[id] else { return nil }
            return (series.title, series.categoryID)
        case let .occurrence(key):
            guard let series = store.calendarState.recurrence.series[key.seriesID] else { return nil }
            if case let .modified(override)? = store.calendarState.recurrence.exceptions[key] {
                return (override.title, override.categoryID)
            }
            return (series.title, series.categoryID)
        }
    }

    @discardableResult
    func chooseExistingPrimary(_ noteID: NoteID) async throws -> Bool {
        if hasLegacyMarkdown {
            let prepared = try prepareLegacyMigrationPreview()
            legacyMigrationPreview = prepared.preview
            legacyPreviewCheckedTaskCompletedAt = prepared.checkedTaskCompletedAt
            legacyPreviewNoteRevision = store.state.notes[noteID]?.revision
            presentedSheet = .legacyNotesResolution(noteID)
            // Domain forbids attaching primary while legacy markdown remains.
            return false
        }
        return try await attachPrimary(noteID, legacyResolution: nil)
    }

    /// A workspace imported from the calendar-only format may not contain any
    /// notes yet. Preview the same migration without inventing a target note.
    func previewLegacyForNewPrimary() throws {
        let prepared = try prepareLegacyMigrationPreview()
        legacyMigrationPreview = prepared.preview
        legacyPreviewCheckedTaskCompletedAt = prepared.checkedTaskCompletedAt
        legacyPreviewNoteRevision = nil
        presentedSheet = nil
        statusMessage = nil
    }

    @discardableResult
    func mergeLegacyIntoExistingPrimary(_ noteID: NoteID) async throws -> Bool {
        guard let preview = legacyMigrationPreview,
              let expectedRevision = legacyPreviewNoteRevision,
              let checkedTaskCompletedAt = legacyPreviewCheckedTaskCompletedAt,
              store.state.notes[noteID] != nil
        else {
            statusMessage = "迁移预览已失效，请重新选择笔记。"
            return false
        }
        let outcome: Bool
        do {
            let transaction = try await store.sendWorkspace(
                .attachPrimaryNote(.init(
                    scope: scopeForItemActions(),
                    noteID: noteID,
                    legacyResolution: .previewAndMerge(
                        expectedNoteRevision: expectedRevision,
                        importAuthorization: authorization(
                            for: preview,
                            checkedTaskCompletedAt: checkedTaskCompletedAt
                        )
                    ),
                    replacing: resolved?.noteSet.primaryNoteID != nil ? .detachOldPrimary : nil,
                    linkedTaskDisposition: nil
                )),
                undoLabel: "迁移旧随记"
            )
            refresh()
            outcome = isCommitted(transaction)
        } catch {
            statusMessage = "旧随记合并失败，原文和目标笔记均未被替换。"
            throw error
        }
        if outcome {
            clearLegacyPreview()
        } else {
            statusMessage = "旧随记或目标笔记已变化，请重新预览。"
            try refreshLegacyPreview(for: noteID)
        }
        return outcome
    }

    @discardableResult
    func createPrimaryNoteFromLegacyPreview() async throws -> Bool {
        guard let preview = legacyMigrationPreview,
              let checkedTaskCompletedAt = legacyPreviewCheckedTaskCompletedAt
        else {
            statusMessage = "迁移预览已失效，请重新开始。"
            return false
        }
        let now = clock()
        var note = Note.empty(
            id: NoteID(),
            categoryID: store.calendarState.uncategorizedID,
            now: now
        )
        note.title = "旧随记"
        note.document = preview.document
        let outcome: WorkspaceTransactionOutcome
        do {
            outcome = try await store.sendWorkspace(
                .createPrimaryNoteForCalendar(.init(
                    scope: scopeForItemActions(),
                    note: note,
                    legacyImportAuthorization: authorization(
                        for: preview,
                        checkedTaskCompletedAt: checkedTaskCompletedAt
                    )
                )),
                undoLabel: "迁移旧随记"
            )
        } catch {
            statusMessage = "新建主笔记失败，旧随记仍保留在原处。"
            throw error
        }
        refresh()
        guard isCommitted(outcome) else {
            statusMessage = "旧随记已变化，请重新预览。"
            return false
        }
        clearLegacyPreview()
        return true
    }

    @discardableResult
    func attachPrimary(
        _ noteID: NoteID,
        legacyResolution: ExistingPrimaryLegacyResolution?
    ) async throws -> Bool {
        let payload = AttachPrimaryNotePayload(
            scope: scopeForItemActions(),
            noteID: noteID,
            legacyResolution: legacyResolution,
            replacing: resolved?.noteSet.primaryNoteID != nil ? .detachOldPrimary : nil,
            linkedTaskDisposition: nil
        )
        let outcome = try await store.sendWorkspace(
            .attachPrimaryNote(payload),
            undoLabel: "关联主笔记"
        )
        presentedSheet = nil
        refresh()
        return isCommitted(outcome)
    }

    @discardableResult
    func attachReference(_ noteID: NoteID) async throws -> Bool {
        let outcome = try await store.sendWorkspace(
            .attachReferenceNote(scopeForItemActions(), noteID),
            undoLabel: "添加参考笔记"
        )
        refresh()
        return isCommitted(outcome)
    }

    @discardableResult
    func requiresTaskUnlinkBeforeDetaching(_ noteID: NoteID) -> Bool {
        guard primaryNote?.id == noteID,
              case let .item(itemID) = target else { return false }
        return store.state.taskBlockLinks.contains {
            $0.noteID == noteID && $0.calendarItemID == itemID
        }
    }

    @discardableResult
    func detach(
        _ noteID: NoteID,
        linkedTaskDisposition: TaskBlockPrimaryChangeDisposition? = nil
    ) async throws -> Bool {
        let outcome = try await store.sendWorkspace(
            .detachNote(
                scopeForItemActions(),
                noteID,
                linkedTaskDisposition: linkedTaskDisposition
            ),
            undoLabel: "取消关联笔记"
        )
        refresh()
        return isCommitted(outcome)
    }

    @discardableResult
    func scheduleNoteOnCalendar(noteID: NoteID, item: CalendarItem) async throws -> Bool {
        let outcome = try await store.sendWorkspace(
            .scheduleNoteOnCalendar(.init(noteID: noteID, item: item)),
            undoLabel: "从笔记安排到日历"
        )
        refresh()
        return isCommitted(outcome)
    }

    func openNotePicker(isPrimary: Bool) {
        presentedSheet = .notePicker(isPrimary: isPrimary)
    }

    func dismissSheet() {
        presentedSheet = nil
        clearLegacyPreview()
    }

    private func prepareLegacyMigrationPreview() throws -> (
        preview: LegacyMarkdownMigrationPreview,
        checkedTaskCompletedAt: Date
    ) {
        let completedAt = clock()
        let initial = try BlockMarkdownCodec.importMarkdown(
            legacyMarkdown,
            checkedTaskCompletedAt: completedAt
        )
        let preview = try LegacyMarkdownMigrationPlanner.preview(
            scope: scopeForItemActions(),
            in: store.state,
            injectedBlockIDs: initial.document.blocks.map(\.id),
            checkedTaskCompletedAt: completedAt
        )
        return (preview, completedAt)
    }

    private func authorization(
        for preview: LegacyMarkdownMigrationPreview,
        checkedTaskCompletedAt: Date
    ) -> LegacyMarkdownImportAuthorization {
        LegacyMarkdownImportAuthorization(
            expectedSourceChecksum: preview.sourceChecksum,
            injectedBlockIDs: preview.document.blocks.map(\.id),
            checkedTaskCompletedAt: checkedTaskCompletedAt,
            diagnostics: preview.diagnostics.isEmpty
                ? .rejectIfPresent
                : .accept(expectedDiagnosticsChecksum: preview.diagnosticsChecksum)
        )
    }

    private func clearLegacyPreview() {
        legacyMigrationPreview = nil
        legacyPreviewNoteRevision = nil
        legacyPreviewCheckedTaskCompletedAt = nil
        presentedSheet = nil
    }

    private func refreshLegacyPreview(for noteID: NoteID) throws {
        guard hasLegacyMarkdown else {
            clearLegacyPreview()
            return
        }
        let prepared = try prepareLegacyMigrationPreview()
        legacyMigrationPreview = prepared.preview
        legacyPreviewCheckedTaskCompletedAt = prepared.checkedTaskCompletedAt
        legacyPreviewNoteRevision = store.state.notes[noteID]?.revision
        presentedSheet = .legacyNotesResolution(noteID)
    }

    private func isCommitted(_ outcome: WorkspaceTransactionOutcome) -> Bool {
        if case .committed = outcome { return true }
        return false
    }
}
