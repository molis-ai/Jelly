import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("CalendarNoteRelationResolverTests")
struct CalendarNoteRelationResolverTests {
    @Test func itemAndSeriesResolveTheirBaselinesWithoutSynthesizingStorage() throws {
        let fixture = try RelationFixture()
        var relations = CalendarNoteRelationGraph.empty
        relations.baselines[.item(fixture.itemID)] = .init(
            primaryNoteID: fixture.primary,
            referenceNoteIDs: [fixture.reference]
        )

        let item = try CalendarNoteRelationResolver.resolve(
            .item(fixture.itemID), calendar: fixture.calendar, relations: relations
        )
        let series = try CalendarNoteRelationResolver.resolve(
            .series(fixture.series.id), calendar: fixture.calendar, relations: relations
        )

        #expect(item.noteSet == .init(primaryNoteID: fixture.primary, referenceNoteIDs: [fixture.reference]))
        #expect(item.isClickable)
        #expect(series.noteSet == .init(primaryNoteID: nil, referenceNoteIDs: []))
        #expect(series.isClickable)
        #expect(relations.baselines[.series(fixture.series.id)] == nil)
    }

    @Test func occurrenceInheritsBaselineAndExplicitAddedPrimaryDoesNotBecomeReference() throws {
        let fixture = try RelationFixture()
        let key = fixture.naturalKey
        let relations = CalendarNoteRelationGraph(
            baselines: [.series(fixture.series.id): .init(
                primaryNoteID: fixture.primary,
                referenceNoteIDs: [fixture.reference]
            )],
            occurrenceOverrides: [key: .init(
                key: key,
                primary: .inherit,
                addedReferenceNoteIDs: [fixture.primary],
                removedReferenceNoteIDs: []
            )]
        )

        let resolved = try CalendarNoteRelationResolver.resolve(
            .occurrence(key), calendar: fixture.calendar, relations: relations
        )

        #expect(resolved.noteSet == .init(primaryNoteID: fixture.primary, referenceNoteIDs: [fixture.reference]))
    }

    @Test func occurrenceReplacePromotesInheritedReferenceAndClearRemovesPrimary() throws {
        let fixture = try RelationFixture()
        let key = fixture.naturalKey
        let baseline = CalendarNoteSet(primaryNoteID: fixture.primary, referenceNoteIDs: [fixture.reference])
        let replaced = CalendarNoteRelationGraph(
            baselines: [.series(fixture.series.id): baseline],
            occurrenceOverrides: [key: .init(
                key: key, primary: .replace(fixture.reference),
                addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
            )]
        )
        let cleared = CalendarNoteRelationGraph(
            baselines: [.series(fixture.series.id): baseline],
            occurrenceOverrides: [key: .init(
                key: key, primary: .clear,
                addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
            )]
        )

        let replaceResult = try CalendarNoteRelationResolver.resolve(
            .occurrence(key), calendar: fixture.calendar, relations: replaced
        )
        let clearResult = try CalendarNoteRelationResolver.resolve(
            .occurrence(key), calendar: fixture.calendar, relations: cleared
        )

        #expect(replaceResult.noteSet == .init(primaryNoteID: fixture.reference, referenceNoteIDs: []))
        #expect(clearResult.noteSet == .init(primaryNoteID: nil, referenceNoteIDs: [fixture.reference]))
    }

