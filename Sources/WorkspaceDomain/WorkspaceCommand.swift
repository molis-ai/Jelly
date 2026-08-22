import CalendarDomain
import Foundation

public enum LegacyDiagnosticDisposition: Equatable, Sendable {
    case rejectIfPresent
    case accept(expectedDiagnosticsChecksum: String)
}

public struct LegacyMarkdownImportAuthorization: Equatable, Sendable {
    public let expectedSourceChecksum: String
    public let injectedBlockIDs: [BlockID]
    public let checkedTaskCompletedAt: Date
    public let diagnostics: LegacyDiagnosticDisposition

    public init(
        expectedSourceChecksum: String,
        injectedBlockIDs: [BlockID],
        checkedTaskCompletedAt: Date,
        diagnostics: LegacyDiagnosticDisposition
    ) {
        self.expectedSourceChecksum = expectedSourceChecksum
        self.injectedBlockIDs = injectedBlockIDs
        self.checkedTaskCompletedAt = checkedTaskCompletedAt
        self.diagnostics = diagnostics
    }
}

public enum ExistingPrimaryLegacyResolution: Equatable, Sendable {
    case previewAndMerge(
        expectedNoteRevision: Int64,
        importAuthorization: LegacyMarkdownImportAuthorization
    )
    case cancel
}

public enum PrimaryReplacementDisposition: Equatable, Sendable {
    case demoteOldPrimaryToReference
    case detachOldPrimary
}

public enum TaskBlockPrimaryChangeDisposition: Equatable, Sendable {
    case unlinkPreservingCompletion
}

public enum PermanentDeleteSubject: Hashable, Sendable {
    case note(NoteID)
    case inspiration(InspirationID, deletedAt: Date)
}

public struct PermanentDeleteAuthorization: Equatable, Sendable {
    public let subject: PermanentDeleteSubject
    public let sourceWorkspaceRevision: Int64
    public let impactChecksum: String

    public init(subject: PermanentDeleteSubject, sourceWorkspaceRevision: Int64, impactChecksum: String) {
        self.subject = subject
        self.sourceWorkspaceRevision = sourceWorkspaceRevision
        self.impactChecksum = impactChecksum
    }
}

public struct PermanentDeletePreview: Equatable, Sendable {
    public let subject: PermanentDeleteSubject
    public let sourceWorkspaceRevision: Int64
    public let effects: [PermanentDeleteEffect]
    public let checksum: String

    public init(
        subject: PermanentDeleteSubject,
        sourceWorkspaceRevision: Int64,
        effects: [PermanentDeleteEffect],
        checksum: String
    ) {
        self.subject = subject
        self.sourceWorkspaceRevision = sourceWorkspaceRevision
        self.effects = effects
        self.checksum = checksum
    }
}

public enum PermanentDeleteEffect: Hashable, Codable, Sendable {
    case clearBaselinePrimary(CalendarNoteOwnerID)
    case removeBaselineReference(CalendarNoteOwnerID)
    case clearOccurrenceReplacement(OccurrenceKey)
    case removeOccurrenceAddedReference(OccurrenceKey)
    case removeOccurrenceRemovedReference(OccurrenceKey)
    case removeTaskBlockLink(TaskBlockCalendarLink)
    case removeInspirationNoteLink(InspirationNoteLink)
    case tombstoneInspirationNoteLink(noteID: NoteID, inspirationID: InspirationID)
}

public enum CalendarRelationScope: Equatable, Sendable {
    case item(UUID)
    case series(UUID)
    case occurrenceOnly(OccurrenceKey)
    case occurrenceThisAndFuture(OccurrenceKey, newSeriesID: UUID)
}

public struct AttachPrimaryNotePayload: Equatable, Sendable {
    public let scope: CalendarRelationScope
    public let noteID: NoteID
    public let legacyResolution: ExistingPrimaryLegacyResolution?
    public let replacing: PrimaryReplacementDisposition?
    public let linkedTaskDisposition: TaskBlockPrimaryChangeDisposition?

    public init(
        scope: CalendarRelationScope,
        noteID: NoteID,
        legacyResolution: ExistingPrimaryLegacyResolution?,
        replacing: PrimaryReplacementDisposition?,
        linkedTaskDisposition: TaskBlockPrimaryChangeDisposition?
    ) {
        self.scope = scope
        self.noteID = noteID
        self.legacyResolution = legacyResolution
        self.replacing = replacing
        self.linkedTaskDisposition = linkedTaskDisposition
    }
}

public struct CreatePrimaryNoteForCalendarPayload: Equatable, Sendable {
    public let scope: CalendarRelationScope
    public let note: Note
    public let legacyImportAuthorization: LegacyMarkdownImportAuthorization?

