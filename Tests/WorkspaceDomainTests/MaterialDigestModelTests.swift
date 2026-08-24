import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("MaterialDigestModelTests")
struct MaterialDigestModelTests {
    @Test func v3ResultPersistsOnlyFingerprintSummaryAndProvenance() throws {
        let state = MaterialDigestV3Fixture.workspace()
        let result = try #require(state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.result)
        let encoded = try JSONEncoder.workspaceDeterministic.encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["transcript"] == nil)
        #expect(object["contentFingerprint"] as? String == result.contentFingerprint)
        #expect(object["summary"] != nil)
        #expect(object["provenance"] != nil)
        #expect(object["completedAt"] != nil)
    }

    @Test func validatorRejectsDanglingOrMismatchedDigest() throws {
        var state = MaterialDigestFixture.workspace()
        let inspiration = try #require(state.inspirations.values.first)
        let digest = MaterialDigestFixture.succeeded(for: inspiration)
        state.materialDigests[InspirationID()] = digest
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsDigestWhoseInspirationIDDoesNotMatchTheKey() throws {
        var state = MaterialDigestFixture.workspace()
        let inspiration = try #require(state.inspirations.values.first)
        var digest = MaterialDigestFixture.succeeded(for: inspiration)
        let foreignID = InspirationID()
        digest = MaterialDigest(
            id: digest.id,
            inspirationID: foreignID,
            sourceChecksum: digest.sourceChecksum,
            currentRun: digest.currentRun,
            result: digest.result,
            lastFailure: digest.lastFailure,
            createdAt: digest.createdAt,
            updatedAt: digest.updatedAt
        )
        state.materialDigests[inspiration.id] = digest
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorAcceptsThreeToSevenTakeawaysAndOrderedSegments() throws {
        let three = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        try WorkspaceValidator.validate(three)
        let seven = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 7)
        try WorkspaceValidator.validate(seven)
    }

    @Test func validatorAcceptsOneTakeaway() throws {
        try WorkspaceValidator.validate(
            MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 1)
        )
    }

    @Test func validatorRejectsZeroOrEightTakeaways() throws {
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(
                MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 0)
            )
        }
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(
                MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 8)
            )
        }
    }

    @Test func validatorRejectsChapterOrQuotePastTranscriptEndOnV2() throws {
        var chapterState = MaterialDigestFixture.workspaceWithSucceededDigest(
            takeawayCount: 1,
            contractVersion: "summary-contract-v2"
        )
        let inspirationID = try #require(chapterState.inspirations.keys.first)
        chapterState.materialDigests[inspirationID]?.result?.summary.chapters = [
            DigestChapter(startSeconds: 20.6, title: "越界", points: ["点"])
        ]
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(chapterState)
        }

        var quoteState = MaterialDigestFixture.workspaceWithSucceededDigest(
            takeawayCount: 1,
            contractVersion: "summary-contract-v2"
        )
        quoteState.materialDigests[inspirationID]?.result?.summary.quotes = [
            DigestQuote(speaker: nil, startSeconds: 20.6, text: "主体")
        ]
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(quoteState)
        }
    }

    @Test func validatorRejectsQuoteTextOrSpeakerMissingFromTranscriptOnV2() throws {
        var textState = MaterialDigestFixture.workspaceWithSucceededDigest(
            takeawayCount: 1,
            contractVersion: "summary-contract-v2"
        )
        let inspirationID = try #require(textState.inspirations.keys.first)
        textState.materialDigests[inspirationID]?.result?.summary.quotes = [
            DigestQuote(speaker: nil, startSeconds: 8, text: "专家指出大模型已经具备通用智能。")
        ]
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(textState)
        }

        var speakerState = MaterialDigestFixture.workspaceWithSucceededDigest(
            takeawayCount: 1,
            contractVersion: "summary-contract-v2"
        )
        speakerState.materialDigests[inspirationID]?.result?.summary.quotes = [
            DigestQuote(speaker: "专家", startSeconds: 8, text: "主体")
        ]
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(speakerState)
        }
    }

    @Test func validatorAcceptsHistoricalV1WhenQuoteTimestampIsSecondsOffMatchingSegment() throws {
        try WorkspaceValidator.validate(
            MaterialDigestFixture.workspaceWithSkewedQuoteDigest(
                contractVersion: "summary-contract-v1"
            )
        )
    }

    @Test func validatorRejectsTheSameSkewedQuoteWhenLabeledV2() throws {
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(
                MaterialDigestFixture.workspaceWithSkewedQuoteDigest(
                    contractVersion: "summary-contract-v2"
                )
            )
        }
    }

    @Test func validatorRejectsEmptyThesis() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.summary.thesis = "   "
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsNegativeTranscriptTime() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        var blocks = try #require(state.materialDigests[inspirationID]?.preparedSnapshot?.blocks)
        blocks[0].locator = .timestamp(startSeconds: -1, endSeconds: 8)
        state.materialDigests[inspirationID]?.preparedSnapshot = try MaterialDigestFixture.snapshot(
            blocks: blocks,
            for: try #require(state.inspirations[inspirationID])
        )
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsSegmentThatEndsBeforeItStarts() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        var blocks = try #require(state.materialDigests[inspirationID]?.preparedSnapshot?.blocks)
        blocks[0].locator = .timestamp(startSeconds: 12, endSeconds: 4)
        state.materialDigests[inspirationID]?.preparedSnapshot = try MaterialDigestFixture.snapshot(
            blocks: blocks,
            for: try #require(state.inspirations[inspirationID])
        )
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsOutOfOrderChapters() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.summary.chapters = [
            DigestChapter(startSeconds: 90, title: "后段", points: ["b"]),
            DigestChapter(startSeconds: 10, title: "前段", points: ["a"])
        ]
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsEmptyProvenanceOnSucceededResult() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.provenance.modelIdentifier = ""
        state.materialDigests[inspirationID]?.result?.provenance.inputFingerprint = ""
        state.materialDigests[inspirationID]?.result?.provenance.summaryContractVersion = ""
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsChecksumMismatch() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspiration = try #require(state.inspirations.values.first)
        let original = try #require(state.materialDigests[inspiration.id])
        state.materialDigests[inspiration.id] = MaterialDigest(
            id: original.id,
            inspirationID: original.inspirationID,
            sourceChecksum: "not-the-current-source",
            currentRun: original.currentRun,
            result: original.result,
            lastFailure: original.lastFailure,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorAllowsSucceededResultToCoexistWithANewRun() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.currentRun = MaterialDigestRun(
            id: MaterialDigestRunID(),
            stage: .fetchingSource,
            startedAt: MaterialDigestFixture.later,
            updatedAt: MaterialDigestFixture.later
        )
        try WorkspaceValidator.validate(state)
    }
}

