import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("WorkspaceReducerTests")
struct WorkspaceReducerTests {
    @Test func createUpdateArchiveAndRestoreNoteAllocateExactRevisions() throws {
        var workspace = try Task4Fixture.workspace()
        let created = Task4Fixture.note(
            id: Task4Fixture.newNoteID,
            title: "新笔记",
            revision: 0,
            updatedAt: Task4Fixture.now
        )

        let create = try WorkspaceReducer.reduce(
            workspace,
            command: .createNote(.init(note: created)),
            now: Task4Fixture.later
        )
        workspace = try #require(create.change).state
        #expect(workspace.revision == 6)
        #expect(workspace.notes[created.id]?.revision == 1)

        let stored = try #require(workspace.notes[created.id])
        var submitted = stored
        submitted.title = "改名"
        let update = try WorkspaceReducer.reduce(
            workspace,
            command: .updateNote(try Task4Fixture.submission(base: stored, submitted: submitted)),
            now: Task4Fixture.latest
        )
        workspace = try #require(update.change).state
        #expect(workspace.revision == 7)
        #expect(workspace.notes[created.id]?.revision == 2)
        #expect(workspace.notes[created.id]?.updatedAt == Task4Fixture.latest)

        let archive = try WorkspaceReducer.reduce(
            workspace,
            command: .archiveNote(created.id, at: Task4Fixture.archiveAt),
            now: Task4Fixture.archiveAt
        )
        workspace = try #require(archive.change).state
        #expect(workspace.revision == 8)
        #expect(workspace.notes[created.id]?.revision == 3)
        #expect(workspace.notes[created.id]?.archivedAt == Task4Fixture.archiveAt)

        let restore = try WorkspaceReducer.reduce(
            workspace,
            command: .restoreNote(created.id, at: Task4Fixture.restoreAt),
            now: Task4Fixture.restoreAt
        )
        workspace = try #require(restore.change).state
        #expect(workspace.revision == 9)
        #expect(workspace.notes[created.id]?.revision == 4)
        #expect(workspace.notes[created.id]?.archivedAt == nil)
    }

    @Test func identicalAndCancelledCommandsReturnTypedNoChangeWithoutRevision() throws {
        let workspace = try Task4Fixture.workspace(itemLegacyNotes: "旧正文")
        let note = try #require(workspace.notes[Task4Fixture.noteID])
        let identical = try WorkspaceReducer.reduce(
            workspace,
            command: .updateNote(try Task4Fixture.submission(base: note, submitted: note)),
            now: Task4Fixture.later
        )
        #expect(identical == .noChange(.identical))

        let cancelled = try WorkspaceReducer.reduce(
            workspace,
            command: .attachPrimaryNote(.init(
                scope: .item(Task4Fixture.itemID),
                noteID: note.id,
                legacyResolution: .cancel,
                replacing: nil,
                linkedTaskDisposition: nil
            )),
            now: Task4Fixture.later
        )
        #expect(cancelled == .noChange(.cancelled))
        #expect(workspace.revision == 5)
        #expect(workspace.calendar.items[Task4Fixture.itemID]?.notes == "旧正文")
    }

    @Test func draftMergesDisjointFieldsAndConflictsOnSameField() throws {
        let baseWorkspace = try Task4Fixture.workspace()
        let base = try #require(baseWorkspace.notes[Task4Fixture.noteID])
        var currentWorkspace = baseWorkspace
        currentWorkspace.notes[base.id]?.title = "服务端标题"
        currentWorkspace.notes[base.id]?.revision = 4
        currentWorkspace.revision = 6
        var submitted = base
        submitted.categoryID = Task4Fixture.workCategoryID

        let merged = try WorkspaceReducer.reduce(
            currentWorkspace,
            command: .updateNote(try Task4Fixture.submission(base: base, submitted: submitted)),
            now: Task4Fixture.later
        )
        let mergedState = try #require(merged.change).state
        #expect(mergedState.notes[base.id]?.title == "服务端标题")
        #expect(mergedState.notes[base.id]?.categoryID == Task4Fixture.workCategoryID)
        #expect(mergedState.notes[base.id]?.revision == 5)
        #expect(mergedState.revision == 7)

        var conflictingSubmission = base
        conflictingSubmission.title = "草稿标题"
        let conflict = try WorkspaceReducer.reduce(
            currentWorkspace,
            command: .updateNote(try Task4Fixture.submission(base: base, submitted: conflictingSubmission)),
            now: Task4Fixture.later
        )
        guard case let .conflict(.noteDraft(payload)) = conflict else {
            Issue.record("应返回逐字段草稿冲突")
            return
        }
        #expect(payload.noteID == base.id)
        #expect(payload.currentRevision == 4)
        #expect(payload.conflictingFields == [.title])
        #expect(payload.base == base)
        #expect(payload.submitted == conflictingSubmission)
        #expect(payload.current == currentWorkspace.notes[base.id])
        #expect(currentWorkspace.revision == 6)
    }

    @Test func draftWhoseNoteWasRemovedReturnsAnHonestTypedMissingNoteConflict() throws {
        var workspace = try Task4Fixture.workspace()
        let removed = try #require(workspace.notes[Task4Fixture.noteID])
        workspace.notes.removeValue(forKey: Task4Fixture.noteID)
        let submission = try Task4Fixture.submission(base: removed, submitted: removed)

        let result = try WorkspaceReducer.reduce(
            workspace, command: .updateNote(submission), now: Task4Fixture.later
        )

        #expect(result == .conflict(.noteMissing(removed.id)))
        #expect(workspace.notes[removed.id] == nil)
    }

    @Test func forgedDraftFieldsAndBaseIdentityMismatchThrowAtomically() throws {
        let workspace = try Task4Fixture.workspace()
        let base = try #require(workspace.notes[Task4Fixture.noteID])
        var submitted = base
        submitted.title = "真的改了"
        let forged = try Task4Fixture.submission(
            base: base,
            submitted: submitted,
            modifiedFields: []
        )
        #expect(throws: WorkspaceReducerError.invalidDraftSubmission) {
            try WorkspaceReducer.reduce(workspace, command: .updateNote(forged), now: Task4Fixture.later)
        }

