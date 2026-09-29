import CalendarDomain
import Foundation

public enum WorkspaceUndoDirection: Sendable { case undo, redo }
public enum WorkspaceUndoReducerError: Error, Equatable, Sendable { case conflict, revisionOverflow, invalidCandidate }

private struct ValueChange<Value: Equatable & Sendable>: Equatable, Sendable {
    let before: Value?
    let after: Value?
}

private struct CalendarWriteSet: Equatable, Sendable {
    let categories: [UUID: CalendarCategoryWrite]
    let items: [UUID: CalendarItemWrite]
    let series: [UUID: WeeklySeriesWrite]
    let exceptions: [OccurrenceKey: ValueChange<OccurrenceExceptionKind>]
    let completions: [OccurrenceKey: ValueChange<OccurrenceCompletion>]
    var isEmpty: Bool { categories.isEmpty && items.isEmpty && series.isEmpty && exceptions.isEmpty && completions.isEmpty }
}

private struct CalendarCategoryFieldWrite: Equatable, Sendable {
    let name: ValueChange<String>?
    let colorHex: ValueChange<String>?
    let sortIndex: ValueChange<Int>?
    /// Timestamps are restored with the calendar mutation, but do not make an
    /// otherwise independent later edit conflict with undo.
    let updatedAt: ValueChange<Date>?
    var isEmpty: Bool { name == nil && colorHex == nil && sortIndex == nil && updatedAt == nil }
}

private enum CalendarCategoryWrite: Equatable, Sendable {
    case update(CalendarCategoryFieldWrite)
    case structural(ValueChange<CalendarCategory>)
}

private struct WeeklySeriesFieldWrite: Equatable, Sendable {
    let kind: ValueChange<ItemKind>?
    let title: ValueChange<String>?
    let categoryID: ValueChange<UUID>?
    let ruleStartDate: ValueChange<CalendarDate>?
    let recurrenceEndDate: ValueChange<CalendarDate?>?
    let weekdays: ValueChange<Set<Weekday>>?
    let durationDays: ValueChange<Int>?
    let startTime: ValueChange<MinuteOfDay?>?
    let endTime: ValueChange<MinuteOfDay?>?
    let priority: ValueChange<ItemPriority>?
    let isPinned: ValueChange<Bool>?
    let notes: ValueChange<String>?
    let reminder: ValueChange<ItemReminder?>?
    let creationTimeZoneIdentifier: ValueChange<String>?
    let updatedAt: ValueChange<Date>?

    var isEmpty: Bool {
        kind == nil && title == nil && categoryID == nil && ruleStartDate == nil && recurrenceEndDate == nil && weekdays == nil && durationDays == nil && startTime == nil && endTime == nil && priority == nil && isPinned == nil && notes == nil && reminder == nil && creationTimeZoneIdentifier == nil && updatedAt == nil
    }
}

private enum WeeklySeriesWrite: Equatable, Sendable {
    case update(WeeklySeriesFieldWrite)
    case structural(ValueChange<WeeklySeries>)
}

private struct CalendarItemFieldWrite: Equatable, Sendable {
    let kind: ValueChange<ItemKind>?
    let title: ValueChange<String>?
    let categoryID: ValueChange<UUID>?
    let schedule: ValueChange<CalendarSchedule>?
    let creationTimeZoneIdentifier: ValueChange<String>?
    let priority: ValueChange<ItemPriority>?
    let isPinned: ValueChange<Bool>?
    let notes: ValueChange<String>?
    let untimedRank: ValueChange<Int>?
    let reminder: ValueChange<ItemReminder?>?
    let completedAt: ValueChange<Date?>?
    let updatedAt: ValueChange<Date>?

    var isEmpty: Bool {
        kind == nil && title == nil && categoryID == nil && schedule == nil && creationTimeZoneIdentifier == nil && priority == nil && isPinned == nil && notes == nil && untimedRank == nil && reminder == nil && completedAt == nil && updatedAt == nil
    }
}

private enum CalendarItemWrite: Equatable, Sendable {
    case update(CalendarItemFieldWrite)
    case structural(ValueChange<CalendarItem>)
}