    public init(
        scope: CalendarRelationScope,
        note: Note,
        legacyImportAuthorization: LegacyMarkdownImportAuthorization?
    ) {
        self.scope = scope
        self.note = note
        self.legacyImportAuthorization = legacyImportAuthorization
    }
}

public struct ScheduleNoteOnCalendarPayload: Equatable, Sendable {
    public let noteID: NoteID
    public let item: CalendarItem

    public init(noteID: NoteID, item: CalendarItem) {
        self.noteID = noteID
        self.item = item
    }
}

public struct ScheduleTaskBlockPayload: Equatable, Sendable {
    public let noteID: NoteID
    public let blockID: BlockID
    public let item: CalendarItem

    public init(noteID: NoteID, blockID: BlockID, item: CalendarItem) {
        self.noteID = noteID
        self.blockID = blockID
        self.item = item
    }
}

public struct CreateNotePayload: Equatable, Sendable {
    public let note: Note
    public init(note: Note) { self.note = note }
}

public struct CreateInspirationPayload: Equatable, Sendable {
    public let inspiration: Inspiration
    public init(inspiration: Inspiration) { self.inspiration = inspiration }
}

public struct ConvertInspirationToNotePayload: Equatable, Sendable {
    public let inspirationID: InspirationID
    public let proposedNote: Note

    public init(inspirationID: InspirationID, proposedNote: Note) {
        self.inspirationID = inspirationID
        self.proposedNote = proposedNote
    }
}

public enum TaskCompletionTarget: Hashable, Sendable {
    case calendarItem(UUID)
    case taskBlock(noteID: NoteID, blockID: BlockID)
}

public enum TaskCompletionValue: Equatable, Sendable {
    case incomplete
    case complete(ifTransitioningAt: Date)
}

public struct InspirationMetadataExpectation: Equatable, Sendable {
    public let sourceChecksum: String
    public init(sourceChecksum: String) { self.sourceChecksum = sourceChecksum }
}

public struct WorkspaceConsistencyRepairPayload: Equatable, Sendable {
    public let expectedIssuesChecksum: String
    public let resolutions: [WorkspaceConsistencyIssueID: WorkspaceConsistencyResolution]

    public init(
        expectedIssuesChecksum: String,
        resolutions: [WorkspaceConsistencyIssueID: WorkspaceConsistencyResolution]
    ) {
        self.expectedIssuesChecksum = expectedIssuesChecksum
        self.resolutions = resolutions
    }
}

public struct WorkspaceRestoreContentPayload: Equatable, Sendable {
    public let content: WorkspaceContentSnapshot
    public let sourceRevisionHighWatermark: Int64
    public let sourceNoteRevisions: [NoteID: Int64]

    public init(
        content: WorkspaceContentSnapshot,
        sourceRevisionHighWatermark: Int64,
        sourceNoteRevisions: [NoteID: Int64]
    ) {
        self.content = content
        self.sourceRevisionHighWatermark = sourceRevisionHighWatermark
        self.sourceNoteRevisions = sourceNoteRevisions
    }
}

public enum WorkspaceCommand: Sendable {
    case calendar(CalendarCommand)
    case createNote(CreateNotePayload)
    case updateNote(NoteDraftSubmission)
    case archiveNote(NoteID, at: Date)
    case restoreNote(NoteID, at: Date)
    case setNotePinned(NoteID, Bool, at: Date)
    case permanentlyDeleteNote(NoteID, authorization: PermanentDeleteAuthorization)
    case createPrimaryNoteForCalendar(CreatePrimaryNoteForCalendarPayload)
    case attachPrimaryNote(AttachPrimaryNotePayload)
    case attachReferenceNote(CalendarRelationScope, NoteID)
    case detachNote(CalendarRelationScope, NoteID, linkedTaskDisposition: TaskBlockPrimaryChangeDisposition?)
    case scheduleNoteOnCalendar(ScheduleNoteOnCalendarPayload)
    case scheduleTaskBlock(ScheduleTaskBlockPayload)
    case unlinkTaskBlock(noteID: NoteID, blockID: BlockID)
    case setTaskCompletion(TaskCompletionTarget, value: TaskCompletionValue)
    case createInspiration(CreateInspirationPayload)
    case updateInspirationText(InspirationID, rawText: String, at: Date)
    case updateInspirationMetadata(
        InspirationID,
        expectedSource: InspirationMetadataExpectation,
        metadata: SourceMetadata,
        resolvedKind: ResolvedSourceKind
    )
    case convertInspirationToNote(ConvertInspirationToNotePayload)
    case changeInspirationCategory(InspirationID, categoryID: UUID, at: Date)
    case archiveInspiration(InspirationID, at: Date)
    case restoreInspiration(InspirationID, at: Date)
    case permanentlyDeleteInspiration(
        InspirationID,
        at: Date,
        authorization: PermanentDeleteAuthorization
    )
    case createCategory(CalendarCategory)
    case updateCategory(CalendarCategory)
    case reorderCategories([UUID])
    case deleteCategory(UUID)
    case repairConsistency(WorkspaceConsistencyRepairPayload)
    case restoreContent(WorkspaceRestoreContentPayload)
    case applyDecompositionPlan(ApplyDecompositionPlanPayload)
}

