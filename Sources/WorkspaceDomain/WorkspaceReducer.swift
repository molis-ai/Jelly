import CalendarDomain
import Foundation

struct WorkspaceMutationMetadata: Equatable, Sendable {
    var draftContext: PersistableDraftContext?
    var seriesOutcome: SeriesFutureMutationOutcome?
}

enum WorkspaceCommandControl: Equatable, Sendable {
    case proceed
    case result(WorkspaceReductionResult)
}

public enum WorkspaceReducer {
    public static func reduce(
        _ state: WorkspaceState,
        command: WorkspaceCommand,
        now: Date
    ) throws -> WorkspaceReductionResult {
        if case let .repairConsistency(payload) = command {
            return try reduceConsistencyRepair(state, payload: payload)
        }

        do {
            try WorkspaceValidator.validate(state)
        } catch {
            throw WorkspaceReducerError.invalidInputWorkspace
        }

        if case let .restoreContent(payload) = command {
            return try reduceRestore(state, payload: payload)
        }

        var candidate = state
        var metadata = WorkspaceMutationMetadata()
        let control = try apply(command, to: &candidate, now: now, metadata: &metadata)
        if case let .result(result) = control { return result }

        guard !businessEquivalent(candidate, state) else {
            return .noChange(.identical)
        }

        let changedNoteIDs = try allocateRevisions(from: state, to: &candidate)
        if let draft = metadata.draftContext,
           let finalNote = candidate.notes[draft.noteID] {
            metadata.draftContext = .init(
                noteID: finalNote.id,
                editSessionID: draft.editSessionID,
                draftGeneration: draft.draftGeneration,
                noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(finalNote),
                persistedNoteRevision: finalNote.revision
            )
        }
        do {
            try WorkspaceValidator.validate(candidate)
        } catch {
            throw WorkspaceReducerError.finalValidationFailed
        }
        return .changed(.init(
            state: candidate,
            changedNoteIDs: changedNoteIDs,
            draftContext: metadata.draftContext,
            seriesOutcome: metadata.seriesOutcome
        ))
    }

