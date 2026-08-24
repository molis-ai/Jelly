import Foundation
import WorkspaceDomain

struct MaterialInputBudget: Equatable, Sendable {
    let maximumEstimatedTokens: Int
    let reservedOutputTokens: Int

    var availableInputTokens: Int {
        maximumEstimatedTokens - reservedOutputTokens
    }
}

protocol MaterialTokenEstimating: Sendable {
    func estimatedTokens(for text: String) -> Int
}

struct ConservativeMaterialTokenEstimator: MaterialTokenEstimating, Sendable {
    func estimatedTokens(for text: String) -> Int {
        max(1, (text.utf8.count + 2) / 3)
    }
}

struct MaterialChunk: Equatable, Sendable {
    let index: Int
    let blockIDs: [MaterialBlockID]
    let renderedText: String
}

struct MaterialChunker: Sendable {
    private let estimator: any MaterialTokenEstimating
    private let perBlockOverheadTokens: Int

    init(
        estimator: any MaterialTokenEstimating = ConservativeMaterialTokenEstimator(),
        perBlockOverheadTokens: Int = 16
    ) {
        self.estimator = estimator
        self.perBlockOverheadTokens = perBlockOverheadTokens
    }

    func chunks(
        snapshot: MaterialSnapshot,
        budget: MaterialInputBudget
    ) throws -> [MaterialChunk] {
        let available = budget.availableInputTokens
        guard available > 0 else { throw MaterialDigestPipelineError.contextTooLong }
        var groups: [[MaterialBlock]] = []
        var current: [MaterialBlock] = []
        var currentTokens = 0

        for block in snapshot.blocks {
            let rendered = Self.render(block)
            let tokens = estimator.estimatedTokens(for: rendered) + perBlockOverheadTokens
            guard tokens <= available else {
                throw MaterialDigestPipelineError.contextTooLong
            }
            if !current.isEmpty, currentTokens + tokens > available {
                groups.append(current)
                current = []
                currentTokens = 0
            }
            current.append(block)
            currentTokens += tokens
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { index, blocks in
            MaterialChunk(
                index: index,
                blockIDs: blocks.map(\.id),
                renderedText: blocks.map(Self.render).joined(separator: "\n")
            )
        }
    }

    private static func render(_ block: MaterialBlock) -> String {
        "[\(block.id.rawValue.uuidString)] \(block.text)"
    }
}

struct HierarchicalMaterialSummarizer: MaterialSummarizing, Sendable {
    let base: any MaterialSummarizing
    let chunker: MaterialChunker
    let budget: MaterialInputBudget

    init(
        base: any MaterialSummarizing,
        chunker: MaterialChunker = MaterialChunker(),
        budget: MaterialInputBudget = .init(
            maximumEstimatedTokens: 65_536,
            reservedOutputTokens: 12_288
        )
    ) {
        self.base = base
        self.chunker = chunker
        self.budget = budget
    }

    var isConfigured: Bool { base.isConfigured }

    func summarize(
        _ snapshot: MaterialSnapshot,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput {
        let chunks = try chunker.chunks(snapshot: snapshot, budget: budget)
        guard !chunks.isEmpty else { throw MaterialDigestPipelineError.insufficientContent }
        if chunks.count == 1 {
            return try await base.summarize(snapshot, source: source)
        }

        var shardSummaries: [InspirationSummary] = []
        shardSummaries.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let shardSnapshot = try Self.snapshot(
                source: snapshot,
                blocks: Self.blocks(for: chunk, in: snapshot),
                adapterIdentifier: "hierarchical-shard-\(chunk.index + 1)"
            )
            let output = try await base.summarize(shardSnapshot, source: source)
            guard output.summaryContractVersion == MaterialDigestSummaryContract.v3 else {
                throw MaterialDigestPipelineError.invalidSummary
            }
            do {
                try MaterialDigestEvidence.validateNewSummary(output.summary, against: shardSnapshot)
            } catch {
                throw MaterialDigestPipelineError.invalidSummary
            }
            shardSummaries.append(output.summary)
        }

        let synthesisSnapshot = try Self.synthesisSnapshot(
            original: snapshot,
            summaries: shardSummaries
        )
        let output = try await base.summarize(synthesisSnapshot, source: source)
        guard output.summaryContractVersion == MaterialDigestSummaryContract.v3 else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        do {
            try MaterialDigestEvidence.validateNewSummary(output.summary, against: snapshot)
        } catch {
            throw MaterialDigestPipelineError.invalidSummary
        }
        return output
    }

    private static func blocks(
        for chunk: MaterialChunk,
        in snapshot: MaterialSnapshot
    ) -> [MaterialBlock] {
        let ids = Set(chunk.blockIDs)
        return snapshot.blocks.filter { ids.contains($0.id) }
    }

    private static func synthesisSnapshot(
        original: MaterialSnapshot,
        summaries: [InspirationSummary]
    ) throws -> MaterialSnapshot {
        let originals = Dictionary(uniqueKeysWithValues: original.blocks.map { ($0.id, $0) })
        var snippets: [MaterialBlockID: [String]] = [:]

        func append(_ text: String, evidence: [MaterialBlockID]) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            for id in evidence where originals[id]?.role != .metadata {
                if snippets[id]?.contains(normalized) != true {
                    snippets[id, default: []].append(normalized)
                }
            }
        }
        for summary in summaries {
            append(summary.thesisClaim.text, evidence: summary.thesisClaim.evidenceBlockIDs)
            summary.takeawayClaims.forEach { append($0.text, evidence: $0.evidenceBlockIDs) }
            for chapter in summary.chapters {
                if let anchor = chapter.anchorBlockID { append(chapter.title, evidence: [anchor]) }
                chapter.pointClaims.forEach { append($0.text, evidence: $0.evidenceBlockIDs) }
            }
            for quote in summary.quotes {
                if let evidence = quote.evidenceBlockID { append(quote.text, evidence: [evidence]) }
            }
            summary.droppedClaims.forEach { append($0.text, evidence: $0.evidenceBlockIDs) }
        }

        let blocks = original.blocks.compactMap { originalBlock -> MaterialBlock? in
            guard let texts = snippets[originalBlock.id], !texts.isEmpty else { return nil }
            return MaterialBlock(
                id: originalBlock.id,
                role: .body,
                text: texts.joined(separator: "\n"),
                locator: originalBlock.locator,
                confidence: originalBlock.confidence
            )
        }
        guard !blocks.isEmpty else { throw MaterialDigestPipelineError.invalidSummary }
        return try snapshot(
            source: original,
            blocks: blocks,
            adapterIdentifier: "hierarchical-shards"
        )
    }

    private static func snapshot(
        source: MaterialSnapshot,
        blocks: [MaterialBlock],
        adapterIdentifier: String
    ) throws -> MaterialSnapshot {
        let provenance = MaterialAcquisitionProvenance(
            adapterIdentifier: adapterIdentifier,
            adapterVersion: "1",
            acquiredAt: source.createdAt
        )
        let draft = MaterialSnapshot(
            sourceChecksum: source.sourceChecksum,
            contentFingerprint: "pending",
            blocks: blocks,
            coverage: .sufficient,
            provenance: provenance,
            createdAt: source.createdAt
        )
        return MaterialSnapshot(
            sourceChecksum: source.sourceChecksum,
            contentFingerprint: try WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
            blocks: blocks,
            coverage: draft.coverage,
            provenance: provenance,
            createdAt: source.createdAt
        )
    }
}
