import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialDigestPresentationTests")
struct MaterialDigestPresentationTests {
    @Test func articleAndUnknownURLSourcesCanBeManuallyDigested() {
        let article = inspiration(kind: .article, url: URL(string: "https://example.com/post")!)
        let articlePresentation = MaterialDigestPresentation.project(
            inspiration: article,
            digest: nil,
            operatorAvailable: true
        )
        #expect(articlePresentation.isVisible)
        #expect(articlePresentation.primaryActionTitle == "提炼这份材料")

        let podcastHome = inspiration(
            kind: .unknown,
            url: URL(string: "https://www.xiaoyuzhoufm.com/podcast/1")!
        )
        let unknownPresentation = MaterialDigestPresentation.project(
            inspiration: podcastHome,
            digest: nil,
            operatorAvailable: true
        )
        #expect(unknownPresentation.isVisible)
        #expect(unknownPresentation.primaryActionTitle == "提炼这份材料")
    }

    @Test func textAndFileSourcesUseTheSameManualDigestAction() {
        let textPresentation = MaterialDigestPresentation.project(
            inspiration: .text(
                rawText: "一段需要整理的长材料",
                categoryID: UUID(),
                now: MaterialDigestPresentationFixture.now
            ),
            digest: nil,
            operatorAvailable: true
        )
        #expect(textPresentation.isVisible)
        #expect(textPresentation.primaryActionTitle == "提炼这份材料")

        let filePresentation = MaterialDigestPresentation.project(
            inspiration: fileInspiration(kind: .document, displayName: "研究报告.pdf"),
            digest: nil,
            operatorAvailable: true
        )
        #expect(filePresentation.isVisible)
        #expect(filePresentation.primaryActionTitle == "提炼这份材料")
    }