        let mismatched = NoteDraftSubmission(
            noteID: base.id,
            editSessionID: Task4Fixture.editSessionID,
            baseNoteRevision: base.revision + 1,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: 1,
            snapshot: submitted,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submitted),
            modifiedFields: [.title],
            linkedBlockDeletionDispositions: [:]
        )
        #expect(throws: WorkspaceReducerError.invalidDraftSubmission) {
            try WorkspaceReducer.reduce(workspace, command: .updateNote(mismatched), now: Task4Fixture.later)
        }
        #expect(workspace.revision == 5)
        #expect(workspace.notes[base.id] == base)
    }

    @Test func noteDraftBaseIdentityFieldsAreNonoptionalContractValues() throws {
        let workspace = try Task4Fixture.workspace()
        let base = try #require(workspace.notes[Task4Fixture.noteID])
        let submission = try Task4Fixture.submission(base: base, submitted: base)

        #expect(String(reflecting: type(of: submission.baseNoteRevision)) == "Swift.Int64")
        #expect(String(reflecting: type(of: submission.baseNoteSnapshotChecksum)) == "Swift.String")
    }

    @Test func malformedDraftBaseLinkTopologyThrowsTypedErrorWithoutTrap() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask()
        let base = try #require(workspace.notes[Task4Fixture.noteID])
        let link = try #require(workspace.taskBlockLinks.first)
        let duplicateBlockLink = TaskBlockCalendarLink(
            noteID: link.noteID,
            blockID: link.blockID,
            calendarItemID: Task4Fixture.otherItemID
        )
        var submitted = base
        submitted.document.blocks[0].inlineContent = .plain("修改任务")

        #expect(throws: WorkspaceReducerError.invalidDraftSubmission) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .updateNote(try Task4Fixture.submission(
                    base: base,
                    submitted: submitted,
                    baseLinks: [link, duplicateBlockLink]
                )),
                now: Task4Fixture.later
            )
        }
        #expect(workspace.revision == 5)
        #expect(workspace.taskBlockLinks == [link])
    }

    @Test func draftAffectedLinkContextConflictsButUnaffectedLinkMerges() throws {
        let baseWorkspace = try Task4Fixture.workspaceWithLinkedTask()
        let base = try #require(baseWorkspace.notes[Task4Fixture.noteID])
        let baseLink = try #require(baseWorkspace.taskBlockLinks.first)
        var submitted = base
        submitted.document.blocks[0].inlineContent = .plain("改过的任务")

        var deletedLinkWorkspace = baseWorkspace
        deletedLinkWorkspace.taskBlockLinks.removeAll()
        deletedLinkWorkspace.revision += 1
        let deleteConflict = try WorkspaceReducer.reduce(
            deletedLinkWorkspace,
            command: .updateNote(try Task4Fixture.submission(
                base: base,
                submitted: submitted,
                baseLinks: [baseLink]
            )),
            now: Task4Fixture.later
        )
        #expect(Task4Fixture.conflictingFields(deleteConflict) == [.document])

        var reboundWorkspace = baseWorkspace
        reboundWorkspace.taskBlockLinks = [TaskBlockCalendarLink(
            noteID: base.id,
            blockID: Task4Fixture.taskBlockID,
            calendarItemID: Task4Fixture.otherItemID
        )]
        reboundWorkspace.calendar.items[Task4Fixture.otherItemID] = try Task4Fixture.item(
            id: Task4Fixture.otherItemID,
            title: "任务"
        )
        reboundWorkspace.calendarNoteRelations.baselines[.item(Task4Fixture.otherItemID)] = .init(
            primaryNoteID: base.id,
            referenceNoteIDs: []
        )
        reboundWorkspace.revision += 1
        let rebindConflict = try WorkspaceReducer.reduce(
            reboundWorkspace,
            command: .updateNote(try Task4Fixture.submission(
                base: base,
                submitted: submitted,
                baseLinks: [baseLink]
            )),
            now: Task4Fixture.later
        )
        #expect(Task4Fixture.conflictingFields(rebindConflict) == [.document])

        var unaffected = baseWorkspace
        let extraNote = Task4Fixture.note(
            id: Task4Fixture.otherNoteID,
            title: "另一个任务",
            revision: 1,
            task: true
        )
        unaffected.notes[extraNote.id] = extraNote
        unaffected.calendar.items[Task4Fixture.otherItemID] = try Task4Fixture.item(
            id: Task4Fixture.otherItemID,
            title: "任务"
        )
        unaffected.calendarNoteRelations.baselines[.item(Task4Fixture.otherItemID)] = .init(
            primaryNoteID: extraNote.id,
            referenceNoteIDs: []
        )
        unaffected.taskBlockLinks.insert(.init(
            noteID: extraNote.id,
            blockID: Task4Fixture.otherTaskBlockID,
            calendarItemID: Task4Fixture.otherItemID
        ))
        unaffected.revision += 1
        let positive = try WorkspaceReducer.reduce(
            unaffected,
            command: .updateNote(try Task4Fixture.submission(
                base: base,
                submitted: submitted,
                baseLinks: [baseLink]
            )),
            now: Task4Fixture.later
        )
        #expect(positive.change?.state.notes[base.id]?.document.blocks[0].inlineContent == .plain("改过的任务"))
        #expect(positive.change?.state.taskBlockLinks.count == 2)
    }

    @Test func rawCalendarAllowInterceptRejectAndSeriesMigrationAreAtomic() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTaskAndSeriesRelation()
        let moved = try WorkspaceReducer.reduce(
            workspace,
            command: .calendar(.moveItem(Task4Fixture.itemID, to: Task4Fixture.day.addingDays(1))),
            now: Task4Fixture.later
        )
        #expect(moved.change?.state.revision == 6)
        #expect(moved.change?.state.calendar.items[Task4Fixture.itemID]?.schedule.startDate == Task4Fixture.day.addingDays(1))

        let deleted = try WorkspaceReducer.reduce(
            workspace,
            command: .calendar(.deleteItem(Task4Fixture.itemID)),
            now: Task4Fixture.later
        )
        let deletedState = try #require(deleted.change).state
        #expect(deletedState.calendar.items[Task4Fixture.itemID] == nil)
        #expect(deletedState.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)] == nil)
        #expect(deletedState.taskBlockLinks.isEmpty)
        #expect(deletedState.notes[Task4Fixture.noteID] != nil)

        #expect(throws: WorkspaceReducerError.rawCalendarCategoryCommandRejected) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .calendar(.createCategory(Task4Fixture.category(
                    id: Task4Fixture.extraCategoryID,
                    name: "越权"
                ))),
                now: Task4Fixture.later
            )
        }

        let boundary = OccurrenceKey(seriesID: Task4Fixture.seriesID, originalDate: Task4Fixture.day.addingDays(7))
        let split = try WorkspaceReducer.reduce(
            workspace,
            command: .calendar(.mutateSeries(
                boundary,
                scope: .thisAndFuture,
                edit: .patch(.init(title: "新系列")),
                newSeriesID: Task4Fixture.newSeriesID
            )),
            now: Task4Fixture.later
        )
        let splitChange = try #require(split.change)
        #expect(splitChange.seriesOutcome != nil)
        #expect(splitChange.state.calendar.recurrence.series[Task4Fixture.newSeriesID] != nil)
        #expect(splitChange.state.calendarNoteRelations.baselines[.series(Task4Fixture.newSeriesID)]?.primaryNoteID == Task4Fixture.noteID)
        #expect(splitChange.state.revision == 6)
    }

    @Test func rawCalendarBusinessNoOpAndLinkedCompletionSynchronizesAtomically() throws {
        let workspace = try Task4Fixture.workspace()
        let noOp = try WorkspaceReducer.reduce(
            workspace,
            command: .calendar(.moveItem(Task4Fixture.itemID, to: Task4Fixture.day)),
            now: Task4Fixture.later
        )
        #expect(noOp == .noChange(.identical))

        let linked = try Task4Fixture.workspaceWithLinkedTask()
        let result = try WorkspaceReducer.reduce(
            linked,
            command: .calendar(.setTaskCompleted(Task4Fixture.itemID, Task4Fixture.completedAt)),
            now: Task4Fixture.later
        )
        let state = try #require(result.change).state
        #expect(state.calendar.items[Task4Fixture.itemID]?.completedAt == Task4Fixture.completedAt)
        #expect(state.notes[Task4Fixture.noteID]?.document.blocks[0].taskState?.completedAt == Task4Fixture.completedAt)
        #expect(state.notes[Task4Fixture.noteID]?.revision == 4)
        #expect(state.revision == 6)
    }

    @Test func splitFailureIsTypedAndDoesNotLeakRelationMigration() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTaskAndSeriesRelation()
        let boundary = OccurrenceKey(
            seriesID: Task4Fixture.seriesID,
            originalDate: Task4Fixture.day.addingDays(7)
        )
        #expect(throws: WorkspaceReducerError.seriesMutationFailure(.duplicateSeriesID)) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .calendar(.mutateSeries(
                    boundary,
                    scope: .thisAndFuture,
                    edit: .patch(.init(title: "不会提交")),
                    newSeriesID: Task4Fixture.seriesID
                )),
                now: Task4Fixture.later
            )
        }
        #expect(workspace.calendar.recurrence.series.count == 1)
        #expect(workspace.calendarNoteRelations.baselines[.series(Task4Fixture.seriesID)]?.primaryNoteID == Task4Fixture.noteID)
        #expect(workspace.revision == 5)
    }

    @Test func compositeSchedulingAndRelationCommandsApplyOnce() throws {
        let workspace = try Task4Fixture.workspaceWithoutItem()
        let scheduled = try WorkspaceReducer.reduce(
            workspace,
            command: .scheduleNoteOnCalendar(.init(
                noteID: Task4Fixture.noteID,
                item: try Task4Fixture.item(id: Task4Fixture.itemID, title: "安排笔记")
            )),
            now: Task4Fixture.later
        )
        let scheduledState = try #require(scheduled.change).state
        #expect(scheduledState.calendar.items[Task4Fixture.itemID] != nil)
        #expect(scheduledState.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)] == .init(
            primaryNoteID: Task4Fixture.noteID,
            referenceNoteIDs: []
        ))
        #expect(scheduledState.revision == 6)

        let attachedReference = try WorkspaceReducer.reduce(
            try Task4Fixture.workspace(),
            command: .attachReferenceNote(.item(Task4Fixture.itemID), Task4Fixture.otherNoteID),
            now: Task4Fixture.later
        )
        #expect(attachedReference.change?.state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.referenceNoteIDs == [Task4Fixture.otherNoteID])
    }

    @Test func compositeFailuresNeverLeakCandidateOrRevision() throws {
        let workspace = try Task4Fixture.workspaceWithoutItem()
        var invalidNote = Task4Fixture.note(id: Task4Fixture.newNoteID, title: "非法", revision: 0)
        invalidNote.categoryID = Task4Fixture.missingCategoryID
        #expect(throws: WorkspaceReducerError.invalidNote) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .createPrimaryNoteForCalendar(.init(
                    scope: .series(Task4Fixture.seriesID),
                    note: invalidNote,
                    legacyImportAuthorization: nil
                )),
                now: Task4Fixture.later
            )
        }

        #expect(throws: WorkspaceReducerError.calendarFailure(.unknownCategory)) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .scheduleNoteOnCalendar(.init(
                    noteID: Task4Fixture.noteID,
                    item: try Task4Fixture.item(id: Task4Fixture.seriesID, title: "无分类", categoryID: Task4Fixture.missingCategoryID)
                )),
                now: Task4Fixture.later
            )
        }
        #expect(workspace.revision == 5)
        #expect(workspace.calendar.items.isEmpty)
        #expect(workspace.notes[Task4Fixture.newNoteID] == nil)
    }

    @Test func legacyPlannerReplaysExactIDsAndRejectsDiagnosticsOrStaleSource() throws {
        let workspace = try Task4Fixture.workspace(itemLegacyNotes: "# 标题\n\n- [x] 完成")
        let ids = [Task4Fixture.importBlockID, Task4Fixture.importTaskBlockID]
        let direct = try BlockMarkdownCodec.importMarkdown(
            "# 标题\n\n- [x] 完成",
            idSource: .fixed(ids),
            checkedTaskCompletedAt: Task4Fixture.completedAt
        )
        #expect(direct.document.blocks.count == ids.count)
        let preview: LegacyMarkdownMigrationPreview
        do {
            preview = try LegacyMarkdownMigrationPlanner.preview(
                scope: .item(Task4Fixture.itemID),
                in: workspace,
                injectedBlockIDs: ids,
                checkedTaskCompletedAt: Task4Fixture.completedAt
            )
        } catch {
            Issue.record("首个 legacy preview 不应失败：\(error)")
            return
        }
        #expect(preview.document.blocks.map(\.id) == ids)
        let authorization = LegacyMarkdownImportAuthorization(
            expectedSourceChecksum: preview.sourceChecksum,
            injectedBlockIDs: ids,
            checkedTaskCompletedAt: Task4Fixture.completedAt,
            diagnostics: .rejectIfPresent
        )
        let merged: WorkspaceReductionResult
        do {
            merged = try WorkspaceReducer.reduce(
                workspace,
                command: .attachPrimaryNote(.init(
                    scope: .item(Task4Fixture.itemID),
                    noteID: Task4Fixture.noteID,
                    legacyResolution: .previewAndMerge(
                        expectedNoteRevision: 3,
                        importAuthorization: authorization
                    ),
                    replacing: nil,
                    linkedTaskDisposition: nil
                )),
                now: Task4Fixture.later
            )
        } catch {
            Issue.record("首个 legacy replay 不应失败：\(error)")
            return
        }
        let mergedState = try #require(merged.change).state
        #expect(mergedState.notes[Task4Fixture.noteID].map { Array($0.document.blocks.dropFirst()) } == preview.document.blocks)
        #expect(mergedState.calendar.items[Task4Fixture.itemID]?.notes == "")
        #expect(mergedState.notes[Task4Fixture.noteID]?.revision == 4)

        var stale = workspace
        stale.calendar.items[Task4Fixture.itemID]?.notes = "源已变化"
        let staleResult = try WorkspaceReducer.reduce(
            stale,
            command: .attachPrimaryNote(.init(
                scope: .item(Task4Fixture.itemID),
                noteID: Task4Fixture.noteID,
                legacyResolution: .previewAndMerge(expectedNoteRevision: 3, importAuthorization: authorization),
                replacing: nil,
                linkedTaskDisposition: nil
            )),
            now: Task4Fixture.later
        )
        #expect(staleResult == .noChange(.staleLegacyPreview))
        #expect(stale.calendar.items[Task4Fixture.itemID]?.notes == "源已变化")

        let diagnosticWorkspace = try Task4Fixture.workspace(itemLegacyNotes: "|a|b|\n|-|-|\n|1|2|")
        let diagnosticPreview: LegacyMarkdownMigrationPreview
        do {
            diagnosticPreview = try LegacyMarkdownMigrationPlanner.preview(
                scope: .item(Task4Fixture.itemID),
                in: diagnosticWorkspace,
                injectedBlockIDs: [Task4Fixture.importBlockID],
                checkedTaskCompletedAt: Task4Fixture.completedAt
            )
        } catch {
            Issue.record("diagnostic preview 不应失败：\(error)")
            return
        }
        #expect(diagnosticPreview.diagnostics.isEmpty == false)
        #expect(throws: WorkspaceReducerError.legacyDiagnosticsRequireConfirmation) {
            try WorkspaceReducer.reduce(
                diagnosticWorkspace,
                command: .attachPrimaryNote(.init(
                    scope: .item(Task4Fixture.itemID),
                    noteID: Task4Fixture.noteID,
                    legacyResolution: .previewAndMerge(
                        expectedNoteRevision: 3,
                        importAuthorization: .init(
                            expectedSourceChecksum: diagnosticPreview.sourceChecksum,
                            injectedBlockIDs: [Task4Fixture.importBlockID],
                            checkedTaskCompletedAt: Task4Fixture.completedAt,
                            diagnostics: .rejectIfPresent
                        )
                    ),
                    replacing: nil,
                    linkedTaskDisposition: nil
                )),
                now: Task4Fixture.later
            )
        }
        let accepted: WorkspaceReductionResult
        do {
            accepted = try WorkspaceReducer.reduce(
                diagnosticWorkspace,
                command: .attachPrimaryNote(.init(
                    scope: .item(Task4Fixture.itemID),
                    noteID: Task4Fixture.noteID,
                    legacyResolution: .previewAndMerge(
                        expectedNoteRevision: 3,
                        importAuthorization: .init(
                            expectedSourceChecksum: diagnosticPreview.sourceChecksum,
                            injectedBlockIDs: [Task4Fixture.importBlockID],
                            checkedTaskCompletedAt: Task4Fixture.completedAt,
                            diagnostics: .accept(expectedDiagnosticsChecksum: diagnosticPreview.diagnosticsChecksum)
                        )
                    ),
                    replacing: nil,
                    linkedTaskDisposition: nil
                )),
                now: Task4Fixture.later
            )
        } catch {
            Issue.record("已授权 diagnostics 的 replay 不应失败：\(error)")
            return
        }
        #expect(accepted.change != nil)
    }

    @Test func legacyFixedIDsMustBeExactAndCollisionFree() throws {
        let workspace = try Task4Fixture.workspace(itemLegacyNotes: "一段")
        let preview = try LegacyMarkdownMigrationPlanner.preview(
            scope: .item(Task4Fixture.itemID),
            in: workspace,
            injectedBlockIDs: [Task4Fixture.importBlockID],
            checkedTaskCompletedAt: Task4Fixture.completedAt
        )
        let extraIDs = [Task4Fixture.importBlockID, Task4Fixture.importTaskBlockID]
        let extra = LegacyMarkdownImportAuthorization(
            expectedSourceChecksum: preview.sourceChecksum,
            injectedBlockIDs: extraIDs,
            checkedTaskCompletedAt: Task4Fixture.completedAt,
            diagnostics: .rejectIfPresent
        )
        #expect(throws: WorkspaceReducerError.invalidLegacyAuthorization) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .attachPrimaryNote(.init(
                    scope: .item(Task4Fixture.itemID), noteID: Task4Fixture.noteID,
                    legacyResolution: .previewAndMerge(expectedNoteRevision: 3, importAuthorization: extra),
                    replacing: nil, linkedTaskDisposition: nil
                )),
                now: Task4Fixture.later
            )
        }

        let collision = LegacyMarkdownImportAuthorization(
            expectedSourceChecksum: preview.sourceChecksum,
            injectedBlockIDs: [Task4Fixture.paragraphBlockID],
            checkedTaskCompletedAt: Task4Fixture.completedAt,
            diagnostics: .rejectIfPresent
        )
        #expect(throws: WorkspaceReducerError.invalidLegacyAuthorization) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .attachPrimaryNote(.init(
                    scope: .item(Task4Fixture.itemID), noteID: Task4Fixture.noteID,
                    legacyResolution: .previewAndMerge(expectedNoteRevision: 3, importAuthorization: collision),
                    replacing: nil, linkedTaskDisposition: nil
                )),
                now: Task4Fixture.later
            )
        }
    }

    @Test func legacyCreateCompositeUsesTheExactAuthorizedPreviewDocument() throws {
        let workspace = try Task4Fixture.workspace(itemLegacyNotes: "# 新笔记")
        let preview = try LegacyMarkdownMigrationPlanner.preview(
            scope: .item(Task4Fixture.itemID),
            in: workspace,
            injectedBlockIDs: [Task4Fixture.importBlockID],
            checkedTaskCompletedAt: Task4Fixture.completedAt
        )
        var proposed = Task4Fixture.note(
            id: Task4Fixture.newNoteID,
            title: "迁移笔记",
            revision: 0
        )
        proposed.document = preview.document
        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .createPrimaryNoteForCalendar(.init(
                scope: .item(Task4Fixture.itemID),
                note: proposed,
                legacyImportAuthorization: Task4Fixture.authorization(preview)
            )),
            now: Task4Fixture.later
        )
        let state = try #require(result.change).state
        #expect(state.notes[proposed.id]?.document == preview.document)
        #expect(state.notes[proposed.id]?.revision == 1)
        #expect(state.calendar.items[Task4Fixture.itemID]?.notes == "")
        #expect(state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == proposed.id)
        #expect(state.revision == 6)
    }

    @Test func legacyOccurrenceOnlyAndFutureClearOnlyAuthorizedScope() throws {
        let key = OccurrenceKey(seriesID: Task4Fixture.seriesID, originalDate: Task4Fixture.day)
        var workspace = try Task4Fixture.workspace()
        workspace.calendar.recurrence.series[Task4Fixture.seriesID]?.notes = "系列旧文"
        workspace.calendar.recurrence.exceptions[key] = .modified(Task4Fixture.occurrenceOverride(notes: "本次旧文"))
        let onlyPreview = try LegacyMarkdownMigrationPlanner.preview(
            scope: .occurrenceOnly(key), in: workspace,
            injectedBlockIDs: [Task4Fixture.importBlockID],
            checkedTaskCompletedAt: Task4Fixture.completedAt
        )
        let onlyResult = try WorkspaceReducer.reduce(
            workspace,
            command: .attachPrimaryNote(.init(
                scope: .occurrenceOnly(key),
                noteID: Task4Fixture.noteID,
                legacyResolution: .previewAndMerge(
                    expectedNoteRevision: 3,
                    importAuthorization: Task4Fixture.authorization(onlyPreview)
                ),
                replacing: nil,
                linkedTaskDisposition: nil
            )),
            now: Task4Fixture.later
        )
        let onlyState = try #require(onlyResult.change).state
        guard case let .modified(onlyOverride) = onlyState.calendar.recurrence.exceptions[key] else {
            Issue.record("only-this 应保留 modified exception")
            return
        }
        #expect(onlyOverride.notes == "")
        #expect(onlyState.calendar.recurrence.series[Task4Fixture.seriesID]?.notes == "系列旧文")

        let futurePreview = try LegacyMarkdownMigrationPlanner.preview(
            scope: .occurrenceThisAndFuture(key, newSeriesID: Task4Fixture.newSeriesID),
            in: workspace,
            injectedBlockIDs: [Task4Fixture.importBlockID],
            checkedTaskCompletedAt: Task4Fixture.completedAt
        )
        let futureResult = try WorkspaceReducer.reduce(
            workspace,
            command: .attachPrimaryNote(.init(
                scope: .occurrenceThisAndFuture(key, newSeriesID: Task4Fixture.newSeriesID),
                noteID: Task4Fixture.noteID,
                legacyResolution: .previewAndMerge(
                    expectedNoteRevision: 3,
                    importAuthorization: Task4Fixture.authorization(futurePreview)
                ),
                replacing: nil,
                linkedTaskDisposition: nil
            )),
            now: Task4Fixture.later
        )
        let futureState = try #require(futureResult.change).state
        #expect(futureState.calendar.recurrence.series[Task4Fixture.newSeriesID]?.notes == "")
        #expect(futureState.calendarNoteRelations.baselines[.series(Task4Fixture.newSeriesID)]?.primaryNoteID == Task4Fixture.noteID)
        #expect(futureState.calendar.recurrence.series[Task4Fixture.seriesID]?.notes == nil || futureState.calendar.recurrence.series[Task4Fixture.seriesID]?.notes == "系列旧文")
    }

    @Test func primaryReplacementRequiresExactDispositionAndPreservesReferences() throws {
        var workspace = try Task4Fixture.workspace()
        workspace.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)] = .init(
            primaryNoteID: Task4Fixture.noteID,
            referenceNoteIDs: []
        )
        #expect(throws: WorkspaceReducerError.primaryReplacementDispositionRequired) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .attachPrimaryNote(.init(
                    scope: .item(Task4Fixture.itemID), noteID: Task4Fixture.otherNoteID,
                    legacyResolution: nil, replacing: nil, linkedTaskDisposition: nil
                )),
                now: Task4Fixture.later
            )
        }
        let demoted = try WorkspaceReducer.reduce(
            workspace,
            command: .attachPrimaryNote(.init(
                scope: .item(Task4Fixture.itemID), noteID: Task4Fixture.otherNoteID,
                legacyResolution: nil, replacing: .demoteOldPrimaryToReference,
                linkedTaskDisposition: nil
            )),
            now: Task4Fixture.later
        )
        let set = try #require(demoted.change?.state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)])
        #expect(set.primaryNoteID == Task4Fixture.otherNoteID)
        #expect(set.referenceNoteIDs == [Task4Fixture.noteID])
    }

    @Test func permanentDeletePreviewIsCanonicalAndStaleAuthorizationIsNoChange() throws {
        var workspace = try Task4Fixture.workspaceWithLinkedTask()
        workspace.notes[Task4Fixture.noteID]?.archivedAt = Task4Fixture.archiveAt
        workspace.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.referenceNoteIDs.insert(Task4Fixture.otherNoteID)
        workspace.inspirationNoteLinks.insert(.init(
            source: .live(Task4Fixture.inspirationID),
            noteID: Task4Fixture.noteID,
            createdAt: Task4Fixture.now
        ))
        let first = try PermanentDeletePlanner.preview(.note(Task4Fixture.noteID), in: workspace)
        let second = try PermanentDeletePlanner.preview(.note(Task4Fixture.noteID), in: workspace)
        #expect(first == second)
        #expect(first.effects.contains(.clearBaselinePrimary(.item(Task4Fixture.itemID))))
        #expect(first.effects.contains(.removeTaskBlockLink(try #require(workspace.taskBlockLinks.first))))

        let stale = try WorkspaceReducer.reduce(
            workspace,
            command: .permanentlyDeleteNote(Task4Fixture.noteID, authorization: .init(
                subject: first.subject,
                sourceWorkspaceRevision: first.sourceWorkspaceRevision - 1,
                impactChecksum: first.checksum
            )),
            now: Task4Fixture.later
        )
        #expect(stale == .noChange(.staleDeleteAuthorization))

        let deleted = try WorkspaceReducer.reduce(
            workspace,
            command: .permanentlyDeleteNote(Task4Fixture.noteID, authorization: .init(
                subject: first.subject,
                sourceWorkspaceRevision: first.sourceWorkspaceRevision,
                impactChecksum: first.checksum
            )),
            now: Task4Fixture.later
        )
        let state = try #require(deleted.change).state
        #expect(state.notes[Task4Fixture.noteID] == nil)
        #expect(state.calendar.items[Task4Fixture.itemID] != nil)
        #expect(state.inspirations[Task4Fixture.inspirationID] != nil)
        #expect(state.taskBlockLinks.isEmpty)
        #expect(state.inspirationNoteLinks.isEmpty)
        #expect(state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == nil)
    }

    @Test func permanentDeleteRejectsAnActiveNoteEvenWithAnExactAuthorization() throws {
        let workspace = try Task4Fixture.workspace()
        let preview = try PermanentDeletePlanner.preview(.note(Task4Fixture.noteID), in: workspace)
        let authorization = PermanentDeleteAuthorization(
            subject: preview.subject,
            sourceWorkspaceRevision: preview.sourceWorkspaceRevision,
            impactChecksum: preview.checksum
        )

        #expect(throws: WorkspaceReducerError.permanentDeleteRequiresArchivedSubject) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .permanentlyDeleteNote(Task4Fixture.noteID, authorization: authorization),
                now: Task4Fixture.later
            )
        }
    }

    @Test func consistencyInspectorRepairsAllEdgesAndRejectsPartialOrStalePayloads() throws {
        var broken = try Task4Fixture.workspace()
        broken.notes[Task4Fixture.noteID] = Task4Fixture.note(
            id: Task4Fixture.noteID,
            title: "可修复任务",
            revision: 3,
            task: true
        )
        let missingNote = NoteID(Task4Fixture.uuid(900))
        let missingItem = Task4Fixture.uuid(901)
        broken.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)] = .init(
            primaryNoteID: missingNote,
            referenceNoteIDs: []
        )
        broken.taskBlockLinks.insert(.init(
            noteID: Task4Fixture.noteID,
            blockID: Task4Fixture.taskBlockID,
            calendarItemID: missingItem
        ))
        let report = WorkspaceConsistencyInspector.inspect(broken)
        #expect(report.issues.count == 2)
        let partial = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: [try #require(report.issues.first).id: .unlink]
        )
        #expect(throws: WorkspaceReducerError.invalidConsistencyRepair) {
            try WorkspaceReducer.reduce(broken, command: .repairConsistency(partial), now: Task4Fixture.later)
        }

        let all = Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, WorkspaceConsistencyResolution.unlink) })
        let repaired = try WorkspaceReducer.reduce(
            broken,
            command: .repairConsistency(.init(expectedIssuesChecksum: report.issuesChecksum, resolutions: all)),
            now: Task4Fixture.later
        )
        let state = try #require(repaired.change).state
        #expect(state.revision == 6)
        #expect(state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)] == nil)
        #expect(state.taskBlockLinks.isEmpty)
        try WorkspaceValidator.validate(state)

        let stale = try WorkspaceReducer.reduce(
            broken,
            command: .repairConsistency(.init(expectedIssuesChecksum: "stale", resolutions: all)),
            now: Task4Fixture.later
        )
        #expect(stale == .noChange(.staleConsistencyPreview))
    }

    @Test func consistencyRepairGroupsMultipleDefectsOnOneLink() throws {
        var broken = try Task4Fixture.workspace()
        let brokenLink = TaskBlockCalendarLink(
            noteID: NoteID(Task4Fixture.uuid(910)),
            blockID: BlockID(Task4Fixture.uuid(911)),
            calendarItemID: Task4Fixture.uuid(912)
        )
        broken.taskBlockLinks = [brokenLink]
        let report = WorkspaceConsistencyInspector.inspect(broken)
        #expect(report.issues.count == 2)
        #expect(Set(report.issues.map(\.locator)) == [.taskBlock(brokenLink)])
        let resolutions = Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, WorkspaceConsistencyResolution.unlink) })
        let repaired = try WorkspaceReducer.reduce(
            broken,
            command: .repairConsistency(.init(
                expectedIssuesChecksum: report.issuesChecksum,
                resolutions: resolutions
            )),
            now: Task4Fixture.later
        )
        #expect(repaired.change?.state.taskBlockLinks.isEmpty == true)
    }

    @Test func consistencyRepairCombinesSharedLinkRelinksWithAnotherUnlink() throws {
        var broken = try Task4Fixture.workspaceWithLinkedTask()
        broken.taskBlockLinks.removeAll()
        let brokenLink = TaskBlockCalendarLink(
            noteID: NoteID(Task4Fixture.uuid(920)),
            blockID: BlockID(Task4Fixture.uuid(921)),
            calendarItemID: Task4Fixture.uuid(922)
        )
        broken.taskBlockLinks.insert(brokenLink)
        let missingOwner = CalendarNoteOwnerID.item(Task4Fixture.uuid(923))
        broken.calendarNoteRelations.baselines[missingOwner] = .init(
            primaryNoteID: nil,
            referenceNoteIDs: [Task4Fixture.otherNoteID]
        )
        let report = WorkspaceConsistencyInspector.inspect(broken)
        #expect(report.hasFatalIssues == false)
        #expect(report.issues.count == 3)
        var resolutions = [WorkspaceConsistencyIssueID: WorkspaceConsistencyResolution]()
        for issue in report.issues {
            switch (issue.locator, issue.defect) {
            case (.taskBlock(brokenLink), .missingCalendarItem):
                resolutions[issue.id] = .relink(.calendarItem(Task4Fixture.itemID))
            case (.taskBlock(brokenLink), .missingTaskBlock):
                resolutions[issue.id] = .relink(.taskBlock(
                    noteID: Task4Fixture.noteID,
                    blockID: Task4Fixture.taskBlockID
                ))
            case (.calendarBaseline(missingOwner), .missingCalendarOwner):
                resolutions[issue.id] = .unlink
            default:
                Issue.record("出现未预期的 consistency issue：\(issue)")
            }
        }
        let repaired = try WorkspaceReducer.reduce(
            broken,
            command: .repairConsistency(.init(
                expectedIssuesChecksum: report.issuesChecksum,
                resolutions: resolutions
            )),
            now: Task4Fixture.later
        )
        let state = try #require(repaired.change).state
        #expect(state.taskBlockLinks == [.init(
            noteID: Task4Fixture.noteID,
            blockID: Task4Fixture.taskBlockID,
            calendarItemID: Task4Fixture.itemID
        )])
        #expect(state.calendarNoteRelations.baselines[missingOwner] == nil)
        try WorkspaceValidator.validate(state)
    }

    @Test func consistencyRepairRelinksChildEndpointBeforeItsDanglingOwner() throws {
        var broken = try Task4Fixture.workspace()
        let missingOwner = CalendarNoteOwnerID.item(Task4Fixture.uuid(930))
        let missingNote = NoteID(Task4Fixture.uuid(931))
        broken.calendarNoteRelations.baselines[missingOwner] = .init(
            primaryNoteID: missingNote,
            referenceNoteIDs: []
        )
        let report = WorkspaceConsistencyInspector.inspect(broken)
        #expect(report.issues.count == 2)
        var resolutions = [WorkspaceConsistencyIssueID: WorkspaceConsistencyResolution]()
        for issue in report.issues {
            switch issue.locator {
            case let .calendarBaseline(owner) where owner == missingOwner:
                resolutions[issue.id] = .relink(.calendarOwner(.item(Task4Fixture.itemID)))
            case let .calendarNote(.baselinePrimary(owner: owner, noteID: noteID))
                where owner == missingOwner && noteID == missingNote:
                resolutions[issue.id] = .relink(.note(Task4Fixture.otherNoteID))
            default:
                Issue.record("出现未预期的父子 consistency issue：\(issue)")
            }
        }
        let repaired = try WorkspaceReducer.reduce(
            broken,
            command: .repairConsistency(.init(
                expectedIssuesChecksum: report.issuesChecksum,
                resolutions: resolutions
            )),
            now: Task4Fixture.later
        )
        #expect(repaired.change?.state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == Task4Fixture.otherNoteID)
        try WorkspaceValidator.validate(try #require(repaired.change).state)
    }

    @Test func consistencyRepairMovesBaselineOwnerBeforeDependentTaskBlockRelink() throws {
        var broken = try Task4Fixture.workspace()
        broken.notes[Task4Fixture.noteID] = Task4Fixture.note(
            id: Task4Fixture.noteID,
            title: "待修任务",
            revision: 3,
            task: true
        )
        let missingItemID = Task4Fixture.uuid(932)
        let missingOwner = CalendarNoteOwnerID.item(missingItemID)
        let brokenLink = TaskBlockCalendarLink(
            noteID: Task4Fixture.noteID,
            blockID: Task4Fixture.taskBlockID,
            calendarItemID: missingItemID
        )
        broken.calendarNoteRelations.baselines[missingOwner] = .init(
            primaryNoteID: Task4Fixture.noteID,
            referenceNoteIDs: []
        )
        broken.taskBlockLinks = [brokenLink]

        let report = WorkspaceConsistencyInspector.inspect(broken)
        #expect(report.hasFatalIssues == false)
        #expect(report.issues.count == 2)
        var resolutions = [WorkspaceConsistencyIssueID: WorkspaceConsistencyResolution]()
        for issue in report.issues {
            switch (issue.locator, issue.defect) {
            case (.calendarBaseline(missingOwner), .missingCalendarOwner):
                resolutions[issue.id] = .relink(.calendarOwner(.item(Task4Fixture.itemID)))
            case (.taskBlock(brokenLink), .missingCalendarItem):
                resolutions[issue.id] = .relink(.calendarItem(Task4Fixture.itemID))
            default:
                Issue.record("出现未预期的组合 consistency issue：\(issue)")
            }
        }

        let repaired = try WorkspaceReducer.reduce(
            broken,
            command: .repairConsistency(.init(
                expectedIssuesChecksum: report.issuesChecksum,
                resolutions: resolutions
            )),
            now: Task4Fixture.later
        )
        let state = try #require(repaired.change).state
        #expect(state.calendarNoteRelations.baselines[missingOwner] == nil)
        #expect(state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == Task4Fixture.noteID)
        #expect(state.taskBlockLinks == [.init(
            noteID: Task4Fixture.noteID,
            blockID: Task4Fixture.taskBlockID,
            calendarItemID: Task4Fixture.itemID
        )])
        try WorkspaceValidator.validate(state)
    }

    @Test func fatalInvalidDocumentIsNotARepairableRelationshipIssue() throws {
        var broken = try Task4Fixture.workspace()
        broken.notes[Task4Fixture.noteID]?.document.blocks[0].indentLevel = 99
        let report = WorkspaceConsistencyInspector.inspect(broken)
        #expect(report.hasFatalIssues)
        #expect(throws: WorkspaceReducerError.fatalConsistencyIssues) {
            try WorkspaceReducer.reduce(
                broken,
                command: .repairConsistency(.init(
                    expectedIssuesChecksum: report.issuesChecksum,
                    resolutions: [:]
                )),
                now: Task4Fixture.later
            )
        }
    }

    @Test func restoreUsesPerNoteSourceRevisionsAndHighWatermarkRules() throws {
        var current = try Task4Fixture.workspace()
        current.notes[Task4Fixture.noteID]?.revision = 4
        current.notes[Task4Fixture.otherNoteID]?.revision = 2
        current.revision = 7
        var source = current
        source.notes[Task4Fixture.noteID]?.revision = 40
        source.notes[Task4Fixture.otherNoteID]?.revision = 3
        source.notes[Task4Fixture.otherNoteID]?.title = "快照内容"
        let restoredNote = Task4Fixture.note(id: Task4Fixture.newNoteID, title: "已删除后恢复", revision: 12)
        source.notes[restoredNote.id] = restoredNote
        source.revision = 40
        let snapshot = WorkspaceContentSnapshot(state: source)
        let result = try WorkspaceReducer.reduce(
            current,
            command: .restoreContent(.init(
                content: snapshot,
                sourceRevisionHighWatermark: 40,
                sourceNoteRevisions: [
                    Task4Fixture.noteID: 40,
                    Task4Fixture.otherNoteID: 3,
                    Task4Fixture.newNoteID: 12
                ]
            )),
            now: Task4Fixture.later
        )
        let state = try #require(result.change).state
        #expect(state.revision == 41)
        #expect(state.notes[Task4Fixture.noteID]?.revision == 40)
        #expect(state.notes[Task4Fixture.otherNoteID]?.revision == 4)
        #expect(state.notes[Task4Fixture.newNoteID]?.revision == 41)
    }

    @Test func restorePreservesMaterialDigestsAndRejectsMismatchedKeys() throws {
        let fixture = MaterialDigestReducerFixture()
        let source = try fixture.succeededState()
        var current = fixture.workspace
        current.revision = 10
        let snapshot = WorkspaceContentSnapshot(state: source)
        let restored = try WorkspaceReducer.reduce(
            current,
            command: .restoreContent(.init(
                content: snapshot,
                sourceRevisionHighWatermark: source.revision,
                sourceNoteRevisions: [:]
            )),
            now: fixture.later
        )
        let state = try #require(restored.change).state
        #expect(state.materialDigests[fixture.inspiration.id]?.result == fixture.result)
        #expect(state.inspirations[fixture.inspiration.id]?.rawURL == fixture.inspiration.rawURL)

        var mismatched = snapshot
        if let digest = mismatched.materialDigests.removeValue(forKey: fixture.inspiration.id) {
            mismatched.materialDigests[InspirationID()] = digest
        }
        #expect(throws: WorkspaceReducerError.invalidRestoreMetadata) {
            try WorkspaceReducer.reduce(
                current,
                command: .restoreContent(.init(
                    content: mismatched,
                    sourceRevisionHighWatermark: source.revision,
                    sourceNoteRevisions: [:]
                )),
                now: fixture.later
            )
        }
    }

    @Test func restoreRejectsInvalidMetadataAndOverflowBeforeMutation() throws {
        let workspace = try Task4Fixture.workspace()
        let snapshot = WorkspaceContentSnapshot(state: workspace)
        #expect(throws: WorkspaceReducerError.invalidRestoreMetadata) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .restoreContent(.init(
                    content: snapshot,
                    sourceRevisionHighWatermark: 2,
                    sourceNoteRevisions: [Task4Fixture.noteID: 3]
                )),
                now: Task4Fixture.later
            )
        }
        var maxed = workspace
        maxed.revision = .max
        maxed.notes = maxed.notes.mapValues { note in
            var note = note
            note.revision = .max
            return note
        }
        #expect(throws: WorkspaceReducerError.revisionOverflow) {
            try WorkspaceReducer.reduce(
                maxed,
                command: .restoreContent(.init(
                    content: WorkspaceContentSnapshot(state: maxed),
                    sourceRevisionHighWatermark: .max,
                    sourceNoteRevisions: maxed.notes.mapValues(\.revision)
                )),
                now: Task4Fixture.later
            )
        }
    }
}