private struct InspirationFieldWrite: Equatable, Sendable {
    let rawText: ValueChange<String?>?
    let rawURL: ValueChange<URL?>?
    let rawFile: ValueChange<FileReference?>?
    let resolvedSourceKind: ValueChange<ResolvedSourceKind>?
    let resolvedMetadata: ValueChange<SourceMetadata?>?
    let categoryID: ValueChange<UUID>?
    let lifecycle: ValueChange<InspirationLifecycle>?
    let lastReviewedAt: ValueChange<Date?>?
    let expansion: ValueChange<InspirationExpansion?>?
    let perspective: ValueChange<InspirationPerspective?>?
    let scheduledItemIDs: ValueChange<[UUID]>?
    var isEmpty: Bool {
        rawText == nil && rawURL == nil && rawFile == nil && resolvedSourceKind == nil && resolvedMetadata == nil && categoryID == nil && lifecycle == nil
            && lastReviewedAt == nil && expansion == nil && perspective == nil && scheduledItemIDs == nil
    }
}

private enum InspirationWrite: Equatable, Sendable {
    case update(InspirationFieldWrite)
    case structural(ValueChange<Inspiration>)
}

private struct CalendarNoteSetFieldWrite: Equatable, Sendable {
    let primaryNoteID: ValueChange<NoteID?>?
    let addedReferenceNoteIDs: Set<NoteID>
    let removedReferenceNoteIDs: Set<NoteID>
    var isEmpty: Bool { primaryNoteID == nil && addedReferenceNoteIDs.isEmpty && removedReferenceNoteIDs.isEmpty }
}

private enum CalendarNoteSetWrite: Equatable, Sendable {
    case update(CalendarNoteSetFieldWrite)
}

private struct OccurrenceNoteOverrideFieldWrite: Equatable, Sendable {
    let primary: ValueChange<OccurrencePrimaryOverride>?
    let addedReferenceNoteIDs: Set<NoteID>
    let removedAddedReferenceNoteIDs: Set<NoteID>
    let addedRemovedReferenceNoteIDs: Set<NoteID>
    let removedRemovedReferenceNoteIDs: Set<NoteID>

    var isEmpty: Bool {
        primary == nil
            && addedReferenceNoteIDs.isEmpty
            && removedAddedReferenceNoteIDs.isEmpty
            && addedRemovedReferenceNoteIDs.isEmpty
            && removedRemovedReferenceNoteIDs.isEmpty
    }
}

private enum OccurrenceNoteOverrideWrite: Equatable, Sendable {
    case update(OccurrenceNoteOverrideFieldWrite)
}

private struct NoteFieldWrite: Equatable, Sendable {
    let title: ValueChange<String>?
    let document: ValueChange<BlockDocument>?
    let categoryID: ValueChange<UUID>?
    let archivedAt: ValueChange<Date?>?
}

private enum NoteWrite: Equatable, Sendable {
    case update(NoteFieldWrite)
    case structural(before: Note?, after: Note?, expectedBeforeIncarnation: Int64?, expectedAfterIncarnation: Int64?)
}

/// A reversible write-set. It contains only changed map entries and link
/// membership changes; it deliberately cannot restore a whole WorkspaceState.
public struct WorkspaceUndoRecord: Equatable, Sendable {
    public let label: String?
    fileprivate let calendar: CalendarWriteSet
    fileprivate let notes: [NoteID: NoteWrite]
    fileprivate let inspirations: [InspirationID: InspirationWrite]
    fileprivate let baselines: [CalendarNoteOwnerID: CalendarNoteSetWrite]
    fileprivate let occurrenceOverrides: [OccurrenceKey: OccurrenceNoteOverrideWrite]
    fileprivate let addedTaskLinks: Set<TaskBlockCalendarLink>
    fileprivate let removedTaskLinks: Set<TaskBlockCalendarLink>
    fileprivate let addedInspirationLinks: Set<InspirationNoteLink>
    fileprivate let removedInspirationLinks: Set<InspirationNoteLink>
    fileprivate let undatedItems: [UUID: ValueChange<UndatedItem>]

    fileprivate init(label: String?, before: WorkspaceState, after: WorkspaceState) {
        self.label = label
        calendar = .init(
            categories: makeCategoryChanges(before.calendar.categories, after.calendar.categories),
            items: makeItemChanges(before.calendar.items, after.calendar.items),
            series: makeSeriesChanges(before.calendar.recurrence.series, after.calendar.recurrence.series),
            exceptions: makeChanges(before.calendar.recurrence.exceptions, after.calendar.recurrence.exceptions),
            completions: makeChanges(before.calendar.recurrence.completions, after.calendar.recurrence.completions)
        )
        notes = makeNoteChanges(before.notes, after.notes)
        inspirations = makeInspirationChanges(before.inspirations, after.inspirations)
        baselines = makeBaselineChanges(before.calendarNoteRelations.baselines, after.calendarNoteRelations.baselines)
        occurrenceOverrides = makeOccurrenceOverrideChanges(
            before.calendarNoteRelations.occurrenceOverrides,
            after.calendarNoteRelations.occurrenceOverrides
        )
        addedTaskLinks = after.taskBlockLinks.subtracting(before.taskBlockLinks)
        removedTaskLinks = before.taskBlockLinks.subtracting(after.taskBlockLinks)
        addedInspirationLinks = after.inspirationNoteLinks.subtracting(before.inspirationNoteLinks)
        removedInspirationLinks = before.inspirationNoteLinks.subtracting(after.inspirationNoteLinks)
        undatedItems = makeChanges(before.undatedItems, after.undatedItems)
    }

