import CalendarDomain
import Foundation

public enum WorkspaceValidationError: Error, Equatable, Sendable {
    case invalidCalendar
    case invalidWorkspaceRevision
    case inconsistentNoteKey(NoteID)
    case invalidNoteRevision(NoteID)
    case inconsistentInspirationKey(InspirationID)
    case unknownCategory(UUID)
    case invalidNoteDocument(NoteID)
    case invalidInspirationInput(InspirationID)
    case danglingCalendarOwner(CalendarNoteOwnerID)
    case danglingOccurrenceOverride(OccurrenceKey)
    case inconsistentOccurrenceOverrideKey(OccurrenceKey)
    case danglingNote(NoteID)
    case primaryAlsoReference(CalendarNoteOwnerID, NoteID)
    case occurrencePrimaryAlsoReference(OccurrenceKey, NoteID)
    case overlappingOccurrenceReferences(OccurrenceKey, NoteID)
    case primaryConflictsWithLegacyMarkdown(CalendarNoteOwnerID)
    case occurrencePrimaryConflictsWithLegacyMarkdown(OccurrenceKey)
    case danglingCalendarItem(UUID)
    case taskBlockMissingTask(NoteID, BlockID)
    case taskBlockMissingPrimaryNote(NoteID, UUID)
    case duplicateTaskBlock(BlockID)
    case duplicateTaskCalendarItem(UUID)
    case taskTitleMismatch(NoteID, BlockID, UUID)
    case taskCompletionMismatch(NoteID, BlockID, UUID)
    case danglingLiveInspiration(InspirationID)
    case inconsistentMaterialDigestKey(InspirationID)
    case danglingMaterialDigest(InspirationID)
    case invalidMaterialDigestInspiration(InspirationID)
    case materialDigestChecksumMismatch(InspirationID)
    case invalidMaterialDigestRun(InspirationID)
    case invalidMaterialDigestResult(InspirationID)
    case invalidMaterialDigestFailure(InspirationID)
    case invalidMaterialSnapshot(InspirationID)
}

public enum WorkspaceValidator {
    public static func validate(_ state: WorkspaceState) throws {
        guard state.revision >= 0 else {
            throw WorkspaceValidationError.invalidWorkspaceRevision
        }
        do {
            try CalendarStateValidator.validate(state.calendar)
        } catch {
            throw WorkspaceValidationError.invalidCalendar
        }

        try validateNotes(state)
        try validateInspirations(state)
        try validateCalendarRelations(state)
        try validateTaskBlockLinks(state)
        try validateInspirationLinks(state)
        try validateMaterialDigests(state)
    }

    private static func validateNotes(_ state: WorkspaceState) throws {
        for (key, note) in state.notes {
            guard key == note.id else {
                throw WorkspaceValidationError.inconsistentNoteKey(key)
            }
            guard state.calendar.categories[note.categoryID] != nil else {
                throw WorkspaceValidationError.unknownCategory(note.categoryID)
            }
            guard note.revision >= 0, note.revision <= state.revision else {
                throw WorkspaceValidationError.invalidNoteRevision(note.id)
            }
            do {
                try BlockDocumentValidator.validate(note.document)
            } catch {
                throw WorkspaceValidationError.invalidNoteDocument(note.id)
            }
        }
    }

    private static func validateInspirations(_ state: WorkspaceState) throws {
        for (key, inspiration) in state.inspirations {
            guard key == inspiration.id else {
                throw WorkspaceValidationError.inconsistentInspirationKey(key)
            }
            guard state.calendar.categories[inspiration.categoryID] != nil else {
                throw WorkspaceValidationError.unknownCategory(inspiration.categoryID)
            }
            guard hasValidRawInput(inspiration) else {
                throw WorkspaceValidationError.invalidInspirationInput(inspiration.id)
            }
        }
    }

