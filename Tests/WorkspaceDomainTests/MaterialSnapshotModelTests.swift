import Foundation
import Testing
import WorkspaceDomain

@Suite("MaterialSnapshotModelTests")
struct MaterialSnapshotModelTests {
    @Test func snapshotRoundTripsMixedLocatorsWithoutInventingTimestamps() throws {
        let body = MaterialBlock(
            id: MaterialBlockID(), role: .body, text: "正文第一段",
            locator: .paragraph(index: 1), confidence: nil
        )
        let page = MaterialBlock(
            id: MaterialBlockID(), role: .ocr, text: "扫描页文字",
            locator: .page(number: 3), confidence: .init(basisPoints: 9_200)
        )
        let snapshot = MaterialSnapshot.fixture(blocks: [body, page], coverage: .sufficient)
        let decoded = try JSONDecoder().decode(
            MaterialSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(decoded.blocks.map(\.locator) == [.paragraph(index: 1), .page(number: 3)])
    }

    @Test func metadataCannotBeTheOnlyEvidenceForANewClaim() {
        let metadata = MaterialBlock(
            id: MaterialBlockID(), role: .metadata, text: "页面标题",
            locator: .paragraph(index: 0), confidence: nil
        )
        let claim = DigestClaim(text: "标题就是事实", evidenceBlockIDs: [metadata.id])
        #expect(MaterialDigestEvidence.hasNonMetadataEvidence(claim, blocks: [metadata]) == false)
    }

    @Test func validatorRejectsDuplicateBlockIDsWithAnOtherwiseCurrentFingerprint() throws {
        let id = MaterialBlockID()
        var state = MaterialDigestV3Fixture.workspace()
        let template = try #require(
            state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.preparedSnapshot
        )
        let snapshot = try signedSnapshot(template: template, blocks: [
            .init(id: id, role: .body, text: "正文", locator: .paragraph(index: 1), confidence: nil),
            .init(id: id, role: .metadata, text: "标题", locator: .paragraph(index: 0), confidence: nil)
        ])
        state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.preparedSnapshot = snapshot
        state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.result?.contentFingerprint = snapshot.contentFingerprint
        #expect(throws: WorkspaceValidationError.self) { try WorkspaceValidator.validate(state) }
    }

    @Test func validatorRejectsNegativeParagraphLocatorWithACurrentFingerprint() throws {
        var state = MaterialDigestV3Fixture.workspace()
        let template = try #require(
            state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.preparedSnapshot
        )
        var blocks = template.blocks
        blocks[0].locator = .paragraph(index: -1)
        let snapshot = try signedSnapshot(template: template, blocks: blocks)
        state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.preparedSnapshot = snapshot
        state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.result?.contentFingerprint = snapshot.contentFingerprint
        #expect(throws: WorkspaceValidationError.self) { try WorkspaceValidator.validate(state) }
    }

    @Test func validatorRejectsMetadataOnlyClaimWithAValidSnapshot() throws {
        var state = MaterialDigestV3Fixture.workspace()
        let template = try #require(
            state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.preparedSnapshot
        )
        let metadata = MaterialBlock(
            id: MaterialBlockID(),
            role: .metadata,
            text: "页面标题",
            locator: .paragraph(index: 0),
            confidence: nil
        )
        let snapshot = try signedSnapshot(template: template, blocks: template.blocks + [metadata])
        state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.preparedSnapshot = snapshot
        state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.result?.contentFingerprint = snapshot.contentFingerprint
        state.materialDigests[MaterialDigestV3Fixture.inspirationID]?.result?.summary.thesisClaim =
            DigestClaim(text: "标题就是事实", evidenceBlockIDs: [metadata.id])
        #expect(throws: WorkspaceValidationError.self) { try WorkspaceValidator.validate(state) }
    }

    @Test func fingerprintIgnoresAcquisitionTimeButChangesWithNormalizedText() throws {
        let first = MaterialSnapshot.fixture(text: "同一正文", acquiredAt: .distantPast)
        let second = MaterialSnapshot.fixture(text: "同一正文", acquiredAt: .distantFuture)
        #expect(try WorkspaceChecksum.materialSnapshotContentFingerprint(first)
            == WorkspaceChecksum.materialSnapshotContentFingerprint(second))
        #expect(try WorkspaceChecksum.materialSnapshotContentFingerprint(first)
            != WorkspaceChecksum.materialSnapshotContentFingerprint(.fixture(text: "正文变化")))
    }
}

private func signedSnapshot(
    template: MaterialSnapshot,
    blocks: [MaterialBlock]
) throws -> MaterialSnapshot {
    let draft = MaterialSnapshot(
        sourceChecksum: template.sourceChecksum,
        contentFingerprint: "pending",
        blocks: blocks,
        coverage: template.coverage,
        provenance: template.provenance,
        createdAt: template.createdAt
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

extension MaterialSnapshot {
    static func fixture(
        blocks: [MaterialBlock],
        coverage: MaterialCoverage = .sufficient,
        sourceChecksum: String = "source-checksum",
        contentFingerprint: String = "content-fingerprint",
        acquiredAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> MaterialSnapshot {
        MaterialSnapshot(
            sourceChecksum: sourceChecksum,
            contentFingerprint: contentFingerprint,
            blocks: blocks,
            coverage: coverage,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "test-adapter",
                adapterVersion: "1",
                acquiredAt: acquiredAt
            ),
            createdAt: createdAt
        )
    }

    static func fixture(
        text: String,
        acquiredAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> MaterialSnapshot {
        let block = MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000b001")!),
            role: .body,
            text: text,
            locator: .paragraph(index: 1),
            confidence: nil
        )
        return .fixture(
            blocks: [block],
            coverage: .sufficient,
            acquiredAt: acquiredAt,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
    }
}