enum MaterialDigestV3Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let later = Date(timeIntervalSince1970: 1_800_000_100)
    static let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-00000000d101")!
    static let inspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-00000000d102")!)
    static let digestID = MaterialDigestID(UUID(uuidString: "00000000-0000-0000-0000-00000000d103")!)
    static let bodyBlockID = MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000d104")!)
    static let transcriptBlockID = MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000d105")!)

    static func workspace() -> WorkspaceState {
        var state = WorkspaceState.empty(
            calendar: CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        )
        state.revision = 1
        let item = MaterialDigestFixture.inspiration(id: inspirationID)
        state.inspirations[item.id] = item
        let snapshot = snapshot()
        state.materialDigests[item.id] = MaterialDigest(
            id: digestID,
            inspirationID: item.id,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(item),
            currentRun: nil,
            result: result(for: snapshot, inspiration: item),
            lastFailure: nil,
            preparedSnapshot: snapshot,
            createdAt: now,
            updatedAt: later
        )
        return state
    }

    static func snapshot() -> MaterialSnapshot {
        let blocks = [
            MaterialBlock(
                id: bodyBlockID,
                role: .body,
                text: "正文第一段",
                locator: .paragraph(index: 1),
                confidence: nil
            ),
            MaterialBlock(
                id: transcriptBlockID,
                role: .transcript,
                text: "主体",
                locator: .timestamp(startSeconds: 8, endSeconds: 20),
                confidence: nil
            )
        ]
        let draft = MaterialSnapshot(
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(
                MaterialDigestFixture.inspiration(id: inspirationID)
            ),
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
            sourceChecksum: draft.sourceChecksum,
            contentFingerprint: fingerprint,
            blocks: draft.blocks,
            coverage: draft.coverage,
            provenance: draft.provenance,
            createdAt: draft.createdAt
        )
    }

    static func result(for snapshot: MaterialSnapshot, inspiration: Inspiration) -> MaterialDigestResult {
        MaterialDigestResult(
            summary: InspirationSummary(
                thesis: DigestClaim(text: "核心论点", evidenceBlockIDs: [bodyBlockID]),
                takeaways: [DigestClaim(text: "观点1", evidenceBlockIDs: [bodyBlockID])],
                chapters: [
                    DigestChapter(
                        title: "主体",
                        anchorBlockID: transcriptBlockID,
                        points: [DigestClaim(text: "展开", evidenceBlockIDs: [transcriptBlockID])],
                        startSeconds: 8
                    )
                ],
                quotes: [
                    DigestQuote(
                        speaker: nil,
                        startSeconds: 8,
                        text: "主体",
                        evidenceBlockID: transcriptBlockID
                    )
                ],
                dropped: [DigestClaim(text: "片头", evidenceBlockIDs: [bodyBlockID])]
            ),
            provenance: DigestProvenance(
                modelIdentifier: "test-model",
                generatedAt: later,
                inputFingerprint: snapshot.contentFingerprint,
                summaryContractVersion: MaterialDigestSummaryContract.v3
            ),
            completedAt: later,
            contentFingerprint: snapshot.contentFingerprint
        )
    }
}

