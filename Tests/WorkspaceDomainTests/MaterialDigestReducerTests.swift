import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("MaterialDigestReducerTests")
struct MaterialDigestReducerTests {
    @Test func savedSnapshotSurvivesSummaryFailureAndReuseRetrySkipsRefresh() throws {
        var fixture = MaterialDigestReducerV3Fixture()
        try fixture.start(mode: .refreshSource)
        try fixture.save(snapshot: fixture.snapshot)
        try fixture.fail(code: .summarizationFailed)
        #expect(fixture.digest.pendingSnapshot == fixture.snapshot)
        try fixture.start(mode: .reusePreparedSnapshot)
        #expect(fixture.digest.pendingSnapshot == fixture.snapshot)
        #expect(fixture.digest.currentRun?.stage == .preparingSummary)
    }

    @Test func refreshKeepsAcceptedSnapshotAndOldV3ResultUntilReplacementSucceeds() throws {
        var fixture = try MaterialDigestReducerV3Fixture.succeeded()
        let oldResult = fixture.digest.result
        let acceptedSnapshot = fixture.digest.preparedSnapshot
        #expect(oldResult?.provenance.summaryContractVersion == MaterialDigestSummaryContract.v3)
        try fixture.start(mode: .refreshSource)
        #expect(fixture.digest.preparedSnapshot == acceptedSnapshot)
        #expect(fixture.digest.pendingSnapshot == nil)
        #expect(fixture.digest.result == oldResult)
    }

    @Test func failedRefreshKeepsOldResultAndRetriesThePersistedCandidate() throws {
        var fixture = try MaterialDigestReducerV3Fixture.succeeded()
        let oldResult = try #require(fixture.digest.result)
        let acceptedSnapshot = try #require(fixture.digest.preparedSnapshot)
        let refreshedSnapshot = try fixture.snapshot(replacingBodyWith: "刷新后的主体")

        try fixture.start(mode: .refreshSource)
        try fixture.save(snapshot: refreshedSnapshot)
        #expect(fixture.digest.preparedSnapshot == acceptedSnapshot)
        #expect(fixture.digest.pendingSnapshot == refreshedSnapshot)
        #expect(fixture.digest.result == oldResult)

        try fixture.fail(code: .summarizationFailed)
        #expect(fixture.digest.preparedSnapshot == acceptedSnapshot)
        #expect(fixture.digest.pendingSnapshot == refreshedSnapshot)
        #expect(fixture.digest.result == oldResult)

        try fixture.start(mode: .reusePreparedSnapshot)
        #expect(fixture.digest.currentRun?.stage == .preparingSummary)
        try fixture.advance(to: .summarizing)
        try fixture.complete(summary: fixture.summary(for: refreshedSnapshot))

        #expect(fixture.digest.preparedSnapshot == refreshedSnapshot)
        #expect(fixture.digest.pendingSnapshot == nil)
        #expect(fixture.digest.result?.contentFingerprint == refreshedSnapshot.contentFingerprint)
        #expect(fixture.digest.result != oldResult)
    }