    @Test func idleSupportedSourceShowsStartAction() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: nil,
            operatorAvailable: true
        )
        #expect(presentation.isVisible)
        #expect(presentation.statusText == "尚未提炼")
        #expect(presentation.primaryActionTitle == "提炼这份材料")
        #expect(presentation.showsCancel == false)
        #expect(presentation.showsRetry == false)
        #expect(presentation.showsConfirmDownload == false)
        #expect(presentation.showsOpenSettings == false)
    }

    @Test func unconfiguredModelStillAllowsPreparingMaterialBeforeSummary() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: nil,
            operatorAvailable: true,
            modelConfigured: false
        )
        #expect(presentation.isVisible)
        #expect(presentation.statusText == "可以先读取材料；生成摘要前再配置模型。")
        #expect(presentation.primaryActionTitle == "提炼这份材料")
        #expect(presentation.showsOpenSettings == false)
        #expect(presentation.showsRetry == false)
        #expect(presentation.showsCancel == false)
    }

    @Test func configuredModelTurnsPreviousSetupFailureIntoRetry() {
        var digest = runningDigest(stage: .fetchingSource)
        digest.currentRun = nil
        digest.lastFailure = MaterialDigestFailure(
            code: .modelNotConfigured,
            userMessage: "尚未配置摘要模型，请先在设置中填写。",
            occurredAt: MaterialDigestPresentationFixture.now
        )

        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: digest,
            operatorAvailable: true,
            modelConfigured: true
        )
        #expect(presentation.statusText == "设置已就绪，可以重试提炼。")
        #expect(presentation.primaryActionTitle == "重试")
        #expect(presentation.showsRetry)
        #expect(presentation.showsOpenSettings == false)
    }

    @Test func hiddenWhenOperatorIsUnavailable() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: nil,
            operatorAvailable: false
        )
        #expect(presentation.isVisible == false)
        #expect(presentation.primaryActionTitle == nil)
    }

    @Test func eachStageHasExactChineseStatus() {
        let cases: [(MaterialDigestStage, String)] = [
            (.fetchingSource, "正在读取材料"),
            (.downloadingModel, "正在下载识别模型"),
            (.transcribing, "正在识别音频"),
            (.summarizing, "正在生成摘要")
        ]
        for (stage, expected) in cases {
            let presentation = MaterialDigestPresentation.project(
                inspiration: videoInspiration(),
                digest: runningDigest(stage: stage),
                operatorAvailable: true
            )
            #expect(presentation.statusText == expected)
            #expect(presentation.showsCancel)
            #expect(presentation.primaryActionTitle == nil)
        }

        let audioFetching = MaterialDigestPresentation.project(
            inspiration: audioInspiration(),
            digest: runningDigest(stage: .fetchingSource),
            operatorAvailable: true
        )
        #expect(audioFetching.statusText == "正在读取材料")

        let audioTranscribing = MaterialDigestPresentation.project(
            inspiration: audioInspiration(),
            digest: runningDigest(stage: .transcribing),
            operatorAvailable: true
        )
        #expect(audioTranscribing.statusText == "正在识别音频")
    }

    @Test func awaitingConsentShowsDownloadSizeAndContinue() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: runningDigest(
                stage: .awaitingModelDownloadConsent,
                modelDownloadApproximateBytes: 700_000_000
            ),
            operatorAvailable: true
        )
        #expect(
            presentation.statusText
                == MaterialDigestPresentation.modelDownloadConsentText(approximateBytes: 700_000_000)
        )
        #expect(presentation.statusText.contains("700"))
        #expect(!presentation.statusText.contains("626"))
        #expect(presentation.statusText.contains("能公开读取字幕时不会下载"))
        #expect(!presentation.statusText.contains("有字幕的材料不会下载"))
        #expect(presentation.showsConfirmDownload)
        #expect(presentation.confirmDownloadTitle == "下载并继续")
        #expect(presentation.showsCancel)
    }

    @Test func modelDownloadHidesMisleadingFileCountProgressButTranscriptionKeepsItsProgress() {
        let downloading = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: runningDigest(stage: .downloadingModel),
            operatorAvailable: true,
            progressFraction: 0.34
        )
        #expect(downloading.progressFraction == nil)
        #expect(downloading.statusText == "正在下载识别模型")

        let transcribing = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: runningDigest(stage: .transcribing),
            operatorAvailable: true,
            progressFraction: 0.34
        )
        #expect(transcribing.statusText == "正在识别音频 34%")
    }

    @Test func retryKeepsPreviousResultVisibleWithNewProgress() {
        let digest = runningDigest(stage: .summarizing, result: succeededResult())
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: digest,
            operatorAvailable: true
        )
        #expect(presentation.statusText == "正在生成摘要")
        #expect(presentation.thesis == "核心论点")
        #expect(presentation.takeaways.count == 3)
        #expect(presentation.showsCancel)
    }

    @Test func failureShowsRetryWithoutClaimingSuccess() {
        var digest = runningDigest(stage: .fetchingSource)
        digest.currentRun = nil
        digest.lastFailure = MaterialDigestFailure(
            code: .restrictedSource,
            userMessage: "来源受限，无法获取字幕或音频。",
            occurredAt: MaterialDigestPresentationFixture.now
        )
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: digest,
            operatorAvailable: true
        )
        #expect(presentation.statusText == "来源受限，无法获取字幕或音频。")
        #expect(presentation.showsRetry)
        #expect(presentation.primaryActionTitle == "重试")
        #expect(presentation.thesis == nil)
    }

    @Test func insufficientContentShowsRetryWithoutWriteNote() {
        var digest = runningDigest(stage: .summarizing)
        digest.currentRun = nil
        digest.lastFailure = MaterialDigestFailure(
            code: .insufficientContent,
            userMessage: "没有识别到可提炼的内容，原始链接仍然保留。",
            occurredAt: MaterialDigestPresentationFixture.now
        )
        let presentation = MaterialDigestPresentation.project(
            inspiration: audioInspiration(),
            digest: digest,
            operatorAvailable: true
        )
        #expect(presentation.statusText == "没有识别到可提炼的内容，原始链接仍然保留。")
        #expect(presentation.showsRetry)
        #expect(presentation.primaryActionTitle == "重试")
        #expect(presentation.thesis == nil)
        #expect(presentation.takeaways.isEmpty)
        #expect(!presentation.statusText.contains("提炼完成"))
        #expect(!presentation.statusText.contains("写入笔记"))
    }

    @Test func successShowsStructuredReviewFields() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: succeededDigest(),
            operatorAvailable: true
        )
        #expect(presentation.thesis == "核心论点")
        #expect(presentation.takeaways.map(\.text) == ["观点1", "观点2", "观点3"])
        #expect(presentation.chapters.map(\.title) == ["开场", "主体"])
        #expect(presentation.quotes.map(\.text) == ["主体"])
        #expect(presentation.dropped == ["片头"])
        #expect(presentation.transcriptAvailable)
        #expect(presentation.transcriptSegments.map(\.text) == ["开场", "主体"])
        #expect(presentation.transcriptCollapsedByDefault)
        #expect(presentation.showsCancel == false)
        #expect(presentation.showsRefresh)
    }

    @Test func excludedContentTitleMatchesTheMaterialKind() {
        let textPresentation = MaterialDigestPresentation.project(
            inspiration: fileInspiration(kind: .document, displayName: "材料.txt"),
            digest: succeededDigest(),
            operatorAvailable: true
        )
        let audioPresentation = MaterialDigestPresentation.project(
            inspiration: audioInspiration(),
            digest: succeededDigest(),
            operatorAvailable: true
        )

        #expect(textPresentation.droppedSectionTitle == "未纳入摘要")
        #expect(audioPresentation.droppedSectionTitle == "广告与片头片尾")
    }

    @Test func archivedSourceNeverShowsActionsThatSilentlyDoNothing() {
        var archived = videoInspiration()
        archived.lifecycle = .archived

        let withoutResult = MaterialDigestPresentation.project(
            inspiration: archived,
            digest: nil,
            operatorAvailable: true
        )
        #expect(withoutResult.isVisible == false)

        let withResult = MaterialDigestPresentation.project(
            inspiration: archived,
            digest: succeededDigest(),
            operatorAvailable: true
        )
        #expect(withResult.isVisible)
        #expect(withResult.thesis == "核心论点")
        #expect(withResult.primaryActionTitle == nil)
        #expect(withResult.showsRetry == false)
        #expect(withResult.showsConfirmDownload == false)
        #expect(withResult.showsCancel == false)
        #expect(withResult.showsRefresh == false)
    }

    @Test func v3ResultShowsCoverageAndLocatorDerivedEvidence() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: .videoFixture(),
            digest: .v3SucceededPartial(),
            operatorAvailable: true
        )
        #expect(presentation.coverageText == "基于部分内容：2/3 项已读取")
        #expect(presentation.thesisEvidenceLabels == ["01:23"])
        #expect(presentation.takeaways.first?.evidenceLabels == ["01:23"])
        #expect(presentation.droppedClaims.first?.evidenceLabels == ["01:23"])
        #expect(presentation.materialCollapsedByDefault)
    }

    @Test func partialCoverageExplainsWhatWasNotRead() {
        var digest = MaterialDigest.v3SucceededPartial()
        digest.preparedSnapshot?.coverage = .partial(
            processed: 2,
            expected: 3,
            issues: [.ocrFailed, .visualSemanticsUnavailable]
        )
        let presentation = MaterialDigestPresentation.project(
            inspiration: .videoFixture(),
            digest: digest,
            operatorAvailable: true
        )
        #expect(
            presentation.coverageText
                == "基于部分内容：2/3 项已读取；部分图片文字未识别；摘要不包含视频画面含义"
        )
    }

    @Test func restrictedXiaohongshuOffersSourcePreservingRecoveryActions() {
        var digest = runningDigest(stage: .fetchingSource)
        digest.currentRun = nil
        digest.lastFailure = MaterialDigestFailure(
            code: .restrictedSource,
            userMessage: "来源受限，无法获取材料。",
            occurredAt: MaterialDigestPresentationFixture.now
        )
        let presentation = MaterialDigestPresentation.project(
            inspiration: inspiration(
                kind: .socialPost,
                url: URL(string: "https://www.xiaohongshu.com/explore/public-note")!
            ),
            digest: digest,
            operatorAvailable: true
        )
        #expect(presentation.statusText == "小红书限制了公开内容读取，原始链接仍然保留。")
        #expect(presentation.recoveryActions == [.pasteText, .chooseFile, .retrySource])
        #expect(presentation.primaryActionTitle == nil)
        #expect(presentation.showsRetry == false)
    }

    @Test func noteUsesLocatorLabelsAndKeepsSourceFirst() throws {
        let document = InspirationNoteDocumentBuilder.document(
            for: .urlFixture(),
            digest: .v3SucceededPDF()
        )
        #expect(document.blocks.first?.kind == .link)
        #expect(document.plainText.contains("核心论点（第 3 页）"))
        #expect(document.plainText.contains("要点（第 3 页）"))
        #expect(document.plainText.contains("无关页眉（第 3 页）"))
    }

    @Test func noteUsesSourceSpecificExcludedContentHeading() throws {
        let digest = MaterialDigest.v3SucceededPDF()
        let result = try #require(digest.result)
        let textBlocks = InspirationNoteDocumentBuilder.summaryBlocks(
            for: result,
            snapshot: digest.preparedSnapshot,
            sourceKind: .document
        )
        let audioBlocks = InspirationNoteDocumentBuilder.summaryBlocks(
            for: succeededResult(),
            snapshot: legacySnapshot(for: audioInspiration()),
            sourceKind: .audio
        )
        let text = textBlocks.map { $0.inlineContent.spans.map(\.text).joined() }
        let audio = audioBlocks.map { $0.inlineContent.spans.map(\.text).joined() }

        #expect(text.contains("未纳入摘要"))
        #expect(audio.contains("广告与片头片尾"))
    }
}