    private static func validateCalendarRelations(_ state: WorkspaceState) throws {
        for (owner, noteSet) in state.calendarNoteRelations.baselines {
            guard contains(owner, in: state.calendar) else {
                throw WorkspaceValidationError.danglingCalendarOwner(owner)
            }
            try validate(noteSet, for: owner, in: state.notes)
            if noteSet.primaryNoteID != nil, hasLegacyMarkdown(for: owner, in: state.calendar) {
                throw WorkspaceValidationError.primaryConflictsWithLegacyMarkdown(owner)
            }
        }

        for (key, override) in state.calendarNoteRelations.occurrenceOverrides {
            guard key == override.key else {
                throw WorkspaceValidationError.inconsistentOccurrenceOverrideKey(key)
            }
            guard CalendarNoteRelationResolver.isLogicalInstance(key, in: state.calendar.recurrence) else {
                throw WorkspaceValidationError.danglingOccurrenceOverride(key)
            }
            if case let .replace(noteID) = override.primary {
                try require(noteID, in: state.notes)
                if override.addedReferenceNoteIDs.contains(noteID) {
                    throw WorkspaceValidationError.occurrencePrimaryAlsoReference(key, noteID)
                }
            }
            for noteID in override.addedReferenceNoteIDs {
                try require(noteID, in: state.notes)
            }
            for noteID in override.removedReferenceNoteIDs {
                try require(noteID, in: state.notes)
            }
            if let overlap = override.addedReferenceNoteIDs.intersection(override.removedReferenceNoteIDs).first {
                throw WorkspaceValidationError.overlappingOccurrenceReferences(key, overlap)
            }
            guard !CalendarNoteRelationResolver.isSkipped(key, in: state.calendar.recurrence) else {
                continue
            }
            let resolved = try CalendarNoteRelationResolver.resolve(
                .occurrence(key),
                calendar: state.calendar,
                relations: state.calendarNoteRelations
            )
            if resolved.noteSet.primaryNoteID != nil,
               hasLegacyMarkdown(for: key, in: state.calendar) {
                throw WorkspaceValidationError.occurrencePrimaryConflictsWithLegacyMarkdown(key)
            }
        }
    }

    private static func validateTaskBlockLinks(_ state: WorkspaceState) throws {
        var linkedBlockIDs = Set<BlockID>()
        var linkedCalendarItemIDs = Set<UUID>()

        for link in state.taskBlockLinks {
            guard state.calendar.items[link.calendarItemID] != nil else {
                throw WorkspaceValidationError.danglingCalendarItem(link.calendarItemID)
            }
            guard let note = state.notes[link.noteID],
                  let block = note.document.blocks.first(where: { $0.id == link.blockID && $0.kind == .task })
            else {
                throw WorkspaceValidationError.taskBlockMissingTask(link.noteID, link.blockID)
            }
            guard linkedBlockIDs.insert(link.blockID).inserted else {
                throw WorkspaceValidationError.duplicateTaskBlock(link.blockID)
            }
            guard linkedCalendarItemIDs.insert(link.calendarItemID).inserted else {
                throw WorkspaceValidationError.duplicateTaskCalendarItem(link.calendarItemID)
            }
            let owner = CalendarNoteOwnerID.item(link.calendarItemID)
            guard state.calendarNoteRelations.baselines[owner]?.primaryNoteID == link.noteID else {
                throw WorkspaceValidationError.taskBlockMissingPrimaryNote(link.noteID, link.calendarItemID)
            }
            guard state.calendar.items[link.calendarItemID]?.title
                == TaskBlockCalendarTitle.normalized(
                    block.inlineContent.spans.map(\.text).joined()
                ) else {
                throw WorkspaceValidationError.taskTitleMismatch(
                    link.noteID,
                    link.blockID,
                    link.calendarItemID
                )
            }
            guard state.calendar.items[link.calendarItemID]?.completedAt == block.taskState?.completedAt else {
                throw WorkspaceValidationError.taskCompletionMismatch(
                    link.noteID,
                    link.blockID,
                    link.calendarItemID
                )
            }
        }
    }