    fileprivate var isEmpty: Bool {
        calendar.isEmpty && notes.isEmpty && inspirations.isEmpty && baselines.isEmpty && occurrenceOverrides.isEmpty && addedTaskLinks.isEmpty && removedTaskLinks.isEmpty && addedInspirationLinks.isEmpty && removedInspirationLinks.isEmpty && undatedItems.isEmpty
    }
}

public struct WorkspaceUndoApplication: Equatable, Sendable {
    public let candidate: WorkspaceState
    public let reverseRecord: WorkspaceUndoRecord
    public let noteRevisionHighWatermarks: [NoteID: Int64]
}

private func makeChanges<Key: Hashable & Sendable, Value: Equatable & Sendable>(_ before: [Key: Value], _ after: [Key: Value]) -> [Key: ValueChange<Value>] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { key in
        before[key] == after[key] ? nil : (key, .init(before: before[key], after: after[key]))
    })
}

private func makeNoteChanges(_ before: [NoteID: Note], _ after: [NoteID: Note]) -> [NoteID: NoteWrite] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { id in
        guard let old = before[id] else { return (id, .structural(before: nil, after: after[id], expectedBeforeIncarnation: nil, expectedAfterIncarnation: after[id]?.revision)) }
        guard let new = after[id] else { return (id, .structural(before: old, after: nil, expectedBeforeIncarnation: old.revision, expectedAfterIncarnation: nil)) }
        let fields = NoteFieldWrite(
            title: old.title == new.title ? nil : .init(before: old.title, after: new.title),
            document: old.document == new.document ? nil : .init(before: old.document, after: new.document),
            categoryID: old.categoryID == new.categoryID ? nil : .init(before: old.categoryID, after: new.categoryID),
            archivedAt: old.archivedAt == new.archivedAt ? nil : .init(before: old.archivedAt, after: new.archivedAt)
        )
        return fields.title == nil && fields.document == nil && fields.categoryID == nil && fields.archivedAt == nil ? nil : (id, .update(fields))
    })
}

private func makeItemChanges(_ before: [UUID: CalendarItem], _ after: [UUID: CalendarItem]) -> [UUID: CalendarItemWrite] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { id in
        guard let old = before[id], let new = after[id] else {
            return before[id] == after[id] ? nil : (id, .structural(.init(before: before[id], after: after[id])))
        }
        let fields = CalendarItemFieldWrite(
            kind: old.kind == new.kind ? nil : .init(before: old.kind, after: new.kind),
            title: old.title == new.title ? nil : .init(before: old.title, after: new.title),
            categoryID: old.categoryID == new.categoryID ? nil : .init(before: old.categoryID, after: new.categoryID),
            schedule: old.schedule == new.schedule ? nil : .init(before: old.schedule, after: new.schedule),
            creationTimeZoneIdentifier: old.creationTimeZoneIdentifier == new.creationTimeZoneIdentifier ? nil : .init(before: old.creationTimeZoneIdentifier, after: new.creationTimeZoneIdentifier),
            priority: old.priority == new.priority ? nil : .init(before: old.priority, after: new.priority),
            isPinned: old.isPinned == new.isPinned ? nil : .init(before: old.isPinned, after: new.isPinned),
            notes: old.notes == new.notes ? nil : .init(before: old.notes, after: new.notes),
            untimedRank: old.untimedRank == new.untimedRank ? nil : .init(before: old.untimedRank, after: new.untimedRank),
            reminder: old.reminder == new.reminder ? nil : .init(before: old.reminder, after: new.reminder),
            completedAt: old.completedAt == new.completedAt ? nil : .init(before: old.completedAt, after: new.completedAt),
            updatedAt: old.updatedAt == new.updatedAt ? nil : .init(before: old.updatedAt, after: new.updatedAt)
        )
        return fields.isEmpty ? nil : (id, .update(fields))
    })
}