private enum MaterialDigestPresentationFixture {
    static let now = Date(timeIntervalSince1970: 1_800_400_000)
}

private func videoInspiration() -> Inspiration {
    inspiration(kind: .video, url: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!)
}

private func audioInspiration() -> Inspiration {
    inspiration(kind: .audio, url: URL(string: "https://www.xiaoyuzhoufm.com/episode/1")!)
}

private func inspiration(kind: ResolvedSourceKind, url: URL) -> Inspiration {
    Inspiration(
        id: InspirationID(UUID(uuidString: "00000000-0000-0000-0000-00000000e001")!),
        inputKind: .url,
        rawText: nil,
        rawURL: url,
        rawFile: nil,
        resolvedSourceKind: kind,
        resolvedMetadata: nil,
        categoryID: UUID(uuidString: "00000000-0000-0000-0000-00000000e000")!,
        lifecycle: .active,
        createdAt: MaterialDigestPresentationFixture.now,
        updatedAt: MaterialDigestPresentationFixture.now
    )
}

private func fileInspiration(kind: ResolvedSourceKind, displayName: String) -> Inspiration {
    Inspiration(
        id: InspirationID(),
        inputKind: .file,
        rawText: nil,
        rawURL: nil,
        rawFile: FileReference(bookmarkData: Data([1, 2, 3]), displayName: displayName),
        resolvedSourceKind: kind,
        resolvedMetadata: nil,
        categoryID: UUID(),
        lifecycle: .active,
        createdAt: MaterialDigestPresentationFixture.now,
        updatedAt: MaterialDigestPresentationFixture.now
    )
}

