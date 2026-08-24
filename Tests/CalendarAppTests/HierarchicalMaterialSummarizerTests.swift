import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("HierarchicalMaterialSummarizerTests")
struct HierarchicalMaterialSummarizerTests {
    @Test func chunkerNeverSplitsABlockAndPreservesOrder() throws {
        let snapshot = try hierarchicalSnapshot(lengths: [80, 80, 80])
        let chunks = try MaterialChunker(estimator: CharacterTokenEstimator()).chunks(
            snapshot: snapshot,
            budget: .init(maximumEstimatedTokens: 180, reservedOutputTokens: 20)
        )

        #expect(chunks.count == 3)
        #expect(chunks.flatMap(\.blockIDs) == snapshot.blocks.map(\.id))
        #expect(chunks.allSatisfy { Set($0.blockIDs).count == $0.blockIDs.count })
    }

    @Test func shortMaterialStillUsesExactlyOneStrictV3Call() async throws {
        let base = RecordingHierarchicalBaseSummarizer()
        let snapshot = try hierarchicalSnapshot(lengths: [20, 20])
        let worker = HierarchicalMaterialSummarizer(
            base: base,
            chunker: MaterialChunker(estimator: CharacterTokenEstimator()),
            budget: .init(maximumEstimatedTokens: 200, reservedOutputTokens: 20)
        )

        _ = try await worker.summarize(snapshot, source: hierarchicalSource())

        #expect(base.callCount == 1)
    }

    @Test func longMaterialUsesShardsThenSynthesisAndKeepsOriginalEvidence() async throws {
        let base = RecordingHierarchicalBaseSummarizer()
        let snapshot = try hierarchicalSnapshot(lengths: [80, 80, 80])
        let worker = HierarchicalMaterialSummarizer(
            base: base,
            chunker: MaterialChunker(estimator: CharacterTokenEstimator()),
            budget: .init(maximumEstimatedTokens: 180, reservedOutputTokens: 20)
        )

        let output = try await worker.summarize(snapshot, source: hierarchicalSource())

        #expect(base.callCount == 4)
        #expect(Set(output.summary.thesisClaim.evidenceBlockIDs).isSubset(of: Set(snapshot.blocks.map(\.id))))
        try MaterialDigestEvidence.validateNewSummary(output.summary, against: snapshot)
    }

    @Test func synthesisRejectsEvidenceNotPresentInOriginalSnapshot() async throws {
        let base = RecordingHierarchicalBaseSummarizer(foreignEvidenceOnSynthesis: true)
        let snapshot = try hierarchicalSnapshot(lengths: [80, 80])
        let worker = HierarchicalMaterialSummarizer(
            base: base,
            chunker: MaterialChunker(estimator: CharacterTokenEstimator()),
            budget: .init(maximumEstimatedTokens: 180, reservedOutputTokens: 20)
        )

        await #expect(throws: MaterialDigestPipelineError.invalidSummary) {
            _ = try await worker.summarize(snapshot, source: hierarchicalSource())
        }
    }
}

private struct CharacterTokenEstimator: MaterialTokenEstimating {
    func estimatedTokens(for text: String) -> Int { text.count }
}

private final class RecordingHierarchicalBaseSummarizer: MaterialSummarizing, @unchecked Sendable {
    var isConfigured = true
    private(set) var callCount = 0
    let foreignEvidenceOnSynthesis: Bool

    init(foreignEvidenceOnSynthesis: Bool = false) {
        self.foreignEvidenceOnSynthesis = foreignEvidenceOnSynthesis
    }

    func summarize(
        _ snapshot: MaterialSnapshot,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput {
        callCount += 1
        let isSynthesis = snapshot.provenance.adapterIdentifier == "hierarchical-shards"
        let evidence = isSynthesis && foreignEvidenceOnSynthesis
            ? MaterialBlockID()
            : try #require(snapshot.blocks.first(where: { $0.role != .metadata })?.id)
        return MaterialSummarizerOutput(
            summary: InspirationSummary(
                thesis: DigestClaim(text: isSynthesis ? "综合结论" : "分段结论", evidenceBlockIDs: [evidence]),
                takeaways: [DigestClaim(text: "可执行要点", evidenceBlockIDs: [evidence])],
                chapters: [],
                quotes: [],
                dropped: []
            ),
            endpointHost: "api.example.com",
            model: "fixture",
            summaryContractVersion: MaterialDigestSummaryContract.v3
        )
    }
}

private func hierarchicalSnapshot(lengths: [Int]) throws -> MaterialSnapshot {
    let blocks = lengths.enumerated().map { index, length in
        MaterialBlock(
            id: MaterialBlockID(),
            role: .body,
            text: String(repeating: Character("甲"), count: length),
            locator: .paragraph(index: index + 1),
            confidence: nil
        )
    }
    let draft = MaterialSnapshot(
        sourceChecksum: "hierarchical-checksum",
        contentFingerprint: "pending",
        blocks: blocks,
        coverage: .sufficient,
        provenance: .init(adapterIdentifier: "fixture", adapterVersion: "1", acquiredAt: .distantPast),
        createdAt: .distantPast
    )
    return MaterialSnapshot(
        sourceChecksum: draft.sourceChecksum,
        contentFingerprint: try WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
        blocks: blocks,
        coverage: draft.coverage,
        provenance: draft.provenance,
        createdAt: draft.createdAt
    )
}

private func hierarchicalSource() -> MaterialSource {
    MaterialSource(
        inspirationID: InspirationID(),
        text: "长材料",
        sourceChecksum: "hierarchical-checksum"
    )
}