enum Task4Fixture {
    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static let uncategorizedID = uuid(400)
    static let workCategoryID = uuid(401)
    static let extraCategoryID = uuid(402)
    static let missingCategoryID = uuid(499)
    static let itemID = uuid(410)
    static let otherItemID = uuid(411)
    static let seriesID = uuid(420)
    static let newSeriesID = uuid(421)
    static let noteID = NoteID(uuid(430))
    static let otherNoteID = NoteID(uuid(431))
    static let newNoteID = NoteID(uuid(432))
    static let inspirationID = InspirationID(uuid(440))
    static let otherInspirationID = InspirationID(uuid(441))
    static let paragraphBlockID = BlockID(uuid(450))
    static let taskBlockID = BlockID(uuid(451))
    static let otherTaskBlockID = BlockID(uuid(452))
    static let importBlockID = BlockID(uuid(453))
    static let importTaskBlockID = BlockID(uuid(454))
    static let editSessionID = uuid(460)
    static let now = Date(timeIntervalSince1970: 1_786_220_000)
    static let later = Date(timeIntervalSince1970: 1_786_220_100)
    static let latest = Date(timeIntervalSince1970: 1_786_220_200)
    static let completedAt = Date(timeIntervalSince1970: 1_786_220_300)
    static let archiveAt = Date(timeIntervalSince1970: 1_786_220_400)
    static let restoreAt = Date(timeIntervalSince1970: 1_786_220_500)
    static let day = CalendarDate(year: 2026, month: 8, day: 10)!

