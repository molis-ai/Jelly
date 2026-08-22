import CalendarDomain
import CryptoKit
import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceDocumentCodecTests")
struct WorkspaceDocumentCodecTests {
    @Test func v1AndV2LoadThroughTheSingleCalendarMigrationPath() throws {
        let v1 = WorkspacePersistenceFixtures.v1CalendarDocument()
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()

        let v1Result = try WorkspaceDocumentCodec.decode(v1)
        let v2Result = try WorkspaceDocumentCodec.decode(v2)

        #expect(v1Result.provenance.sourceSchema == 1)
        #expect(v1Result.state == .empty(calendar: WorkspacePersistenceFixtures.calendarState))
        #expect(v2Result.provenance.sourceSchema == 2)
        #expect(v2Result.state == .empty(calendar: WorkspacePersistenceFixtures.calendarState))
    }

    @Test func v2LoadReturnsExactRawByteProvenance() throws {
        let data = try WorkspacePersistenceFixtures.v2CalendarDocument()

        let result = try WorkspaceDocumentCodec.decode(data)

        #expect(result.provenance.sourceBytesSHA256 == WorkspacePersistenceFixtures.sha256(data))
        #expect(result.provenance.sourceByteCount == data.count)
        #expect(result.state.calendar == WorkspacePersistenceFixtures.calendarState)
    }

    @Test func currentRoundTripUsesDeterministicEncodingAndPreservesAllWorkspaceContent() throws {
        let expected = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 3)

        let first = try WorkspaceDocumentCodec.encode(expected)
        let second = try WorkspaceDocumentCodec.encode(expected)
        let result = try WorkspaceDocumentCodec.decode(first)

