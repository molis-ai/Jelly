import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("WorkspaceModelTests")
struct WorkspaceModelTests {
    @Test func workspaceRoundTripPreservesCalendarStableIDsAndLifecyclePayloads() throws {
        let calendar = CalendarState.empty(
            uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            now: Date(timeIntervalSince1970: 1_786_220_000)
        )
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        let inspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000104")!)
        let completedAt = Date(timeIntervalSince1970: 1_786_220_400)
        let note = Note(
            id: noteID,
            title: "归档笔记",
            document: BlockDocument(blocks: [
                DocumentBlock(
                    id: blockID,
                    kind: .task,
                    inlineContent: .plain("写方案"),
                    taskState: .init(completedAt: completedAt),
                    indentLevel: 0
                )
            ]),
            categoryID: calendar.uncategorizedID,
            archivedAt: Date(timeIntervalSince1970: 1_786_220_800),
            revision: 7,
            createdAt: Date(timeIntervalSince1970: 1_786_220_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_221_000)
        )
        let inspiration = Inspiration(
            id: inspirationID,
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://example.com/read")!,
            rawFile: nil,
            resolvedSourceKind: .article,
            resolvedMetadata: .init(
                title: "阅读材料",
                siteName: "Example",
                domain: "example.com",
                thumbnailURL: URL(string: "https://example.com/thumbnail.png"),
                fetchStatus: .succeeded
            ),
            categoryID: calendar.uncategorizedID,
            lifecycle: .archived,
            createdAt: Date(timeIntervalSince1970: 1_786_220_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_221_000)
        )
        let workspace = WorkspaceState(
            revision: 11,
            calendar: calendar,
            notes: [noteID: note],
            inspirations: [inspirationID: inspiration],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [],
            materialDigests: [:]
        )

        let data = try JSONEncoder.workspaceDeterministic.encode(workspace)
        let decoded = try JSONDecoder.workspaceDeterministic.decode(WorkspaceState.self, from: data)

        #expect(decoded == workspace)
        #expect(decoded.calendar == calendar)
        #expect(decoded.notes[noteID]?.document.blocks[0].taskState?.completedAt == completedAt)
        #expect(decoded.inspirations[inspirationID]?.inputKind == .url)
        #expect(decoded.inspirations[inspirationID]?.resolvedSourceKind == .article)
        #expect(decoded.inspirations[inspirationID]?.lifecycle == .archived)
    }

