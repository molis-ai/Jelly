import Foundation

extension WorkspaceReducer {
    static func createInspiration(
        _ inspiration: Inspiration,
        in candidate: inout WorkspaceState
    ) throws {
        guard candidate.inspirations[inspiration.id] == nil else {
            throw WorkspaceReducerError.duplicateInspiration(inspiration.id)
        }
        var probe = candidate
        probe.inspirations[inspiration.id] = inspiration
        do {
            try WorkspaceValidator.validate(probe)
        } catch {
            throw WorkspaceReducerError.invalidInspiration
        }
        candidate.inspirations[inspiration.id] = inspiration
    }

    static func updateInspirationText(
        _ id: InspirationID,
        rawText: String,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard inspiration.inputKind == .text,
              inspiration.lifecycle == .active,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.inspirationNoteLinks.contains(where: { link in
                  if case let .live(sourceID) = link.source { return sourceID == id }
                  return false
              }) else {
            throw WorkspaceReducerError.invalidInspiration
        }
        guard inspiration.rawText != rawText else {
            return .result(.noChange(.identical))
        }
        inspiration.rawText = rawText
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
        candidate.materialDigests.removeValue(forKey: id)
        return .proceed
    }

    static func updateInspirationMetadata(
        _ id: InspirationID,
        expectation: InspirationMetadataExpectation,
        metadata: SourceMetadata,
        kind: ResolvedSourceKind,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard WorkspaceChecksum.inspirationSourceChecksum(inspiration) == expectation.sourceChecksum else {
            return .result(.noChange(.staleMetadata))
        }
        guard inspiration.resolvedMetadata != metadata || inspiration.resolvedSourceKind != kind else {
            return .result(.noChange(.identical))
        }
        inspiration.resolvedMetadata = metadata
        inspiration.resolvedSourceKind = kind
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func convertInspiration(
        _ payload: ConvertInspirationToNotePayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard candidate.inspirations[payload.inspirationID] != nil else {
            throw WorkspaceReducerError.missingInspiration(payload.inspirationID)
        }
        let existing = candidate.inspirationNoteLinks
            .filter { link in
                if case let .live(linkedID) = link.source { linkedID == payload.inspirationID } else { false }
            }
            .min { lhs, rhs in
                lhs.noteID.rawValue.uuidString < rhs.noteID.rawValue.uuidString
            }
        if let existing {
            return .result(.noChange(.inspirationAlreadyConverted(existing.noteID)))
        }
        try createNote(payload.proposedNote, in: &candidate)
        candidate.inspirationNoteLinks.insert(.init(
            source: .live(payload.inspirationID),
            noteID: payload.proposedNote.id,
            createdAt: now
        ))
        if let plan = payload.digestWrite {
            guard var digest = candidate.materialDigests[payload.inspirationID],
                  let result = digest.result,
                  try WorkspaceChecksum.materialDigestResultFingerprint(result) == plan.resultFingerprint,
                  !plan.blockIDs.isEmpty,
                  Set(plan.blockIDs).count == plan.blockIDs.count,
                  Set(plan.blockIDs).isSubset(of: Set(payload.proposedNote.document.blocks.map(\.id)))
            else {
                throw WorkspaceReducerError.invalidInspiration
            }
            digest.noteWrite = MaterialDigestNoteWrite(
                noteID: payload.proposedNote.id,
                resultFingerprint: plan.resultFingerprint,
                blockIDs: plan.blockIDs,
                writtenAt: now
            )
            digest.updatedAt = now
            candidate.materialDigests[payload.inspirationID] = digest
        }
        return .proceed
    }

    static func writeMaterialDigestToNote(
        _ payload: WriteMaterialDigestToNotePayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var digest = candidate.materialDigests[payload.inspirationID],
              let result = digest.result,
              let noteLink = candidate.inspirationNoteLinks.first(where: { link in
                  if case let .live(id) = link.source {
                      return id == payload.inspirationID && link.noteID == payload.noteID
                  }
                  return false
              }),
              noteLink.noteID == payload.noteID,
              var note = candidate.notes[payload.noteID]
        else {
            throw WorkspaceReducerError.invalidInspiration
        }
        guard note.revision == payload.expectedNoteRevision,
              try WorkspaceChecksum.materialDigestResultFingerprint(result) == payload.resultFingerprint
        else {
            return .result(.noChange(.staleMaterialDigestNote))
        }
        if digest.noteWrite?.noteID == payload.noteID,
           digest.noteWrite?.resultFingerprint == payload.resultFingerprint {
            return .result(.noChange(.materialDigestAlreadyWritten(payload.noteID)))
        }
        guard !payload.proposedBlocks.isEmpty,
              Set(payload.proposedBlocks.map(\.id)).count == payload.proposedBlocks.count
        else {
            throw WorkspaceReducerError.invalidInspiration
        }
        let existingBlockIDs = Set(note.document.blocks.map(\.id))
        guard existingBlockIDs.isDisjoint(with: payload.proposedBlocks.map(\.id)) else {
            throw WorkspaceReducerError.invalidInspiration
        }
        if let previous = digest.noteWrite, previous.noteID == payload.noteID {
            let replacedIDs = Set(previous.blockIDs)
            note.document.blocks.removeAll { replacedIDs.contains($0.id) }
        }
        note.document.blocks.append(contentsOf: payload.proposedBlocks)
        note.updatedAt = now
        candidate.notes[payload.noteID] = note
        digest.noteWrite = MaterialDigestNoteWrite(
            noteID: payload.noteID,
            resultFingerprint: payload.resultFingerprint,
            blockIDs: payload.proposedBlocks.map(\.id),
            writtenAt: now
        )
        digest.updatedAt = now
        candidate.materialDigests[payload.inspirationID] = digest
        return .proceed
    }

    static func setInspirationLifecycle(
        _ id: InspirationID,
        lifecycle: InspirationLifecycle,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard inspiration.lifecycle != lifecycle else { return }
        inspiration.lifecycle = lifecycle
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
    }

    static func changeInspirationCategory(
        _ id: InspirationID,
        categoryID: UUID,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id],
              candidate.calendar.categories[categoryID] != nil else {
            throw WorkspaceReducerError.invalidInspiration
        }
        guard inspiration.categoryID != categoryID else {
            return .result(.noChange(.identical))
        }
        inspiration.categoryID = categoryID
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func permanentlyDeleteInspiration(
        _ id: InspirationID,
        deletedAt: Date,
        authorization: PermanentDeleteAuthorization,
        in candidate: inout WorkspaceState
    ) throws -> WorkspaceCommandControl {
        guard let inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard inspiration.lifecycle == .archived else {
            throw WorkspaceReducerError.permanentDeleteRequiresArchivedSubject
        }
        let subject = PermanentDeleteSubject.inspiration(id, deletedAt: deletedAt)
        let preview = try PermanentDeletePlanner.preview(subject, in: candidate)
        guard authorization.subject == subject,
              authorization.sourceWorkspaceRevision == preview.sourceWorkspaceRevision,
              authorization.impactChecksum == preview.checksum
        else {
            return .result(.noChange(.staleDeleteAuthorization))
        }
        candidate.inspirationNoteLinks = Set(candidate.inspirationNoteLinks.map { link in
            guard case let .live(linkedID) = link.source, linkedID == id else { return link }
            return InspirationNoteLink(
                source: .deleted(originalID: id, deletedAt: deletedAt),
                noteID: link.noteID,
                createdAt: link.createdAt
            )
        })
        candidate.materialDigests.removeValue(forKey: id)
        candidate.inspirations.removeValue(forKey: id)
        return .proceed
    }
}
