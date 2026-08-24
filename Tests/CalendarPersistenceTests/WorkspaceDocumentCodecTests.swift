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

    @Test func v4PayloadWithoutDigestsMigratesToEmptyMaterialDigests() throws {
        let legacyState = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 3)
        let v4Bytes = try JSONEncoder.workspaceDeterministic.encode(
            LegacyWorkspaceDocumentV3V4(
                schemaVersion: 4,
                state: LegacyWorkspaceStateV3V4(state: legacyState)
            )
        )
        #expect(String(decoding: v4Bytes, as: UTF8.self).contains("materialDigests") == false)

        let result = try WorkspaceDocumentCodec.decode(v4Bytes)
        #expect(result.provenance.sourceSchema == 4)
        #expect(result.state.materialDigests.isEmpty)
        #expect(result.state.inspirations == legacyState.inspirations)
        #expect(result.state.notes == legacyState.notes)
        #expect(result.state.revision == legacyState.revision)
    }

    @Test func v3LinkedTaskPayloadWithoutDigestsMigratesTitlesAndEmptyDigests() throws {
        let (legacy, itemID) = try WorkspacePersistenceFixtures.linkedTaskWorkspace(
            calendarTitle: "旧日历标题"
        )
        let v3Bytes = try JSONEncoder.workspaceDeterministic.encode(
            LegacyWorkspaceDocumentV3V4(
                schemaVersion: 3,
                state: LegacyWorkspaceStateV3V4(state: legacy)
            )
        )
        #expect(String(decoding: v3Bytes, as: UTF8.self).contains("materialDigests") == false)

        let result = try WorkspaceDocumentCodec.decode(v3Bytes)
        #expect(result.provenance.sourceSchema == 3)
        #expect(result.state.calendar.items[itemID]?.title == "正文里的行动")
        #expect(result.state.materialDigests.isEmpty)
        #expect(result.consistencyIssues.isEmpty)
        try WorkspaceValidator.validate(result.state)
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

    @Test func v4TimedTranscriptMigratesToV5BlocksAndLegacyReadOnlySummary() throws {
        let v4 = try WorkspacePersistenceFixtures.v4WorkspaceWithMaterialDigest()
        let loaded = try WorkspaceDocumentCodec.decode(v4)
        let digest = try #require(loaded.state.materialDigests.values.first)
        #expect(loaded.provenance.sourceSchema == 4)
        #expect(digest.preparedSnapshot?.blocks.map(\.role) == [.transcript, .transcript])
        #expect(digest.preparedSnapshot?.blocks.map(\.locator) == [
            .timestamp(startSeconds: 0, endSeconds: 8),
            .timestamp(startSeconds: 8, endSeconds: 20)
        ])
        #expect(digest.result?.provenance.summaryContractVersion == "summary-contract-v2")
        #expect(try WorkspaceDocumentCodec.decode(WorkspaceDocumentCodec.encode(loaded.state)).state == loaded.state)
    }

    @Test func v4MigrationPreservesUniqueBlockIDsBeyondOneByte() throws {
        let loaded = try WorkspaceDocumentCodec.decode(
            WorkspacePersistenceFixtures.v4WorkspaceWithMaterialDigest(segmentCount: 257)
        )
        let digest = try #require(loaded.state.materialDigests.values.first)
        let blocks = try #require(digest.preparedSnapshot?.blocks)

        #expect(blocks.count == 257)
        #expect(Set(blocks.map(\.id)).count == 257)
        #expect(try WorkspaceDocumentCodec.decode(WorkspaceDocumentCodec.encode(loaded.state)).state == loaded.state)
    }

    @Test func v4MigrationPreservesUniqueBlockIDsAtTheMaterialBoundary() throws {
        let count = MaterialDigestContentLimits.maximumMaterialBlocks
        let loaded = try WorkspaceDocumentCodec.decode(
            WorkspacePersistenceFixtures.v4WorkspaceWithMaterialDigest(segmentCount: count)
        )
        let blocks = try #require(
            loaded.state.materialDigests.values.first?.preparedSnapshot?.blocks
        )

        #expect(blocks.count == count)
        #expect(Set(blocks.map(\.id)).count == count)
    }

    @Test func v5IsRejectedByLegacyV4WriterInsteadOfBeingSilentlyDowngraded() throws {
        let encoded = try WorkspaceDocumentCodec.encode(
            try WorkspacePersistenceFixtures.workspaceWithMaterialDigests()
        )
        #expect(try JSONDecoder.workspaceDeterministic.decode(SchemaEnvelopeFixture.self, from: encoded).schemaVersion == 5)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.workspaceDeterministic.decode(LegacyWorkspaceDocumentV3V4.self, from: encoded)
        }
    }

    @Test func v4CompatibleRoundTripPreservesSucceededAwaitingAndRetryDigests() throws {
        let expected = try WorkspacePersistenceFixtures.workspaceWithMaterialDigests()
        let encoded = try WorkspaceDocumentCodec.encode(expected)
        let decoded = try WorkspaceDocumentCodec.decode(encoded)
        #expect(decoded.provenance.sourceSchema == 5)
        #expect(decoded.state == expected)
        #expect(decoded.state.materialDigests.count == 3)
        #expect(try WorkspaceDocumentCodec.encode(decoded.state) == encoded)
    }

    @Test func v4RoundTripPreservesDigestNoteWriteAfterConversion() throws {
        let fixture = try WorkspacePersistenceFixtures.workspaceWithWrittenMaterialDigest()

        let encoded = try WorkspaceDocumentCodec.encode(fixture.state)
        let decoded = try WorkspaceDocumentCodec.decode(encoded)

        #expect(decoded.state == fixture.state)
        #expect(decoded.state.materialDigests[fixture.inspirationID]?.noteWrite?.noteID == fixture.noteID)
        #expect(decoded.state.notes[fixture.noteID]?.document.blocks == [fixture.digestBlock])
    }

    @Test func v4MigrationRebindsNoteWriteToTheMigratedResultFingerprint() throws {
        let fixture = try WorkspacePersistenceFixtures.workspaceWithWrittenMaterialDigest()
        let oldFingerprint = try #require(
            fixture.state.materialDigests[fixture.inspirationID]?.noteWrite?.resultFingerprint
        )
        let v4 = try WorkspacePersistenceFixtures.v4Bytes(from: fixture.state)

        let decoded = try WorkspaceDocumentCodec.decode(v4)
        let digest = try #require(decoded.state.materialDigests[fixture.inspirationID])
        let result = try #require(digest.result)
        let migratedFingerprint = try WorkspaceChecksum.materialDigestResultFingerprint(result)

        #expect(migratedFingerprint != oldFingerprint)
        #expect(digest.noteWrite?.resultFingerprint == migratedFingerprint)
        #expect(digest.noteWrite?.noteID == fixture.noteID)
        #expect(decoded.state.notes[fixture.noteID]?.document.blocks == [fixture.digestBlock])
    }

    @Test func v4DigestNoteWriteCannotClaimAUserBlockThatIsNotInTheNote() throws {
        let fixture = try WorkspacePersistenceFixtures.workspaceWithWrittenMaterialDigest()
        var invalid = fixture.state
        invalid.notes[fixture.noteID]?.document = .empty()
        let raw = try JSONEncoder.workspaceDeterministic.encode(
            WorkspaceDocument(state: invalid)
        )

        #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try WorkspaceDocumentCodec.decode(raw)
        }
    }

    @Test func previousV4ReaderCanStillRecoverOriginalNotesAndInspirations() throws {
        let expected = try WorkspacePersistenceFixtures.workspaceWithMaterialDigests()
        let encoded = try WorkspacePersistenceFixtures.v4Bytes(from: expected)

        let legacy = try JSONDecoder.workspaceDeterministic.decode(
            LegacyWorkspaceDocumentV3V4.self,
            from: encoded
        )

        #expect(legacy.schemaVersion == 4)
        #expect(legacy.state.notes == expected.notes)
        #expect(legacy.state.inspirations == expected.inspirations)
        #expect(legacy.state.inspirationNoteLinks == expected.inspirationNoteLinks)
    }

    @Test func v1DigestWithQuoteTimestampSkewRoundTripsNotesAndInspirationsWithoutSchemaBump() throws {
        let expected = try WorkspacePersistenceFixtures.workspaceWithHistoricalV1SkewedQuote()
        try WorkspaceValidator.validate(expected)

        let encoded = try WorkspaceDocumentCodec.encode(expected)
        let decoded = try WorkspaceDocumentCodec.decode(encoded)

        #expect(decoded.provenance.sourceSchema == 5)
        #expect(decoded.provenance.sourceSchema == WorkspaceDocument.currentSchemaVersion)
        #expect(decoded.state.notes == expected.notes)
        #expect(decoded.state.inspirations == expected.inspirations)
        #expect(decoded.state.materialDigests == expected.materialDigests)
        #expect(decoded.state.inspirationNoteLinks == expected.inspirationNoteLinks)
        #expect(decoded.state == expected)

        var v2 = expected
        let inspirationID = try #require(v2.materialDigests.keys.first)
        v2.materialDigests[inspirationID]?.result?.provenance.summaryContractVersion = "summary-contract-v2"
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(v2)
        }
        #expect(throws: WorkspacePersistenceError.invalidWorkspace) {
            _ = try WorkspaceDocumentCodec.encode(v2)
        }
        let rawV2 = try JSONEncoder.workspaceDeterministic.encode(WorkspaceDocument(state: v2))
        #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try WorkspaceDocumentCodec.decode(rawV2)
        }
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

    static func v4WorkspaceWithMaterialDigest(segmentCount: Int = 2) throws -> Data {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let inspiration = try materialInspiration(index: 4, now: now)
        var state = WorkspaceState.empty(calendar: calendarState)
        state.revision = 8
        state.inspirations[inspiration.id] = inspiration
        let digest = succeededDigest(for: inspiration, now: now)
        let result = try #require(digest.result)
        let sourceTranscript = try #require(digest.preparedSnapshot).timestampedTranscript
        let transcript = segmentCount == sourceTranscript.segments.count
            ? sourceTranscript
            : TimestampedTranscript(
                segments: (0..<segmentCount).map { index in
                    TranscriptSegment(
                        startSeconds: Double(index),
                        endSeconds: Double(index + 1),
                        text: "片段\(index)"
                    )
                }
            )
        let legacyDigest = LegacyMaterialDigestV4(
            id: digest.id,
            inspirationID: digest.inspirationID,
            sourceChecksum: digest.sourceChecksum,
            currentRun: digest.currentRun,
            result: LegacyMaterialDigestResultV4(
                transcript: transcript,
                summary: LegacyInspirationSummaryV4(
                    thesis: result.summary.thesis,
                    takeaways: result.summary.takeaways,
                    chapters: [],
                    quotes: [],
                    dropped: []
                ),
                provenance: DigestProvenance(
                    modelIdentifier: result.provenance.modelIdentifier,
                    generatedAt: result.provenance.generatedAt,
                    inputFingerprint: result.provenance.inputFingerprint,
                    summaryContractVersion: "summary-contract-v2"
                ),
                completedAt: result.completedAt
            ),
            lastFailure: digest.lastFailure,
            noteWrite: digest.noteWrite,
            createdAt: digest.createdAt,
            updatedAt: digest.updatedAt
        )
        var v4State = EncodableV4WorkspaceState(state: state)
        v4State.materialDigests = [inspiration.id: legacyDigest]
        return try JSONEncoder.workspaceDeterministic.encode(
            EncodableV4WorkspaceDocument(schemaVersion: 4, state: v4State)
        )
    }

    static func v4Bytes(from state: WorkspaceState) throws -> Data {
        let document = EncodableV4WorkspaceDocument(
            schemaVersion: 4,
            state: EncodableV4WorkspaceState(state: state)
        )
        return try JSONEncoder.workspaceDeterministic.encode(document)
    }

    private static func v4Bytes(
        from digest: MaterialDigest,
        inspiration: Inspiration,
        summaryContractVersion: String,
        state: WorkspaceState
    ) throws -> Data {
        let result = try #require(digest.result)
        var migrated = state
        migrated.materialDigests = [
            inspiration.id: MaterialDigest(
                id: digest.id,
                inspirationID: digest.inspirationID,
                sourceChecksum: digest.sourceChecksum,
                currentRun: digest.currentRun,
                result: MaterialDigestResult(
                    summary: result.summary,
                    provenance: DigestProvenance(
                        modelIdentifier: result.provenance.modelIdentifier,
                        generatedAt: result.provenance.generatedAt,
                        inputFingerprint: result.provenance.inputFingerprint,
                        summaryContractVersion: summaryContractVersion
                    ),
                    completedAt: result.completedAt
                ),
                lastFailure: digest.lastFailure,
                noteWrite: digest.noteWrite,
                preparedSnapshot: digest.preparedSnapshot,
                createdAt: digest.createdAt,
                updatedAt: digest.updatedAt
            )
        ]
        return try v4Bytes(from: migrated)
    }

    static func workspaceWithMaterialDigests() throws -> WorkspaceState {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        var state = WorkspaceState.empty(calendar: calendarState)
        state.revision = 8
        let succeeded = try materialInspiration(index: 1, now: now)
        let awaiting = try materialInspiration(index: 2, now: now)
        let retrying = try materialInspiration(index: 3, now: now)
        state.inspirations = [
            succeeded.id: succeeded,
            awaiting.id: awaiting,
            retrying.id: retrying
        ]
        state.materialDigests = [
            succeeded.id: succeededDigest(for: succeeded, now: now),
            awaiting.id: awaitingDigest(for: awaiting, now: now),
            retrying.id: retryDigest(for: retrying, now: now)
        ]
        try WorkspaceValidator.validate(state)
        return state
    }

    static func workspaceWithHistoricalV1SkewedQuote() throws -> WorkspaceState {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        var state = WorkspaceState.empty(calendar: calendarState)
        state.revision = 9
        let inspiration = try materialInspiration(index: 9, now: now)
        let note = Note(
            id: NoteID(uuid(820)),
            title: "用户笔记",
            document: .init(blocks: [
                DocumentBlock(
                    id: BlockID(uuid(821)),
                    kind: .paragraph,
                    inlineContent: .plain("保留这条笔记"),
                    taskState: nil,
                    indentLevel: 0
                )
            ]),
            categoryID: categoryID,
            archivedAt: nil,
            revision: 2,
            createdAt: now,
            updatedAt: now
        )
        state.notes[note.id] = note
        state.inspirations[inspiration.id] = inspiration
        state.inspirationNoteLinks.insert(
            InspirationNoteLink(source: .live(inspiration.id), noteID: note.id, createdAt: now)
        )
        let transcript = TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 10, text: "片头预告"),
            TranscriptSegment(
                startSeconds: 10,
                endSeconds: 25,
                text: "这句话才是真正的引用原文"
            ),
            TranscriptSegment(startSeconds: 25, endSeconds: 40, text: "收尾")
        ])
        state.materialDigests[inspiration.id] = digest(
            for: inspiration,
            now: now,
            currentRun: nil,
            result: MaterialDigestResult(
                summary: InspirationSummary(
                    thesis: "核心论点",
                    takeaways: ["观点1", "观点2", "观点3"],
                    chapters: [
                        DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                        DigestChapter(startSeconds: 10, title: "主体", points: ["展开"])
                    ],
                    quotes: [
                        DigestQuote(
                            speaker: nil,
                            startSeconds: 38,
                            text: "这句话才是真正的引用原文"
                        )
                    ],
                    dropped: []
                ),
                provenance: DigestProvenance(
                    modelIdentifier: "test-model",
                    generatedAt: now,
                    inputFingerprint: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
                    summaryContractVersion: "summary-contract-v1"
                ),
                completedAt: now
            ),
            transcript: transcript
        )
        return state
    }

    static func workspaceWithWrittenMaterialDigest() throws -> (
        state: WorkspaceState,
        inspirationID: InspirationID,
        noteID: NoteID,
        digestBlock: DocumentBlock
    ) {
        let source = try workspaceWithMaterialDigests()
        let inspirationID = try #require(source.materialDigests.first(where: {
            $0.value.result != nil && $0.value.currentRun == nil
        })?.key)
        let inspiration = try #require(source.inspirations[inspirationID])
        let result = try #require(source.materialDigests[inspirationID]?.result)
        let digestBlock = DocumentBlock(
            id: BlockID(uuid(811)),
            kind: .paragraph,
            inlineContent: .plain("核心论点"),
            taskState: nil,
            indentLevel: 0
        )
        var note = Note.empty(
            id: NoteID(uuid(810)),
            categoryID: inspiration.categoryID,
            now: result.completedAt
        )
        note.title = "材料提炼"
        note.document = BlockDocument(blocks: [digestBlock])
        let reduction = try WorkspaceReducer.reduce(
            source,
            command: .convertInspirationToNote(.init(
                inspirationID: inspirationID,
                proposedNote: note,
                digestWrite: .init(
                    resultFingerprint: WorkspaceChecksum.materialDigestResultFingerprint(result),
                    blockIDs: [digestBlock.id]
                )
            )),
            now: result.completedAt
        )
        return (
            state: try #require(reduction.change?.state),
            inspirationID: inspirationID,
            noteID: note.id,
            digestBlock: digestBlock
        )
    }

    private static func materialInspiration(index: Int, now: Date) throws -> Inspiration {
        let id = InspirationID(uuid(600 + index))
        return Inspiration(
            id: id,
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7m\(index)/")!,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: nil,
            categoryID: categoryID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func succeededDigest(for inspiration: Inspiration, now: Date) -> MaterialDigest {
        digest(
            for: inspiration,
            now: now,
            currentRun: nil,
            result: succeededResult(for: inspiration, now: now)
        )
    }

    private static func awaitingDigest(for inspiration: Inspiration, now: Date) -> MaterialDigest {
        digest(
            for: inspiration,
            now: now,
            currentRun: MaterialDigestRun(
                id: MaterialDigestRunID(uuid(700)),
                stage: .awaitingModelDownloadConsent,
                startedAt: now,
                updatedAt: now
            ),
            result: nil
        )
    }

    private static func retryDigest(for inspiration: Inspiration, now: Date) -> MaterialDigest {
        digest(
            for: inspiration,
            now: now,
            currentRun: MaterialDigestRun(
                id: MaterialDigestRunID(uuid(701)),
                stage: .fetchingSource,
                startedAt: now,
                updatedAt: now
            ),
            result: succeededResult(for: inspiration, now: now)
        )
    }

    private static func digest(
        for inspiration: Inspiration,
        now: Date,
        currentRun: MaterialDigestRun?,
        result: MaterialDigestResult?,
        transcript: TimestampedTranscript? = nil
    ) -> MaterialDigest {
        let preparedSnapshot = result.map { _ in
            snapshot(
                for: inspiration,
                transcript: transcript ?? standardTranscript,
                now: now
            )
        }
        return MaterialDigest(
            id: MaterialDigestID(inspiration.id.rawValue),
            inspirationID: inspiration.id,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
            currentRun: currentRun,
            result: result,
            lastFailure: nil,
            preparedSnapshot: preparedSnapshot,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func succeededResult(for inspiration: Inspiration, now: Date) -> MaterialDigestResult {
        MaterialDigestResult(
            summary: InspirationSummary(
                thesis: "核心论点",
                takeaways: ["观点1", "观点2", "观点3"],
                chapters: [
                    DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                    DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
                ],
                quotes: [],
                dropped: []
            ),
            provenance: DigestProvenance(
                modelIdentifier: "test-model",
                generatedAt: now,
                inputFingerprint: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
                summaryContractVersion: "summary-contract-v1"
            ),
            completedAt: now
        )
    }

    private static var standardTranscript: TimestampedTranscript {
        TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
            TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
        ])
    }

    private static func snapshot(
        for inspiration: Inspiration,
        transcript: TimestampedTranscript,
        now: Date
    ) -> MaterialSnapshot {
        let blocks = transcript.segments.enumerated().map { index, segment in
            MaterialBlock(
                id: MaterialBlockID(uuid(9_100 + index)),
                role: .transcript,
                text: segment.text,
                locator: .timestamp(
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds
                ),
                confidence: nil
            )
        }
        let draft = MaterialSnapshot(
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
            contentFingerprint: "pending",
            blocks: blocks,
            coverage: .sufficient,
            provenance: .init(
                adapterIdentifier: "persistence-fixture",
                adapterVersion: "1",
                acquiredAt: now
            ),
            createdAt: now
        )
        return MaterialSnapshot(
            sourceChecksum: draft.sourceChecksum,
            contentFingerprint: try! WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
            blocks: blocks,
            coverage: draft.coverage,
            provenance: draft.provenance,
            createdAt: now
        )
    }

    private static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
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
            inspirationNoteLinks: [],
            materialDigests: [:]
        )
    }

    static func linkedTaskWorkspace(calendarTitle: String) throws -> (WorkspaceState, UUID) {
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
            document: .init(blocks: [try .task(id: blockID, text: "正文里的行动")]),
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
                inspirationNoteLinks: [],
                materialDigests: [:]
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
            inspirationNoteLinks: [],
            materialDigests: [:]
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

private struct EncodableV4WorkspaceDocument: Encodable {
    var schemaVersion: Int
    var state: EncodableV4WorkspaceState
}

private struct EncodableV4WorkspaceState: Encodable {
    var revision: Int64
    var calendar: CalendarState
    var notes: [NoteID: Note]
    var inspirations: [InspirationID: Inspiration]
    var calendarNoteRelations: CalendarNoteRelationGraph
    var taskBlockLinks: Set<TaskBlockCalendarLink>
    var inspirationNoteLinks: Set<InspirationNoteLink>
    var materialDigests: [InspirationID: LegacyMaterialDigestV4]

    init(state: WorkspaceState) {
        revision = state.revision
        calendar = state.calendar
        notes = state.notes
        inspirations = state.inspirations
        calendarNoteRelations = state.calendarNoteRelations
        taskBlockLinks = state.taskBlockLinks
        inspirationNoteLinks = state.inspirationNoteLinks
        materialDigests = state.materialDigests.mapValues { digest in
            LegacyMaterialDigestV4(
                id: digest.id,
                inspirationID: digest.inspirationID,
                sourceChecksum: digest.sourceChecksum,
                currentRun: digest.currentRun,
                result: digest.result.map { result in
                    LegacyMaterialDigestResultV4(
                        transcript: digest.preparedSnapshot!.timestampedTranscript,
                        summary: LegacyInspirationSummaryV4(
                            thesis: result.summary.thesis,
                            takeaways: result.summary.takeaways,
                            chapters: result.summary.chapters.map {
                                LegacyDigestChapterV4(
                                    startSeconds: $0.startSeconds,
                                    title: $0.title,
                                    points: $0.points
                                )
                            },
                            quotes: result.summary.quotes.map {
                                LegacyDigestQuoteV4(
                                    speaker: $0.speaker,
                                    startSeconds: $0.startSeconds,
                                    text: $0.text
                                )
                            },
                            dropped: result.summary.dropped
                        ),
                        provenance: result.provenance,
                        completedAt: result.completedAt
                    )
                },
                lastFailure: digest.lastFailure,
                noteWrite: digest.noteWrite,
                createdAt: digest.createdAt,
                updatedAt: digest.updatedAt
            )
        }
    }
}

private struct LegacyWorkspaceStateV3V4: Codable, Equatable {
    var revision: Int64
    var calendar: CalendarState
    var notes: [NoteID: Note]
    var inspirations: [InspirationID: Inspiration]
    var calendarNoteRelations: CalendarNoteRelationGraph
    var taskBlockLinks: Set<TaskBlockCalendarLink>
    var inspirationNoteLinks: Set<InspirationNoteLink>

    init(state: WorkspaceState) {
        revision = state.revision
        calendar = state.calendar
        notes = state.notes
        inspirations = state.inspirations
        calendarNoteRelations = state.calendarNoteRelations
        taskBlockLinks = state.taskBlockLinks
        inspirationNoteLinks = state.inspirationNoteLinks
    }
}

private struct LegacyWorkspaceDocumentV3V4: Codable, Equatable {
    var schemaVersion: Int
    var state: LegacyWorkspaceStateV3V4

    init(schemaVersion: Int, state: LegacyWorkspaceStateV3V4) {
        self.schemaVersion = schemaVersion
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 3 || schemaVersion == 4 else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "legacy V3/V4 reader rejects schema \(schemaVersion)"
                )
            )
        }
        state = try container.decode(LegacyWorkspaceStateV3V4.self, forKey: .state)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case state
    }
}

private struct SchemaEnvelopeFixture: Decodable {
    let schemaVersion: Int
}