    @Test func checksumIgnoresNoteRevisionAndEncoderFormattingButIncludesProtectedContent() throws {
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000105")!)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let block = DocumentBlock(
            id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000107")!),
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "第一段", marks: [.italic, .bold], linkURL: nil),
                .init(text: "链接", marks: [], linkURL: URL(string: "https://example.com/a")!)
            ]),
            taskState: nil,
            indentLevel: 0
        )
        let original = Note(
            id: noteID,
            title: "标题",
            document: BlockDocument(blocks: [block]),
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var revised = original
        revised.revision = 99
        revised.updatedAt = Date(timeIntervalSince1970: 1_786_222_000)
        var changed = original
        changed.title = "改后的标题"
        var changedDocument = original
        changedDocument.document.blocks[0].inlineContent = .plain("另一段")
        var changedCategory = original
        changedCategory.categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000117")!
        var changedArchivedAt = original
        changedArchivedAt.archivedAt = Date(timeIntervalSince1970: 1_786_223_000)
        var changedCreatedAt = original
        changedCreatedAt.createdAt = Date(timeIntervalSince1970: 1_786_224_000)
        let changedID = Note(
            id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000118")!),
            title: original.title,
            document: original.document,
            categoryID: original.categoryID,
            archivedAt: original.archivedAt,
            revision: original.revision,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        var reorderedMarks = original
        reorderedMarks.document.blocks[0].inlineContent.spans[0].marks = [.bold, .italic]
        let compactEncoder = JSONEncoder()
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let compactDecoded = try JSONDecoder().decode(Note.self, from: compactEncoder.encode(original))
        let prettyDecoded = try JSONDecoder().decode(Note.self, from: prettyEncoder.encode(original))

        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) == WorkspaceChecksum.noteSnapshotChecksum(revised))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) == WorkspaceChecksum.noteSnapshotChecksum(changedCreatedAt))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) != WorkspaceChecksum.noteSnapshotChecksum(changed))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) != WorkspaceChecksum.noteSnapshotChecksum(changedDocument))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) != WorkspaceChecksum.noteSnapshotChecksum(changedCategory))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) != WorkspaceChecksum.noteSnapshotChecksum(changedArchivedAt))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) != WorkspaceChecksum.noteSnapshotChecksum(changedID))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) == WorkspaceChecksum.noteSnapshotChecksum(reorderedMarks))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(compactDecoded) == WorkspaceChecksum.noteSnapshotChecksum(prettyDecoded))
        #expect(try WorkspaceChecksum.normalizedNoteSnapshotData(original) == WorkspaceChecksum.normalizedNoteSnapshotData(revised))
    }

    @Test func codeInfoStringRoundTripsAndParticipatesInChecksum() throws {
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000128")!)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000129")!
        let codeID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000130")!)
        let note = Note(
            id: noteID,
            title: "代码",
            document: .init(blocks: [
                .init(
                    id: codeID,
                    kind: .code,
                    inlineContent: .plain("print(1)"),
                    taskState: nil,
                    indentLevel: 0,
                    codeInfoString: "swift linenums=1"
                )
            ]),
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var changed = note
        changed.document.blocks[0].codeInfoString = "python"
        let decoded = try JSONDecoder.workspaceDeterministic.decode(
            Note.self,
            from: JSONEncoder.workspaceDeterministic.encode(note)
        )

        #expect(decoded.document.blocks[0].codeInfoString == "swift linenums=1")
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(note) != WorkspaceChecksum.noteSnapshotChecksum(changed))
    }

    @Test func workspaceRoundTripPreservesEveryBlockInputAndNonemptyRelationStorageShape() throws {
        let now = Date(timeIntervalSince1970: 1_786_220_000)
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000119")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000120")!
        let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000121")!
        let date = CalendarDate(year: 2026, month: 8, day: 9)!
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000122")!)
        let referenceNoteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000123")!)
        let taskID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000124")!)
        let textInspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000125")!)
        let urlInspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000126")!)
        let fileInspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000127")!)
        var calendar = CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        calendar.items[itemID] = try CalendarItem(
            id: itemID,
            kind: .task,
            title: "待办",
            categoryID: uncategorizedID,
            schedule: try CalendarSchedule(startDate: date, endDate: date, startTime: nil, endTime: nil),
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        calendar.recurrence.series[seriesID] = try WeeklySeries(
            id: seriesID,
            kind: .task,
            title: "关联系列",
            categoryID: uncategorizedID,
            ruleStartDate: date,
            recurrenceEndDate: nil,
            weekdays: [.sunday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
            createdAt: now,
            updatedAt: now
        )
        let note = Note(
            id: noteID,
            title: "完整 Block 笔记",
            document: .init(blocks: [
                .init(id: BlockID(), kind: .paragraph, inlineContent: .plain("正文"), taskState: nil, indentLevel: 0),
                .init(id: BlockID(), kind: .heading1, inlineContent: .plain("一级"), taskState: nil, indentLevel: 0),
                .init(id: BlockID(), kind: .heading2, inlineContent: .plain("二级"), taskState: nil, indentLevel: 0),
                .init(id: BlockID(), kind: .heading3, inlineContent: .plain("三级"), taskState: nil, indentLevel: 0),
                .init(id: BlockID(), kind: .bullet, inlineContent: .plain("无序"), taskState: nil, indentLevel: 0),
                .init(id: BlockID(), kind: .ordered, inlineContent: .plain("有序"), taskState: nil, indentLevel: 1),
                .init(id: taskID, kind: .task, inlineContent: .plain("待办"), taskState: .init(completedAt: nil), indentLevel: 2),
                .init(id: BlockID(), kind: .quote, inlineContent: .plain("引用"), taskState: nil, indentLevel: 0),
                .init(id: BlockID(), kind: .code, inlineContent: .plain("print(1)"), taskState: nil, indentLevel: 0, codeInfoString: "swift"),
                .init(id: BlockID(), kind: .divider, inlineContent: .plain(""), taskState: nil, indentLevel: 0),
                .init(id: BlockID(), kind: .link, inlineContent: .init(spans: [.init(text: "链接", linkURL: URL(string: "https://example.com")!)]), taskState: nil, indentLevel: 0)
            ]),
            categoryID: uncategorizedID,
            archivedAt: nil,
            revision: 0,
            createdAt: now,
            updatedAt: now
        )
        let reference = Note.empty(id: referenceNoteID, categoryID: uncategorizedID, now: now)
        let occurrenceKey = OccurrenceKey(seriesID: seriesID, originalDate: date)
        let workspace = WorkspaceState(
            revision: 4,
            calendar: calendar,
            notes: [noteID: note, referenceNoteID: reference],
            inspirations: [
                textInspirationID: .text(id: textInspirationID, rawText: "原始文字", categoryID: uncategorizedID, now: now),
                urlInspirationID: .init(id: urlInspirationID, inputKind: .url, rawText: nil, rawURL: URL(string: "https://example.com/read")!, rawFile: nil, resolvedSourceKind: .article, resolvedMetadata: nil, categoryID: uncategorizedID, lifecycle: .active, createdAt: now, updatedAt: now),
                fileInspirationID: .init(id: fileInspirationID, inputKind: .file, rawText: nil, rawURL: nil, rawFile: .init(bookmarkData: Data([1]), displayName: "材料.pdf"), resolvedSourceKind: .document, resolvedMetadata: nil, categoryID: uncategorizedID, lifecycle: .active, createdAt: now, updatedAt: now)
            ],
            calendarNoteRelations: .init(
                baselines: [
                    .item(itemID): .init(primaryNoteID: noteID, referenceNoteIDs: [referenceNoteID]),
                    .series(seriesID): .init(primaryNoteID: referenceNoteID, referenceNoteIDs: [])
                ],
                occurrenceOverrides: [
                    occurrenceKey: .init(key: occurrenceKey, primary: .replace(noteID), addedReferenceNoteIDs: [referenceNoteID], removedReferenceNoteIDs: [])
                ]
            ),
            taskBlockLinks: [.init(noteID: noteID, blockID: taskID, calendarItemID: itemID)],
            inspirationNoteLinks: [.init(source: .live(textInspirationID), noteID: noteID, createdAt: now)],
            materialDigests: [:]
        )

        try WorkspaceValidator.validate(workspace)
        let decoded = try JSONDecoder.workspaceDeterministic.decode(
            WorkspaceState.self,
            from: JSONEncoder.workspaceDeterministic.encode(workspace)
        )

        #expect(decoded == workspace)
        #expect(decoded.notes[noteID]?.document.blocks.map(\.kind) == [.paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .code, .divider, .link])
        #expect(decoded.notes[noteID]?.document.blocks[8].codeInfoString == "swift")
        #expect(Set(decoded.inspirations.values.map(\.inputKind)) == [.text, .url, .file])
        #expect(decoded.calendarNoteRelations.baselines.count == 2)
        #expect(decoded.calendarNoteRelations.occurrenceOverrides[occurrenceKey]?.primary == .replace(noteID))
        #expect(decoded.taskBlockLinks.count == 1)
        #expect(decoded.inspirationNoteLinks.count == 1)
    }

    @Test func workspaceValidatorAcceptsLiveAndDeletedInspirationLinksWithoutCopyingSourceContent() throws {
        let calendar = CalendarState.empty(
            uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000000108")!,
            now: .distantPast
        )
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000109")!)
        let inspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000110")!)
        let note = Note.empty(
            id: noteID,
            categoryID: calendar.uncategorizedID,
            now: .distantPast
        )
        let inspiration = Inspiration.text(
            id: inspirationID,
            rawText: "保留原始输入",
            categoryID: calendar.uncategorizedID,
            now: .distantPast
        )
        let live = InspirationNoteLink(
            source: .live(inspirationID),
            noteID: noteID,
            createdAt: .distantPast
        )
        let deleted = InspirationNoteLink(
            source: .deleted(originalID: InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000111")!), deletedAt: .distantPast),
            noteID: noteID,
            createdAt: .distantPast
        )
        let workspace = WorkspaceState(
            revision: 0,
            calendar: calendar,
            notes: [noteID: note],
            inspirations: [inspirationID: inspiration],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [live, deleted],
            materialDigests: [:]
        )

        try WorkspaceValidator.validate(workspace)
    }

    @Test func workspaceValidatorRejectsDanglingCalendarRelationOwner() throws {
        let workspace = try validWorkspace()
        let owner = CalendarNoteOwnerID.item(UUID(uuidString: "00000000-0000-0000-0000-000000000112")!)
        var invalid = workspace
        invalid.calendarNoteRelations.baselines[owner] = .init(
            primaryNoteID: invalid.notes.keys.first,
            referenceNoteIDs: []
        )

        #expect(throws: WorkspaceValidationError.danglingCalendarOwner(owner)) {
            try WorkspaceValidator.validate(invalid)
        }
    }

    @Test func workspaceValidatorRejectsPrimaryNoteDuplicatedAsReference() throws {
        let workspace = try validWorkspace()
        let itemID = try #require(workspace.calendar.items.keys.first)
        let noteID = try #require(workspace.notes.keys.first)
        let owner = CalendarNoteOwnerID.item(itemID)
        var invalid = workspace
        invalid.calendarNoteRelations.baselines[owner] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: [noteID]
        )

        #expect(throws: WorkspaceValidationError.primaryAlsoReference(owner, noteID)) {
            try WorkspaceValidator.validate(invalid)
        }
    }

    @Test func workspaceValidatorRejectsTaskBlockLinkWithoutMatchingPrimaryNote() throws {
        let workspace = try validWorkspace()
        let itemID = try #require(workspace.calendar.items.keys.first)
        let noteID = try #require(workspace.notes.keys.first)
        let blockID = try #require(workspace.notes[noteID]?.document.blocks.first?.id)
        var invalid = workspace
        invalid.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: itemID)]

        #expect(throws: WorkspaceValidationError.taskBlockMissingPrimaryNote(noteID, itemID)) {
            try WorkspaceValidator.validate(invalid)
        }
    }

    @Test func workspaceValidatorRejectsOccurrencePrimaryDuplicatedAsAddedReference() throws {
        let workspace = try validWorkspace()
        let noteID = try #require(workspace.notes.keys.first)
        let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000128")!
        let date = CalendarDate(year: 2026, month: 8, day: 9)!
        let key = OccurrenceKey(seriesID: seriesID, originalDate: date)
        var invalid = workspace
        invalid.calendar.recurrence.series[seriesID] = try WeeklySeries(
            id: seriesID,
            kind: .task,
            title: "冲突系列",
            categoryID: invalid.calendar.uncategorizedID,
            ruleStartDate: date,
            recurrenceEndDate: nil,
            weekdays: [.sunday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        invalid.calendarNoteRelations.occurrenceOverrides[key] = .init(
            key: key,
            primary: .replace(noteID),
            addedReferenceNoteIDs: [noteID],
            removedReferenceNoteIDs: []
        )

        #expect(throws: WorkspaceValidationError.occurrencePrimaryAlsoReference(key, noteID)) {
            try WorkspaceValidator.validate(invalid)
        }
    }

    @Test func contentSnapshotExcludesWorkspaceAndPerNoteRevisions() throws {
        let original = try validWorkspace()
        var revised = original
        revised.revision = 99
        revised.notes = revised.notes.mapValues { note in
            var note = note
            note.revision = 77
            return note
        }

        let first = WorkspaceContentSnapshot(state: original)
        let second = WorkspaceContentSnapshot(state: revised)

        #expect(first == second)
        let encoded = String(
            decoding: try JSONEncoder.workspaceDeterministic.encode(first),
            as: UTF8.self
        )
        #expect(encoded.contains("revision") == false)
    }

    @Test func validatorRejectsNegativeOrFutureNoteRevision() throws {
        let original = try validWorkspace()
        let noteID = try #require(original.notes.keys.first)
        var negative = original
        negative.notes[noteID]?.revision = -1
        #expect(throws: WorkspaceValidationError.invalidNoteRevision(noteID)) {
            try WorkspaceValidator.validate(negative)
        }

        var future = original
        future.notes[noteID]?.revision = original.revision + 1
        #expect(throws: WorkspaceValidationError.invalidNoteRevision(noteID)) {
            try WorkspaceValidator.validate(future)
        }
    }

    @Test func validatorRequiresLinkedTaskAndItemCompletionToMatch() throws {
        var workspace = try validWorkspace()
        let noteID = try #require(workspace.notes.keys.first)
        let blockID = try #require(workspace.notes[noteID]?.document.blocks.first?.id)
        let itemID = try #require(workspace.calendar.items.keys.first)
        workspace.calendarNoteRelations.baselines[.item(itemID)] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: []
        )
        workspace.taskBlockLinks = [.init(
            noteID: noteID,
            blockID: blockID,
            calendarItemID: itemID
        )]
        workspace.calendar.items[itemID]?.completedAt = Date(timeIntervalSince1970: 1_786_220_999)

        #expect(throws: WorkspaceValidationError.taskCompletionMismatch(noteID, blockID, itemID)) {
            try WorkspaceValidator.validate(workspace)
        }
    }

    @Test func validatorRejectsLinkedTaskAndItemWithDifferentTitles() throws {
        var workspace = try validWorkspace()
        let noteID = try #require(workspace.notes.keys.first)
        let blockID = try #require(workspace.notes[noteID]?.document.blocks.first?.id)
        let itemID = try #require(workspace.calendar.items.keys.first)
        workspace.calendarNoteRelations.baselines[.item(itemID)] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: []
        )
        workspace.taskBlockLinks = [.init(
            noteID: noteID,
            blockID: blockID,
            calendarItemID: itemID
        )]
        workspace.calendar.items[itemID]?.title = "另一条行动"

        #expect(throws: (any Error).self) {
            try WorkspaceValidator.validate(workspace)
        }
    }

    private func validWorkspace() throws -> WorkspaceState {
        let now = Date(timeIntervalSince1970: 1_786_220_000)
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000113")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000114")!
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000115")!)
        let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000116")!)
        var calendar = CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        calendar.items[itemID] = try CalendarItem(
            id: itemID,
            kind: .task,
            title: "关联待办",
            categoryID: uncategorizedID,
            schedule: try CalendarSchedule(
                startDate: .init(year: 2026, month: 8, day: 9)!,
                endDate: .init(year: 2026, month: 8, day: 9)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        return WorkspaceState(
            revision: 0,
            calendar: calendar,
            notes: [noteID: .init(
                id: noteID,
                title: "关联笔记",
                document: .init(blocks: [
                    .init(
                        id: blockID,
                        kind: .task,
                        inlineContent: .plain("关联待办"),
                        taskState: .init(completedAt: nil),
                        indentLevel: 0
                    )
                ]),
                categoryID: uncategorizedID,
                archivedAt: nil,
                revision: 0,
                createdAt: now,
                updatedAt: now
            )],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [],
            materialDigests: [:]
        )
    }
}