public enum WorkspaceNoChangeReason: Equatable, Sendable {
    case identical
    case cancelled
    case staleLegacyPreview
    case staleMetadata
    case staleDeleteAuthorization
    case staleConsistencyPreview
    case inspirationAlreadyConverted(NoteID)
}

public enum WorkspaceConflict: Equatable, Sendable {
    case noteDraft(NoteDraftConflict)
    case noteMissing(NoteID)
    case decomposition(DecompositionWorkspaceConflict)
}

public struct NoteDraftConflict: Equatable, Sendable {
    public let noteID: NoteID
    public let currentRevision: Int64
    public let conflictingFields: Set<NoteDraftField>
    public let base: Note
    public let submitted: Note
    public let current: Note

    public init(
        noteID: NoteID,
        currentRevision: Int64,
        conflictingFields: Set<NoteDraftField>,
        base: Note,
        submitted: Note,
        current: Note
    ) {
        self.noteID = noteID
        self.currentRevision = currentRevision
        self.conflictingFields = conflictingFields
        self.base = base
        self.submitted = submitted
        self.current = current
    }
}

public struct WorkspaceReduction: Equatable, Sendable {
    public let state: WorkspaceState
    public let changedNoteIDs: Set<NoteID>
    public let draftContext: PersistableDraftContext?
    public let seriesOutcome: SeriesFutureMutationOutcome?

    public init(
        state: WorkspaceState,
        changedNoteIDs: Set<NoteID>,
        draftContext: PersistableDraftContext?,
        seriesOutcome: SeriesFutureMutationOutcome?
    ) {
        self.state = state
        self.changedNoteIDs = changedNoteIDs
        self.draftContext = draftContext
        self.seriesOutcome = seriesOutcome
    }
}

public enum WorkspaceReductionResult: Equatable, Sendable {
    case noChange(WorkspaceNoChangeReason)
    case conflict(WorkspaceConflict)
    case changed(WorkspaceReduction)

    public var change: WorkspaceReduction? {
        if case let .changed(value) = self { value } else { nil }
    }
}

public enum WorkspaceReducerError: Error, Equatable, Sendable {
    case invalidInputWorkspace
    case invalidNote
    case invalidInspiration
    case missingNote(NoteID)
    case duplicateNote(NoteID)
    case missingInspiration(InspirationID)
    case duplicateInspiration(InspirationID)
    case missingCalendarTarget
    case rawCalendarCategoryCommandRejected
    case calendarFailure(ReducerError)
    case seriesMutationFailure(SeriesMutationError)
    case relationMigrationFailure(SeriesRelationMigrationError)
    case invalidDraftSubmission
    case invalidLinkedBlockDispositions
    case taskBlockMissingOrNotTask
    case taskTitleMismatch
    case taskCompletionMismatch
    case duplicateTaskBlockLink
    case primaryReplacementDispositionRequired
    case unexpectedPrimaryReplacementDisposition
    case linkedTaskDispositionRequired
    case unexpectedLinkedTaskDisposition
    case legacyDiagnosticsRequireConfirmation
    case invalidLegacyAuthorization
    case invalidPermanentDeleteAuthorization
    case permanentDeleteRequiresArchivedSubject
    case invalidConsistencyRepair
    case fatalConsistencyIssues
    case invalidRestoreMetadata
    case revisionOverflow
    case finalValidationFailed
    case invalidDecompositionPlan
}

public struct LegacyMarkdownMigrationPreview: Equatable, Sendable {
    public let scope: CalendarRelationScope
    public let document: BlockDocument
    public let diagnostics: [BlockMarkdownDiagnostic]
    public let sourceChecksum: String
    public let diagnosticsChecksum: String

    public init(
        scope: CalendarRelationScope,
        document: BlockDocument,
        diagnostics: [BlockMarkdownDiagnostic],
        sourceChecksum: String,
        diagnosticsChecksum: String
    ) {
        self.scope = scope
        self.document = document
        self.diagnostics = diagnostics
        self.sourceChecksum = sourceChecksum
        self.diagnosticsChecksum = diagnosticsChecksum
    }
}
