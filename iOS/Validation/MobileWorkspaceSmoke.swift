import CalendarDomain
import CalendarPersistence
import Foundation
import WorkspaceDomain

@main
struct MobileWorkspaceSmoke {
    struct Failure: Error { let message: String }
    static let testNow = Date(timeIntervalSince1970: 1_789_000_000)
    @MainActor static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    @MainActor static func firstNoteMigrationJourney() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-Mobile-Legacy-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try MobileWorkspace(rootURL: root)
        await app.load()
        let day = CalendarDate(year: 2026, month: 9, day: 27)!
        var item = try CalendarItem(id: UUID(), kind: .task, title: "旧格式随记", categoryID: app.state.calendar.uncategorizedID,
            schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil), completedAt: nil,
            createdAt: testNow, updatedAt: testNow)
        item.notes = "# 保留的原文\n\n- [x] 已确认的行动\n\n中文段落"
        let created = await app.sendCalendar(.createItem(item))
        try expect(created && app.state.notes.isEmpty, "legacy migration must begin without existing notes")
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: app.store, clock: { testNow })
        let before = app.state
        try model.previewLegacyForNewPrimary()
        try expect(model.legacyMigrationPreview != nil && app.state == before, "new-primary preview must not mutate or create a placeholder note")
        let migrated = try await model.createPrimaryNoteFromLegacyPreview()
        guard let primary = model.primaryNote else { throw Failure(message: "migration did not create primary note") }
        try expect(migrated && app.state.notes.count == 1 && app.state.calendar.items[item.id]?.notes == "", "confirmed migration must atomically clear legacy notes and attach the first note")
        try expect(primary.document.blocks.contains { $0.inlineContent.spans.map(\.text).joined() == "中文段落" }, "migration must retain text")
        try expect(primary.document.blocks.contains { $0.kind == .task && $0.taskState?.completedAt == testNow }, "migration must retain checked-task semantics")
        let restarted = try MobileWorkspace(rootURL: root)
        await restarted.load()
        try expect(restarted.state.notes[primary.id] == primary && restarted.state.calendar.items[item.id]?.notes == "", "migration must survive a fresh instance")
        let undone = await app.undo()
        try expect(undone && app.state.notes.isEmpty && app.state.calendar.items[item.id]?.notes == item.notes, "one undo must restore legacy text and remove the new note")
    }
    @MainActor static func linkedTaskJourney() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-Mobile-Linked-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try MobileWorkspace(rootURL: root)
        await app.load()
        let category = CalendarCategory(id: UUID(), name: "移动端验证分类", colorHex: "#4F7EF7", sortIndex: 1, createdAt: testNow, updatedAt: testNow)
        let categoryCreated = await app.send(.createCategory(category))
        try expect(categoryCreated && app.state.calendar.categories[category.id] == category, "category must persist")
        let blockID = BlockID()
        var note = Note.empty(categoryID: category.id, now: testNow)
        note.title = "带行动的笔记"
        note.document = BlockDocument(blocks: [try DocumentBlock.task(id: blockID, text: "完成联动验证", completionDescription: "重启后双方完成时间一致")])
        let noteCreated = await app.send(.createNote(.init(note: note)), label: "创建笔记")
        try expect(noteCreated && app.state.notes[note.id]?.document == note.document, "task block note must persist")
        let day = CalendarDate(year: 2026, month: 9, day: 26)!
        let item = try CalendarItem(id: UUID(), kind: .task, title: "完成联动验证", categoryID: category.id, schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil), completedAt: nil, createdAt: testNow, updatedAt: testNow)
        let scheduled = await app.send(.scheduleTaskBlock(.init(noteID: note.id, blockID: blockID, item: item)), label: "安排任务块")
        let link = TaskBlockCalendarLink(noteID: note.id, blockID: blockID, calendarItemID: item.id)
        try expect(scheduled && app.state.taskBlockLinks.contains(link) && app.state.calendar.items[item.id] != nil, "scheduling must atomically add task and link")
        try expect(app.state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == note.id, "scheduled task must link primary note")
        let completion = Date(timeIntervalSince1970: 1_789_000_000)
        let completed = await app.send(.setTaskCompletion(.calendarItem(item.id), value: .complete(ifTransitioningAt: completion)), label: "完成事项")
        try expect(completed && app.state.calendar.items[item.id]?.completedAt == completion && app.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == completion, "calendar completion must update task block")
        let undone = await app.undo()
        try expect(undone && app.state.calendar.items[item.id]?.completedAt == nil && app.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == nil && app.state.taskBlockLinks.contains(link), "undo completion must restore both sides and preserve link")
        let restarted = try MobileWorkspace(rootURL: root)
        await restarted.load()
        try expect(restarted.isReady && restarted.state.taskBlockLinks.contains(link) && restarted.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == nil, "linked undo must survive reload")
        let completedFromBlock = await restarted.send(.setTaskCompletion(.taskBlock(noteID: note.id, blockID: blockID), value: .complete(ifTransitioningAt: completion)))
        try expect(completedFromBlock && restarted.state.calendar.items[item.id]?.completedAt == completion, "block completion must update calendar")
        guard let backup = await restarted.prepareBackupExport() else { throw Failure(message: "linked backup export failed") }
        defer { try? FileManager.default.removeItem(at: backup) }
        guard let preview = await restarted.inspectBackup(at: backup) else { throw Failure(message: "linked backup preview failed") }
        let reopened = await restarted.send(.setTaskCompletion(.taskBlock(noteID: note.id, blockID: blockID), value: .incomplete))
        try expect(reopened && restarted.state.calendar.items[item.id]?.completedAt == nil, "reopen must affect calendar")
        let restored = await restarted.restore(preview)
        try expect(restored, "linked backup restore failed")
        let verified = try MobileWorkspace(rootURL: root)
        await verified.load()
        try expect(verified.isReady && verified.state.calendar.categories[category.id] == category && verified.state.taskBlockLinks.contains(link) && verified.state.calendar.items[item.id]?.completedAt == completion && verified.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == completion, "backup restore must preserve category, task, note, link and both completion timestamps")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jelly-Mobile-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try MobileWorkspace(rootURL: root)
        await app.load()
        try expect(app.isReady, "empty store must load")
        try expect(app.state.calendar.items.isEmpty && app.state.notes.isEmpty && app.state.inspirations.isEmpty, "must not seed mock content")
        let day = CalendarDate(year: 2026, month: 9, day: 26)!
        let first = try CalendarItem(id: UUID(), kind: .task, title: "真实持久化路径", categoryID: app.state.calendar.uncategorizedID, schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil), completedAt: nil, createdAt: testNow, updatedAt: testNow)
        let created = await app.sendCalendar(.createItem(first), label: "新增事项")
        try expect(created && app.state.calendar.items[first.id] == first, "create must persist and publish")
        let disk = try WorkspaceDocumentCodec.decode(Data(contentsOf: root.appendingPathComponent("calendar-v1.json"))).state
        try expect(disk.calendar.items[first.id] == first, "disk must match created task")
        let blockedEditor = UUID()
        app.registerEditorBarrier(id: blockedEditor) { false }
        let blockedUndo = await app.undo()
        let blockedExport = await app.prepareBackupExport()
        try expect(!blockedUndo && blockedExport == nil && app.state.calendar.items[first.id] == first, "unprotected editor must block undo and backup export")
        app.unregisterEditorBarrier(id: blockedEditor)
        let cleanEditor = UUID()
        var editorFlushed = false
        app.registerEditorBarrier(id: cleanEditor) {
            editorFlushed = true
            app.unregisterEditorBarrier(id: cleanEditor)
            return true
        }
        let undone = await app.undo()
        try expect(undone && editorFlushed && app.state.calendar.items.isEmpty, "undo must flush editor snapshot and remove task")
        let redone = await app.redo()
        try expect(redone && app.state.calendar.items[first.id] == first, "redo must restore task")
        let restarted = try MobileWorkspace(rootURL: root)
        await restarted.load()
        try expect(restarted.state.calendar.items[first.id] == first, "restart must retain task")
        guard let backup = await restarted.prepareBackupExport() else { throw Failure(message: "backup export failed") }
        defer { try? FileManager.default.removeItem(at: backup) }
        let beforePreview = restarted.state
        guard let preview = await restarted.inspectBackup(at: backup) else { throw Failure(message: "backup inspection failed") }
        try expect(restarted.state == beforePreview, "preview must not mutate state")
        let second = try CalendarItem(id: UUID(), kind: .task, title: "备份之后", categoryID: restarted.state.calendar.uncategorizedID, schedule: first.schedule, completedAt: nil, createdAt: testNow, updatedAt: testNow)
        let addedSecond = await restarted.sendCalendar(.createItem(second))
        try expect(addedSecond, "second create failed")
        let restored = await restarted.restore(preview)
        try expect(restored && restarted.state.calendar.items.count == 1 && restarted.state.calendar.items[first.id] == first, "restore must replace with inspected snapshot")
        let rollbacks = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("restore-rollbacks"), includingPropertiesForKeys: nil)
        try expect(!rollbacks.isEmpty, "restore must preserve rollback")
        let reloaded = try MobileWorkspace(rootURL: root)
        await reloaded.load()
        try expect(reloaded.isReady && reloaded.state.calendar.items.count == 1, "restored state must survive restart")
        let stale = try MobileWorkspace(rootURL: root)
        await stale.load()
        let addedAfterRestore = await reloaded.sendCalendar(.createItem(second))
        try expect(addedAfterRestore, "post-restore create failed")
        let staleAttempt = await stale.sendCalendar(.deleteItem(first.id))
        try expect(!staleAttempt && stale.errorMessage != nil, "stale writer must not report success")
        let refreshed = await stale.reloadExternalSource()
        try expect(refreshed && stale.state.calendar.items[first.id] != nil && stale.state.calendar.items[second.id] != nil, "external reload must preserve actual committed data")
        let invalid = root.appendingPathComponent("invalid.json")
        try Data("invalid".utf8).write(to: invalid)
        let beforeInvalid = stale.state
        let invalidPreview = await stale.inspectBackup(at: invalid)
        try expect(invalidPreview == nil && stale.state == beforeInvalid, "invalid backup must preserve live state")
        try await linkedTaskJourney()
        try await firstNoteMigrationJourney()
        try await itemEditingJourney()
        try await MobileNoteSessionSmoke.run()
        print("PASS: empty data, verified create, undo/redo, restart, backup inspection, rollback restore, stale-writer rejection, external reload, invalid import, category, note task scheduling, bidirectional completion, linked undo, linked restart and restore")
    }
}
