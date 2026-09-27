import CalendarDomain
import Foundation
import WorkspaceDomain

extension MobileWorkspaceSmoke {
    @MainActor static func itemEditingJourney() async throws {
        try await completionJourney()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-Mobile-Editing-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try MobileWorkspace(rootURL: root)
        await app.load()
        let day = CalendarDate(year: 2026, month: 9, day: 21)!
        let blockID = BlockID()
        var note = Note.empty(categoryID: app.state.calendar.uncategorizedID, now: testNow)
        note.document = BlockDocument(blocks: [try DocumentBlock.task(id: blockID, text: "原始标题")])
        let noteCreated = await app.send(.createNote(.init(note: note)))
        try expect(noteCreated, "editing fixture note must save")
        let schedule = try CalendarSchedule(startDate: day, endDate: day,
            startTime: MinuteOfDay(hour: 9, minute: 0), endTime: MinuteOfDay(hour: 10, minute: 0))
        let item = try CalendarItem(id: UUID(), kind: .task, title: "原始标题", categoryID: note.categoryID,
            schedule: schedule, completedAt: nil, createdAt: testNow, updatedAt: testNow)
        let scheduled = await app.send(.scheduleTaskBlock(.init(noteID: note.id, blockID: blockID, item: item)))
        try expect(scheduled, "editing fixture must schedule task block")
        let opened = try MobileItemEditorRequest.existing(.item(item), scope: .onlyThis, state: app.state)
        var edited = opened.draft; edited.title = "只修改标题"
        let completed = await app.send(.setTaskCompletion(.taskBlock(noteID: note.id, blockID: blockID), value: .complete(ifTransitioningAt: testNow)))
        try expect(completed, "linked completion must save while sheet stays open")
        let saved = await app.sendCalendar(try MobileItemEditing.command(request: opened, edited: edited, state: app.state, now: testNow))
        try expect(saved && app.state.calendar.items[item.id]?.title == edited.title && app.state.calendar.items[item.id]?.completedAt == testNow && app.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == testNow,
            "title save must preserve latest completion on item and linked block")
        let undoTitle = await app.undo()
        try expect(undoTitle && app.state.calendar.items[item.id]?.title == item.title && app.state.calendar.items[item.id]?.completedAt == testNow,
            "undo title must leave earlier linked completion intact")
        let redoTitle = await app.redo()
        try expect(redoTitle, "rebased title redo must succeed")

        var legacy = try CalendarItem(id: UUID(), kind: .task, title: "旧随记", categoryID: note.categoryID,
            schedule: schedule, completedAt: nil, createdAt: testNow, updatedAt: testNow)
        legacy.notes = "随记原文不能恢复到已有主笔记的事项"
        legacy.untimedRank = 42
        let createdLegacy = await app.sendCalendar(.createItem(legacy))
        try expect(createdLegacy, "legacy fixture must save")
        let legacyOpened = try MobileItemEditorRequest.existing(.item(legacy), scope: .onlyThis, state: app.state)
        let relation = CalendarNoteIntegrationModel(target: .item(legacy.id), store: app.store, clock: { testNow })
        try relation.previewLegacyForNewPrimary()
        let migrated = try await relation.createPrimaryNoteFromLegacyPreview()
        guard let primary = relation.primaryNote else { throw Failure(message: "legacy primary missing") }
        try expect(migrated, "legacy migration must save")
        var legacyEdited = legacyOpened.draft; legacyEdited.title = "迁移后改标题"
        let savedAfterMigration = await app.sendCalendar(try MobileItemEditing.command(request: legacyOpened, edited: legacyEdited, state: app.state, now: testNow))
        try expect(savedAfterMigration && app.state.calendar.items[legacy.id]?.untimedRank == 42 && app.state.calendar.items[legacy.id]?.notes == "" && app.state.notes[primary.id]?.document == primary.document,
            "saving stale sheet must preserve migration and leave legacy text empty")
        var unsavedNotes = legacyOpened.draft; unsavedNotes.notes += "本地未保存"
        let beforeConflict = app.state
        do {
            _ = try MobileItemEditing.command(request: legacyOpened, edited: unsavedNotes, state: app.state)
            throw Failure(message: "unsaved notes must require explicit resolution")
        } catch MobileItemEditingError.notesMoved { }
        try expect(app.state == beforeConflict && unsavedNotes.notes.hasSuffix("本地未保存"), "notes conflict must preserve input and state")

        var conflicting = legacyOpened.draft; conflicting.title = "本地另一标题"
        do {
            _ = try MobileItemEditing.command(request: legacyOpened, edited: conflicting, state: app.state)
            throw Failure(message: "simultaneous title edits must conflict")
        } catch MobileItemEditingError.conflict { }

        let series = try WeeklySeries(id: UUID(), kind: .task, title: "重复任务", categoryID: note.categoryID,
            ruleStartDate: day, recurrenceEndDate: day.addingDays(21), weekdays: [day.weekday], durationDays: 1,
            startTime: MinuteOfDay(hour: 9, minute: 0), endTime: MinuteOfDay(hour: 10, minute: 0), createdAt: testNow, updatedAt: testNow)
        let createdSeries = await app.sendCalendar(.createSeries(series))
        try expect(createdSeries, "recurring fixture must save")
        let firstKey = OccurrenceKey(seriesID: series.id, originalDate: day)
        let first = try MobileItemEditing.current(mode: .editOccurrence(series: series, key: firstKey, scope: .onlyThis), state: app.state)
        let completedOccurrence = await app.send(try MobileItemEditing.completionCommand(mode: first.mode, state: app.state, now: testNow))
        try expect(completedOccurrence, "occurrence must complete while sheet open")
        var firstEdited = first.draft; firstEdited.title = "仅修改本次"
        let savedOccurrence = await app.sendCalendar(try MobileItemEditing.command(request: first, edited: firstEdited, state: app.state, now: testNow))
        try expect(savedOccurrence && app.state.calendar.recurrence.completions[firstKey]?.completedAt == testNow && app.state.calendar.recurrence.series[series.id]?.title == series.title,
            "occurrence edit must retain completion and not rewrite entire series")
        let nextKey = OccurrenceKey(seriesID: series.id, originalDate: day.addingDays(7))
        let future = try MobileItemEditing.current(mode: .editOccurrence(series: series, key: nextKey, scope: .thisAndFuture), state: app.state)
        let laterSchedule = try CalendarSchedule(startDate: nextKey.originalDate, endDate: nextKey.originalDate,
            startTime: MinuteOfDay(hour: 11, minute: 0), endTime: MinuteOfDay(hour: 12, minute: 0))
        let splitID = UUID()
        let futureSaved = await app.sendCalendar(try MobileItemEditing.command(request: future,
            edited: MobileItemEditing.applying(laterSchedule, to: future.draft), state: app.state, now: testNow, newSeriesID: splitID))
        try expect(futureSaved && app.state.calendar.recurrence.series[splitID]?.startTime == laterSchedule.startTime && app.state.calendar.recurrence.series[series.id]?.startTime == series.startTime && app.state.calendar.recurrence.completions[firstKey]?.completedAt == testNow,
            "future reschedule must use domain split semantics and preserve history")
        let restarted = try MobileWorkspace(rootURL: root)
        await restarted.load()
        try expect(restarted.isReady, "saved store must be ready after restart")
        try expectPersistedEditingState(restarted.state, app.state)
        try timeGridGeometryChecks(item: item, day: day)
        print("PASS: mobile editor latest completion, legacy migration, unsaved-note conflict, same-field conflict, recurrence scope/split, undo and restart; time-grid geometry and overlap lanes")
    }