private func makeCategoryChanges(_ before: [UUID: CalendarCategory], _ after: [UUID: CalendarCategory]) -> [UUID: CalendarCategoryWrite] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { id in
        guard let old = before[id], let new = after[id] else {
            return before[id] == after[id] ? nil : (id, .structural(.init(before: before[id], after: after[id])))
        }
        let fields = CalendarCategoryFieldWrite(
            name: old.name == new.name ? nil : .init(before: old.name, after: new.name),
            colorHex: old.colorHex == new.colorHex ? nil : .init(before: old.colorHex, after: new.colorHex),
            sortIndex: old.sortIndex == new.sortIndex ? nil : .init(before: old.sortIndex, after: new.sortIndex),
            updatedAt: old.updatedAt == new.updatedAt ? nil : .init(before: old.updatedAt, after: new.updatedAt)
        )
        return fields.isEmpty ? nil : (id, .update(fields))
    })
}

private func makeSeriesChanges(_ before: [UUID: WeeklySeries], _ after: [UUID: WeeklySeries]) -> [UUID: WeeklySeriesWrite] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { id in
        guard let old = before[id], let new = after[id] else {
            return before[id] == after[id] ? nil : (id, .structural(.init(before: before[id], after: after[id])))
        }
        let fields = WeeklySeriesFieldWrite(
            kind: old.kind == new.kind ? nil : .init(before: old.kind, after: new.kind),
            title: old.title == new.title ? nil : .init(before: old.title, after: new.title),
            categoryID: old.categoryID == new.categoryID ? nil : .init(before: old.categoryID, after: new.categoryID),
            ruleStartDate: old.ruleStartDate == new.ruleStartDate ? nil : .init(before: old.ruleStartDate, after: new.ruleStartDate),
            recurrenceEndDate: old.recurrenceEndDate == new.recurrenceEndDate ? nil : .init(before: old.recurrenceEndDate, after: new.recurrenceEndDate),
            weekdays: old.weekdays == new.weekdays ? nil : .init(before: old.weekdays, after: new.weekdays),
            durationDays: old.durationDays == new.durationDays ? nil : .init(before: old.durationDays, after: new.durationDays),
            startTime: old.startTime == new.startTime ? nil : .init(before: old.startTime, after: new.startTime),
            endTime: old.endTime == new.endTime ? nil : .init(before: old.endTime, after: new.endTime),
            priority: old.priority == new.priority ? nil : .init(before: old.priority, after: new.priority),
            isPinned: old.isPinned == new.isPinned ? nil : .init(before: old.isPinned, after: new.isPinned),
            notes: old.notes == new.notes ? nil : .init(before: old.notes, after: new.notes),
            reminder: old.reminder == new.reminder ? nil : .init(before: old.reminder, after: new.reminder),
            creationTimeZoneIdentifier: old.creationTimeZoneIdentifier == new.creationTimeZoneIdentifier ? nil : .init(before: old.creationTimeZoneIdentifier, after: new.creationTimeZoneIdentifier),
            updatedAt: old.updatedAt == new.updatedAt ? nil : .init(before: old.updatedAt, after: new.updatedAt)
        )
        return fields.isEmpty ? nil : (id, .update(fields))
    })
}

private func makeInspirationChanges(_ before: [InspirationID: Inspiration], _ after: [InspirationID: Inspiration]) -> [InspirationID: InspirationWrite] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { id in
        guard let old = before[id], let new = after[id] else {
            return before[id] == after[id] ? nil : (id, .structural(.init(before: before[id], after: after[id])))
        }
        let fields = InspirationFieldWrite(
            rawText: old.rawText == new.rawText ? nil : .init(before: old.rawText, after: new.rawText),
            rawURL: old.rawURL == new.rawURL ? nil : .init(before: old.rawURL, after: new.rawURL),
            rawFile: old.rawFile == new.rawFile ? nil : .init(before: old.rawFile, after: new.rawFile),
            resolvedSourceKind: old.resolvedSourceKind == new.resolvedSourceKind ? nil : .init(before: old.resolvedSourceKind, after: new.resolvedSourceKind),
            resolvedMetadata: old.resolvedMetadata == new.resolvedMetadata ? nil : .init(before: old.resolvedMetadata, after: new.resolvedMetadata),
            categoryID: old.categoryID == new.categoryID ? nil : .init(before: old.categoryID, after: new.categoryID),
            lifecycle: old.lifecycle == new.lifecycle ? nil : .init(before: old.lifecycle, after: new.lifecycle),
            lastReviewedAt: old.lastReviewedAt == new.lastReviewedAt ? nil : .init(before: old.lastReviewedAt, after: new.lastReviewedAt),
            expansion: old.expansion == new.expansion ? nil : .init(before: old.expansion, after: new.expansion),
            perspective: old.perspective == new.perspective ? nil : .init(before: old.perspective, after: new.perspective),
            scheduledItemIDs: old.scheduledItemIDs == new.scheduledItemIDs ? nil : .init(before: old.scheduledItemIDs, after: new.scheduledItemIDs)
        )
        return fields.isEmpty ? nil : (id, .update(fields))
    })
}

