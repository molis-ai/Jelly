import CalendarDomain
import Foundation

public struct WorkspaceConsistencyIssueID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct WorkspaceConsistencyIssue: Hashable, Codable, Sendable {
    public let id: WorkspaceConsistencyIssueID
    public let locator: WorkspaceRelationshipLocator
    public let defect: WorkspaceRelationshipDefect

    public init(
        id: WorkspaceConsistencyIssueID,
        locator: WorkspaceRelationshipLocator,
        defect: WorkspaceRelationshipDefect
    ) {
        self.id = id
        self.locator = locator
        self.defect = defect
    }
}

public enum WorkspaceRelationshipLocator: Hashable, Codable, Sendable {
    case calendarBaseline(CalendarNoteOwnerID)
    case occurrenceOverride(OccurrenceKey)
    case calendarNote(CalendarNoteRelationSlot)
    case taskBlock(TaskBlockCalendarLink)
    case inspirationNote(InspirationNoteLink)
}

public enum CalendarNoteRelationSlot: Hashable, Codable, Sendable {
    case baselinePrimary(owner: CalendarNoteOwnerID, noteID: NoteID)
    case baselineReference(owner: CalendarNoteOwnerID, noteID: NoteID)
    case occurrencePrimary(key: OccurrenceKey, noteID: NoteID)
    case occurrenceAddedReference(key: OccurrenceKey, noteID: NoteID)
    case occurrenceRemovedReference(key: OccurrenceKey, noteID: NoteID)
}

public enum WorkspaceRelationshipDefect: Hashable, Codable, Sendable {
    case missingCalendarOwner
    case missingOccurrence
    case missingNote
    case missingCalendarItem
    case missingTaskBlock
    case missingInspiration
}

public enum WorkspaceRelationshipEndpoint: Hashable, Codable, Sendable {
    case calendarOwner(CalendarNoteOwnerID)
    case occurrence(OccurrenceKey)
    case note(NoteID)
    case calendarItem(UUID)
    case taskBlock(noteID: NoteID, blockID: BlockID)
    case inspiration(InspirationID)
}

public enum WorkspaceConsistencyResolution: Hashable, Codable, Sendable {
    case unlink
    case relink(WorkspaceRelationshipEndpoint)
}

public struct WorkspaceConsistencyReport: Equatable, Sendable {
    public let issues: [WorkspaceConsistencyIssue]
    public let issuesChecksum: String
    public let fatalNoteIDs: Set<NoteID>
    public let hasFatalIssues: Bool

    public init(
        issues: [WorkspaceConsistencyIssue],
        issuesChecksum: String,
        fatalNoteIDs: Set<NoteID>,
        hasFatalIssues: Bool? = nil
    ) {
        self.issues = issues
        self.issuesChecksum = issuesChecksum
        self.fatalNoteIDs = fatalNoteIDs
        self.hasFatalIssues = hasFatalIssues ?? !fatalNoteIDs.isEmpty
    }
}