    @Test func startCreatesFetchingRunForSupportedURLInspiration() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let digest = try #require(started.materialDigests[fixture.inspiration.id])
        #expect(digest.id == fixture.digestID)
        #expect(digest.inspirationID == fixture.inspiration.id)
        #expect(digest.sourceChecksum == fixture.sourceChecksum)
        #expect(digest.currentRun?.id == fixture.runID)
        #expect(digest.currentRun?.stage == .resolvingSource)
        #expect(digest.currentRun?.startedAt == fixture.now)
        #expect(digest.currentRun?.updatedAt == fixture.now)
        #expect(digest.result == nil)
        #expect(digest.lastFailure == nil)
        #expect(started.inspirations[fixture.inspiration.id] == fixture.inspiration)
    }

    @Test func completeRequiresExactRunAndSourceAndAtomicallyReplacesResult() throws {
        let fixture = MaterialDigestReducerFixture()
        let summarizing = try fixture.summarizingState()
        let completed = try fixture.reduce(
            .completeMaterialDigest(fixture.completePayload),
            from: summarizing
        )
        let digest = try #require(completed.materialDigests[fixture.inspiration.id])
        #expect(digest.currentRun == nil)
        #expect(digest.result == fixture.result)
        #expect(digest.lastFailure == nil)
        #expect(completed.inspirations[fixture.inspiration.id]?.rawURL == fixture.inspiration.rawURL)
    }

    @Test func allowedStageGraphFollowsCaptionAudioAndModelPaths() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let fetching = try fixture.reduce(fixture.advance(to: .fetchingSource), from: started)

        let extracting = try fixture.reduce(
            fixture.advance(to: .extractingText),
            from: fetching
        )
        let prepared = try fixture.reduce(
            fixture.advance(to: .preparingSummary),
            from: extracting
        )
        let captionPath = try fixture.reduce(
            fixture.advance(to: .summarizing),
            from: prepared
        )
        #expect(captionPath.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .summarizing)

        let transcribing = try fixture.reduce(
            fixture.advance(to: .transcribing),
            from: fetching
        )
        #expect(transcribing.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .transcribing)
        let awaiting = try fixture.reduce(
            fixture.advance(to: .awaitingModelDownloadConsent),
            from: transcribing
        )
        #expect(awaiting.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .awaitingModelDownloadConsent)
        let downloading = try fixture.reduce(
            fixture.advance(to: .downloadingModel),
            from: awaiting
        )
        #expect(downloading.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .downloadingModel)
        let refetch = try fixture.reduce(
            fixture.advance(to: .fetchingSource),
            from: downloading
        )
        #expect(refetch.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .fetchingSource)

        let preparedFromTranscript = try fixture.reduce(
            fixture.advance(to: .preparingSummary),
            from: transcribing
        )
        let summarizing = try fixture.reduce(
            fixture.advance(to: .summarizing),
            from: preparedFromTranscript
        )
        #expect(summarizing.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .summarizing)
    }

    @Test func illegalStageJumpsAreRejectedWithoutChangingState() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        #expect(throws: WorkspaceReducerError.invalidMaterialDigestStage) {
            _ = try fixture.reduce(fixture.advance(to: .downloadingModel), from: started)
        }
        #expect(throws: WorkspaceReducerError.invalidMaterialDigestStage) {
            _ = try fixture.reduce(fixture.advance(to: .summarizing), from: started)
        }
        let fetching = try fixture.reduce(fixture.advance(to: .fetchingSource), from: started)
        let transcribing = try fixture.reduce(fixture.advance(to: .transcribing), from: fetching)
        #expect(throws: WorkspaceReducerError.invalidMaterialDigestStage) {
            _ = try fixture.reduce(fixture.advance(to: .fetchingSource), from: transcribing)
        }
        #expect(started.revision == fixture.workspace.revision + 1)
    }

    @Test func startWhileRunningReturnsAlreadyRunning() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let again = try fixture.outcome(.startMaterialDigest(fixture.startPayload), from: started)
        #expect(again == .noChange(.materialDigestAlreadyRunning))
        #expect(started.materialDigests[fixture.inspiration.id]?.currentRun?.id == fixture.runID)
    }

    @Test func staleRunAndSourceCompleteAreRejected() throws {
        let fixture = MaterialDigestReducerFixture()
        let summarizing = try fixture.summarizingState()

        let staleRun = CompleteMaterialDigestPayload(
            expectation: MaterialDigestRunExpectation(
                inspirationID: fixture.inspiration.id,
                runID: fixture.retryRunID,
                sourceChecksum: fixture.sourceChecksum
            ),
            expectedContentFingerprint: fixture.snapshot.contentFingerprint,
            summary: fixture.summary,
            provenance: fixture.provenance
        )
        #expect(try fixture.outcome(.completeMaterialDigest(staleRun), from: summarizing) == .noChange(.staleMaterialDigestRun))

        let staleSource = CompleteMaterialDigestPayload(
            expectation: MaterialDigestRunExpectation(
                inspirationID: fixture.inspiration.id,
                runID: fixture.runID,
                sourceChecksum: "stale-source"
            ),
            expectedContentFingerprint: fixture.snapshot.contentFingerprint,
            summary: fixture.summary,
            provenance: fixture.provenance
        )
        #expect(try fixture.outcome(.completeMaterialDigest(staleSource), from: summarizing) == .noChange(.staleMaterialDigestSource))
        #expect(summarizing.materialDigests[fixture.inspiration.id]?.result == nil)
    }

    @Test func cancelThenLateCompleteDoesNotWriteResult() throws {
        let fixture = MaterialDigestReducerFixture()
        let summarizing = try fixture.summarizingState()
        let cancelled = try fixture.reduce(.cancelMaterialDigest(fixture.expectation), from: summarizing)
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.currentRun == nil)
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .cancelled)
        #expect(try fixture.outcome(.completeMaterialDigest(fixture.completePayload), from: cancelled) == .noChange(.materialDigestNotRunning))
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.result == nil)
        #expect(cancelled.inspirations[fixture.inspiration.id] == fixture.inspiration)
    }

    @Test func retryKeepsPreviousResultAndRejectsTheOldFailure() throws {
        let fixture = MaterialDigestReducerFixture()
        let summarizing = try fixture.summarizingState()
        let succeeded = try fixture.reduce(.completeMaterialDigest(fixture.completePayload), from: summarizing)
        let retryStart = StartMaterialDigestPayload(
            inspirationID: fixture.inspiration.id,
            digestID: MaterialDigestID(),
            runID: fixture.retryRunID,
            expectedSourceChecksum: fixture.sourceChecksum
        )
        let retrying = try fixture.reduce(.startMaterialDigest(retryStart), from: succeeded, now: fixture.later)
        let digest = try #require(retrying.materialDigests[fixture.inspiration.id])
        #expect(digest.id == fixture.digestID)
        #expect(digest.result == fixture.result)
        #expect(digest.currentRun?.id == fixture.retryRunID)
        #expect(digest.lastFailure == nil)

        let lateOldFailure = FailMaterialDigestPayload(
            expectation: fixture.expectation,
            code: .summarizationFailed,
            userMessage: "摘要失败，原始链接仍然保留。"
        )
        #expect(try fixture.outcome(.failMaterialDigest(lateOldFailure), from: retrying) == .noChange(.staleMaterialDigestRun))
        #expect(retrying.materialDigests[fixture.inspiration.id]?.result == fixture.result)
    }

    @Test func failureAndCancelPreservePreviousSuccessfulResult() throws {
        let fixture = MaterialDigestReducerFixture()
        let succeeded = try fixture.succeededState()
        let retrying = try fixture.reduce(
            .startMaterialDigest(StartMaterialDigestPayload(
                inspirationID: fixture.inspiration.id,
                digestID: fixture.digestID,
                runID: fixture.retryRunID,
                expectedSourceChecksum: fixture.sourceChecksum
            )),
            from: succeeded,
            now: fixture.later
        )
        let failed = try fixture.reduce(
            .failMaterialDigest(.init(
                expectation: MaterialDigestRunExpectation(
                    inspirationID: fixture.inspiration.id,
                    runID: fixture.retryRunID,
                    sourceChecksum: fixture.sourceChecksum
                ),
                code: .sourceUnavailable,
                userMessage: "暂时无法获取材料，原始链接仍然保留。"
            )),
            from: retrying,
            now: fixture.later
        )
        #expect(failed.materialDigests[fixture.inspiration.id]?.result == fixture.result)
        #expect(failed.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .sourceUnavailable)
        #expect(failed.inspirations[fixture.inspiration.id] == fixture.inspiration)

        let retryingAgain = try fixture.reduce(
            .startMaterialDigest(StartMaterialDigestPayload(
                inspirationID: fixture.inspiration.id,
                digestID: fixture.digestID,
                runID: fixture.retryRunID,
                expectedSourceChecksum: fixture.sourceChecksum
            )),
            from: failed,
            now: fixture.later
        )
        let cancelled = try fixture.reduce(
            .cancelMaterialDigest(MaterialDigestRunExpectation(
                inspirationID: fixture.inspiration.id,
                runID: fixture.retryRunID,
                sourceChecksum: fixture.sourceChecksum
            )),
            from: retryingAgain,
            now: fixture.later
        )
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.result == fixture.result)
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .cancelled)
    }

    @Test func markInterruptedKeepsAwaitingConsentAndInterruptsOtherStages() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let fetching = try fixture.reduce(fixture.advance(to: .fetchingSource), from: started)
        let awaiting = try fixture.reduce(
            fixture.advance(to: .awaitingModelDownloadConsent),
            from: fetching
        )
        let kept = try fixture.outcome(
            .markInterruptedMaterialDigest(fixture.expectation),
            from: awaiting
        )
        #expect(kept == .noChange(.identical))
        #expect(awaiting.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .awaitingModelDownloadConsent)

        let fetchingInterrupted = try fixture.reduce(
            .markInterruptedMaterialDigest(fixture.expectation),
            from: started
        )
        #expect(fetchingInterrupted.materialDigests[fixture.inspiration.id]?.currentRun == nil)
        #expect(fetchingInterrupted.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .interrupted)
        #expect(fetchingInterrupted.materialDigests[fixture.inspiration.id]?.result == nil)
    }

    @Test func writingAndUpdatingDigestPreservesUserBlocksAndIsIdempotent() throws {
        let fixture = MaterialDigestReducerFixture()
        let succeeded = try fixture.succeededState()
        let noteID = NoteID()
        let userBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("这是用户自己写的内容"),
            taskState: nil,
            indentLevel: 0
        )
        var note = Note.empty(id: noteID, categoryID: fixture.inspiration.categoryID, now: fixture.now)
        note.title = "材料笔记"
        note.document = BlockDocument(blocks: [userBlock])
        let converted = try fixture.reduce(
            .convertInspirationToNote(.init(
                inspirationID: fixture.inspiration.id,
                proposedNote: note
            )),
            from: succeeded
        )

        let firstResult = try #require(converted.materialDigests[fixture.inspiration.id]?.result)
        let firstFingerprint = try WorkspaceChecksum.materialDigestResultFingerprint(firstResult)
        let firstDigestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("第一版摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let firstWrite = try fixture.reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(converted.notes[noteID]?.revision),
                resultFingerprint: firstFingerprint,
                proposedBlocks: [firstDigestBlock]
            )),
            from: converted
        )
        #expect(firstWrite.notes[noteID]?.document.blocks == [userBlock, firstDigestBlock])
        #expect(try fixture.outcome(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(firstWrite.notes[noteID]?.revision),
                resultFingerprint: firstFingerprint,
                proposedBlocks: [DocumentBlock(
                    id: BlockID(),
                    kind: .paragraph,
                    inlineContent: .plain("不该重复写入"),
                    taskState: nil,
                    indentLevel: 0
                )]
            )),
            from: firstWrite
        ) == .noChange(.materialDigestAlreadyWritten(noteID)))

        var retried = firstWrite
        retried.materialDigests[fixture.inspiration.id]?.result?.summary.thesis = "更新后的核心论点"
        let updatedResult = try #require(retried.materialDigests[fixture.inspiration.id]?.result)
        let updatedFingerprint = try WorkspaceChecksum.materialDigestResultFingerprint(updatedResult)
        let updatedDigestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("第二版摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let updated = try fixture.reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(retried.notes[noteID]?.revision),
                resultFingerprint: updatedFingerprint,
                proposedBlocks: [updatedDigestBlock]
            )),
            from: retried
        )
        #expect(updated.notes[noteID]?.document.blocks == [userBlock, updatedDigestBlock])
        #expect(updated.notes[noteID]?.document.blocks.contains(firstDigestBlock) == false)
        #expect(updated.materialDigests[fixture.inspiration.id]?.noteWrite?.blockIDs == [updatedDigestBlock.id])
    }

    @Test func deletingManagedDigestBlocksClearsNoteWriteAndSavesTheNote() throws {
        let fixture = MaterialDigestReducerFixture()
        let written = try fixture.noteWithWrittenDigest()
        let noteID = written.noteID
        let digestBlockID = written.digestBlock.id
        let userBlock = written.userBlock
        let base = try #require(written.state.notes[noteID])
        var submitted = base
        submitted.document.blocks.removeAll { $0.id == digestBlockID }
        submitted.updatedAt = fixture.later

        let saved = try fixture.reduce(
            .updateNote(try fixture.noteSubmission(base: base, submitted: submitted)),
            from: written.state,
            now: fixture.later
        )
        #expect(saved.notes[noteID]?.document.blocks == [userBlock])
        #expect(saved.materialDigests[fixture.inspiration.id]?.noteWrite == nil)
        #expect(saved.materialDigests[fixture.inspiration.id]?.result != nil)
    }

    @Test func rewritingDigestDoesNotDeleteUserModifiedFormerDigestBlocks() throws {
        let fixture = MaterialDigestReducerFixture()
        let written = try fixture.noteWithWrittenDigest()
        let noteID = written.noteID
        let base = try #require(written.state.notes[noteID])
        var submitted = base
        submitted.document.blocks = submitted.document.blocks.map { block in
            guard block.id == written.digestBlock.id else { return block }
            var edited = block
            edited.inlineContent = .plain("用户改过的摘要段落")
            return edited
        }
        submitted.updatedAt = fixture.later
        let edited = try fixture.reduce(
            .updateNote(try fixture.noteSubmission(base: base, submitted: submitted)),
            from: written.state,
            now: fixture.later
        )
        #expect(edited.materialDigests[fixture.inspiration.id]?.noteWrite == nil)
        #expect(
            edited.notes[noteID]?.document.blocks.map { $0.inlineContent.spans.map(\.text).joined() }
                == ["这是用户自己写的内容", "用户改过的摘要段落"]
        )

        var retried = edited
        retried.materialDigests[fixture.inspiration.id]?.result?.summary.thesis = "新一轮核心论点"
        let updatedResult = try #require(retried.materialDigests[fixture.inspiration.id]?.result)
        let newDigestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("新一轮摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let rewritten = try fixture.reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(retried.notes[noteID]?.revision),
                resultFingerprint: try WorkspaceChecksum.materialDigestResultFingerprint(updatedResult),
                proposedBlocks: [newDigestBlock]
            )),
            from: retried
        )
        #expect(
            rewritten.notes[noteID]?.document.blocks.map { $0.inlineContent.spans.map(\.text).joined() }
                == ["这是用户自己写的内容", "用户改过的摘要段落", "新一轮摘要"]
        )
        #expect(rewritten.materialDigests[fixture.inspiration.id]?.noteWrite?.blockIDs == [newDigestBlock.id])
    }
}