private func makeBaselineChanges(_ before: [CalendarNoteOwnerID: CalendarNoteSet], _ after: [CalendarNoteOwnerID: CalendarNoteSet]) -> [CalendarNoteOwnerID: CalendarNoteSetWrite] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { owner in
        let old = before[owner] ?? .init(primaryNoteID: nil, referenceNoteIDs: [])
        let new = after[owner] ?? .init(primaryNoteID: nil, referenceNoteIDs: [])
        let fields = CalendarNoteSetFieldWrite(
            primaryNoteID: old.primaryNoteID == new.primaryNoteID ? nil : .init(before: old.primaryNoteID, after: new.primaryNoteID),
            addedReferenceNoteIDs: new.referenceNoteIDs.subtracting(old.referenceNoteIDs),
            removedReferenceNoteIDs: old.referenceNoteIDs.subtracting(new.referenceNoteIDs)
        )
        return fields.isEmpty ? nil : (owner, .update(fields))
    })
}

private func makeOccurrenceOverrideChanges(
    _ before: [OccurrenceKey: OccurrenceNoteOverride],
    _ after: [OccurrenceKey: OccurrenceNoteOverride]
) -> [OccurrenceKey: OccurrenceNoteOverrideWrite] {
    Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { key in
        let empty = OccurrenceNoteOverride(
            key: key, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
        )
        let old = before[key] ?? empty
        let new = after[key] ?? empty
        let fields = OccurrenceNoteOverrideFieldWrite(
            primary: old.primary == new.primary ? nil : .init(before: old.primary, after: new.primary),
            addedReferenceNoteIDs: new.addedReferenceNoteIDs.subtracting(old.addedReferenceNoteIDs),
            removedAddedReferenceNoteIDs: old.addedReferenceNoteIDs.subtracting(new.addedReferenceNoteIDs),
            addedRemovedReferenceNoteIDs: new.removedReferenceNoteIDs.subtracting(old.removedReferenceNoteIDs),
            removedRemovedReferenceNoteIDs: old.removedReferenceNoteIDs.subtracting(new.removedReferenceNoteIDs)
        )
        return fields.isEmpty ? nil : (key, .update(fields))
    })
}

public enum WorkspaceUndoReducer {
    public static func record(before: WorkspaceState, after: WorkspaceState, label: String?) -> WorkspaceUndoRecord? {
        let record = WorkspaceUndoRecord(label: label, before: before, after: after)
        return record.isEmpty ? nil : record
    }

    public static func apply(_ record: WorkspaceUndoRecord, direction: WorkspaceUndoDirection, to state: WorkspaceState, noteRevisionHighWatermarks: [NoteID: Int64]) throws -> WorkspaceUndoApplication {
        guard state.revision < Int64.max else { throw WorkspaceUndoReducerError.revisionOverflow }
        var candidate = state
        let undo = direction == .undo
        try applyCategories(record.calendar.categories, to: &candidate.calendar.categories, undo: undo)
        try applyItems(record.calendar.items, to: &candidate.calendar.items, undo: undo)
        try applySeries(record.calendar.series, to: &candidate.calendar.recurrence.series, undo: undo)
        try apply(record.calendar.exceptions, to: &candidate.calendar.recurrence.exceptions, undo: undo, normalize: { $0 })
        try apply(record.calendar.completions, to: &candidate.calendar.recurrence.completions, undo: undo, normalize: { $0 })
        try applyNotes(record.notes, to: &candidate.notes, undo: undo)
        try applyInspirations(record.inspirations, to: &candidate.inspirations, undo: undo)
        try applyBaselines(record.baselines, to: &candidate.calendarNoteRelations.baselines, undo: undo)
        try applyOccurrenceOverrides(
            record.occurrenceOverrides,
            to: &candidate.calendarNoteRelations.occurrenceOverrides,
            undo: undo
        )
        try applyLinks(added: record.addedTaskLinks, removed: record.removedTaskLinks, to: &candidate.taskBlockLinks, undo: undo)
        try applyLinks(added: record.addedInspirationLinks, removed: record.removedInspirationLinks, to: &candidate.inspirationNoteLinks, undo: undo)
        try apply(record.undatedItems, to: &candidate.undatedItems, undo: undo, normalize: { $0 })
        candidate.revision = state.revision + 1
        var ledger = noteRevisionHighWatermarks
        for id in record.notes.keys {
            let high = max(ledger[id] ?? 0, state.notes[id]?.revision ?? 0, candidate.notes[id]?.revision ?? 0)
            ledger[id] = high
            guard var note = candidate.notes[id] else { continue }
            guard high < Int64.max else { throw WorkspaceUndoReducerError.revisionOverflow }
            note.revision = high + 1
            candidate.notes[id] = note
            ledger[id] = note.revision
        }
        do { try WorkspaceValidator.validate(candidate) } catch { throw WorkspaceUndoReducerError.invalidCandidate }
        let reverse: WorkspaceUndoRecord
        if undo {
            reverse = .init(label: record.label, before: candidate, after: state)
        } else {
            reverse = .init(label: record.label, before: state, after: candidate)
        }
        return .init(candidate: candidate, reverseRecord: reverse, noteRevisionHighWatermarks: ledger)
    }