public enum WorkspaceConsistencyInspector {
    public static func inspect(_ state: WorkspaceState) -> WorkspaceConsistencyReport {
        var raw: [(WorkspaceRelationshipLocator, WorkspaceRelationshipDefect)] = []
        var fatalNoteIDs = Set<NoteID>()

        for note in state.notes.values {
            if (try? BlockDocumentValidator.validate(note.document)) == nil {
                fatalNoteIDs.insert(note.id)
            }
        }

        for (owner, noteSet) in state.calendarNoteRelations.baselines {
            if !contains(owner, in: state.calendar) {
                raw.append((.calendarBaseline(owner), .missingCalendarOwner))
            }
            if let noteID = noteSet.primaryNoteID, state.notes[noteID] == nil {
                raw.append((.calendarNote(.baselinePrimary(owner: owner, noteID: noteID)), .missingNote))
            }
            for noteID in noteSet.referenceNoteIDs where state.notes[noteID] == nil {
                raw.append((.calendarNote(.baselineReference(owner: owner, noteID: noteID)), .missingNote))
            }
        }

        for (key, override) in state.calendarNoteRelations.occurrenceOverrides {
            if !CalendarNoteRelationResolver.isLogicalInstance(key, in: state.calendar.recurrence) {
                raw.append((.occurrenceOverride(key), .missingOccurrence))
            }
            if case let .replace(noteID) = override.primary, state.notes[noteID] == nil {
                raw.append((.calendarNote(.occurrencePrimary(key: key, noteID: noteID)), .missingNote))
            }
            for noteID in override.addedReferenceNoteIDs where state.notes[noteID] == nil {
                raw.append((.calendarNote(.occurrenceAddedReference(key: key, noteID: noteID)), .missingNote))
            }
            for noteID in override.removedReferenceNoteIDs where state.notes[noteID] == nil {
                raw.append((.calendarNote(.occurrenceRemovedReference(key: key, noteID: noteID)), .missingNote))
            }
        }

        for link in state.taskBlockLinks {
            if state.calendar.items[link.calendarItemID] == nil {
                raw.append((.taskBlock(link), .missingCalendarItem))
            }
            guard let note = state.notes[link.noteID],
                  note.document.blocks.contains(where: { $0.id == link.blockID && $0.kind == .task })
            else {
                raw.append((.taskBlock(link), .missingTaskBlock))
                continue
            }
        }

        for link in state.inspirationNoteLinks {
            if state.notes[link.noteID] == nil {
                raw.append((.inspirationNote(link), .missingNote))
            }
            if case let .live(id) = link.source, state.inspirations[id] == nil {
                raw.append((.inspirationNote(link), .missingInspiration))
            }
        }

        var ordered = raw
        ordered.sort { lhs, rhs in
            let leftLocator = canonical(lhs.0)
            let rightLocator = canonical(rhs.0)
            if leftLocator != rightLocator { return leftLocator < rightLocator }
            return canonical(lhs.1) < canonical(rhs.1)
        }
        let issues: [WorkspaceConsistencyIssue] = ordered.map { locator, defect in
            let locatorKey = canonical(locator)
            let defectKey = canonical(defect)
            return WorkspaceConsistencyIssue(
                id: .init(rawValue: WorkspaceChecksum.sha256Hex("\(locatorKey)|\(defectKey)")),
                locator: locator,
                defect: defect
            )
        }
        let checksum = WorkspaceChecksum.sha256Hex(
            issues.map { "\($0.id.rawValue)|\(canonical($0.locator))|\(canonical($0.defect))" }
                .joined(separator: "\n")
        )
        let materialDigestsAreFatal = (try? WorkspaceValidator.validateMaterialDigests(state)) == nil
        var structuralProbe = state
        structuralProbe.calendarNoteRelations = .empty
        structuralProbe.taskBlockLinks = []
        structuralProbe.inspirationNoteLinks = []
        for inspirationID in structuralProbe.materialDigests.keys {
            structuralProbe.materialDigests[inspirationID]?.noteWrite = nil
        }
        let coreIsFatal = (try? WorkspaceValidator.validate(structuralProbe)) == nil
        return .init(
            issues: issues,
            issuesChecksum: checksum,
            fatalNoteIDs: fatalNoteIDs,
            hasFatalIssues: materialDigestsAreFatal || coreIsFatal || hasFatalRelationshipShape(state)
        )
    }

    private static func contains(_ owner: CalendarNoteOwnerID, in calendar: CalendarState) -> Bool {
        switch owner {
        case let .item(id): calendar.items[id] != nil
        case let .series(id): calendar.recurrence.series[id] != nil
        }
    }

    private static func hasFatalRelationshipShape(_ state: WorkspaceState) -> Bool {
        for (owner, set) in state.calendarNoteRelations.baselines {
            if let primary = set.primaryNoteID, set.referenceNoteIDs.contains(primary) { return true }
            if set.primaryNoteID != nil, hasLegacyMarkdown(owner, in: state.calendar) { return true }
        }
        for (key, override) in state.calendarNoteRelations.occurrenceOverrides {
            if key != override.key { return true }
            if !override.addedReferenceNoteIDs.isDisjoint(with: override.removedReferenceNoteIDs) {
                return true
            }
            if case let .replace(primary) = override.primary,
               override.addedReferenceNoteIDs.contains(primary) {
                return true
            }
            if CalendarNoteRelationResolver.isLogicalInstance(key, in: state.calendar.recurrence),
               !CalendarNoteRelationResolver.isSkipped(key, in: state.calendar.recurrence),
               let resolved = try? CalendarNoteRelationResolver.resolve(
                   .occurrence(key),
                   calendar: state.calendar,
                   relations: state.calendarNoteRelations
               ),
               resolved.noteSet.primaryNoteID != nil,
               hasLegacyMarkdown(key, in: state.calendar) {
                return true
            }
        }
        var blockIDs = Set<BlockID>()
        var itemIDs = Set<UUID>()
        for link in state.taskBlockLinks {
            if !blockIDs.insert(link.blockID).inserted || !itemIDs.insert(link.calendarItemID).inserted {
                return true
            }
            guard let item = state.calendar.items[link.calendarItemID],
                  let note = state.notes[link.noteID],
                  let block = note.document.blocks.first(where: {
                      $0.id == link.blockID && $0.kind == .task
                  })
            else {
                continue
            }
            if state.calendarNoteRelations.baselines[.item(link.calendarItemID)]?.primaryNoteID
                != link.noteID {
                return true
            }
            if item.title != TaskBlockCalendarTitle.normalized(
                block.inlineContent.spans.map(\.text).joined()
            ) { return true }
            if item.completedAt != block.taskState?.completedAt { return true }
        }
        return false
    }