private func runningDigest(
    stage: MaterialDigestStage,
    result: MaterialDigestResult? = nil,
    modelDownloadApproximateBytes: Int64? = nil
) -> MaterialDigest {
    let item = videoInspiration()
    let snapshot = legacySnapshot(for: item)
    return MaterialDigest(
        id: MaterialDigestID(),
        inspirationID: item.id,
        sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(item),
        currentRun: MaterialDigestRun(
            id: MaterialDigestRunID(),
            stage: stage,
            startedAt: MaterialDigestPresentationFixture.now,
            updatedAt: MaterialDigestPresentationFixture.now,
            modelDownloadApproximateBytes: modelDownloadApproximateBytes
        ),
        result: result,
        lastFailure: nil,
        preparedSnapshot: result == nil ? nil : snapshot,
        createdAt: MaterialDigestPresentationFixture.now,
        updatedAt: MaterialDigestPresentationFixture.now
    )
}

private func succeededDigest() -> MaterialDigest {
    let item = videoInspiration()
    let snapshot = legacySnapshot(for: item)
    return MaterialDigest(
        id: MaterialDigestID(),
        inspirationID: item.id,
        sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(item),
        currentRun: nil,
        result: succeededResult(),
        lastFailure: nil,
        preparedSnapshot: snapshot,
        createdAt: MaterialDigestPresentationFixture.now,
        updatedAt: MaterialDigestPresentationFixture.now
    )
}