enum MaterialDigestFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let later = Date(timeIntervalSince1970: 1_800_000_100)
    static let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-00000000d001")!
    static let inspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-00000000d002")!)
    static let digestID = MaterialDigestID(UUID(uuidString: "00000000-0000-0000-0000-00000000d003")!)

    static func inspiration(
        id: InspirationID = inspirationID,
        kind: ResolvedSourceKind = .video,
        url: URL = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!
    ) -> Inspiration {
        Inspiration(
            id: id,
            inputKind: .url,
            rawText: nil,
            rawURL: url,
            rawFile: nil,
            resolvedSourceKind: kind,
            resolvedMetadata: nil,
            categoryID: uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
    }

    static func snapshot(
        transcript: TimestampedTranscript,
        for inspiration: Inspiration
    ) -> MaterialSnapshot {
        let blocks = transcript.segments.enumerated().map { index, segment in
            MaterialBlock(
                id: MaterialBlockID(
                    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 7_100 + index))!
                ),
                role: .transcript,
                text: segment.text,
                locator: .timestamp(
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds
                ),
                confidence: nil
            )
        }
        return try! snapshot(blocks: blocks, for: inspiration)
    }

    static func snapshot(
        blocks: [MaterialBlock],
        for inspiration: Inspiration
    ) throws -> MaterialSnapshot {
        let checksum = WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        let draft = MaterialSnapshot(
            sourceChecksum: checksum,
            contentFingerprint: "pending",
            blocks: blocks,
            coverage: .sufficient,
            provenance: .init(
                adapterIdentifier: "model-fixture",
                adapterVersion: "1",
                acquiredAt: now
            ),
            createdAt: now
        )
        return MaterialSnapshot(
            sourceChecksum: checksum,
            contentFingerprint: try WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
            blocks: blocks,
            coverage: draft.coverage,
            provenance: draft.provenance,
            createdAt: draft.createdAt
        )
    }

    static func workspace() -> WorkspaceState {
        var state = WorkspaceState.empty(
            calendar: CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        )
        state.revision = 1
        let item = inspiration()
        state.inspirations[item.id] = item
        return state
    }

    static func succeeded(
        for inspiration: Inspiration,
        takeawayCount: Int = 3,
        contractVersion: String = "summary-contract-v1",
        transcript: TimestampedTranscript = TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
            TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
        ]),
        quotes: [DigestQuote] = [
            DigestQuote(speaker: nil, startSeconds: 8, text: "主体")
        ]
    ) -> MaterialDigest {
        let takeaways = takeawayCount <= 0 ? [] : (1...takeawayCount).map { "观点\($0)" }
        let snapshot = snapshot(transcript: transcript, for: inspiration)
        return MaterialDigest(
            id: digestID,
            inspirationID: inspiration.id,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
            currentRun: nil,
            result: MaterialDigestResult(
                summary: InspirationSummary(
                    thesis: "核心论点",
                    takeaways: takeaways,
                    chapters: [
                        DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                        DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
                    ],
                    quotes: quotes,
                    dropped: ["片头"]
                ),
                provenance: DigestProvenance(
                    modelIdentifier: "test-model",
                    generatedAt: later,
                    inputFingerprint: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
                    summaryContractVersion: contractVersion
                ),
                completedAt: later
            ),
            lastFailure: nil,
            preparedSnapshot: snapshot,
            createdAt: now,
            updatedAt: later
        )
    }

    static func workspaceWithSucceededDigest(
        takeawayCount: Int,
        contractVersion: String = "summary-contract-v1"
    ) -> WorkspaceState {
        var state = workspace()
        let inspiration = state.inspirations[inspirationID]!
        state.materialDigests[inspiration.id] = succeeded(
            for: inspiration,
            takeawayCount: takeawayCount,
            contractVersion: contractVersion
        )
        return state
    }

    static func workspaceWithSkewedQuoteDigest(contractVersion: String) -> WorkspaceState {
        var state = workspace()
        let inspiration = state.inspirations[inspirationID]!
        state.materialDigests[inspiration.id] = succeeded(
            for: inspiration,
            takeawayCount: 3,
            contractVersion: contractVersion,
            transcript: skewedQuoteTranscript,
            quotes: [skewedQuote]
        )
        return state
    }

    static let skewedQuoteTranscript = TimestampedTranscript(segments: [
        TranscriptSegment(startSeconds: 0, endSeconds: 10, text: "片头预告"),
        TranscriptSegment(startSeconds: 10, endSeconds: 25, text: "这句话才是真正的引用原文"),
        TranscriptSegment(startSeconds: 25, endSeconds: 40, text: "收尾")
    ])

    static let skewedQuote = DigestQuote(
        speaker: nil,
        startSeconds: 38,
        text: "这句话才是真正的引用原文"
    )
}