    private static func apply<Key: Hashable & Sendable, Value: Equatable & Sendable>(_ changes: [Key: ValueChange<Value>], to map: inout [Key: Value], undo: Bool, normalize: (Value) -> Value) throws {
        for (key, change) in changes {
            let expected = undo ? change.after : change.before
            let replacement = undo ? change.before : change.after
            guard map[key].map(normalize) == expected.map(normalize) else { throw WorkspaceUndoReducerError.conflict }
            map[key] = replacement
        }
    }

    private static func applyNotes(_ changes: [NoteID: NoteWrite], to notes: inout [NoteID: Note], undo: Bool) throws {
        for (id, change) in changes {
            switch change {
            case let .update(fields):
                guard var next = notes[id] else { throw WorkspaceUndoReducerError.conflict }
                try applyNote(fields.title, value: &next.title, undo: undo)
                try applyNote(fields.document, value: &next.document, undo: undo)
                try applyNote(fields.categoryID, value: &next.categoryID, undo: undo)
                try applyNote(fields.archivedAt, value: &next.archivedAt, undo: undo)
                notes[id] = next
            case let .structural(before, after, beforeRevision, afterRevision):
                let expected = undo ? after : before
                let expectedRevision = undo ? afterRevision : beforeRevision
                let replacement = undo ? before : after
                guard notes[id].map({ note in expected.map { WorkspaceReducer.noteBusinessEquivalent(note, $0) && note.revision == expectedRevision } ?? false }) ?? (expected == nil) else { throw WorkspaceUndoReducerError.conflict }
                notes[id] = replacement
            }
        }
    }

    private static func applyItems(_ changes: [UUID: CalendarItemWrite], to items: inout [UUID: CalendarItem], undo: Bool) throws {
        for (id, change) in changes {
            switch change {
            case let .update(fields):
                guard var next = items[id] else { throw WorkspaceUndoReducerError.conflict }
                try applyItem(fields.kind, value: &next.kind, undo: undo)
                try applyItem(fields.title, value: &next.title, undo: undo)
                try applyItem(fields.categoryID, value: &next.categoryID, undo: undo)
                try applyItem(fields.schedule, value: &next.schedule, undo: undo)
                try applyItem(fields.creationTimeZoneIdentifier, value: &next.creationTimeZoneIdentifier, undo: undo)
                try applyItem(fields.priority, value: &next.priority, undo: undo)
                try applyItem(fields.isPinned, value: &next.isPinned, undo: undo)
                try applyItem(fields.notes, value: &next.notes, undo: undo)
                try applyItem(fields.untimedRank, value: &next.untimedRank, undo: undo)
                try applyItem(fields.reminder, value: &next.reminder, undo: undo)
                try applyItem(fields.completedAt, value: &next.completedAt, undo: undo)
                restoreTimestamp(fields.updatedAt, value: &next.updatedAt, undo: undo)
                items[id] = next
            case let .structural(change):
                let expected = undo ? change.after : change.before
                let replacement = undo ? change.before : change.after
                guard items[id].map(normalizeItem) == expected.map(normalizeItem) else { throw WorkspaceUndoReducerError.conflict }
                items[id] = replacement
            }
        }
    }