    private static func hasLegacyMarkdown(
        _ owner: CalendarNoteOwnerID,
        in calendar: CalendarState
    ) -> Bool {
        switch owner {
        case let .item(id):
            calendar.items[id].map { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? false
        case let .series(id):
            calendar.recurrence.series[id]
                .map { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? false
        }
    }

    private static func hasLegacyMarkdown(
        _ key: OccurrenceKey,
        in calendar: CalendarState
    ) -> Bool {
        if case let .modified(override) = calendar.recurrence.exceptions[key] {
            return !override.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return calendar.recurrence.series[key.seriesID]
            .map { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? false
    }

    static func canonical(_ locator: WorkspaceRelationshipLocator) -> String {
        switch locator {
        case let .calendarBaseline(owner): "baseline|\(canonical(owner))"
        case let .occurrenceOverride(key): "occurrence|\(canonical(key))"
        case let .calendarNote(slot): "calendar-note|\(canonical(slot))"
        case let .taskBlock(link):
            "task|\(link.noteID.rawValue.uuidString)|\(link.blockID.rawValue.uuidString)|\(link.calendarItemID.uuidString)"
        case let .inspirationNote(link):
            "inspiration-note|\(canonical(link.source))|\(link.noteID.rawValue.uuidString)|\(link.createdAt.timeIntervalSince1970)"
        }
    }

    static func canonical(_ defect: WorkspaceRelationshipDefect) -> String {
        switch defect {
        case .missingCalendarOwner: "missing-calendar-owner"
        case .missingOccurrence: "missing-occurrence"
        case .missingNote: "missing-note"
        case .missingCalendarItem: "missing-calendar-item"
        case .missingTaskBlock: "missing-task-block"
        case .missingInspiration: "missing-inspiration"
        }
    }

    static func canonical(_ owner: CalendarNoteOwnerID) -> String {
        switch owner {
        case let .item(id): "item|\(id.uuidString)"
        case let .series(id): "series|\(id.uuidString)"
        }
    }

    static func canonical(_ key: OccurrenceKey) -> String {
        "\(key.seriesID.uuidString)|\(key.originalDate.year)-\(key.originalDate.month)-\(key.originalDate.day)"
    }

    private static func canonical(_ slot: CalendarNoteRelationSlot) -> String {
        switch slot {
        case let .baselinePrimary(owner, noteID):
            "baseline-primary|\(canonical(owner))|\(noteID.rawValue.uuidString)"
        case let .baselineReference(owner, noteID):
            "baseline-reference|\(canonical(owner))|\(noteID.rawValue.uuidString)"
        case let .occurrencePrimary(key, noteID):
            "occurrence-primary|\(canonical(key))|\(noteID.rawValue.uuidString)"
        case let .occurrenceAddedReference(key, noteID):
            "occurrence-added|\(canonical(key))|\(noteID.rawValue.uuidString)"
        case let .occurrenceRemovedReference(key, noteID):
            "occurrence-removed|\(canonical(key))|\(noteID.rawValue.uuidString)"
        }
    }

    private static func canonical(_ source: InspirationSourceReference) -> String {
        switch source {
        case let .live(id): "live|\(id.rawValue.uuidString)"
        case let .deleted(id, at): "deleted|\(id.rawValue.uuidString)|\(at.timeIntervalSince1970)"
        }
    }
}
