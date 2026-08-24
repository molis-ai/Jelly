import CalendarDomain
import Foundation

extension WorkspaceReducer {
    static func createNote(_ note: Note, in candidate: inout WorkspaceState) throws {
        guard candidate.notes[note.id] == nil else {
            throw WorkspaceReducerError.duplicateNote(note.id)
        }
        try validateProposedNote(note, in: candidate)
        candidate.notes[note.id] = note
    }

    static func setNoteArchive(
        _ id: NoteID,
        archivedAt: Date?,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws {
        guard var note = candidate.notes[id] else { throw WorkspaceReducerError.missingNote(id) }
        guard note.archivedAt != archivedAt else { return }
        note.archivedAt = archivedAt
        note.updatedAt = now
        candidate.notes[id] = note
    }

    static func setNotePinned(
        _ id: NoteID,
        isPinned: Bool,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws {
        guard var note = candidate.notes[id] else { throw WorkspaceReducerError.missingNote(id) }
        guard note.archivedAt == nil, note.isPinned != isPinned else { return }
        note.isPinned = isPinned
        note.updatedAt = now
        candidate.notes[id] = note
    }

    static func updateNote(
        _ submission: NoteDraftSubmission,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws -> WorkspaceCommandControl {
        guard let current = candidate.notes[submission.noteID] else {
            return .result(.conflict(.noteMissing(submission.noteID)))
        }
        let base = submission.baseSnapshot
        let submitted = submission.snapshot
        let baseLinkBlockIDs = submission.baseLinkedTaskBlockLinks.map(\.blockID)
        let baseLinkItemIDs = submission.baseLinkedTaskBlockLinks.map(\.calendarItemID)
        guard base.id == submission.noteID,
              submitted.id == submission.noteID,
              submission.baseNoteRevision == base.revision,
              submission.baseNoteSnapshotChecksum == (try WorkspaceChecksum.noteSnapshotChecksum(base)),
              submission.noteSnapshotChecksum == (try WorkspaceChecksum.noteSnapshotChecksum(submitted)),
              submission.modifiedFields == derivedFields(base: base, submitted: submitted),
              Set(baseLinkBlockIDs).count == baseLinkBlockIDs.count,
              Set(baseLinkItemIDs).count == baseLinkItemIDs.count,
              submission.baseLinkedTaskBlockLinks.allSatisfy({ link in
                  link.noteID == base.id
                      && base.document.blocks.contains(where: { $0.id == link.blockID && $0.kind == .task })
              })
        else {
            throw WorkspaceReducerError.invalidDraftSubmission
        }

        var conflicts = Set<NoteDraftField>()
        let title = merge(base.title, submitted.title, current.title, field: .title, conflicts: &conflicts)
        let document = merge(
            base.document,
            submitted.document,
            current.document,
            field: .document,
            conflicts: &conflicts
        )
        let categoryID = merge(
            base.categoryID,
            submitted.categoryID,
            current.categoryID,
            field: .categoryID,
            conflicts: &conflicts
        )
        let archivedAt = merge(
            base.archivedAt,
            submitted.archivedAt,
            current.archivedAt,
            field: .archivedAt,
            conflicts: &conflicts
        )

        let affected = affectedBlockIDs(base: base.document, submitted: submitted.document)
        let baseProjection = linkProjection(submission.baseLinkedTaskBlockLinks, affected: affected)
        let currentProjection = linkProjection(
            Set(candidate.taskBlockLinks.filter { $0.noteID == current.id }),
            affected: affected
        )
        if baseProjection != currentProjection { conflicts.insert(.document) }

        if !conflicts.isEmpty {
            return .result(.conflict(.noteDraft(.init(
                noteID: current.id,
                currentRevision: current.revision,
                conflictingFields: conflicts,
                base: base,
                submitted: submitted,
                current: current
            ))))
        }

        let currentLinks = candidate.taskBlockLinks.filter { $0.noteID == current.id }
        let submittedDocumentChanged = base.document != submitted.document
        let dispositionIDs: Set<BlockID> = submittedDocumentChanged
            ? Set(currentLinks.compactMap { link in
                let block = submitted.document.blocks.first { $0.id == link.blockID }
                return block?.kind == .task ? nil : link.blockID
            })
            : []
        guard Set(submission.linkedBlockDeletionDispositions.keys) == dispositionIDs else {
            throw WorkspaceReducerError.invalidLinkedBlockDispositions
        }

        for link in currentLinks where !dispositionIDs.contains(link.blockID) {
            guard let oldBlock = current.document.blocks.first(where: { $0.id == link.blockID }),
                  let newBlock = document.blocks.first(where: { $0.id == link.blockID && $0.kind == .task })
            else { continue }
            if oldBlock.taskState?.completedAt != newBlock.taskState?.completedAt {
                try applyCalendar(
                    .setTaskCompleted(link.calendarItemID, newBlock.taskState?.completedAt),
                    to: &candidate,
                    now: now,
                    metadata: &metadata
                )
            }
            let oldTitle = TaskBlockCalendarTitle.normalized(
                oldBlock.inlineContent.spans.map(\.text).joined()
            )
            let newTitle = TaskBlockCalendarTitle.normalized(
                newBlock.inlineContent.spans.map(\.text).joined()
            )
            if oldTitle != newTitle,
               var item = candidate.calendar.items[link.calendarItemID] {
                item.title = newTitle
                try applyCalendar(
                    .updateItem(item),
                    to: &candidate,
                    now: now,
                    metadata: &metadata
                )
            }
        }

        for (blockID, disposition) in submission.linkedBlockDeletionDispositions {
            guard let link = currentLinks.first(where: { $0.blockID == blockID }) else {
                throw WorkspaceReducerError.invalidLinkedBlockDispositions
            }
            candidate.taskBlockLinks.remove(link)
            if disposition == .deleteCalendarItem {
                var localMetadata = WorkspaceMutationMetadata()
                try applyCalendar(
                    .deleteItem(link.calendarItemID),
                    to: &candidate,
                    now: now,
                    metadata: &localMetadata
                )
            }
        }

        var merged = current
        merged.title = title
        merged.document = document
        merged.categoryID = categoryID
        merged.archivedAt = archivedAt
        if WorkspaceNoteContent(note: merged) != WorkspaceNoteContent(note: current) {
            merged.createdAt = current.createdAt
            merged.updatedAt = now
        }
        try validateProposedNote(merged, in: candidate)
        candidate.notes[current.id] = merged
        releaseManagedDigestWriteIfUserChangedBlocks(
            noteID: current.id,
            mergedDocument: document,
            affectedBlockIDs: affected,
            in: &candidate,
            now: now
        )
        metadata.draftContext = .init(
            noteID: current.id,
            editSessionID: .editor(submission.editSessionID),
            draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: submission.noteSnapshotChecksum,
            persistedNoteRevision: current.revision
        )
        return .proceed
    }

    static func scheduleTaskBlock(
        _ payload: ScheduleTaskBlockPayload,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws {
        guard let note = candidate.notes[payload.noteID],
              let block = note.document.blocks.first(where: {
                  $0.id == payload.blockID && $0.kind == .task
              })
        else {
            throw WorkspaceReducerError.taskBlockMissingOrNotTask
        }
        let expectedLink = TaskBlockCalendarLink(
            noteID: payload.noteID,
            blockID: payload.blockID,
            calendarItemID: payload.item.id
        )
        let existingBlockLink = candidate.taskBlockLinks.first { $0.blockID == payload.blockID }
        let existingItemLink = candidate.taskBlockLinks.first { $0.calendarItemID == payload.item.id }
        if existingBlockLink != nil || existingItemLink != nil {
            guard existingBlockLink == expectedLink,
                  existingItemLink == expectedLink,
                  var existingItem = candidate.calendar.items[payload.item.id]
            else {
                throw WorkspaceReducerError.duplicateTaskBlockLink
            }
            existingItem.schedule = payload.item.schedule
            try applyCalendar(.updateItem(existingItem), to: &candidate, now: now, metadata: &metadata)
            return
        }
        if candidate.calendar.items[payload.item.id] != nil {
            throw WorkspaceReducerError.calendarFailure(.invalidState)
        }
        guard block.taskState?.completedAt == payload.item.completedAt else {
            throw WorkspaceReducerError.taskCompletionMismatch
        }
        guard TaskBlockCalendarTitle.normalized(
            block.inlineContent.spans.map(\.text).joined()
        ) == payload.item.title else {
            throw WorkspaceReducerError.taskTitleMismatch
        }
        try applyCalendar(.createItem(payload.item), to: &candidate, now: now, metadata: &metadata)
        let owner = CalendarNoteOwnerID.item(payload.item.id)
        if let existing = candidate.calendarNoteRelations.baselines[owner],
           existing.primaryNoteID != nil || !existing.referenceNoteIDs.isEmpty {
            throw WorkspaceReducerError.primaryReplacementDispositionRequired
        }
        candidate.calendarNoteRelations.baselines[owner] = .init(
            primaryNoteID: payload.noteID,
            referenceNoteIDs: []
        )
        candidate.taskBlockLinks.insert(expectedLink)
    }

    static func setTaskCompletion(
        _ target: TaskCompletionTarget,
        value: TaskCompletionValue,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        let link: TaskBlockCalendarLink?
        switch target {
        case let .calendarItem(id):
            link = candidate.taskBlockLinks.first { $0.calendarItemID == id }
        case let .taskBlock(noteID, blockID):
            link = candidate.taskBlockLinks.first { $0.noteID == noteID && $0.blockID == blockID }
        }
        guard let link,
              var note = candidate.notes[link.noteID],
              let index = note.document.blocks.firstIndex(where: {
                  $0.id == link.blockID && $0.kind == .task
              }),
              let item = candidate.calendar.items[link.calendarItemID]
        else {
            throw WorkspaceReducerError.taskBlockMissingOrNotTask
        }
        let blockCompletion = note.document.blocks[index].taskState?.completedAt
        guard blockCompletion == item.completedAt else {
            throw WorkspaceReducerError.taskCompletionMismatch
        }
        let desired: Date?
        switch value {
        case .incomplete:
            guard item.completedAt != nil else { return .result(.noChange(.identical)) }
            desired = nil
        case let .complete(ifTransitioningAt):
            guard item.completedAt == nil else { return .result(.noChange(.identical)) }
            desired = ifTransitioningAt
        }
        do {
            candidate.calendar = try CalendarReducer.reduce(
                candidate.calendar,
                command: .setTaskCompleted(link.calendarItemID, desired),
                now: now
            )
        } catch let error as ReducerError {
            throw WorkspaceReducerError.calendarFailure(error)
        }
        note.document.blocks[index].taskState?.completedAt = desired
        note.updatedAt = now
        candidate.notes[note.id] = note
        return .proceed
    }

    static func unlinkTaskBlock(
        noteID: NoteID,
        blockID: BlockID,
        in candidate: inout WorkspaceState
    ) -> WorkspaceCommandControl {
        guard let link = candidate.taskBlockLinks.first(where: {
            $0.noteID == noteID && $0.blockID == blockID
        }) else {
            return .result(.noChange(.identical))
        }
        candidate.taskBlockLinks.remove(link)
        return .proceed
    }

    static func permanentlyDeleteNote(
        _ id: NoteID,
        authorization: PermanentDeleteAuthorization,
        in candidate: inout WorkspaceState
    ) throws -> WorkspaceCommandControl {
        guard let note = candidate.notes[id] else { throw WorkspaceReducerError.missingNote(id) }
        guard note.archivedAt != nil else {
            throw WorkspaceReducerError.permanentDeleteRequiresArchivedSubject
        }
        let subject = PermanentDeleteSubject.note(id)
        let preview = try PermanentDeletePlanner.preview(subject, in: candidate)
        guard authorization.subject == subject,
              authorization.sourceWorkspaceRevision == preview.sourceWorkspaceRevision,
              authorization.impactChecksum == preview.checksum
        else {
            return .result(.noChange(.staleDeleteAuthorization))
        }
        for owner in Array(candidate.calendarNoteRelations.baselines.keys) {
            guard var set = candidate.calendarNoteRelations.baselines[owner] else { continue }
            if set.primaryNoteID == id { set.primaryNoteID = nil }
            set.referenceNoteIDs.remove(id)
            if set.primaryNoteID == nil && set.referenceNoteIDs.isEmpty {
                candidate.calendarNoteRelations.baselines.removeValue(forKey: owner)
            } else {
                candidate.calendarNoteRelations.baselines[owner] = set
            }
        }
        for key in Array(candidate.calendarNoteRelations.occurrenceOverrides.keys) {
            guard var override = candidate.calendarNoteRelations.occurrenceOverrides[key] else { continue }
            if case let .replace(noteID) = override.primary, noteID == id { override.primary = .clear }
            override.addedReferenceNoteIDs.remove(id)
            override.removedReferenceNoteIDs.remove(id)
            if override.primary == .inherit,
               override.addedReferenceNoteIDs.isEmpty,
               override.removedReferenceNoteIDs.isEmpty {
                candidate.calendarNoteRelations.occurrenceOverrides.removeValue(forKey: key)
            } else {
                candidate.calendarNoteRelations.occurrenceOverrides[key] = override
            }
        }
        candidate.taskBlockLinks = Set(candidate.taskBlockLinks.filter { $0.noteID != id })
        candidate.inspirationNoteLinks = Set(candidate.inspirationNoteLinks.filter { $0.noteID != id })
        for inspirationID in Array(candidate.materialDigests.keys) {
            guard candidate.materialDigests[inspirationID]?.noteWrite?.noteID == id else { continue }
            candidate.materialDigests[inspirationID]?.noteWrite = nil
        }
        candidate.notes.removeValue(forKey: id)
        return .proceed
    }

    private static func merge<Value: Equatable>(
        _ base: Value,
        _ submitted: Value,
        _ current: Value,
        field: NoteDraftField,
        conflicts: inout Set<NoteDraftField>
    ) -> Value {
        if submitted == base { return current }
        if current == base || submitted == current { return submitted }
        conflicts.insert(field)
        return current
    }

    private static func derivedFields(base: Note, submitted: Note) -> Set<NoteDraftField> {
        var fields = Set<NoteDraftField>()
        if base.title != submitted.title { fields.insert(.title) }
        if base.document != submitted.document { fields.insert(.document) }
        if base.categoryID != submitted.categoryID { fields.insert(.categoryID) }
        if base.archivedAt != submitted.archivedAt { fields.insert(.archivedAt) }
        return fields
    }

    private static func releaseManagedDigestWriteIfUserChangedBlocks(
        noteID: NoteID,
        mergedDocument: BlockDocument,
        affectedBlockIDs: Set<BlockID>,
        in candidate: inout WorkspaceState,
        now: Date
    ) {
        for inspirationID in Array(candidate.materialDigests.keys) {
            guard var digest = candidate.materialDigests[inspirationID],
                  let noteWrite = digest.noteWrite,
                  noteWrite.noteID == noteID
            else { continue }
            let remainingIDs = Set(mergedDocument.blocks.map(\.id))
            let managed = Set(noteWrite.blockIDs)
            let missing = !managed.isSubset(of: remainingIDs)
            let rewritten = !affectedBlockIDs.isDisjoint(with: managed)
            guard missing || rewritten else { continue }
            digest.noteWrite = nil
            digest.updatedAt = now
            candidate.materialDigests[inspirationID] = digest
        }
    }

    private static func affectedBlockIDs(
        base: BlockDocument,
        submitted: BlockDocument
    ) -> Set<BlockID> {
        let baseMap = Dictionary(uniqueKeysWithValues: base.blocks.map { ($0.id, $0) })
        let submittedMap = Dictionary(uniqueKeysWithValues: submitted.blocks.map { ($0.id, $0) })
        return Set(baseMap.keys).union(submittedMap.keys).filter { id in
            guard let old = baseMap[id], let new = submittedMap[id] else { return true }
            return old.kind != new.kind
                || old.inlineContent != new.inlineContent
                || old.taskState != new.taskState
        }
    }

    private static func linkProjection(
        _ links: Set<TaskBlockCalendarLink>,
        affected: Set<BlockID>
    ) -> [BlockID: UUID] {
        Dictionary(uniqueKeysWithValues: links.compactMap { link in
            affected.contains(link.blockID) ? (link.blockID, link.calendarItemID) : nil
        })
    }
}