    private static func applyCategories(_ changes: [UUID: CalendarCategoryWrite], to categories: inout [UUID: CalendarCategory], undo: Bool) throws {
        for (id, change) in changes {
            switch change {
            case let .update(fields):
                guard var next = categories[id] else { throw WorkspaceUndoReducerError.conflict }
                try applyField(fields.name, value: &next.name, undo: undo)
                try applyField(fields.colorHex, value: &next.colorHex, undo: undo)
                try applyField(fields.sortIndex, value: &next.sortIndex, undo: undo)
                restoreTimestamp(fields.updatedAt, value: &next.updatedAt, undo: undo)
                categories[id] = next
            case let .structural(change):
                let expected = undo ? change.after : change.before
                let replacement = undo ? change.before : change.after
                guard categories[id].map(normalizeCategory) == expected.map(normalizeCategory) else { throw WorkspaceUndoReducerError.conflict }
                categories[id] = replacement
            }
        }
    }

    private static func applySeries(_ changes: [UUID: WeeklySeriesWrite], to series: inout [UUID: WeeklySeries], undo: Bool) throws {
        for (id, change) in changes {
            switch change {
            case let .update(fields):
                guard var next = series[id] else { throw WorkspaceUndoReducerError.conflict }
                try applyField(fields.kind, value: &next.kind, undo: undo)
                try applyField(fields.title, value: &next.title, undo: undo)
                try applyField(fields.categoryID, value: &next.categoryID, undo: undo)
                try applyField(fields.ruleStartDate, value: &next.ruleStartDate, undo: undo)
                try applyField(fields.recurrenceEndDate, value: &next.recurrenceEndDate, undo: undo)
                try applyField(fields.weekdays, value: &next.weekdays, undo: undo)
                try applyField(fields.durationDays, value: &next.durationDays, undo: undo)
                try applyField(fields.startTime, value: &next.startTime, undo: undo)
                try applyField(fields.endTime, value: &next.endTime, undo: undo)
                try applyField(fields.priority, value: &next.priority, undo: undo)
                try applyField(fields.isPinned, value: &next.isPinned, undo: undo)
                try applyField(fields.notes, value: &next.notes, undo: undo)
                try applyField(fields.reminder, value: &next.reminder, undo: undo)
                try applyField(fields.creationTimeZoneIdentifier, value: &next.creationTimeZoneIdentifier, undo: undo)
                restoreTimestamp(fields.updatedAt, value: &next.updatedAt, undo: undo)
                series[id] = next
            case let .structural(change):
                let expected = undo ? change.after : change.before
                let replacement = undo ? change.before : change.after
                guard series[id].map(normalizeSeries) == expected.map(normalizeSeries) else { throw WorkspaceUndoReducerError.conflict }
                series[id] = replacement
            }
        }
    }

    private static func applyInspirations(_ changes: [InspirationID: InspirationWrite], to inspirations: inout [InspirationID: Inspiration], undo: Bool) throws {
        for (id, change) in changes {
            switch change {
            case let .update(fields):
                guard var next = inspirations[id] else { throw WorkspaceUndoReducerError.conflict }
                try applyField(fields.rawText, value: &next.rawText, undo: undo)
                try applyField(fields.rawURL, value: &next.rawURL, undo: undo)
                try applyField(fields.rawFile, value: &next.rawFile, undo: undo)
                try applyField(fields.resolvedSourceKind, value: &next.resolvedSourceKind, undo: undo)
                try applyField(fields.resolvedMetadata, value: &next.resolvedMetadata, undo: undo)
                try applyField(fields.categoryID, value: &next.categoryID, undo: undo)
                try applyField(fields.lifecycle, value: &next.lifecycle, undo: undo)
                try applyField(fields.lastReviewedAt, value: &next.lastReviewedAt, undo: undo)
                try applyField(fields.expansion, value: &next.expansion, undo: undo)
                try applyField(fields.perspective, value: &next.perspective, undo: undo)
                try applyField(fields.scheduledItemIDs, value: &next.scheduledItemIDs, undo: undo)
                inspirations[id] = next
            case let .structural(change):
                let expected = undo ? change.after : change.before
                let replacement = undo ? change.before : change.after
                guard inspirations[id].map(normalizeInspiration) == expected.map(normalizeInspiration) else { throw WorkspaceUndoReducerError.conflict }
                inspirations[id] = replacement
            }
        }
    }