struct MaterialDigestReducerV3Fixture {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let later = Date(timeIntervalSince1970: 1_800_100_060)
    let digestID = MaterialDigestID(UUID(uuidString: "00000000-0000-0000-0000-00000000d301")!)
    let runID = MaterialDigestRunID(UUID(uuidString: "00000000-0000-0000-0000-00000000d302")!)
    let retryRunID = MaterialDigestRunID(UUID(uuidString: "00000000-0000-0000-0000-00000000d303")!)
    let inspiration: Inspiration
    var workspace: WorkspaceState
    let snapshot: MaterialSnapshot

    init() {
        let inner = MaterialDigestReducerFixture()
        inspiration = inner.inspiration
        workspace = inner.workspace
        snapshot = inner.snapshot
    }

    var digest: MaterialDigest {
        workspace.materialDigests[inspiration.id]!
    }

    var sourceChecksum: String {
        WorkspaceChecksum.inspirationSourceChecksum(inspiration)
    }

    mutating func start(mode: MaterialDigestStartMode) throws {
        let runID = workspace.materialDigests[inspiration.id]?.currentRun == nil ? self.runID : retryRunID
        workspace = try MaterialDigestReducerFixture().reduce(
            .startMaterialDigest(
                StartMaterialDigestPayload(
                    inspirationID: inspiration.id,
                    digestID: digestID,
                    runID: runID,
                    expectedSourceChecksum: sourceChecksum,
                    mode: mode
                )
            ),
            from: workspace,
            now: workspace.materialDigests[inspiration.id] == nil ? now : later
        )
    }