    static func validateMaterialDigests(_ state: WorkspaceState) throws {
        for (key, digest) in state.materialDigests {
            guard key == digest.inspirationID else {
                throw WorkspaceValidationError.inconsistentMaterialDigestKey(key)
            }
            guard let inspiration = state.inspirations[digest.inspirationID] else {
                throw WorkspaceValidationError.danglingMaterialDigest(digest.inspirationID)
            }
            guard inspiration.supportsMaterialDigest
            else {
                throw WorkspaceValidationError.invalidMaterialDigestInspiration(digest.inspirationID)
            }
            guard digest.sourceChecksum == WorkspaceChecksum.inspirationSourceChecksum(inspiration) else {
                throw WorkspaceValidationError.materialDigestChecksumMismatch(digest.inspirationID)
            }
            if let run = digest.currentRun {
                try validate(run, for: digest.inspirationID)
            }
            if let snapshot = digest.preparedSnapshot {
                try validate(snapshot, inspirationID: digest.inspirationID, sourceChecksum: digest.sourceChecksum)
            }
            if let snapshot = digest.pendingSnapshot {
                try validate(snapshot, inspirationID: digest.inspirationID, sourceChecksum: digest.sourceChecksum)
            }
            if let result = digest.result {
                try validate(result, digest: digest, for: digest.inspirationID)
            }
            if let failure = digest.lastFailure {
                try validate(failure, for: digest.inspirationID)
            }
            if let noteWrite = digest.noteWrite {
                guard let note = state.notes[noteWrite.noteID],
                      !noteWrite.resultFingerprint.isEmpty,
                      !noteWrite.blockIDs.isEmpty,
                      Set(noteWrite.blockIDs).count == noteWrite.blockIDs.count,
                      Set(noteWrite.blockIDs).isSubset(of: Set(note.document.blocks.map(\.id))),
                      state.inspirationNoteLinks.contains(where: { link in
                          guard link.noteID == noteWrite.noteID,
                                case let .live(linkedID) = link.source
                          else { return false }
                          return linkedID == digest.inspirationID
                      })
                else {
                    throw WorkspaceValidationError.invalidMaterialDigestResult(digest.inspirationID)
                }
            }
        }
    }

    private static func validate(_ run: MaterialDigestRun, for inspirationID: InspirationID) throws {
        guard run.startedAt <= run.updatedAt else {
            throw WorkspaceValidationError.invalidMaterialDigestRun(inspirationID)
        }
    }