private func succeededResult() -> MaterialDigestResult {
    MaterialDigestResult(
        summary: InspirationSummary(
            thesis: "核心论点",
            takeaways: ["观点1", "观点2", "观点3"],
            chapters: [
                DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
            ],
            quotes: [DigestQuote(speaker: nil, startSeconds: 8, text: "主体")],
            dropped: ["片头"]
        ),
        provenance: DigestProvenance(
            modelIdentifier: "api.example.com/test-model",
            generatedAt: MaterialDigestPresentationFixture.now,
            inputFingerprint: "checksum",
            summaryContractVersion: "summary-contract-v1"
        ),
        completedAt: MaterialDigestPresentationFixture.now
    )
}

private func legacySnapshot(for inspiration: Inspiration) -> MaterialSnapshot {
    let blocks = [
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000e201")!),
            role: .transcript,
            text: "开场",
            locator: .timestamp(startSeconds: 0, endSeconds: 8),
            confidence: nil
        ),
        MaterialBlock(
            id: MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000e202")!),
            role: .transcript,
            text: "主体",
            locator: .timestamp(startSeconds: 8, endSeconds: 20),
            confidence: nil
        )
    ]
    let draft = MaterialSnapshot(
        sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
        contentFingerprint: "pending",
        blocks: blocks,
        coverage: .sufficient,
        provenance: .init(
            adapterIdentifier: "presentation-fixture",
            adapterVersion: "1",
            acquiredAt: MaterialDigestPresentationFixture.now
        ),
        createdAt: MaterialDigestPresentationFixture.now
    )
    return MaterialSnapshot(
        sourceChecksum: draft.sourceChecksum,
        contentFingerprint: try! WorkspaceChecksum.materialSnapshotContentFingerprint(draft),
        blocks: blocks,
        coverage: draft.coverage,
        provenance: draft.provenance,
        createdAt: draft.createdAt
    )
}

private extension Inspiration {
    static func videoFixture() -> Inspiration { videoInspiration() }

    static func urlFixture() -> Inspiration {
        inspiration(
            kind: .document,
            url: URL(string: "https://example.com/paper.pdf")!
        )
    }
}

