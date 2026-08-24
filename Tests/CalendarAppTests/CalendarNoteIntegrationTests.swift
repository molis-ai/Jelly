import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("CalendarNoteIntegrationTests")
@MainActor
struct CalendarNoteIntegrationTests {
    @Test func noteRelationLayoutShowsOneClusterAtATime() {
        #expect(CalendarNoteRelationLayout.make(hasPrimary: false, hasLegacyMarkdown: true) == .convertLegacy)
        #expect(CalendarNoteRelationLayout.make(hasPrimary: false, hasLegacyMarkdown: false) == .empty)
        #expect(CalendarNoteRelationLayout.make(hasPrimary: true, hasLegacyMarkdown: true) == .linked)
        #expect(CalendarNoteRelationLayout.make(hasPrimary: false, hasLegacyMarkdown: true).caption != nil)
        #expect(CalendarNoteRelationLayout.make(hasPrimary: false, hasLegacyMarkdown: false).caption == nil)
        #expect(
            CalendarNoteRelationLayout.convertLegacy.caption?.contains("旧版") != true
        )
    }

    @Test func createPrimaryNoteLinksItemAndKeepsNoteBodyIndependent() async throws {
        var calendar = makeEmptyState()
        let category = makeCategory(name: "采购")
        calendar.categories[category.id] = category
        let seededItem = try makeItem(
            categoryID: category.id,
            title: "采购本周食材"
        )
        calendar.items[seededItem.id] = seededItem
        let item = try #require(calendar.items.values.first)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await model.createPrimaryNote())
        let primary = try #require(model.primaryNote)
        #expect(store.state.notes[primary.id] != nil)
        #expect(primary.title == item.title)
        #expect(primary.categoryID == item.categoryID)
        #expect(store.calendarState.items[item.id]?.notes == item.notes)
    }

    @Test func addingExistingNoteToLegacyTextRequiresExplicitChoice() async throws {
        var calendar = makeEmptyState()
        var item = try makeItem(categoryID: calendar.uncategorizedID)
        item.notes = "旧随记正文"
        calendar.items[item.id] = item
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        var workspace = WorkspaceState.empty(calendar: calendar)
        workspace.notes[note.id] = note
        let store = WorkspaceStore(
            initialState: workspace,
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        // Restore note into store via command because InMemory may reseed from calendar-only.
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(model.hasLegacyMarkdown)
        #expect(try await model.chooseExistingPrimary(note.id) == false)
        #expect(model.presentedSheet == .legacyNotesResolution(note.id))
        #expect(store.state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == nil)
    }

    @Test func explicitLegacyPreviewCanMergeIntoTheChosenExistingNote() async throws {
        var calendar = makeEmptyState()
        var item = try makeItem(categoryID: calendar.uncategorizedID)
        item.notes = "# 旧随记\n\n- [x] 已完成"
        calendar.items[item.id] = item
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let completedAt = Date(timeIntervalSince1970: 1_700_001_000)
        let model = CalendarNoteIntegrationModel(
            target: .item(item.id),
            store: store,
            clock: { completedAt }
        )

        #expect(try await model.chooseExistingPrimary(note.id) == false)
        #expect(model.legacyMigrationPreview != nil)
        #expect(try await model.mergeLegacyIntoExistingPrimary(note.id))

        #expect(model.primaryNote?.id == note.id)
        #expect(store.calendarState.items[item.id]?.notes == "")
        #expect(store.state.notes[note.id]?.document.blocks.contains {
            $0.inlineContent.spans.map(\.text).joined() == "旧随记"
        } == true)
    }

    @Test func explicitLegacyPreviewCanCreateANewPrimaryNote() async throws {
        var calendar = makeEmptyState()
        var item = try makeItem(categoryID: calendar.uncategorizedID)
        item.notes = "需要安全迁移的正文"
        calendar.items[item.id] = item
        let existing = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: existing)))
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)

        #expect(try await model.chooseExistingPrimary(existing.id) == false)
        #expect(try await model.createPrimaryNoteFromLegacyPreview())

        let primary = try #require(model.primaryNote)
        #expect(primary.id != existing.id)
        #expect(primary.document.blocks.first?.inlineContent.spans.map(\.text).joined() == "需要安全迁移的正文")
        #expect(store.calendarState.items[item.id]?.notes == "")
    }

    @Test func staleLegacySourceKeepsTheSheetOpenWithARefreshedPreview() async throws {
        var calendar = makeEmptyState()
        var item = try makeItem(categoryID: calendar.uncategorizedID)
        item.notes = "第一次预览"
        calendar.items[item.id] = item
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await model.chooseExistingPrimary(note.id) == false)
        let firstChecksum = try #require(model.legacyMigrationPreview?.sourceChecksum)

        var changed = try #require(store.calendarState.items[item.id])
        changed.notes = "源内容已变化"
        _ = try await store.sendWorkspace(.calendar(.updateItem(changed)))

        #expect(try await model.mergeLegacyIntoExistingPrimary(note.id) == false)
        #expect(model.presentedSheet == .legacyNotesResolution(note.id))
        #expect(model.legacyMigrationPreview?.sourceChecksum != firstChecksum)
        #expect(store.state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == nil)
    }

    @Test func attachReferenceAndDetachPreserveBothObjects() async throws {
        let calendar = try makeStateWithOneItem()
        let item = try #require(calendar.items.values.first)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let noteA = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        let noteB = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        _ = try await store.sendWorkspace(.createNote(.init(note: noteA)))
        _ = try await store.sendWorkspace(.createNote(.init(note: noteB)))
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await model.chooseExistingPrimary(noteA.id))
        #expect(try await model.attachReference(noteB.id))
        #expect(model.referenceNotes.map(\.id).contains(noteB.id))
        #expect(try await model.detach(noteB.id))
        #expect(store.state.notes[noteB.id] != nil)
        #expect(store.calendarState.items[item.id] != nil)
    }

    @Test func scheduleNoteOnCalendarCreatesNonRecurringPrimaryLink() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let day = CalendarDate(year: 2026, month: 8, day: 12)!
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "来自笔记",
            categoryID: calendar.uncategorizedID,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await model.scheduleNoteOnCalendar(noteID: note.id, item: item))
        #expect(store.calendarState.items[item.id] != nil)
        #expect(store.state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == note.id)
    }

    @Test func noteScheduleDefaultsToTheUsersCurrentLocalDay() {
        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let now = Date(timeIntervalSince1970: 1_754_860_200)
        #expect(NoteScheduleDefaults.day(now: now, timeZone: timeZone)
            == CalendarDate.localDay(containing: now, in: timeZone))
    }

    @Test func detachingAPrimaryThatOwnsATaskLinkRequiresAndAcceptsExplicitUnlink() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [try .task(id: blockID, text: "关联待办")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let day = CalendarDate(year: 2026, month: 8, day: 18)!
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "关联待办", categoryID: calendar.uncategorizedID,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(
            .scheduleTaskBlock(.init(noteID: note.id, blockID: blockID, item: item))
        )
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)

        #expect(model.requiresTaskUnlinkBeforeDetaching(note.id))
        #expect(try await model.detach(
            note.id,
            linkedTaskDisposition: .unlinkPreservingCompletion
        ))
        #expect(store.state.taskBlockLinks.isEmpty)
        #expect(store.state.notes[note.id] != nil)
        #expect(store.calendarState.items[item.id] != nil)
    }
}