    mutating func save(snapshot: MaterialSnapshot) throws {
        let run = try #require(digest.currentRun)
        workspace = try MaterialDigestReducerFixture().reduce(
            .saveMaterialSnapshot(
                .init(
                    expectation: MaterialDigestRunExpectation(
                        inspirationID: inspiration.id,
                        runID: run.id,
                        sourceChecksum: sourceChecksum
                    ),
                    snapshot: snapshot
                )
            ),
            from: workspace,
            now: later
        )
    }

    mutating func fail(code: MaterialDigestFailure.Code) throws {
        let run = try #require(digest.currentRun)
        workspace = try MaterialDigestReducerFixture().reduce(
            .failMaterialDigest(
                .init(
                    expectation: MaterialDigestRunExpectation(
                        inspirationID: inspiration.id,
                        runID: run.id,
                        sourceChecksum: sourceChecksum
                    ),
                    code: code,
                    userMessage: "摘要失败，原始链接仍然保留。"
                )
            ),
            from: workspace,
            now: later
        )
    }

    mutating func advance(to stage: MaterialDigestStage) throws {
        let run = try #require(digest.currentRun)
        workspace = try MaterialDigestReducerFixture().reduce(
            .advanceMaterialDigestStage(
                .init(
                    expectation: .init(
                        inspirationID: inspiration.id,
                        runID: run.id,
                        sourceChecksum: sourceChecksum
                    ),
                    stage: stage
                )
            ),
            from: workspace,
            now: later
        )
    }