    private static func applyBaselines(_ changes: [CalendarNoteOwnerID: CalendarNoteSetWrite], to baselines: inout [CalendarNoteOwnerID: CalendarNoteSet], undo: Bool) throws {
        for (owner, change) in changes {
            switch change {
            case let .update(fields):
                var next = baselines[owner] ?? .init(primaryNoteID: nil, referenceNoteIDs: [])
                try applyField(fields.primaryNoteID, value: &next.primaryNoteID, undo: undo)
                let expectPresent = undo ? fields.addedReferenceNoteIDs : fields.removedReferenceNoteIDs
                let expectAbsent = undo ? fields.removedReferenceNoteIDs : fields.addedReferenceNoteIDs
                guard expectPresent.isSubset(of: next.referenceNoteIDs), expectAbsent.isDisjoint(with: next.referenceNoteIDs) else {
                    throw WorkspaceUndoReducerError.conflict
                }
                next.referenceNoteIDs.subtract(expectPresent)
                next.referenceNoteIDs.formUnion(expectAbsent)
                if next.primaryNoteID == nil && next.referenceNoteIDs.isEmpty {
                    baselines.removeValue(forKey: owner)
                } else {
                    baselines[owner] = next
                }
            }
        }
    }

    private static func applyOccurrenceOverrides(
        _ changes: [OccurrenceKey: OccurrenceNoteOverrideWrite],
        to overrides: inout [OccurrenceKey: OccurrenceNoteOverride],
        undo: Bool
    ) throws {
        for (key, change) in changes {
            switch change {
            case let .update(fields):
                var next = overrides[key] ?? .init(
                    key: key, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
                )
                try applyField(fields.primary, value: &next.primary, undo: undo)
                try applySetDelta(
                    added: fields.addedReferenceNoteIDs,
                    removed: fields.removedAddedReferenceNoteIDs,
                    to: &next.addedReferenceNoteIDs,
                    undo: undo
                )
                try applySetDelta(
                    added: fields.addedRemovedReferenceNoteIDs,
                    removed: fields.removedRemovedReferenceNoteIDs,
                    to: &next.removedReferenceNoteIDs,
                    undo: undo
                )
                if next.primary == .inherit
                    && next.addedReferenceNoteIDs.isEmpty
                    && next.removedReferenceNoteIDs.isEmpty {
                    overrides.removeValue(forKey: key)
                } else {
                    overrides[key] = next
                }
            }
        }
    }

    private static func applyNote<Value: Equatable>(_ change: ValueChange<Value>?, value: inout Value, undo: Bool) throws {
        guard let change else { return }
        let expected = undo ? change.after : change.before
        let replacement = undo ? change.before : change.after
        guard value == expected else { throw WorkspaceUndoReducerError.conflict }
        guard let replacement else { throw WorkspaceUndoReducerError.conflict }
        value = replacement
    }

    private static func applyItem<Value: Equatable>(_ change: ValueChange<Value>?, value: inout Value, undo: Bool) throws {
        try applyNote(change, value: &value, undo: undo)
    }

    private static func applyField<Value: Equatable>(_ change: ValueChange<Value>?, value: inout Value, undo: Bool) throws {
        try applyNote(change, value: &value, undo: undo)
    }

    private static func restoreTimestamp(_ change: ValueChange<Date>?, value: inout Date, undo: Bool) {
        guard let change, let replacement = undo ? change.before : change.after else { return }
        value = replacement
    }

    private static func applyLinks<Link: Hashable & Sendable>(added: Set<Link>, removed: Set<Link>, to links: inout Set<Link>, undo: Bool) throws {
        try applySetDelta(added: added, removed: removed, to: &links, undo: undo)
    }

    private static func applySetDelta<Element: Hashable & Sendable>(
        added: Set<Element>,
        removed: Set<Element>,
        to values: inout Set<Element>,
        undo: Bool
    ) throws {
        let expectPresent = undo ? added : removed
        let expectAbsent = undo ? removed : added
        guard expectPresent.isSubset(of: values), expectAbsent.isDisjoint(with: values) else {
            throw WorkspaceUndoReducerError.conflict
        }
        values.subtract(expectPresent)
        values.formUnion(expectAbsent)
    }

    private static func normalizeCategory(_ value: CalendarCategory) -> CalendarCategory { var value = value; value.createdAt = .distantPast; value.updatedAt = .distantPast; return value }
    private static func normalizeItem(_ value: CalendarItem) -> CalendarItem { var value = value; value.createdAt = .distantPast; value.updatedAt = .distantPast; return value }
    private static func normalizeSeries(_ value: WeeklySeries) -> WeeklySeries { var value = value; value.createdAt = .distantPast; value.updatedAt = .distantPast; return value }
    private static func normalizeInspiration(_ value: Inspiration) -> Inspiration { var value = value; value.createdAt = .distantPast; value.updatedAt = .distantPast; return value }
}