    @MainActor static func completionJourney() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-Mobile-Completion-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try MobileWorkspace(rootURL: root)
        await app.load()
        let day = CalendarDate(year: 2026, month: 9, day: 21)!
        let schedule = try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil)
        let ordinary = try CalendarItem(id: UUID(), kind: .task, title: "普通未关联事项", categoryID: app.state.calendar.uncategorizedID,
            schedule: schedule, completedAt: nil, createdAt: testNow, updatedAt: testNow)
        let created = await app.sendCalendar(.createItem(ordinary))
        try expect(created && app.state.taskBlockLinks.isEmpty, "ordinary completion fixture must have no task-block link")
        let opened = try MobileItemEditorRequest.existing(.item(ordinary), scope: .onlyThis, state: app.state)
        var unsavedDraft = opened.draft; unsavedDraft.title = "仍在编辑的标题"
        let done = await app.send(try MobileItemEditing.completionCommand(for: .item(ordinary.id), state: app.state, now: testNow))
        try expect(done && app.state.calendar.items[ordinary.id]?.completedAt == testNow && app.state.calendar.items[ordinary.id]?.title == ordinary.title && unsavedDraft.title == "仍在编辑的标题",
            "ordinary completion must save immediately without submitting or clearing the editor draft")
        // Reuse the mode captured before completion. The helper must consult the
        // latest state, otherwise this incorrectly completes a second time.
        let reopened = await app.send(try MobileItemEditing.completionCommand(mode: opened.mode, state: app.state, now: testNow.addingTimeInterval(60)))
        try expect(reopened && app.state.calendar.items[ordinary.id]?.completedAt == nil, "ordinary item must reopen from stale editor mode using latest state")
        let undone = await app.undo()
        try expect(undone && app.state.calendar.items[ordinary.id]?.completedAt == testNow, "undo reopen must restore ordinary completion timestamp")
        let reread = try MobileWorkspace(rootURL: root); await reread.load()
        try expect(reread.isReady && reread.state.calendar.items[ordinary.id]?.completedAt == testNow && reread.state.taskBlockLinks.isEmpty,
            "ordinary completion undo must survive restart without inventing a task link")
        let savedDraft = await app.sendCalendar(try MobileItemEditing.command(request: opened, edited: unsavedDraft, state: app.state, now: testNow))
        try expect(savedDraft && app.state.calendar.items[ordinary.id]?.title == unsavedDraft.title && app.state.calendar.items[ordinary.id]?.completedAt == testNow,
            "saving other fields after completion must merge and preserve completion")

        let blockID = BlockID()
        var note = Note.empty(categoryID: app.state.calendar.uncategorizedID, now: testNow)
        note.document = BlockDocument(blocks: [try DocumentBlock.task(id: blockID, text: "联动完成入口")])
        let noteCreated = await app.send(.createNote(.init(note: note)))
        try expect(noteCreated, "linked completion fixture note must save")
        let linked = try CalendarItem(id: UUID(), kind: .task, title: "联动完成入口", categoryID: note.categoryID,
            schedule: schedule, completedAt: nil, createdAt: testNow, updatedAt: testNow)
        let scheduled = await app.send(.scheduleTaskBlock(.init(noteID: note.id, blockID: blockID, item: linked)))
        try expect(scheduled, "linked completion fixture must schedule")
        let linkedOpened = try MobileItemEditorRequest.existing(.item(linked), scope: .onlyThis, state: app.state)
        let linkedDone = await app.send(try MobileItemEditing.completionCommand(for: .item(linked.id), state: app.state, now: testNow))
        try expect(linkedDone && app.state.calendar.items[linked.id]?.completedAt == testNow && app.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == testNow,
            "the same calendar helper must atomically complete the linked item and task block")
        let linkedReopened = await app.send(try MobileItemEditing.completionCommand(mode: linkedOpened.mode, state: app.state, now: testNow.addingTimeInterval(60)))
        try expect(linkedReopened && app.state.calendar.items[linked.id]?.completedAt == nil && app.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == nil,
            "the same calendar helper must atomically reopen both linked sides")
        let linkedUndo = await app.undo()
        try expect(linkedUndo && app.state.calendar.items[linked.id]?.completedAt == testNow && app.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == testNow,
            "undo linked reopen must restore both completion timestamps")
        let final = try MobileWorkspace(rootURL: root); await final.load()
        try expect(final.isReady && final.state.calendar.items[ordinary.id]?.title == unsavedDraft.title && final.state.calendar.items[ordinary.id]?.completedAt == testNow && final.state.calendar.items[linked.id]?.completedAt == testNow && final.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == testNow && final.state.taskBlockLinks.contains(.init(noteID: note.id, blockID: blockID, calendarItemID: linked.id)),
            "ordinary draft merge and linked completion undo must survive a fresh workspace")
        print("PASS: production completion helper for ordinary and linked items, immediate save with retained draft, reopen from latest state, atomic undo and restart")
    }

    @MainActor static func expectPersistedEditingState(_ disk: WorkspaceState, _ memory: WorkspaceState) throws {
        // JSON milliseconds / Date's binary Double round-trip may differ by
        // 0.12 microseconds. Preserve exact equality for every business field,
        // allowing at most one microsecond only on storage timestamps.
        var normalized = disk
        func dates<T>(_ actual: T, _ expected: T, _ created: WritableKeyPath<T, Date>, _ updated: WritableKeyPath<T, Date>) throws -> T {
            var value = actual
            for key in [created, updated] {
                try expect(abs(value[keyPath: key].timeIntervalSince(expected[keyPath: key])) <= 0.000_001, "persisted timestamps must retain microsecond precision")
                value[keyPath: key] = expected[keyPath: key]
            }
            return value
        }
        for (id, expected) in memory.calendar.items {
            if let actual = disk.calendar.items[id] { normalized.calendar.items[id] = try dates(actual, expected, \.createdAt, \.updatedAt) }
        }
        for (id, expected) in memory.calendar.categories {
            if let actual = disk.calendar.categories[id] { normalized.calendar.categories[id] = try dates(actual, expected, \.createdAt, \.updatedAt) }
        }
        for (id, expected) in memory.calendar.recurrence.series {
            if let actual = disk.calendar.recurrence.series[id] { normalized.calendar.recurrence.series[id] = try dates(actual, expected, \.createdAt, \.updatedAt) }
        }
        for (id, expected) in memory.notes {
            if let actual = disk.notes[id] { normalized.notes[id] = try dates(actual, expected, \.createdAt, \.updatedAt) }
        }
        try expect(normalized == memory, "all rebased content, completion, identity, ranks, revision, recurrence and relationships must survive reload")
    }

    @MainActor static func timeGridGeometryChecks(item: CalendarItem, day: CalendarDate) throws {
        let crossMidnight = try CalendarSchedule(startDate: day, endDate: day.addingDays(1),
            startTime: MinuteOfDay(hour: 23, minute: 0), endTime: MinuteOfDay(hour: 1, minute: 0))
        let moved = try MobileTimeGridGeometry.reschedule(crossMidnight, dayDelta: 0, minuteDelta: 90, resizeEnd: false)
        try expect(moved.startDate == day.addingDays(1) && moved.startTime?.value == 30 && moved.endTime?.value == 150,
            "moving across midnight must retain the full two-hour duration")
        let backwards = try MobileTimeGridGeometry.reschedule(item.schedule, dayDelta: -1, minuteDelta: -600, resizeEnd: false)
        try expect(backwards.startDate == day.addingDays(-2) && backwards.startTime?.value == 1_380 && backwards.endDate == day.addingDays(-1) && backwards.endTime?.value == 0,
            "negative civil minute offsets must normalize to the correct previous dates")
        let shortened = try MobileTimeGridGeometry.reschedule(item.schedule, dayDelta: 0, minuteDelta: -180, resizeEnd: true)
        try expect(shortened.endTime?.value == 555 && shortened.startTime == item.schedule.startTime,
            "resize cannot invert the event or move its start and has a fifteen-minute minimum")
        let late = try MobileTimeGridGeometry.create(on: day, minute: 1_439)
        try expect(late.startTime?.value == 1_425 && late.endDate == day.addingDays(1) && late.endTime?.value == 0,
            "last slot must snap at 23:45 and end at midnight")
        let selectedUp = try MobileTimeGridGeometry.selection(on: day, from: MobileTimeGridGeometry.y(630), to: MobileTimeGridGeometry.y(540))
        try expect(selectedUp.startTime?.value == 540 && selectedUp.endTime?.value == 630,
            "upward blank drag must create the actual reversed ninety-minute interval")
        let selectedToMidnight = try MobileTimeGridGeometry.selection(on: day, from: MobileTimeGridGeometry.y(1_350), to: MobileTimeGridGeometry.y(1_440))
        try expect(selectedToMidnight.startTime?.value == 1_350 && selectedToMidnight.endDate == day.addingDays(1) && selectedToMidnight.endTime?.value == 0,
            "blank drag to 24:00 must end at the following civil date")
        let block = { (id: String, start: Int, end: Int) in WeekTimedBlock(id: id, entry: .item(item), dayIndex: 0, startMinute: start, endMinute: end) }
        let layout = MobileTimedLayout.placements([block("a", 540, 600), block("b", 570, 630), block("c", 630, 690)])
        try expect(layout.first { $0.id == "a" }?.laneCount == 2 && layout.first { $0.id == "b" }?.lane == 1 && layout.first { $0.id == "c" }?.laneCount == 1,
            "overlap must remain selectable in separate lanes; adjacent events reclaim full width")
    }
}