    static func category(id: UUID, name: String, sortIndex: Int = 2) -> CalendarCategory {
        .init(id: id, name: name, colorHex: "#123456", sortIndex: sortIndex, createdAt: now, updatedAt: now)
    }

    static func item(
        id: UUID,
        title: String,
        categoryID: UUID = uncategorizedID,
        notes: String = "",
        completedAt: Date? = nil
    ) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            kind: .task,
            title: title,
            categoryID: categoryID,
            schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            creationTimeZoneIdentifier: "UTC",
            notes: notes,
            completedAt: completedAt,
            createdAt: now,
            updatedAt: now
        )
    }

    static func series(notes: String = "", categoryID: UUID = uncategorizedID) throws -> WeeklySeries {
        try WeeklySeries(
            id: seriesID,
            kind: .task,
            title: "每周任务",
            categoryID: categoryID,
            ruleStartDate: day,
            recurrenceEndDate: nil,
            weekdays: [day.weekday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
            notes: notes,
            creationTimeZoneIdentifier: "UTC",
            createdAt: now,
            updatedAt: now
        )
    }

    static func occurrenceOverride(notes: String) -> OccurrenceOverride {
        .init(
            displayedSchedule: try! CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            title: "例外",
            kind: .task,
            categoryID: uncategorizedID,
            notes: notes
        )
    }

    static func note(
        id: NoteID,
        title: String,
        revision: Int64,
        categoryID: UUID = uncategorizedID,
        updatedAt: Date = now,
        task: Bool = false,
        completedAt: Date? = nil
    ) -> Note {
        let fallbackBlockID: BlockID
        switch id {
        case noteID:
            fallbackBlockID = paragraphBlockID
        case otherNoteID:
            fallbackBlockID = otherTaskBlockID
        case newNoteID:
            fallbackBlockID = importBlockID
        default:
            fallbackBlockID = BlockID(uuid(479))
        }
        let block = DocumentBlock(
            id: task ? (id == noteID ? taskBlockID : otherTaskBlockID) : fallbackBlockID,
            kind: task ? .task : .paragraph,
            inlineContent: .plain(task ? "任务" : "正文"),
            taskState: task ? .init(completedAt: completedAt) : nil,
            indentLevel: 0
        )
        return Note(
            id: id,
            title: title,
            document: .init(blocks: [block]),
            categoryID: categoryID,
            archivedAt: nil,
            revision: revision,
            createdAt: now,
            updatedAt: updatedAt
        )
    }

    static func inspiration(
        id: InspirationID = inspirationID,
        categoryID: UUID = uncategorizedID,
        rawText: String = "灵感"
    ) -> Inspiration {
        .text(id: id, rawText: rawText, categoryID: categoryID, now: now)
    }

    static func workspace(itemLegacyNotes: String = "") throws -> WorkspaceState {
        var calendar = CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        calendar.categories[workCategoryID] = category(id: workCategoryID, name: "工作", sortIndex: 1)
        calendar.items[itemID] = try item(id: itemID, title: "事项", notes: itemLegacyNotes)
        calendar.recurrence.series[seriesID] = try series()
        let first = note(id: noteID, title: "笔记", revision: 3)
        let second = note(id: otherNoteID, title: "参考", revision: 2)
        return WorkspaceState(
            revision: 5,
            calendar: calendar,
            notes: [first.id: first, second.id: second],
            inspirations: [inspirationID: inspiration()],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [],
            materialDigests: [:]
        )
    }

    static func workspaceWithoutItem() throws -> WorkspaceState {
        var result = try workspace()
        result.calendar.items.removeValue(forKey: itemID)
        return result
    }

    static func workspaceWithLinkedTask(completedAt: Date? = nil) throws -> WorkspaceState {
        var result = try workspace()
        result.notes[noteID] = note(id: noteID, title: "任务笔记", revision: 3, task: true, completedAt: completedAt)
        result.calendar.items[itemID] = try item(id: itemID, title: "任务", completedAt: completedAt)
        result.calendarNoteRelations.baselines[.item(itemID)] = .init(primaryNoteID: noteID, referenceNoteIDs: [])
        result.taskBlockLinks = [.init(noteID: noteID, blockID: taskBlockID, calendarItemID: itemID)]
        return result
    }

    static func workspaceWithLinkedTaskAndSeriesRelation() throws -> WorkspaceState {
        var result = try workspaceWithLinkedTask()
        result.calendarNoteRelations.baselines[.series(seriesID)] = .init(primaryNoteID: noteID, referenceNoteIDs: [])
        return result
    }

    static func submission(
        base: Note,
        submitted: Note,
        modifiedFields: Set<NoteDraftField>? = nil,
        baseLinks: Set<TaskBlockCalendarLink> = [],
        dispositions: [BlockID: LinkedTaskBlockDeletionDisposition] = [:]
    ) throws -> NoteDraftSubmission {
        let fields = modifiedFields ?? derivedFields(base: base, submitted: submitted)
        return NoteDraftSubmission(
            noteID: base.id,
            editSessionID: editSessionID,
            baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: baseLinks,
            draftGeneration: 1,
            snapshot: submitted,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submitted),
            modifiedFields: fields,
            linkedBlockDeletionDispositions: dispositions
        )
    }

    static func derivedFields(base: Note, submitted: Note) -> Set<NoteDraftField> {
        var result = Set<NoteDraftField>()
        if base.title != submitted.title { result.insert(.title) }
        if base.document != submitted.document { result.insert(.document) }
        if base.categoryID != submitted.categoryID { result.insert(.categoryID) }
        if base.archivedAt != submitted.archivedAt { result.insert(.archivedAt) }
        return result
    }

    static func conflictingFields(_ result: WorkspaceReductionResult) -> Set<NoteDraftField>? {
        if case let .conflict(.noteDraft(conflict)) = result { conflict.conflictingFields } else { nil }
    }

    static func authorization(_ preview: LegacyMarkdownMigrationPreview) -> LegacyMarkdownImportAuthorization {
        .init(
            expectedSourceChecksum: preview.sourceChecksum,
            injectedBlockIDs: preview.document.blocks.map(\.id),
            checkedTaskCompletedAt: completedAt,
            diagnostics: preview.diagnostics.isEmpty
                ? .rejectIfPresent
                : .accept(expectedDiagnosticsChecksum: preview.diagnosticsChecksum)
        )
    }
}