    mutating func complete(summary: InspirationSummary) throws {
        let run = try #require(digest.currentRun)
        let snapshot = try #require(digest.pendingSnapshot)
        workspace = try MaterialDigestReducerFixture().reduce(
            .completeMaterialDigest(
                .init(
                    expectation: .init(
                        inspirationID: inspiration.id,
                        runID: run.id,
                        sourceChecksum: sourceChecksum
                    ),
                    expectedContentFingerprint: snapshot.contentFingerprint,
                    summary: summary,
                    provenance: .init(
                        modelIdentifier: "test/v3",
                        generatedAt: .distantPast,
                        inputFingerprint: sourceChecksum,
                        summaryContractVersion: MaterialDigestSummaryContract.v3
                    )
                )
            ),
            from: workspace,
            now: later
        )
    }

    func snapshot(replacingBodyWith text: String) throws -> MaterialSnapshot {
        var blocks = snapshot.blocks
        blocks[1].text = text
        let draft = MaterialSnapshot(
            sourceChecksum: sourceChecksum,
            contentFingerprint: "pending",
            blocks: blocks,
            coverage: snapshot.coverage,
            provenance: snapshot.provenance,
            createdAt: later
        )
        return MaterialSnapshot(
            sourceChecksum: sourceChecksum,
            contentFingerprint: try WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
            blocks: blocks,
            coverage: draft.coverage,
            provenance: draft.provenance,
            createdAt: draft.createdAt
        )
    }