        #expect(first == second)
        #expect(result.provenance.sourceSchema == WorkspaceDocument.currentSchemaVersion)
        #expect(result.state == expected)
        #expect(result.consistencyIssues.isEmpty)
    }

    @Test func unknownSchemaIsRejectedBeforePayloadDecode() {
        let raw = Data(#"{"schemaVersion":999,"state":"not-a-workspace"}"#.utf8)

        #expect(throws: WorkspacePersistenceError.unsupportedSchema(999)) {
            _ = try WorkspaceDocumentCodec.decode(raw)
        }
    }

    @Test func corruptedV3PayloadIsRejectedWithoutARecoveryDecode() throws {
        let valid = try WorkspaceDocumentCodec.encode(
            WorkspacePersistenceFixtures.workspaceWithMultiMarkNote()
        )
        let corrupted = Data(valid.dropLast())

        #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try WorkspaceDocumentCodec.decode(corrupted)
        }
    }

    @Test func danglingRelationshipIsReportedWithoutMutatingDecodedContent() throws {
        var workspace = WorkspaceState.empty(calendar: WorkspacePersistenceFixtures.calendarState)
        workspace.calendarNoteRelations.baselines[.item(UUID())] = .init(
            primaryNoteID: nil,
            referenceNoteIDs: []
        )
        let raw = try JSONEncoder.workspaceDeterministic.encode(
            WorkspaceDocument(schemaVersion: 3, state: workspace)
        )

        let result = try WorkspaceDocumentCodec.decode(raw)

        #expect(result.state == workspace)
        #expect(result.consistencyIssues.count == 1)
        #expect(result.consistencyIssues.first?.defect == .missingCalendarOwner)
    }

    @Test func v3LinkedTaskTitleIsMigratedFromTheTaskBlock() throws {
        let (legacy, itemID) = try WorkspacePersistenceFixtures.linkedTaskWorkspace(
            calendarTitle: "旧日历标题"
        )
        let raw = try JSONEncoder.workspaceDeterministic.encode(
            WorkspaceDocument(schemaVersion: 3, state: legacy)
        )

        let result = try WorkspaceDocumentCodec.decode(raw)

        #expect(result.provenance.sourceSchema == 3)
        #expect(result.state.calendar.items[itemID]?.title == "正文里的行动")
        #expect(result.consistencyIssues.isEmpty)
        try WorkspaceValidator.validate(result.state)
    }

    @Test func taskCompletionDescriptionRoundTripsWithoutEnteringCalendarTitle() throws {
        let (workspace, itemID) = try WorkspacePersistenceFixtures.linkedTaskWorkspace(
            calendarTitle: "正文里的行动",
            completionDescription: "拿到明确上门时间"
        )
        let encoded = try WorkspaceDocumentCodec.encode(workspace)
        let decoded = try WorkspaceDocumentCodec.decode(encoded)
        let note = try #require(decoded.state.notes.values.first)
        let originalNote = try #require(workspace.notes.values.first)

        #expect(decoded.state == workspace)
        #expect(note.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")
        #expect(decoded.state.calendar.items[itemID]?.title == "正文里的行动")
        #expect(decoded.state.calendar.items[itemID]?.title.contains("拿到明确上门时间") == false)
        #expect(
            try WorkspaceChecksum.noteSnapshotChecksum(note)
                == WorkspaceChecksum.noteSnapshotChecksum(originalNote)
        )
        try WorkspaceValidator.validate(decoded.state)

        let legacyTaskJSON = Data(#"{"completedAt":null}"#.utf8)
        #expect(
            try JSONDecoder.workspaceDeterministic.decode(TaskBlockState.self, from: legacyTaskJSON)
                == TaskBlockState(completedAt: nil, completionDescription: nil)
        )
    }

    @Test func currentLinkedTaskTitleMismatchIsRejectedAsFatal() throws {
        let (workspace, _) = try WorkspacePersistenceFixtures.linkedTaskWorkspace(
            calendarTitle: "冲突的日历标题"
        )
        let raw = try JSONEncoder.workspaceDeterministic.encode(
            WorkspaceDocument(schemaVersion: WorkspaceDocument.currentSchemaVersion, state: workspace)
        )

        #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try WorkspaceDocumentCodec.decode(raw)
        }
    }

    @Test func multiMarkV3AndJournalEncodingIsByteStableAcrossARealSubprocess() async throws {
        guard ProcessInfo.processInfo.environment["JELLY_PERSISTENCE_SUBPROCESS"] == nil else { return }
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let childV3 = directory.file("child-v3.json")
        let childJournal = directory.file("child-journal.json")
        var environment = ProcessInfo.processInfo.environment
        environment["JELLY_PERSISTENCE_SUBPROCESS"] = "writer"
        environment["JELLY_PERSISTENCE_CHILD_V3"] = childV3.path
        environment["JELLY_PERSISTENCE_CHILD_JOURNAL"] = childJournal.path
        let testExecutablePath = try #require(CommandLine.arguments.first(where: {
            $0.contains(".xctest/Contents/MacOS/")
        }))
        let testExecutable = URL(fileURLWithPath: testExecutablePath)
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/Library/Developer/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper"
        )
        process.arguments = [
            "--test-bundle-path", testExecutable.path,
            "--filter", "PersistentEncodingSubprocessTests.writesStablePersistentFixturesWhenExplicitlyLaunchedAsChild",
            testExecutable.path,
            "--testing-library", "swift-testing"
        ]
        process.environment = environment
        let childOutput = Pipe()
        process.standardOutput = childOutput
        process.standardError = childOutput
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        guard FileManager.default.fileExists(atPath: childV3.path),
              FileManager.default.fileExists(atPath: childJournal.path)
        else {
            let output = String(decoding: childOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Issue.record(
                "Child process completed without persistent sentinel: executable=\(testExecutable.path); output=\(output)"
            )
            return
        }
        let expected = try WorkspacePersistenceFixtures.workspaceWithMultiMarkNote()
        #expect(try Data(contentsOf: childV3) == WorkspaceDocumentCodec.encode(expected))
        let localJournal = directory.file("local-journal.json")
        let entry = try WorkspacePersistenceFixtures.multiMarkDraftEntry()
        try await DraftJournalRepository(fileURL: localJournal).persist(entry)
        #expect(try Data(contentsOf: childJournal) == Data(contentsOf: localJournal))
        #expect(try await DraftJournalRepository(fileURL: childJournal).current()?.records.first?.entry == entry)
    }
}

@Suite("PersistentEncodingSubprocessTests")
struct PersistentEncodingSubprocessTests {
    @Test func writesStablePersistentFixturesWhenExplicitlyLaunchedAsChild() async throws {
        guard ProcessInfo.processInfo.environment["JELLY_PERSISTENCE_SUBPROCESS"] == "writer" else { return }
        let v3URL = try #require(ProcessInfo.processInfo.environment["JELLY_PERSISTENCE_CHILD_V3"])
        let journalURL = try #require(ProcessInfo.processInfo.environment["JELLY_PERSISTENCE_CHILD_JOURNAL"])
        try WorkspaceDocumentCodec.encode(
            WorkspacePersistenceFixtures.workspaceWithMultiMarkNote()
        ).write(to: URL(fileURLWithPath: v3URL))
        try await DraftJournalRepository(fileURL: URL(fileURLWithPath: journalURL)).persist(
            WorkspacePersistenceFixtures.multiMarkDraftEntry()
        )
    }
}