    private static func validate(
        _ result: MaterialDigestResult,
        digest: MaterialDigest,
        for inspirationID: InspirationID
    ) throws {
        try validate(result.provenance, for: inspirationID)
        if MaterialDigestSummaryContract.isLegacy(result.provenance.summaryContractVersion) {
            guard let snapshot = digest.preparedSnapshot else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
            let transcript = snapshot.timestampedTranscript
            try validate(transcript, for: inspirationID)
            try validate(
                result.summary,
                transcript: transcript,
                contractVersion: result.provenance.summaryContractVersion,
                for: inspirationID
            )
            return
        }
        guard let snapshot = digest.preparedSnapshot,
              snapshot.contentFingerprint == result.contentFingerprint,
              !result.contentFingerprint.isEmpty
        else {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
        do {
            try MaterialDigestEvidence.validateNewSummary(result.summary, against: snapshot)
        } catch {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
        try validateV3SummaryLimits(result.summary, for: inspirationID)
    }

    private static func validate(
        _ snapshot: MaterialSnapshot,
        inspirationID: InspirationID,
        sourceChecksum: String
    ) throws {
        let fingerprint: String
        do {
            fingerprint = try WorkspaceChecksum.materialSnapshotContentFingerprint(snapshot)
        } catch {
            throw WorkspaceValidationError.invalidMaterialSnapshot(inspirationID)
        }
        let totalCharacters = snapshot.blocks.reduce(0) { $0 + $1.text.count }
        guard Set(snapshot.blocks.map(\.id)).count == snapshot.blocks.count,
              snapshot.blocks.count <= MaterialDigestContentLimits.maximumMaterialBlocks,
              totalCharacters <= MaterialDigestContentLimits.maximumMaterialCharacters,
              fingerprint == snapshot.contentFingerprint,
              snapshot.sourceChecksum == sourceChecksum,
              snapshot.blocks.allSatisfy(isValidLocator)
        else {
            throw WorkspaceValidationError.invalidMaterialSnapshot(inspirationID)
        }
    }

    private static func isValidLocator(_ block: MaterialBlock) -> Bool {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || block.role == .metadata else { return false }
        switch block.locator {
        case let .paragraph(index):
            return index >= 0
        case let .timestamp(startSeconds, endSeconds):
            return startSeconds.isFinite
                && endSeconds.isFinite
                && startSeconds >= 0
                && endSeconds >= startSeconds
                && endSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds
        case let .page(number):
            return number >= 1
        case let .image(index):
            return index >= 0
        }
    }

    private static func validateV3SummaryLimits(
        _ summary: InspirationSummary,
        for inspirationID: InspirationID
    ) throws {
        let thesis = summary.thesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thesis.isEmpty,
              thesis.count <= MaterialDigestContentLimits.maximumThesisCharacters
        else {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
        let takeaways = summary.takeaways.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard MaterialDigestContentLimits.takeawayCountRange.contains(takeaways.count),
              takeaways.allSatisfy({
                  !$0.isEmpty && $0.count <= MaterialDigestContentLimits.maximumTakeawayCharacters
              })
        else {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
        var totalCharacters = thesis.count + takeaways.reduce(0) { $0 + $1.count }
        for chapter in summary.chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let points = chapter.points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            totalCharacters += title.count + points.reduce(0) { $0 + $1.count }
            guard totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters,
                  points.allSatisfy({
                      !$0.isEmpty && $0.count <= MaterialDigestContentLimits.maximumPointCharacters
                  })
            else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
        }
        for quote in summary.quotes {
            let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count + (speaker?.count ?? 0)
            guard text.count <= MaterialDigestContentLimits.maximumQuoteCharacters,
                  (speaker?.count ?? 0) <= MaterialDigestContentLimits.maximumSpeakerCharacters,
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
        }
        for item in summary.dropped {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count
            guard !text.isEmpty,
                  text.count <= MaterialDigestContentLimits.maximumDroppedItemCharacters,
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
        }
    }

    private static func validate(_ transcript: TimestampedTranscript, for inspirationID: InspirationID) throws {
        guard !transcript.segments.isEmpty,
              transcript.segments.count <= MaterialDigestContentLimits.maximumTranscriptSegments
        else {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
        var previousStart = -Double.infinity
        var totalCharacters = 0
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count
            guard segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.startSeconds >= 0,
                  segment.endSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds,
                  segment.endSeconds >= segment.startSeconds,
                  segment.startSeconds >= previousStart,
                  !text.isEmpty,
                  text.count <= MaterialDigestContentLimits.maximumSegmentCharacters,
                  totalCharacters <= MaterialDigestContentLimits.maximumTranscriptCharacters
            else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
            previousStart = segment.startSeconds
        }
    }

    private static func validate(
        _ summary: InspirationSummary,
        transcript: TimestampedTranscript,
        contractVersion: String,
        for inspirationID: InspirationID
    ) throws {
        let thesis = summary.thesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thesis.isEmpty,
              thesis.count <= MaterialDigestContentLimits.maximumThesisCharacters
        else {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
        let takeaways = summary.takeaways.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let enforceEvidence = MaterialDigestSummaryContract.enforcesEvidenceAndTranscriptEnd(contractVersion)
        let maximumSourceTime = enforceEvidence
            ? MaterialDigestEvidence.transcriptEnd(transcript)
            : MaterialDigestContentLimits.maximumTimestampSeconds
        guard MaterialDigestContentLimits.takeawayCountRange.contains(takeaways.count),
              takeaways.allSatisfy({
                  !$0.isEmpty && $0.count <= MaterialDigestContentLimits.maximumTakeawayCharacters
              }),
              summary.chapters.count <= MaterialDigestContentLimits.maximumChapters,
              summary.quotes.count <= MaterialDigestContentLimits.maximumQuotes,
              summary.dropped.count <= MaterialDigestContentLimits.maximumDroppedItems
        else {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
        var previousStart = -Double.infinity
        var totalCharacters = thesis.count + takeaways.reduce(0) { $0 + $1.count }
        for chapter in summary.chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let points = chapter.points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            totalCharacters += title.count + points.reduce(0) { $0 + $1.count }
            guard chapter.startSeconds.isFinite,
                  chapter.startSeconds >= 0,
                  chapter.startSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds,
                  chapter.startSeconds <= maximumSourceTime,
                  chapter.startSeconds >= previousStart,
                  !title.isEmpty,
                  title.count <= MaterialDigestContentLimits.maximumChapterTitleCharacters,
                  (1...MaterialDigestContentLimits.maximumChapterPoints).contains(points.count),
                  points.allSatisfy({
                      !$0.isEmpty && $0.count <= MaterialDigestContentLimits.maximumPointCharacters
                  }),
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
            previousStart = chapter.startSeconds
        }
        for quote in summary.quotes {
            let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count + (speaker?.count ?? 0)
            guard quote.startSeconds.isFinite,
                  quote.startSeconds >= 0,
                  quote.startSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds,
                  quote.startSeconds <= maximumSourceTime,
                  !text.isEmpty,
                  text.count <= MaterialDigestContentLimits.maximumQuoteCharacters,
                  (speaker?.count ?? 0) <= MaterialDigestContentLimits.maximumSpeakerCharacters,
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
            if enforceEvidence {
                guard MaterialDigestEvidence.textAppearsNearby(
                    text,
                    at: quote.startSeconds,
                    in: transcript
                ) else {
                    throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
                }
                if let speaker, !speaker.isEmpty {
                    guard MaterialDigestEvidence.speakerAppearsNearby(
                        speaker,
                        at: quote.startSeconds,
                        in: transcript
                    ) else {
                        throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
                    }
                }
            }
        }
        for item in summary.dropped {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count
            guard !text.isEmpty,
                  text.count <= MaterialDigestContentLimits.maximumDroppedItemCharacters,
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
            }
        }
    }

    private static func validate(_ provenance: DigestProvenance, for inspirationID: InspirationID) throws {
        guard !provenance.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provenance.inputFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provenance.summaryContractVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw WorkspaceValidationError.invalidMaterialDigestResult(inspirationID)
        }
    }

    private static func validate(_ failure: MaterialDigestFailure, for inspirationID: InspirationID) throws {
        let message = failure.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              !message.contains("Bearer "),
              !message.lowercased().contains("sk-")
        else {
            throw WorkspaceValidationError.invalidMaterialDigestFailure(inspirationID)
        }
    }

    private static func validateInspirationLinks(_ state: WorkspaceState) throws {
        for link in state.inspirationNoteLinks {
            try require(link.noteID, in: state.notes)
            if case let .live(inspirationID) = link.source,
               state.inspirations[inspirationID] == nil {
                throw WorkspaceValidationError.danglingLiveInspiration(inspirationID)
            }
        }
    }

    private static func validate(
        _ noteSet: CalendarNoteSet,
        for owner: CalendarNoteOwnerID,
        in notes: [NoteID: Note]
    ) throws {
        if let primary = noteSet.primaryNoteID {
            try require(primary, in: notes)
            if noteSet.referenceNoteIDs.contains(primary) {
                throw WorkspaceValidationError.primaryAlsoReference(owner, primary)
            }
        }
        for noteID in noteSet.referenceNoteIDs {
            try require(noteID, in: notes)
        }
    }

    private static func require(_ noteID: NoteID, in notes: [NoteID: Note]) throws {
        guard notes[noteID] != nil else {
            throw WorkspaceValidationError.danglingNote(noteID)
        }
    }

    private static func contains(_ owner: CalendarNoteOwnerID, in calendar: CalendarState) -> Bool {
        switch owner {
        case let .item(id):
            calendar.items[id] != nil
        case let .series(id):
            calendar.recurrence.series[id] != nil
        }
    }

    private static func hasLegacyMarkdown(
        for owner: CalendarNoteOwnerID,
        in calendar: CalendarState
    ) -> Bool {
        switch owner {
        case let .item(id):
            calendar.items[id].map { hasLegacyMarkdown($0.notes) } ?? false
        case let .series(id):
            calendar.recurrence.series[id].map { hasLegacyMarkdown($0.notes) } ?? false
        }
    }

    private static func hasLegacyMarkdown(
        for key: OccurrenceKey,
        in calendar: CalendarState
    ) -> Bool {
        guard let series = calendar.recurrence.series[key.seriesID] else {
            return false
        }
        if case let .modified(override) = calendar.recurrence.exceptions[key] {
            return hasLegacyMarkdown(override.notes)
        }
        return hasLegacyMarkdown(series.notes)
    }

    private static func hasLegacyMarkdown(_ markdown: String) -> Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasValidRawInput(_ inspiration: Inspiration) -> Bool {
        switch inspiration.inputKind {
        case .text:
            guard let rawText = inspiration.rawText else { return false }
            return !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && inspiration.rawURL == nil
                && inspiration.rawFile == nil
        case .url:
            guard let rawURL = inspiration.rawURL else { return false }
            return rawURL.scheme != nil
                && rawURL.host != nil
                && inspiration.rawText == nil
                && inspiration.rawFile == nil
        case .file:
            guard let rawFile = inspiration.rawFile else { return false }
            return !rawFile.bookmarkData.isEmpty
                && !rawFile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && inspiration.rawText == nil
                && inspiration.rawURL == nil
        }
    }
}