    func summary(for snapshot: MaterialSnapshot) -> InspirationSummary {
        let blockIDs = snapshot.blocks.map(\.id)
        return InspirationSummary(
            thesis: DigestClaim(text: "核心论点", evidenceBlockIDs: [blockIDs[0]]),
            takeaways: [DigestClaim(text: "主体观点", evidenceBlockIDs: [blockIDs[1]])],
            chapters: [
                DigestChapter(
                    title: "主体",
                    anchorBlockID: blockIDs[1],
                    points: [DigestClaim(text: "展开", evidenceBlockIDs: [blockIDs[1]])]
                )
            ],
            quotes: [DigestQuote(speaker: nil, text: snapshot.blocks[1].text, evidenceBlockID: blockIDs[1])],
            dropped: []
        )
    }

    static func succeeded() throws -> MaterialDigestReducerV3Fixture {
        var fixture = MaterialDigestReducerV3Fixture()
        let summary = fixture.summary(for: fixture.snapshot)
        let result = MaterialDigestResult(
            summary: summary,
            provenance: DigestProvenance(
                modelIdentifier: "test/v3",
                generatedAt: fixture.now,
                inputFingerprint: fixture.sourceChecksum,
                summaryContractVersion: MaterialDigestSummaryContract.v3
            ),
            completedAt: fixture.now,
            contentFingerprint: fixture.snapshot.contentFingerprint
        )
        fixture.workspace.materialDigests[fixture.inspiration.id] = MaterialDigest(
            id: fixture.digestID,
            inspirationID: fixture.inspiration.id,
            sourceChecksum: fixture.sourceChecksum,
            currentRun: nil,
            result: result,
            lastFailure: nil,
            preparedSnapshot: fixture.snapshot,
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        try WorkspaceValidator.validate(fixture.workspace)
        return fixture
    }
}

struct MaterialDigestReducerFixture {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let later = Date(timeIntervalSince1970: 1_800_100_060)
    let digestID = MaterialDigestID(UUID(uuidString: "00000000-0000-0000-0000-00000000d101")!)
    let runID = MaterialDigestRunID(UUID(uuidString: "00000000-0000-0000-0000-00000000d102")!)
    let retryRunID = MaterialDigestRunID(UUID(uuidString: "00000000-0000-0000-0000-00000000d103")!)
    let inspiration: Inspiration
    let workspace: WorkspaceState

