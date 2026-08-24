import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialSummarizerLiveTests")
struct MaterialSummarizerLiveTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MINIMAX"] == "1")
    )
    func liveMiniMaxProducesGroundedV3Summary() async throws {
        let environment = ProcessInfo.processInfo.environment
        let secret = try #require(environment["MINIMAX_API_KEY"])
        let endpoint = environment["JELLY_LIVE_MINIMAX_ENDPOINT"]
            ?? "https://api.minimaxi.com/v1"
        let model = environment["JELLY_LIVE_MINIMAX_MODEL"] ?? "MiniMax-M3"

        let suite = "jelly-live-minimax-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DigestSettingsStore(defaults: defaults)
        #expect(settings.save(endpoint: endpoint, model: model))

        let credentials = InMemoryDigestCredentialStore()
        try credentials.save(secret)
        defer { try? credentials.delete() }

        let snapshot = try liveMiniMaxSnapshot()
        let summarizer = HierarchicalMaterialSummarizer(
            base: OpenAICompatibleMaterialSummarizer(
                settings: settings,
                credentials: credentials
            )
        )
        let output = try await summarizer.summarize(
            snapshot,
            source: MaterialSource(
                inspirationID: InspirationID(),
                text: snapshot.blocks.map(\.text).joined(separator: "\n"),
                sourceChecksum: snapshot.sourceChecksum
            )
        )

        #expect(output.summaryContractVersion == MaterialDigestSummaryContract.v3)
        #expect(output.model == model)
        #expect(output.endpointHost == "api.minimaxi.com")
        try MaterialDigestEvidence.validateNewSummary(output.summary, against: snapshot)
        #expect(containsHan(output.summary.thesis))
        #expect(output.summary.takeaways.allSatisfy(containsHan))
        #expect(output.summary.chapters.allSatisfy { chapter in
            containsHan(chapter.title) && chapter.points.allSatisfy(containsHan)
        })
        #expect(output.summary.dropped.allSatisfy(containsHan))
    }
}

private func liveMiniMaxSnapshot() throws -> MaterialSnapshot {
    let sourceChecksum = "live-minimax-direct-text"
    let blocks = [
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000c001")!),
            role: .body,
            text: "稳定的材料提炼首先要保留原始内容，再让用户主动决定何时生成摘要。",
            locator: .paragraph(index: 1),
            confidence: nil
        ),
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000c002")!),
            role: .body,
            text: "摘要中的结论必须能追溯到具体证据；来源读取不完整时，应明确告诉用户缺失了什么。",
            locator: .paragraph(index: 2),
            confidence: nil
        ),
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000c003")!),
            role: .body,
            text: "A useful summary should preserve this original sentence as a quote when it is important.",
            locator: .paragraph(index: 3),
            confidence: nil
        )
    ]
    let draft = MaterialSnapshot(
        sourceChecksum: sourceChecksum,
        contentFingerprint: "pending",
        blocks: blocks,
        coverage: .sufficient,
        provenance: MaterialAcquisitionProvenance(
            adapterIdentifier: "live-minimax-direct-text",
            adapterVersion: "1",
            acquiredAt: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
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

private func containsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
    }
}