    @Test func modifiedAndSkippedExceptionsAreLogicalButSkippedIsNotClickable() throws {
        let fixture = try RelationFixture()
        let modifiedKey = OccurrenceKey(seriesID: fixture.series.id, originalDate: fixture.tuesday)
        let skippedKey = OccurrenceKey(seriesID: fixture.series.id, originalDate: fixture.wednesday)
        var calendar = fixture.calendar
        calendar.recurrence.exceptions[modifiedKey] = .modified(fixture.override(on: modifiedKey.originalDate))
        calendar.recurrence.exceptions[skippedKey] = .skipped
        let relations = CalendarNoteRelationGraph(
            baselines: [:],
            occurrenceOverrides: [
                modifiedKey: .init(key: modifiedKey, primary: .replace(fixture.primary), addedReferenceNoteIDs: [], removedReferenceNoteIDs: []),
                skippedKey: .init(key: skippedKey, primary: .replace(fixture.primary), addedReferenceNoteIDs: [], removedReferenceNoteIDs: [])
            ]
        )

        let modified = try CalendarNoteRelationResolver.resolve(
            .occurrence(modifiedKey), calendar: calendar, relations: relations
        )
        let skipped = try CalendarNoteRelationResolver.resolve(
            .occurrence(skippedKey), calendar: calendar, relations: relations
        )

        #expect(modified.isClickable)
        #expect(skipped.isClickable == false)
        #expect(skipped.noteSet.primaryNoteID == fixture.primary)
    }

    @Test func completionOnlyAndNonweekdayRelationKeysAreNotLogicalInstances() throws {
        let fixture = try RelationFixture()
        let completionOnly = OccurrenceKey(seriesID: fixture.series.id, originalDate: fixture.tuesday)
        var calendar = fixture.calendar
        calendar.recurrence.completions[completionOnly] = .init(key: completionOnly, completedAt: .distantPast)
        let relations = CalendarNoteRelationGraph.empty

        #expect(throws: CalendarNoteRelationResolutionError.invalidOccurrence(completionOnly)) {
            try CalendarNoteRelationResolver.resolve(.occurrence(completionOnly), calendar: calendar, relations: relations)
        }
    }

    @Test func validatorRejectsRawReferenceOverlapAndExplicitAddedPrimaryOverlap() throws {
        let fixture = try RelationFixture()
        let key = fixture.naturalKey
        var overlap = fixture.workspace()
        overlap.calendarNoteRelations.occurrenceOverrides[key] = .init(
            key: key, primary: .inherit,
            addedReferenceNoteIDs: [fixture.reference], removedReferenceNoteIDs: [fixture.reference]
        )
        #expect(throws: WorkspaceValidationError.overlappingOccurrenceReferences(key, fixture.reference)) {
            try WorkspaceValidator.validate(overlap)
        }

        var explicitPrimary = fixture.workspace()
        explicitPrimary.calendarNoteRelations.occurrenceOverrides[key] = .init(
            key: key, primary: .replace(fixture.primary),
            addedReferenceNoteIDs: [fixture.primary], removedReferenceNoteIDs: []
        )
        #expect(throws: WorkspaceValidationError.occurrencePrimaryAlsoReference(key, fixture.primary)) {
            try WorkspaceValidator.validate(explicitPrimary)
        }
    }

    @Test func validatorRejectsPrimaryWithItemSeriesAndModifiedOccurrenceLegacyMarkdown() throws {
        let fixture = try RelationFixture()
        var item = fixture.workspace()
        item.calendar.items[fixture.itemID]?.notes = "  旧事项笔记\n"
        item.calendarNoteRelations.baselines[.item(fixture.itemID)] = .init(
            primaryNoteID: fixture.primary, referenceNoteIDs: []
        )
        #expect(throws: WorkspaceValidationError.primaryConflictsWithLegacyMarkdown(.item(fixture.itemID))) {
            try WorkspaceValidator.validate(item)
        }

        var series = fixture.workspace()
        series.calendar.recurrence.series[fixture.series.id]?.notes = "旧系列笔记"
        series.calendarNoteRelations.baselines[.series(fixture.series.id)] = .init(
            primaryNoteID: fixture.primary, referenceNoteIDs: []
        )
        #expect(throws: WorkspaceValidationError.primaryConflictsWithLegacyMarkdown(.series(fixture.series.id))) {
            try WorkspaceValidator.validate(series)
        }

        var occurrence = fixture.workspace()
        occurrence.calendar.recurrence.exceptions[fixture.naturalKey] = .modified(
            fixture.override(on: fixture.naturalKey.originalDate, notes: "\n旧例外笔记")
        )
        occurrence.calendarNoteRelations.occurrenceOverrides[fixture.naturalKey] = .init(
            key: fixture.naturalKey, primary: .replace(fixture.primary),
            addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
        )
        #expect(throws: WorkspaceValidationError.occurrencePrimaryConflictsWithLegacyMarkdown(fixture.naturalKey)) {
            try WorkspaceValidator.validate(occurrence)
        }
    }

    @Test func validatorAllowsSkippedPrimaryRetentionAndReferenceOnlyLegacyCoexistence() throws {
        let fixture = try RelationFixture()
        let skippedKey = OccurrenceKey(seriesID: fixture.series.id, originalDate: fixture.tuesday)
        var skipped = fixture.workspace()
        skipped.calendar.recurrence.exceptions[skippedKey] = .skipped
        skipped.calendar.recurrence.series[fixture.series.id]?.notes = "旧系列笔记"
        skipped.calendarNoteRelations.occurrenceOverrides[skippedKey] = .init(
            key: skippedKey, primary: .replace(fixture.primary),
            addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
        )
        try WorkspaceValidator.validate(skipped)

        var references = fixture.workspace()
        references.calendar.items[fixture.itemID]?.notes = "旧事项笔记"
        references.calendarNoteRelations.baselines[.item(fixture.itemID)] = .init(
            primaryNoteID: nil, referenceNoteIDs: [fixture.reference]
        )
        try WorkspaceValidator.validate(references)
    }

    @Test func validatorRejectsStaleOldFutureOverrideAfterSplit() throws {
        let fixture = try RelationFixture()
        let staleKey = OccurrenceKey(seriesID: fixture.series.id, originalDate: fixture.monday.addingDays(7))
        var workspace = fixture.workspace()
        workspace.calendar.recurrence.series[fixture.series.id]?.recurrenceEndDate = fixture.monday
        workspace.calendarNoteRelations.occurrenceOverrides[staleKey] = .init(
            key: staleKey, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
        )

        #expect(throws: WorkspaceValidationError.danglingOccurrenceOverride(staleKey)) {
            try WorkspaceValidator.validate(workspace)
        }
    }
}