    init() {
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-00000000d100")!
        inspiration = Inspiration(
            id: InspirationID(UUID(uuidString: "00000000-0000-0000-0000-00000000d110")!),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: nil,
            categoryID: uncategorizedID,
            lifecycle: .active,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var state = WorkspaceState.empty(
            calendar: CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        )
        state.revision = 4
        state.inspirations[inspiration.id] = inspiration
        workspace = state
    }

    var sourceChecksum: String {
        WorkspaceChecksum.inspirationSourceChecksum(inspiration)
    }

    var startPayload: StartMaterialDigestPayload {
        StartMaterialDigestPayload(
            inspirationID: inspiration.id,
            digestID: digestID,
            runID: runID,
            expectedSourceChecksum: sourceChecksum
        )
    }

    var expectation: MaterialDigestRunExpectation {
        MaterialDigestRunExpectation(
            inspirationID: inspiration.id,
            runID: runID,
            sourceChecksum: sourceChecksum
        )
    }

    var transcript: TimestampedTranscript {
        TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
            TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
        ])
    }

    var summary: InspirationSummary {
        InspirationSummary(
            thesis: "核心论点",
            takeaways: ["观点1", "观点2", "观点3"],
            chapters: [
                DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
            ],
            quotes: [DigestQuote(speaker: nil, startSeconds: 8, text: "主体")],
            dropped: ["片头"]
        )
    }

    var provenance: DigestProvenance {
        DigestProvenance(
            modelIdentifier: "test-model",
            generatedAt: Date(timeIntervalSince1970: 0),
            inputFingerprint: sourceChecksum,
            summaryContractVersion: "summary-contract-v1"
        )
    }