private extension MaterialDigest {
    static func v3SucceededPartial() -> MaterialDigest {
        let item = Inspiration.videoFixture()
        let blockID = MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000e101")!)
        let block = MaterialBlock(
            id: blockID,
            role: .transcript,
            text: "关键论据",
            locator: .timestamp(startSeconds: 83, endSeconds: 90),
            confidence: nil
        )
        let snapshot = snapshot(blocks: [block], coverage: .partial(processed: 2, expected: 3, issues: []))
        return MaterialDigest(
            id: MaterialDigestID(),
            inspirationID: item.id,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(item),
            currentRun: nil,
            result: MaterialDigestResult(
                summary: InspirationSummary(
                    thesis: DigestClaim(text: "核心论点", evidenceBlockIDs: [blockID]),
                    takeaways: [DigestClaim(text: "关键观点", evidenceBlockIDs: [blockID])],
                    chapters: [],
                quotes: [],
                dropped: [DigestClaim(text: "无关片段", evidenceBlockIDs: [blockID])]
                ),
                provenance: DigestProvenance(
                    modelIdentifier: "api.example.com/test-model",
                    generatedAt: MaterialDigestPresentationFixture.now,
                    inputFingerprint: snapshot.contentFingerprint,
                    summaryContractVersion: MaterialDigestSummaryContract.v3
                ),
                completedAt: MaterialDigestPresentationFixture.now,
                contentFingerprint: snapshot.contentFingerprint
            ),
            lastFailure: nil,
            preparedSnapshot: snapshot,
            createdAt: MaterialDigestPresentationFixture.now,
            updatedAt: MaterialDigestPresentationFixture.now
        )
    }

    static func v3SucceededPDF() -> MaterialDigest {
        let item = Inspiration.urlFixture()
        let blockID = MaterialBlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000e102")!)
        let block = MaterialBlock(
            id: blockID,
            role: .ocr,
            text: "扫描页上的论点",
            locator: .page(number: 3),
            confidence: .init(basisPoints: 9_200)
        )
        let snapshot = snapshot(blocks: [block], coverage: .sufficient)
        return MaterialDigest(
            id: MaterialDigestID(),
            inspirationID: item.id,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(item),
            currentRun: nil,
            result: MaterialDigestResult(
                summary: InspirationSummary(
                    thesis: DigestClaim(text: "核心论点", evidenceBlockIDs: [blockID]),
                    takeaways: [DigestClaim(text: "页内观点", evidenceBlockIDs: [blockID])],
                    chapters: [
                        DigestChapter(
                            title: "扫描页",
                            anchorBlockID: blockID,
                            points: [DigestClaim(text: "要点", evidenceBlockIDs: [blockID])]
                        )
                    ],
                    quotes: [
                        DigestQuote(speaker: nil, text: "扫描页上的论点", evidenceBlockID: blockID)
                    ],
                    dropped: [DigestClaim(text: "无关页眉", evidenceBlockIDs: [blockID])]
                ),
                provenance: DigestProvenance(
                    modelIdentifier: "api.example.com/test-model",
                    generatedAt: MaterialDigestPresentationFixture.now,
                    inputFingerprint: snapshot.contentFingerprint,
                    summaryContractVersion: MaterialDigestSummaryContract.v3
                ),
                completedAt: MaterialDigestPresentationFixture.now,
                contentFingerprint: snapshot.contentFingerprint
            ),
            lastFailure: nil,
            preparedSnapshot: snapshot,
            createdAt: MaterialDigestPresentationFixture.now,
            updatedAt: MaterialDigestPresentationFixture.now
        )
    }

    private static func snapshot(
        blocks: [MaterialBlock],
        coverage: MaterialCoverage
    ) -> MaterialSnapshot {
        let draft = MaterialSnapshot(
            sourceChecksum: "pending",
            contentFingerprint: "pending",
            blocks: blocks,
            coverage: coverage,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: "test-adapter",
                adapterVersion: "1",
                acquiredAt: MaterialDigestPresentationFixture.now
            ),
            createdAt: MaterialDigestPresentationFixture.now
        )
        let fingerprint = (try? WorkspaceChecksum.materialSnapshotContentFingerprint(draft)) ?? "pending"
        return MaterialSnapshot(
            sourceChecksum: draft.sourceChecksum,
            contentFingerprint: fingerprint,
            blocks: blocks,
            coverage: coverage,
            provenance: draft.provenance,
            createdAt: draft.createdAt
        )
    }
}

private extension BlockDocument {
    var plainText: String {
        blocks.map { $0.inlineContent.spans.map(\.text).joined() }.joined(separator: "\n")
    }
}