private struct RelationFixture {
    let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
    let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000503")!
    let primary = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000504")!)
    let reference = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000505")!)
    let monday = CalendarDate(year: 2026, month: 8, day: 3)!
    let tuesday = CalendarDate(year: 2026, month: 8, day: 4)!
    let wednesday = CalendarDate(year: 2026, month: 8, day: 5)!
    let calendar: CalendarState
    let series: WeeklySeries

    init() throws {
        var calendar = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        calendar.items[itemID] = try CalendarItem(
            id: itemID, kind: .task, title: "事项", categoryID: categoryID,
            schedule: .init(startDate: monday, endDate: monday, startTime: nil, endTime: nil),
            notes: "", completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        let series = try WeeklySeries(
            id: seriesID, kind: .task, title: "每周", categoryID: categoryID,
            ruleStartDate: monday, recurrenceEndDate: nil, weekdays: [.monday],
            durationDays: 1, startTime: nil, endTime: nil, notes: "",
            createdAt: .distantPast, updatedAt: .distantPast
        )
        calendar.recurrence.series[seriesID] = series
        self.calendar = calendar
        self.series = series
    }

    var naturalKey: OccurrenceKey { .init(seriesID: series.id, originalDate: monday) }

    func override(on date: CalendarDate, notes: String = "") -> OccurrenceOverride {
        .init(
            displayedSchedule: try! .init(startDate: date, endDate: date, startTime: nil, endTime: nil),
            title: series.title, kind: series.kind, categoryID: series.categoryID, notes: notes
        )
    }

    func workspace() -> WorkspaceState {
        .init(
            revision: 0,
            calendar: calendar,
            notes: [
                primary: .empty(id: primary, categoryID: categoryID, now: .distantPast),
                reference: .empty(id: reference, categoryID: categoryID, now: .distantPast)
            ],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [],
            materialDigests: [:]
        )
    }
}