    private static func apply(
        _ command: WorkspaceCommand,
        to candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws -> WorkspaceCommandControl {
        switch command {
        case let .calendar(command):
            try applyCalendar(command, to: &candidate, now: now, metadata: &metadata)
        case let .createNote(payload):
            try createNote(payload.note, in: &candidate)
        case let .updateNote(submission):
            return try updateNote(submission, in: &candidate, now: now, metadata: &metadata)
        case let .archiveNote(noteID, at):
            try setNoteArchive(noteID, archivedAt: at, in: &candidate, now: at)
        case let .restoreNote(noteID, at):
            try setNoteArchive(noteID, archivedAt: nil, in: &candidate, now: at)
        case let .setNotePinned(noteID, isPinned, at):
            try setNotePinned(noteID, isPinned: isPinned, in: &candidate, now: at)
        case let .permanentlyDeleteNote(noteID, authorization):
            return try permanentlyDeleteNote(noteID, authorization: authorization, in: &candidate)
        case let .createPrimaryNoteForCalendar(payload):
            return try createPrimaryNote(payload, in: &candidate, now: now, metadata: &metadata)
        case let .attachPrimaryNote(payload):
            return try attachPrimaryNote(payload, in: &candidate, now: now, metadata: &metadata)
        case let .attachReferenceNote(scope, noteID):
            try attachReferenceNote(scope, noteID: noteID, in: &candidate, now: now, metadata: &metadata)
        case let .detachNote(scope, noteID, disposition):
            try detachNote(
                scope,
                noteID: noteID,
                linkedTaskDisposition: disposition,
                in: &candidate,
                now: now,
                metadata: &metadata
            )
        case let .scheduleNoteOnCalendar(payload):
            try scheduleNote(payload, in: &candidate, now: now, metadata: &metadata)
        case let .scheduleTaskBlock(payload):
            try scheduleTaskBlock(payload, in: &candidate, now: now, metadata: &metadata)
        case let .unlinkTaskBlock(noteID, blockID):
            return unlinkTaskBlock(noteID: noteID, blockID: blockID, in: &candidate)
        case let .setTaskCompletion(target, value):
            return try setTaskCompletion(target, value: value, in: &candidate, now: now)
        case let .createInspiration(payload):
            try createInspiration(payload.inspiration, in: &candidate)
        case let .updateInspirationText(id, rawText, at):
            return try updateInspirationText(id, rawText: rawText, in: &candidate, now: at)
        case let .updateInspirationMetadata(id, expectation, metadataValue, kind):
            return try updateInspirationMetadata(
                id,
                expectation: expectation,
                metadata: metadataValue,
                kind: kind,
                in: &candidate,
                now: now
            )
        case let .convertInspirationToNote(payload):
            return try convertInspiration(payload, in: &candidate, now: now)
        case let .writeMaterialDigestToNote(payload):
            return try writeMaterialDigestToNote(payload, in: &candidate, now: now)
        case let .changeInspirationCategory(id, categoryID, at):
            return try changeInspirationCategory(id, categoryID: categoryID, in: &candidate, now: at)
        case let .archiveInspiration(id, at):
            try setInspirationLifecycle(id, lifecycle: .archived, in: &candidate, now: at)
        case let .restoreInspiration(id, at):
            try setInspirationLifecycle(id, lifecycle: .active, in: &candidate, now: at)
        case let .permanentlyDeleteInspiration(id, at, authorization):
            return try permanentlyDeleteInspiration(
                id,
                deletedAt: at,
                authorization: authorization,
                in: &candidate
            )
        case let .startMaterialDigest(payload):
            return try startMaterialDigest(payload, in: &candidate, now: now)
        case let .saveMaterialSnapshot(payload):
            return try saveMaterialSnapshot(payload, in: &candidate, now: now)
        case let .advanceMaterialDigestStage(payload):
            return try advanceMaterialDigestStage(payload, in: &candidate, now: now)
        case let .completeMaterialDigest(payload):
            return try completeMaterialDigest(payload, in: &candidate, now: now)
        case let .failMaterialDigest(payload):
            return try failMaterialDigest(payload, in: &candidate, now: now)
        case let .cancelMaterialDigest(expectation):
            return try cancelMaterialDigest(expectation, in: &candidate, now: now)
        case let .markInterruptedMaterialDigest(expectation):
            return try markInterruptedMaterialDigest(expectation, in: &candidate, now: now)
        case let .createCategory(category):
            try applyCategory(.createCategory(category), to: &candidate, now: now)
        case let .updateCategory(category):
            try applyCategory(.updateCategory(category), to: &candidate, now: now)
        case let .reorderCategories(ids):
            try applyCategory(.reorderCategories(ids), to: &candidate, now: now)
        case let .deleteCategory(id):
            try deleteCategory(id, in: &candidate, now: now)
        case let .applyDecompositionPlan(payload):
            return try applyDecompositionPlan(payload, in: &candidate, now: now, metadata: &metadata)
        case .repairConsistency, .restoreContent:
            preconditionFailure("special commands are handled before the ordinary pipeline")
        }
        return .proceed
    }

    static func applyCalendar(
        _ command: CalendarCommand,
        to candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws {
        switch command {
        case .createCategory, .updateCategory, .reorderCategories, .deleteCategory:
            throw WorkspaceReducerError.rawCalendarCategoryCommandRejected
        default:
            break
        }

        let reduction: CalendarReduction
        do {
            reduction = try CalendarReducer.reduceWithOutcome(candidate.calendar, command: command, now: now)
        } catch let error as SeriesMutationError {
            throw WorkspaceReducerError.seriesMutationFailure(error)
        } catch let error as ReducerError {
            throw WorkspaceReducerError.calendarFailure(error)
        }
        candidate.calendar = reduction.state
        if let outcome = reduction.seriesOutcome {
            do {
                candidate.calendarNoteRelations = try SeriesRelationMigration.apply(
                    outcome,
                    resultingGraph: candidate.calendar.recurrence,
                    to: candidate.calendarNoteRelations
                )
            } catch let error as SeriesRelationMigrationError {
                throw WorkspaceReducerError.relationMigrationFailure(error)
            }
            metadata.seriesOutcome = outcome
        }
        if case let .setTaskCompleted(itemID, completedAt) = command,
           let link = candidate.taskBlockLinks.first(where: { $0.calendarItemID == itemID }),
           var note = candidate.notes[link.noteID],
           let blockIndex = note.document.blocks.firstIndex(where: {
               $0.id == link.blockID && $0.kind == .task
           }) {
            note.document.blocks[blockIndex].taskState?.completedAt = completedAt
            note.updatedAt = now
            candidate.notes[note.id] = note
        }
        if case let .updateItem(item) = command,
           let link = candidate.taskBlockLinks.first(where: { $0.calendarItemID == item.id }),
           let updatedTitle = candidate.calendar.items[item.id]?.title,
           var note = candidate.notes[link.noteID],
           let blockIndex = note.document.blocks.firstIndex(where: {
               $0.id == link.blockID && $0.kind == .task
           }),
           TaskBlockCalendarTitle.normalized(
               note.document.blocks[blockIndex].inlineContent.spans.map(\.text).joined()
           ) != updatedTitle {
            note.document.blocks[blockIndex].inlineContent = .plain(updatedTitle)
            note.updatedAt = now
            candidate.notes[note.id] = note
        }
        if case let .deleteItem(id) = command {
            candidate.calendarNoteRelations.baselines.removeValue(forKey: .item(id))
            candidate.taskBlockLinks = Set(candidate.taskBlockLinks.filter { $0.calendarItemID != id })
        }
    }

    static func allocateRevisions(
        from original: WorkspaceState,
        to candidate: inout WorkspaceState
    ) throws -> Set<NoteID> {
        guard original.revision < Int64.max else { throw WorkspaceReducerError.revisionOverflow }
        let candidateWorkspaceRevision = original.revision + 1
        var changed = Set<NoteID>()
        for (id, proposed) in candidate.notes {
            if let old = original.notes[id] {
                guard !noteBusinessEquivalent(old, proposed) else {
                    candidate.notes[id]?.revision = old.revision
                    continue
                }
                guard old.revision < Int64.max else { throw WorkspaceReducerError.revisionOverflow }
                candidate.notes[id]?.revision = old.revision + 1
                changed.insert(id)
            } else {
                candidate.notes[id]?.revision = 1
                changed.insert(id)
            }
        }
        candidate.revision = candidateWorkspaceRevision
        return changed
    }

    static func businessEquivalent(_ lhs: WorkspaceState, _ rhs: WorkspaceState) -> Bool {
        normalizedBusinessState(lhs) == normalizedBusinessState(rhs)
    }

    static func noteBusinessEquivalent(_ lhs: Note, _ rhs: Note) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.document == rhs.document
            && lhs.categoryID == rhs.categoryID
            && lhs.archivedAt == rhs.archivedAt
    }

    private static func normalizedBusinessState(_ state: WorkspaceState) -> WorkspaceState {
        var normalized = state
        normalized.revision = 0
        normalized.notes = normalized.notes.mapValues { note in
            var note = note
            note.revision = 0
            note.createdAt = .distantPast
            note.updatedAt = .distantPast
            return note
        }
        normalized.calendar.categories = normalized.calendar.categories.mapValues { category in
            var category = category
            category.createdAt = .distantPast
            category.updatedAt = .distantPast
            return category
        }
        normalized.calendar.items = normalized.calendar.items.mapValues { item in
            var item = item
            item.createdAt = .distantPast
            item.updatedAt = .distantPast
            return item
        }
        normalized.calendar.recurrence.series = normalized.calendar.recurrence.series.mapValues { series in
            var series = series
            series.createdAt = .distantPast
            series.updatedAt = .distantPast
            return series
        }
        normalized.inspirations = normalized.inspirations.mapValues { inspiration in
            var inspiration = inspiration
            inspiration.createdAt = .distantPast
            inspiration.updatedAt = .distantPast
            return inspiration
        }
        return normalized
    }

    static func validateProposedNote(_ note: Note, in state: WorkspaceState) throws {
        guard state.calendar.categories[note.categoryID] != nil,
              (try? BlockDocumentValidator.validate(note.document)) != nil
        else {
            throw WorkspaceReducerError.invalidNote
        }
    }

    static func reduceRestore(
        _ state: WorkspaceState,
        payload: WorkspaceRestoreContentPayload
    ) throws -> WorkspaceReductionResult {
        let sourceIDs = Set(payload.content.notes.keys)
        guard payload.sourceRevisionHighWatermark >= 0,
              Set(payload.sourceNoteRevisions.keys) == sourceIDs,
              payload.content.notes.allSatisfy({ $0.key == $0.value.id }),
              payload.content.inspirations.allSatisfy({ $0.key == $0.value.id }),
              payload.content.materialDigests.allSatisfy({ $0.key == $0.value.inspirationID }),
              payload.sourceNoteRevisions.values.allSatisfy({
                  $0 >= 0 && $0 <= payload.sourceRevisionHighWatermark
              })
        else {
            throw WorkspaceReducerError.invalidRestoreMetadata
        }
        let allRevisions = [state.revision, payload.sourceRevisionHighWatermark]
            + state.notes.values.map(\.revision)
            + Array(payload.sourceNoteRevisions.values)
        guard let maximum = allRevisions.max(), maximum < Int64.max else {
            throw WorkspaceReducerError.revisionOverflow
        }
        let candidateRevision = maximum + 1
        var noteRevisions = [NoteID: Int64]()
        var changed = Set<NoteID>()
        for (id, content) in payload.content.notes {
            let sourceRevision = payload.sourceNoteRevisions[id]!
            guard let current = state.notes[id] else {
                noteRevisions[id] = candidateRevision
                changed.insert(id)
                continue
            }
            let base = max(current.revision, sourceRevision)
            if WorkspaceNoteContent(note: current) == content {
                noteRevisions[id] = base
            } else {
                guard base < Int64.max else { throw WorkspaceReducerError.revisionOverflow }
                noteRevisions[id] = base + 1
                changed.insert(id)
            }
        }
        let candidate = payload.content.materialized(
            revisions: noteRevisions,
            workspaceRevision: candidateRevision
        )
        guard WorkspaceContentSnapshot(state: candidate) != WorkspaceContentSnapshot(state: state) else {
            return .noChange(.identical)
        }
        do {
            try WorkspaceValidator.validate(candidate)
        } catch {
            throw WorkspaceReducerError.finalValidationFailed
        }
        return .changed(.init(
            state: candidate,
            changedNoteIDs: changed,
            draftContext: nil,
            seriesOutcome: nil
        ))
    }
}