enum WorkspacePersistenceFixtures {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    static let calendarState = CalendarState.empty(
        uncategorizedID: categoryID,
        now: Date(timeIntervalSince1970: 0)
    )

    static func v2CalendarDocument() throws -> Data {
        let encoder = JSONEncoder.workspaceDeterministic
        return try encoder.encode(CalendarDocument(state: calendarState))
    }

    static func v1CalendarDocument() -> Data {
        Data(#"""
        {"schemaVersion":1,"state":{"categories":["00000000-0000-0000-0000-000000000501",{"id":"00000000-0000-0000-0000-000000000501","name":"未分类","colorHex":"#8E8E93","sortIndex":0,"createdAt":0,"updatedAt":0}],"items":[],"recurrence":{"series":[],"exceptions":[],"completions":[]},"uncategorizedID":"00000000-0000-0000-0000-000000000501"}}
        """#.utf8)
    }

    static func workspaceWithOneNote(revision: Int64 = 1) throws -> WorkspaceState {
        let now = Date(timeIntervalSince1970: 0)
        let note = Note(
            id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000502")!),
            title: "迁移测试笔记",
            document: .empty(),
            categoryID: categoryID,
            archivedAt: nil,
            revision: revision,
            createdAt: now,
            updatedAt: now
        )
        return WorkspaceState(
            revision: revision,
            calendar: calendarState,
            notes: [note.id: note],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: []
        )
    }

    static func linkedTaskWorkspace(
        calendarTitle: String,
        completionDescription: String? = nil
    ) throws -> (WorkspaceState, UUID) {
        let now = Date(timeIntervalSince1970: 100)
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000511")!)
        let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000512")!)
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000513")!
        var calendar = calendarState
        calendar.items[itemID] = try CalendarItem(
            id: itemID,
            kind: .task,
            title: calendarTitle,
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 12)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 12)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        let note = Note(
            id: noteID,
            title: "迁移待办",
            document: .init(blocks: [
                try .task(
                    id: blockID,
                    text: "正文里的行动",
                    completionDescription: completionDescription
                )
            ]),
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: now,
            updatedAt: now
        )
        return (
            WorkspaceState(
                revision: 1,
                calendar: calendar,
                notes: [noteID: note],
                inspirations: [:],
                calendarNoteRelations: .init(
                    baselines: [.item(itemID): .init(primaryNoteID: noteID, referenceNoteIDs: [])],
                    occurrenceOverrides: [:]
                ),
                taskBlockLinks: [.init(noteID: noteID, blockID: blockID, calendarItemID: itemID)],
                inspirationNoteLinks: []
            ),
            itemID
        )
    }

    static func workspaceWithMultiMarkNote() throws -> WorkspaceState {
        let now = Date(timeIntervalSince1970: 0)
        let spans = [InlineSpan(text: "带多个标记", marks: [.code, .bold, .italic], linkURL: nil)]
        let block = DocumentBlock(
            id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000503")!),
            kind: .paragraph,
            inlineContent: .init(spans: spans),
            taskState: nil,
            indentLevel: 0,
            codeInfoString: nil
        )
        let note = Note(
            id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000504")!),
            title: "多标记",
            document: .init(schemaVersion: 1, blocks: [block]),
            categoryID: categoryID,
            archivedAt: nil,
            revision: 2,
            createdAt: now,
            updatedAt: now
        )
        return WorkspaceState(
            revision: 2,
            calendar: calendarState,
            notes: [note.id: note],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: []
        )
    }

    static func multiMarkDraftEntry() throws -> DraftJournalEntry {
        let note = try #require(workspaceWithMultiMarkNote().notes.values.first)
        let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
        let unsigned = DraftJournalEntry(
            noteID: note.id,
            editSessionID: .editor(UUID(uuidString: "00000000-0000-0000-0000-000000000505")!),
            baseWorkspaceRevision: 1,
            baseNoteRevision: 1,
            draftGeneration: 10,
            noteSnapshot: note,
            updatedAt: Date(timeIntervalSince1970: 0),
            noteSnapshotChecksum: checksum,
            journalChecksum: ""
        )
        return DraftJournalEntry(
            noteID: unsigned.noteID,
            editSessionID: unsigned.editSessionID,
            baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
            baseNoteRevision: unsigned.baseNoteRevision,
            draftGeneration: unsigned.draftGeneration,
            noteSnapshot: unsigned.noteSnapshot,
            updatedAt: unsigned.updatedAt,
            noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
            journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