    var snapshot: MaterialSnapshot {
        let blocks = [
            MaterialBlock(
                id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000d201")!),
                role: .transcript,
                text: "开场",
                locator: .timestamp(startSeconds: 0, endSeconds: 8),
                confidence: nil
            ),
            MaterialBlock(
                id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000d202")!),
                role: .transcript,
                text: "主体",
                locator: .timestamp(startSeconds: 8, endSeconds: 20),
                confidence: nil
            )
        ]
        let draft = MaterialSnapshot(
            sourceChecksum: sourceChecksum,
            contentFingerprint: "pending",
            blocks: blocks,
            coverage: .sufficient,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "test-adapter",
                adapterVersion: "1",
                acquiredAt: now
            ),
            createdAt: now
        )
        let fingerprint = (try? WorkspaceChecksum.materialSnapshotContentFingerprint(draft)) ?? "pending"
        return MaterialSnapshot(
            sourceChecksum: sourceChecksum,
            contentFingerprint: fingerprint,
            blocks: blocks,
            coverage: draft.coverage,
            provenance: draft.provenance,
            createdAt: now
        )
    }

    var completePayload: CompleteMaterialDigestPayload {
        CompleteMaterialDigestPayload(
            expectation: expectation,
            expectedContentFingerprint: snapshot.contentFingerprint,
            summary: summary,
            provenance: provenance
        )
    }

    var result: MaterialDigestResult {
        var stamped = provenance
        stamped.generatedAt = now
        return MaterialDigestResult(
            summary: summary,
            provenance: stamped,
            completedAt: now,
            contentFingerprint: snapshot.contentFingerprint
        )
    }

    func advancePayload(
        to stage: MaterialDigestStage,
        runID: MaterialDigestRunID? = nil,
        checksum: String? = nil
    ) -> AdvanceMaterialDigestStagePayload {
        AdvanceMaterialDigestStagePayload(
            expectation: MaterialDigestRunExpectation(
                inspirationID: inspiration.id,
                runID: runID ?? self.runID,
                sourceChecksum: checksum ?? sourceChecksum
            ),
            stage: stage
        )
    }

    func advance(
        to stage: MaterialDigestStage,
        runID: MaterialDigestRunID? = nil,
        checksum: String? = nil
    ) -> WorkspaceCommand {
        .advanceMaterialDigestStage(advancePayload(to: stage, runID: runID, checksum: checksum))
    }

    func reduce(
        _ command: WorkspaceCommand,
        from state: WorkspaceState? = nil,
        now clock: Date? = nil
    ) throws -> WorkspaceState {
        let outcome = try WorkspaceReducer.reduce(
            state ?? workspace,
            command: command,
            now: clock ?? now
        )
        return try #require(outcome.change).state
    }

    func outcome(
        _ command: WorkspaceCommand,
        from state: WorkspaceState? = nil,
        now clock: Date? = nil
    ) throws -> WorkspaceReductionResult {
        try WorkspaceReducer.reduce(state ?? workspace, command: command, now: clock ?? now)
    }

    func summarizingState() throws -> WorkspaceState {
        let started = try reduce(.startMaterialDigest(startPayload))
        let saved = try reduce(
            .saveMaterialSnapshot(.init(expectation: expectation, snapshot: snapshot)),
            from: started
        )
        return try reduce(advance(to: .summarizing), from: saved)
    }

    func succeededState() throws -> WorkspaceState {
        try reduce(.completeMaterialDigest(completePayload), from: summarizingState())
    }

    struct WrittenDigestNote {
        var state: WorkspaceState
        var noteID: NoteID
        var userBlock: DocumentBlock
        var digestBlock: DocumentBlock
    }

    func noteWithWrittenDigest() throws -> WrittenDigestNote {
        let succeeded = try succeededState()
        let noteID = NoteID()
        let userBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("这是用户自己写的内容"),
            taskState: nil,
            indentLevel: 0
        )
        var note = Note.empty(id: noteID, categoryID: inspiration.categoryID, now: now)
        note.title = "材料笔记"
        note.document = BlockDocument(blocks: [userBlock])
        let converted = try reduce(
            .convertInspirationToNote(.init(
                inspirationID: inspiration.id,
                proposedNote: note
            )),
            from: succeeded
        )
        let digestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("第一版摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let result = try #require(converted.materialDigests[inspiration.id]?.result)
        let written = try reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(converted.notes[noteID]?.revision),
                resultFingerprint: try WorkspaceChecksum.materialDigestResultFingerprint(result),
                proposedBlocks: [digestBlock]
            )),
            from: converted
        )
        return WrittenDigestNote(
            state: written,
            noteID: noteID,
            userBlock: userBlock,
            digestBlock: digestBlock
        )
    }

    func noteSubmission(base: Note, submitted: Note) throws -> NoteDraftSubmission {
        var fields = Set<NoteDraftField>()
        if base.title != submitted.title { fields.insert(.title) }
        if base.document != submitted.document { fields.insert(.document) }
        if base.categoryID != submitted.categoryID { fields.insert(.categoryID) }
        if base.archivedAt != submitted.archivedAt { fields.insert(.archivedAt) }
        return NoteDraftSubmission(
            noteID: base.id,
            editSessionID: UUID(uuidString: "00000000-0000-0000-0000-00000000d120")!,
            baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: 1,
            snapshot: submitted,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submitted),
            modifiedFields: fields,
            linkedBlockDeletionDispositions: [:]
        )
    }
}
