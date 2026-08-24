import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialDigestCoordinatorTests")
@MainActor
struct MaterialDigestCoordinatorTests {
    @Test func directTextSavesSnapshotBeforeSummaryWithoutCallingURLAcquirer() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let inspiration = Inspiration.text(
            rawText: "第一段正文\n\n第二段正文",
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 1_800_300_000)
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        let acquirer = FixtureMaterialAcquirer(result: .transcript(.init(segments: [])))
        let downloader = RecordingMaterialAudioDownloader()
        let transcriber = FakeMaterialTranscriber(requirement: .ready, transcript: .init(segments: []))
        let summarizer = ControllableMaterialSummarizer(
            mode: .immediate,
            output: MaterialSummarizerOutput(
                summary: InspirationSummary(
                    thesis: "核心论点",
                    takeaways: ["第一条"],
                    chapters: [],
                    quotes: [],
                    dropped: []
                ),
                endpointHost: "api.example.com",
                model: "fixture",
                summaryContractVersion: MaterialDigestSummaryContract.v3
            )
        )
        let coordinator = MaterialDigestCoordinator(
            store: store,
            acquirer: acquirer,
            audioDownloader: downloader,
            transcriber: transcriber,
            summarizer: summarizer
        )

        await coordinator.start(inspirationID: inspiration.id, mode: .refreshSource)

        #expect(await waitUntil { store.state.materialDigests[inspiration.id]?.result != nil })
        #expect(await acquirer.acquireCount == 0)
        let snapshot = try #require(store.state.materialDigests[inspiration.id]?.preparedSnapshot)
        #expect(snapshot.blocks.map(\.text) == ["第一段正文", "第二段正文"])
        #expect(snapshot.blocks.map(\.locator) == [
            .paragraph(index: 1), .paragraph(index: 2)
        ])
    }

    @Test func localTextFileUsesBookmarkAccessAndCompletesTheSameDigestFlow() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-material-\(UUID().uuidString).txt")
        try Data("文件第一段\n\n文件第二段".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .file,
            rawText: nil,
            rawURL: nil,
            rawFile: FileReference(bookmarkData: Data([9, 8, 7]), displayName: "采访.txt"),
            resolvedSourceKind: .plainText,
            resolvedMetadata: nil,
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: Date(timeIntervalSince1970: 1_800_300_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_300_000)
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        let acquirer = FixtureMaterialAcquirer(result: .transcript(.init(segments: [])))
        let summarizer = ControllableMaterialSummarizer(
            mode: .immediate,
            output: MaterialSummarizerOutput(
                summary: InspirationSummary(
                    thesis: "核心论点",
                    takeaways: ["第一条"],
                    chapters: [],
                    quotes: [],
                    dropped: []
                ),
                endpointHost: "api.example.com",
                model: "fixture",
                summaryContractVersion: MaterialDigestSummaryContract.v3
            )
        )
        let coordinator = MaterialDigestCoordinator(
            store: store,
            acquirer: acquirer,
            audioDownloader: RecordingMaterialAudioDownloader(),
            transcriber: FakeMaterialTranscriber(requirement: .ready, transcript: .init(segments: [])),
            summarizer: summarizer,
            fileAccess: FixtureMaterialFileAccess(url: fileURL)
        )

        await coordinator.start(inspirationID: inspiration.id, mode: .refreshSource)

        #expect(await waitUntil { store.state.materialDigests[inspiration.id]?.result != nil })
        #expect(await acquirer.acquireCount == 0)
        let snapshot = try #require(store.state.materialDigests[inspiration.id]?.preparedSnapshot)
        #expect(snapshot.blocks.map(\.text) == ["文件第一段", "文件第二段"])
        #expect(summarizer.receivedSourceTitle == "采访.txt")
    }

    @Test func xiaohongshuImagesCombineBodyAndPartialOCRBeforeSummary() async throws {
        let context = try await makeXiaohongshuCoordinatorContext(
            acquisition: MaterialCompositeAcquisition(
                seedBlocks: xiaohongshuSeedBlocks(),
                images: (1...3).map { MaterialImageAsset(index: $0, data: Data([UInt8($0)])) },
                remoteMedia: nil,
                expectedAssetCount: 3,
                issues: [],
                provenance: xiaohongshuProvenance()
            ),
            imageExtractor: ImageMaterialExtractor(recognizer: CoordinatorFixtureOCR(
                results: [
                    1: .success([.init(text: "图片一", confidence: 0.98)]),
                    2: .success([.init(text: "图片二", confidence: 0.96)]),
                    3: .failure(.unreadable)
                ]
            ))
        )

        await context.coordinator.start(inspirationID: context.inspiration.id, mode: .refreshSource)

        #expect(await waitUntil { context.store.state.materialDigests[context.inspiration.id]?.result != nil })
        let snapshot = try #require(
            context.store.state.materialDigests[context.inspiration.id]?.preparedSnapshot
        )
        #expect(snapshot.blocks.map(\.role) == [.metadata, .body, .metadata, .ocr, .ocr])
        #expect(snapshot.blocks.map(\.text).suffix(2) == ["图片一", "图片二"])
        #expect(snapshot.coverage == .partial(processed: 2, expected: 3, issues: [.ocrFailed]))
    }

    @Test func xiaohongshuVideoCombinesBodyTranscriptAndFrameOCR() async throws {
        let transcriber = FakeMaterialTranscriber(
            requirement: .ready,
            transcript: .init(segments: [
                .init(startSeconds: 0, endSeconds: 5, text: "视频口播")
            ])
        )
        let mediaExtractor = MediaMaterialExtractor(
            transcriber: transcriber,
            audioTrackExtractor: CoordinatorPassthroughAudioTrackExtractor(),
            frameSampler: CoordinatorFixtureFrameSampler(images: [
                MaterialImageAsset(index: 1, data: Data([1]))
            ]),
            ocr: CoordinatorFixtureOCR(results: [
                1: .success([.init(text: "画面标题", confidence: 0.97)])
            ])
        )
        let context = try await makeXiaohongshuCoordinatorContext(
            acquisition: MaterialCompositeAcquisition(
                seedBlocks: xiaohongshuSeedBlocks(),
                images: [],
                remoteMedia: RemoteMediaAsset(
                    kind: .video,
                    url: URL(string: "https://media.example/video.mp4")!,
                    requestHeaders: [:],
                    estimatedBytes: nil
                ),
                expectedAssetCount: 1,
                issues: [],
                provenance: xiaohongshuProvenance()
            ),
            transcriber: transcriber,
            mediaExtractor: mediaExtractor
        )

        await context.coordinator.start(inspirationID: context.inspiration.id, mode: .refreshSource)

        #expect(await waitUntil { context.store.state.materialDigests[context.inspiration.id]?.result != nil })
        let snapshot = try #require(
            context.store.state.materialDigests[context.inspiration.id]?.preparedSnapshot
        )
        #expect(snapshot.blocks.map(\.role) == [.metadata, .body, .metadata, .transcript, .ocr])
        #expect(snapshot.blocks.map(\.text).suffix(2) == ["视频口播", "画面标题"])
        guard case let .partial(_, _, issues) = snapshot.coverage else {
            Issue.record("video snapshot must expose its visual semantics boundary")
            return
        }
        #expect(issues.contains(.visualSemanticsUnavailable))
    }

    @Test func xiaohongshuModelConsentResumesWithoutFetchingThePageAndImagesAgain() async throws {
        let transcriber = FakeMaterialTranscriber(
            requirement: .downloadRequired(approximateBytes: 700_000_000),
            transcript: .init(segments: [
                .init(startSeconds: 0, endSeconds: 5, text: "视频口播")
            ])
        )
        await transcriber.setReadyAfterPrepare(true)
        let mediaExtractor = MediaMaterialExtractor(
            transcriber: transcriber,
            audioTrackExtractor: CoordinatorPassthroughAudioTrackExtractor(),
            frameSampler: CoordinatorFixtureFrameSampler(images: []),
            ocr: CoordinatorFixtureOCR(results: [:])
        )
        let context = try await makeXiaohongshuCoordinatorContext(
            acquisition: MaterialCompositeAcquisition(
                seedBlocks: xiaohongshuSeedBlocks(),
                images: [],
                remoteMedia: RemoteMediaAsset(
                    kind: .video,
                    url: URL(string: "https://media.example/video.mp4")!,
                    requestHeaders: [:],
                    estimatedBytes: nil
                ),
                expectedAssetCount: 1,
                issues: [],
                provenance: xiaohongshuProvenance()
            ),
            transcriber: transcriber,
            mediaExtractor: mediaExtractor
        )

        await context.coordinator.start(inspirationID: context.inspiration.id, mode: .refreshSource)
        #expect(await waitUntil {
            context.store.state.materialDigests[context.inspiration.id]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        #expect(await context.acquirer.acquireCount == 1)

        await context.coordinator.confirmModelDownload(inspirationID: context.inspiration.id)

        #expect(await waitUntil { context.store.state.materialDigests[context.inspiration.id]?.result != nil })
        #expect(await context.acquirer.acquireCount == 1)
        #expect(await transcriber.prepareCount == 1)
    }

    @Test func sourceTitleNormalizationPreservesWordBoundariesAcrossWhitespace() {
        let source = MaterialSource(
            inspirationID: InspirationID(),
            url: URL(string: "https://example.com/material")!,
            kind: .audio,
            sourceChecksum: "checksum",
            sourceTitle: "  Claude\nCode\tAnthropic  "
        )

        #expect(source.sourceTitle == "Claude Code Anthropic")
    }

    @Test func sourceTitleHasAHardUnicodeScalarBound() throws {
        let source = MaterialSource(
            inspirationID: InspirationID(),
            url: URL(string: "https://example.com/material")!,
            kind: .audio,
            sourceChecksum: "checksum",
            sourceTitle: "A" + String(repeating: "\u{0301}", count: 400)
        )

        let title = try #require(source.sourceTitle)
        #expect(title.unicodeScalars.count <= 200)
    }

    @Test func summaryRetryReusesSavedSnapshotWithoutAcquiringOrTranscribingAgain() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: true)
        harness.summarizer.error = .summarizationFailed
        await harness.coordinator.start(inspirationID: harness.inspirationID, mode: .refreshSource)
        #expect(await waitUntil {
            harness.digest?.pendingSnapshot != nil
                && harness.digest?.currentRun == nil
                && harness.digest?.lastFailure?.code == .summarizationFailed
        })
        #expect(await harness.acquirer.acquireCount == 1)
        #expect(await harness.transcriber.transcribeCount == 1)

        harness.summarizer.error = nil
        await harness.coordinator.start(inspirationID: harness.inspirationID, mode: .reusePreparedSnapshot)
        #expect(await waitUntil { harness.digest?.result != nil })
        #expect(await harness.acquirer.acquireCount == 1)
        #expect(await harness.transcriber.transcribeCount == 1)
    }

    @Test func captionPathSkipsDownloaderAndTranscriberThenCompletes() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.caption()
        await harness.coordinator.start(inspirationID: harness.inspirationID)

        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.downloader.downloadCount == 0)
        #expect(await harness.transcriber.transcribeCount == 0)
        let digest = try #require(harness.store.state.materialDigests[harness.inspirationID])
        #expect(digest.currentRun == nil)
        #expect(digest.result?.summary.thesis == "核心论点")
        #expect(digest.result?.provenance.summaryContractVersion == MaterialDigestSummaryContract.v3)
        #expect(await waitUntil { harness.downloader.cleanedRunIDs.count == 1 })
    }

    @Test func audioPathDownloadsAndTranscribesWhenModelReady() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: true)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.downloader.downloadCount == 1)
        #expect(await harness.transcriber.transcribeCount == 1)
        #expect(await harness.transcriber.prepareCount == 0)
    }

    @Test func audioPathPassesSourceTitleAsReadOnlyNamingContext() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: true)
        await harness.coordinator.start(inspirationID: harness.inspirationID)

        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.summarizer.receivedSourceTitle == MaterialDigestCoordinatorHarness.sourceTitle)
        let digest = try #require(harness.store.state.materialDigests[harness.inspirationID])
        #expect(digest.result?.provenance.inputFingerprint != digest.sourceChecksum)
        #expect(
            harness.store.state.materialDigests[harness.inspirationID]?.preparedSnapshot?.timestampedTranscript
                == MaterialDigestCoordinatorHarness.transcript
        )
    }

    @Test func titleThatArrivesDuringAcquisitionStillReachesTranscriptionAndSummary() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(
            modelReady: true,
            sourceTitle: nil
        )
        await harness.acquirer.setHoldAcquire(true)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        await harness.acquirer.waitUntilAcquireStarted()

        let current = try #require(harness.store.state.inspirations[harness.inspirationID])
        _ = try await harness.store.sendWorkspace(
            .updateInspirationMetadata(
                harness.inspirationID,
                expectedSource: .init(
                    sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(current)
                ),
                metadata: SourceMetadata(
                    title: MaterialDigestCoordinatorHarness.sourceTitle,
                    siteName: "小宇宙",
                    domain: current.rawURL?.host,
                    thumbnailURL: nil,
                    fetchStatus: .succeeded
                ),
                resolvedKind: current.resolvedSourceKind
            )
        )
        await harness.acquirer.resumeAcquire()

        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.summarizer.receivedSourceTitle == MaterialDigestCoordinatorHarness.sourceTitle)
    }

    @Test func titleThatArrivesJustAfterAcquisitionStillReachesSummary() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.captionWithSourceTitle(nil)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        await harness.acquirer.waitUntilAcquireStarted()
        try await Task.sleep(for: .milliseconds(25))

        let current = try #require(harness.store.state.inspirations[harness.inspirationID])
        _ = try await harness.store.sendWorkspace(
            .updateInspirationMetadata(
                harness.inspirationID,
                expectedSource: .init(
                    sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(current)
                ),
                metadata: SourceMetadata(
                    title: MaterialDigestCoordinatorHarness.sourceTitle,
                    siteName: "哔哩哔哩",
                    domain: current.rawURL?.host,
                    thumbnailURL: nil,
                    fetchStatus: .succeeded
                ),
                resolvedKind: current.resolvedSourceKind
            )
        )

        #expect(await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.summarizer.receivedSourceTitle == MaterialDigestCoordinatorHarness.sourceTitle)
        let digest = try #require(harness.store.state.materialDigests[harness.inspirationID])
        #expect(digest.result?.provenance.inputFingerprint != digest.sourceChecksum)
    }

    @Test func refreshedTitleReplacesOldTitleWhenMetadataIsStillLoading() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.captionWithSourceTitle("旧标题")
        let initial = try #require(harness.store.state.inspirations[harness.inspirationID])
        _ = try await harness.store.sendWorkspace(
            .updateInspirationMetadata(
                harness.inspirationID,
                expectedSource: .init(
                    sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(initial)
                ),
                metadata: SourceMetadata(
                    title: "旧标题",
                    siteName: "哔哩哔哩",
                    domain: initial.rawURL?.host,
                    thumbnailURL: nil,
                    fetchStatus: .loading
                ),
                resolvedKind: initial.resolvedSourceKind
            )
        )

        await harness.coordinator.start(inspirationID: harness.inspirationID)
        await harness.acquirer.waitUntilAcquireStarted()
        try await Task.sleep(for: .milliseconds(25))

        let current = try #require(harness.store.state.inspirations[harness.inspirationID])
        _ = try await harness.store.sendWorkspace(
            .updateInspirationMetadata(
                harness.inspirationID,
                expectedSource: .init(
                    sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(current)
                ),
                metadata: SourceMetadata(
                    title: MaterialDigestCoordinatorHarness.sourceTitle,
                    siteName: "哔哩哔哩",
                    domain: current.rawURL?.host,
                    thumbnailURL: nil,
                    fetchStatus: .succeeded
                ),
                resolvedKind: current.resolvedSourceKind
            )
        )

        #expect(await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.summarizer.receivedSourceTitle == MaterialDigestCoordinatorHarness.sourceTitle)
    }

    @Test func titleThatChangesDuringTranscriptionIsRefreshedBeforeSummary() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(
            modelReady: true,
            sourceTitle: "旧标题"
        )
        await harness.transcriber.setHoldTranscribe(true)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        await harness.transcriber.waitUntilTranscribeStarted()

        let current = try #require(harness.store.state.inspirations[harness.inspirationID])
        _ = try await harness.store.sendWorkspace(
            .updateInspirationMetadata(
                harness.inspirationID,
                expectedSource: .init(
                    sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(current)
                ),
                metadata: SourceMetadata(
                    title: MaterialDigestCoordinatorHarness.sourceTitle,
                    siteName: "哔哩哔哩",
                    domain: current.rawURL?.host,
                    thumbnailURL: nil,
                    fetchStatus: .succeeded
                ),
                resolvedKind: current.resolvedSourceKind
            )
        )
        await harness.transcriber.resumeTranscribe()

        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.summarizer.receivedSourceTitle == MaterialDigestCoordinatorHarness.sourceTitle)
    }

    @Test func audioPathStopsAtAwaitingConsentWithoutDownloading() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await harness.coordinator.start(inspirationID: harness.inspirationID)

        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        #expect(harness.downloader.downloadCount == 0)
        #expect(await harness.transcriber.prepareCount == 0)
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == nil)
        #expect(
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.modelDownloadApproximateBytes
                == 700_000_000
        )
    }

    @Test func stopExternalWorkCleansAwaitingConsentRunArtifacts() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        let runID = try #require(harness.digest?.currentRun?.id)
        harness.downloader.cleanedRunIDs.removeAll()

        await harness.coordinator.stopExternalWork(inspirationID: harness.inspirationID)

        #expect(harness.downloader.cleanedRunIDs == [runID])
    }

    @Test func modelDownloadFailureMapsToSafeFailureAndKeepsRetry() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        await harness.transcriber.setPrepareError(.modelDownloadFailed)
        await harness.coordinator.confirmModelDownload(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.lastFailure?.code
                == .modelDownloadFailed
        })
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == nil)
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.currentRun == nil)
        #expect(
            harness.store.state.materialDigests[harness.inspirationID]?.lastFailure?.userMessage
                == "模型下载失败，可以稍后重试。"
        )
    }

    @Test func cancellingWhileModelDownloadIsRunningDoesNotComplete() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        await harness.transcriber.setHoldPrepare(true)
        await harness.coordinator.confirmModelDownload(inspirationID: harness.inspirationID)
        await harness.transcriber.waitUntilPrepareStarted()
        await harness.coordinator.cancel(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.lastFailure?.code == .cancelled
        })
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == nil)
        #expect(await harness.transcriber.prepareCount == 1)
    }

    @Test func confirmingModelDownloadPreparesRefetchesAndCompletes() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })

        await harness.transcriber.setReadyAfterPrepare(true)
        await harness.coordinator.confirmModelDownload(inspirationID: harness.inspirationID)
        await harness.coordinator.confirmModelDownload(inspirationID: harness.inspirationID)

        #expect(await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(await harness.transcriber.prepareCount == 1)
        #expect(await harness.acquirer.acquireCount == 2)
        #expect(harness.downloader.downloadCount == 1)
        #expect(await harness.transcriber.transcribeCount == 1)
    }

    @Test func cancelPreventsLateSummaryFromWritingBack() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.caption(summarizer: .suspended)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil { harness.summarizer.started })

        await harness.coordinator.cancel(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.lastFailure?.code == .cancelled
        })

        harness.summarizer.resume(with: MaterialDigestCoordinatorHarness.validOutput)
        try await Task.sleep(for: .milliseconds(40))
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == nil)
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.lastFailure?.code == .cancelled)
    }

    @Test func reconcileInterruptsActiveRunsButKeepsAwaitingConsent() async throws {
        let fetching = try await MaterialDigestCoordinatorHarness.caption(summarizer: .suspended)
        await fetching.coordinator.start(inspirationID: fetching.inspirationID)
        #expect(await waitUntil { fetching.summarizer.started })
        await fetching.coordinator.reconcileInterruptedRuns()
        #expect(await waitUntil {
            fetching.store.state.materialDigests[fetching.inspirationID]?.lastFailure?.code == .interrupted
        })

        let awaiting = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await awaiting.coordinator.start(inspirationID: awaiting.inspirationID)
        #expect(await waitUntil {
            awaiting.store.state.materialDigests[awaiting.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        await awaiting.coordinator.reconcileInterruptedRuns()
        #expect(
            awaiting.store.state.materialDigests[awaiting.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        )
    }

    @Test func retryKeepsPreviousResult() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.caption()
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        let first = try #require(harness.store.state.materialDigests[harness.inspirationID]?.result)

        await harness.acquirer.setResult(.remoteAudio(MaterialDigestCoordinatorHarness.audioAsset))
        await harness.transcriber.setRequirement(.downloadRequired(approximateBytes: 700_000_000))
        await harness.coordinator.start(inspirationID: harness.inspirationID, mode: .refreshSource)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == first)
    }

    @Test func pipelineErrorsMapToSafeChineseMessages() async throws {
        let restricted = try await MaterialDigestCoordinatorHarness.caption()
        await restricted.acquirer.setError(MaterialDigestPipelineError.restrictedSource)
        await restricted.coordinator.start(inspirationID: restricted.inspirationID)
        #expect(await waitUntil {
            restricted.store.state.materialDigests[restricted.inspirationID]?.lastFailure?.code
                == .restrictedSource
        })
        let restrictedMessage = try #require(
            restricted.store.state.materialDigests[restricted.inspirationID]?.lastFailure?.userMessage
        )
        #expect(restrictedMessage.contains("受限"))
        #expect(!restrictedMessage.contains("sk-"))
        #expect(!restrictedMessage.contains("Bearer "))

        let unconfigured = try await MaterialDigestCoordinatorHarness.caption()
        unconfigured.summarizer.isConfigured = false
        await unconfigured.coordinator.start(inspirationID: unconfigured.inspirationID)
        #expect(await waitUntil {
            unconfigured.store.state.materialDigests[unconfigured.inspirationID]?.lastFailure?.code
                == .modelNotConfigured
        })
        #expect(await unconfigured.acquirer.acquireCount == 1)
        #expect(unconfigured.store.state.materialDigests[unconfigured.inspirationID]?.pendingSnapshot != nil)
        let unconfiguredMessage = try #require(
            unconfigured.store.state.materialDigests[unconfigured.inspirationID]?.lastFailure?.userMessage
        )
        #expect(unconfiguredMessage.contains("配置"))
        #expect(!unconfiguredMessage.lowercased().contains("sk-"))

        let invalid = try await MaterialDigestCoordinatorHarness.caption()
        invalid.summarizer.error = MaterialDigestPipelineError.invalidSummary
        await invalid.coordinator.start(inspirationID: invalid.inspirationID)
        #expect(await waitUntil {
            invalid.store.state.materialDigests[invalid.inspirationID]?.lastFailure?.code == .invalidSummary
        })
        #expect(
            invalid.store.state.materialDigests[invalid.inspirationID]?.lastFailure?.userMessage
                == "模型返回的摘要无法校验，没有写入占位内容。"
        )

        let empty = try await MaterialDigestCoordinatorHarness.caption()
        empty.summarizer.error = MaterialDigestPipelineError.insufficientContent
        await empty.coordinator.start(inspirationID: empty.inspirationID)
        #expect(await waitUntil {
            empty.store.state.materialDigests[empty.inspirationID]?.lastFailure?.code
                == .insufficientContent
        })
        #expect(empty.store.state.materialDigests[empty.inspirationID]?.result == nil)
        #expect(empty.store.state.materialDigests[empty.inspirationID]?.currentRun == nil)
        #expect(
            empty.store.state.materialDigests[empty.inspirationID]?.lastFailure?.userMessage
                == "没有识别到可提炼的内容，原始材料仍然保留。"
        )
    }
}

@MainActor
private func makeXiaohongshuCoordinatorContext(
    acquisition: MaterialCompositeAcquisition,
    imageExtractor: ImageMaterialExtractor = ImageMaterialExtractor(),
    transcriber: FakeMaterialTranscriber = FakeMaterialTranscriber(
        requirement: .ready,
        transcript: .init(segments: [])
    ),
    mediaExtractor: MediaMaterialExtractor? = nil
) async throws -> (
    store: WorkspaceStore,
    inspiration: Inspiration,
    coordinator: MaterialDigestCoordinator,
    acquirer: FixtureMaterialAcquirer
) {
    let calendar = makeEmptyState()
    let store = WorkspaceStore(
        initialState: .empty(calendar: calendar),
        repository: InMemoryWorkspaceRepository(initialState: calendar)
    )
    await store.load()
    let now = Date(timeIntervalSince1970: 1_800_300_000)
    let inspiration = Inspiration(
        id: InspirationID(),
        inputKind: .url,
        rawText: nil,
        rawURL: URL(string: "https://www.xiaohongshu.com/explore/public-note")!,
        rawFile: nil,
        resolvedSourceKind: .socialPost,
        resolvedMetadata: nil,
        categoryID: calendar.uncategorizedID,
        lifecycle: .active,
        createdAt: now,
        updatedAt: now
    )
    _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
    let summarizer = ControllableMaterialSummarizer(
        mode: .immediate,
        output: MaterialSummarizerOutput(
            summary: InspirationSummary(
                thesis: "核心论点",
                takeaways: ["第一条"],
                chapters: [],
                quotes: [],
                dropped: []
            ),
            endpointHost: "api.example.com",
            model: "fixture",
            summaryContractVersion: MaterialDigestSummaryContract.v3
        )
    )
    let acquirer = FixtureMaterialAcquirer(result: .composite(acquisition))
    let coordinator = MaterialDigestCoordinator(
        store: store,
        acquirer: acquirer,
        audioDownloader: RecordingMaterialAudioDownloader(),
        transcriber: transcriber,
        summarizer: summarizer,
        imageExtractor: imageExtractor,
        mediaExtractor: mediaExtractor
    )
    return (store, inspiration, coordinator, acquirer)
}

private func xiaohongshuSeedBlocks() -> [MaterialBlock] {
    [
        .init(id: MaterialBlockID(), role: .metadata, text: "标题", locator: .paragraph(index: 1), confidence: nil),
        .init(id: MaterialBlockID(), role: .body, text: "公开正文", locator: .paragraph(index: 1), confidence: nil),
        .init(id: MaterialBlockID(), role: .metadata, text: "话题：#效率", locator: .paragraph(index: 2), confidence: nil)
    ]
}

private func xiaohongshuProvenance() -> MaterialAcquisitionProvenance {
    .init(
        adapterIdentifier: "xiaohongshu-public-page",
        adapterVersion: "1",
        acquiredAt: Date(timeIntervalSince1970: 1_800_300_000)
    )
}

@MainActor
private struct MaterialDigestCoordinatorHarness {
    let store: WorkspaceStore
    let inspirationID: InspirationID
    let acquirer: FixtureMaterialAcquirer
    let downloader: RecordingMaterialAudioDownloader
    let transcriber: FakeMaterialTranscriber
    let summarizer: ControllableMaterialSummarizer
    let coordinator: MaterialDigestCoordinator

    var digest: MaterialDigest? {
        store.state.materialDigests[inspirationID]
    }

    static let audioAsset = RemoteAudioAsset(
        url: URL(string: "https://cdn.example.com/episode.m4a")!,
        requestHeaders: ["Referer": "https://www.xiaoyuzhoufm.com/episode/1"],
        estimatedBytes: 1_024
    )
    static let sourceTitle = "Claude Code 源码泄露｜Anthropic 工程实践"

    static let validOutput = MaterialSummarizerOutput(
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
        endpointHost: "api.example.com",
        model: "test-model",
        summaryContractVersion: MaterialDigestSummaryContract.v3
    )

    static let transcript = TimestampedTranscript(segments: [
        TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
        TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
    ])

    enum SummarizerMode {
        case immediate
        case suspended
    }

    static func caption(summarizer mode: SummarizerMode = .immediate) async throws -> MaterialDigestCoordinatorHarness {
        try await make(
            acquisition: .transcript(transcript),
            modelReady: true,
            summarizer: mode
        )
    }

    static func captionWithSourceTitle(
        _ sourceTitle: String?
    ) async throws -> MaterialDigestCoordinatorHarness {
        try await make(
            acquisition: .transcript(transcript),
            modelReady: true,
            summarizer: .immediate,
            sourceTitle: sourceTitle
        )
    }

    static func audio(
        modelReady: Bool,
        sourceTitle: String? = sourceTitle
    ) async throws -> MaterialDigestCoordinatorHarness {
        try await make(
            acquisition: .remoteAudio(audioAsset),
            modelReady: modelReady,
            summarizer: .immediate,
            sourceTitle: sourceTitle
        )
    }

    private static func make(
        acquisition: MaterialAcquisition,
        modelReady: Bool,
        summarizer mode: SummarizerMode,
        sourceTitle: String? = sourceTitle
    ) async throws -> MaterialDigestCoordinatorHarness {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let url = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!
        let now = Date(timeIntervalSince1970: 1_800_300_000)
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: url,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: sourceTitle.map {
                SourceMetadata(
                    title: $0,
                    siteName: "哔哩哔哩",
                    domain: url.host,
                    thumbnailURL: nil,
                    fetchStatus: .succeeded
                )
            } ?? SourceMetadata(
                title: nil,
                siteName: nil,
                domain: url.host,
                thumbnailURL: nil,
                fetchStatus: .loading
            ),
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        let acquirer = FixtureMaterialAcquirer(result: acquisition)
        let downloader = RecordingMaterialAudioDownloader()
        let transcriber = FakeMaterialTranscriber(
            requirement: modelReady
                ? .ready
                : .downloadRequired(approximateBytes: 700_000_000),
            transcript: transcript
        )
        let summarizer = ControllableMaterialSummarizer(
            mode: mode == .suspended ? .suspended : .immediate,
            output: validOutput
        )
        let coordinator = MaterialDigestCoordinator(
            store: store,
            acquirer: acquirer,
            audioDownloader: downloader,
            transcriber: transcriber,
            summarizer: summarizer
        )
        return .init(
            store: store,
            inspirationID: inspiration.id,
            acquirer: acquirer,
            downloader: downloader,
            transcriber: transcriber,
            summarizer: summarizer,
            coordinator: coordinator
        )
    }
}

private actor FixtureMaterialAcquirer: MaterialAcquiring {
    var result: MaterialAcquisition
    var error: MaterialDigestPipelineError?
    var acquireCount = 0
    private var holdAcquire = false
    private var acquireStarted = false
    private var acquireWaiters: [CheckedContinuation<Void, Never>] = []
    private var acquireContinuation: CheckedContinuation<Void, Never>?

    init(result: MaterialAcquisition) {
        self.result = result
    }

    func setResult(_ value: MaterialAcquisition) { result = value }
    func setError(_ value: MaterialDigestPipelineError?) { error = value }
    func setHoldAcquire(_ value: Bool) { holdAcquire = value }

    func waitUntilAcquireStarted() async {
        if acquireStarted { return }
        await withCheckedContinuation { acquireWaiters.append($0) }
    }

    func resumeAcquire() {
        acquireContinuation?.resume()
        acquireContinuation = nil
    }

    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition {
        acquireCount += 1
        acquireStarted = true
        let waiters = acquireWaiters
        acquireWaiters = []
        waiters.forEach { $0.resume() }
        if holdAcquire {
            await withCheckedContinuation { acquireContinuation = $0 }
        }
        if let error { throw error }
        return result
    }
}

private final class RecordingMaterialAudioDownloader: MaterialAudioDownloading, @unchecked Sendable {
    var downloadCount = 0
    var cleanedRunIDs: [MaterialDigestRunID] = []

    func download(
        _ asset: RemoteAudioAsset,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        downloadCount += 1
        progress(1)
        return URL(fileURLWithPath: "/tmp/jelly-fixture-audio.m4a")
    }

    func cleanup(runID: MaterialDigestRunID) {
        cleanedRunIDs.append(runID)
    }
}

private actor FakeMaterialTranscriber: MaterialTranscribing {
    var requirement: MaterialModelRequirement
    var prepareCount = 0
    var transcribeCount = 0
    let transcript: TimestampedTranscript
    var readyAfterPrepare = false
    private var prepareError: MaterialDigestPipelineError?
    private var holdPrepare = false
    private var prepareHasStarted = false
    private var prepareStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareHold: CheckedContinuation<Void, Error>?
    private var holdTranscribe = false
    private var transcribeHasStarted = false
    private var transcribeStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var transcribeHold: CheckedContinuation<Void, Never>?

    init(requirement: MaterialModelRequirement, transcript: TimestampedTranscript) {
        self.requirement = requirement
        self.transcript = transcript
    }

    func modelRequirement() async -> MaterialModelRequirement { requirement }

    func setRequirement(_ value: MaterialModelRequirement) {
        requirement = value
    }

    func setReadyAfterPrepare(_ value: Bool) {
        readyAfterPrepare = value
    }

    func setPrepareError(_ error: MaterialDigestPipelineError?) {
        prepareError = error
    }

    func setHoldPrepare(_ value: Bool) {
        holdPrepare = value
    }

    func waitUntilPrepareStarted() async {
        if prepareHasStarted { return }
        await withCheckedContinuation { prepareStartedWaiters.append($0) }
    }

    func setHoldTranscribe(_ value: Bool) {
        holdTranscribe = value
    }

    func waitUntilTranscribeStarted() async {
        if transcribeHasStarted { return }
        await withCheckedContinuation { transcribeStartedWaiters.append($0) }
    }

    func resumeTranscribe() {
        transcribeHold?.resume()
        transcribeHold = nil
    }

    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        prepareCount += 1
        prepareHasStarted = true
        let waiters = prepareStartedWaiters
        prepareStartedWaiters = []
        waiters.forEach { $0.resume() }
        if holdPrepare {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    prepareHold = continuation
                }
            } onCancel: {
                Task { await self.cancelHeldPrepare() }
            }
        }
        if let prepareError { throw prepareError }
        if readyAfterPrepare { requirement = .ready }
        progress(1)
    }

    private func cancelHeldPrepare() {
        prepareHold?.resume(throwing: CancellationError())
        prepareHold = nil
    }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        transcribeCount += 1
        transcribeHasStarted = true
        let waiters = transcribeStartedWaiters
        transcribeStartedWaiters = []
        waiters.forEach { $0.resume() }
        if holdTranscribe {
            await withCheckedContinuation { transcribeHold = $0 }
        }
        progress(1)
        return transcript
    }
}

private final class ControllableMaterialSummarizer: MaterialSummarizing, @unchecked Sendable {
    enum Mode {
        case immediate
        case suspended
    }

    var started = false
    var receivedSourceTitle: String?
    var isConfigured = true
    var error: MaterialDigestPipelineError?
    private let mode: Mode
    private let output: MaterialSummarizerOutput
    private var receivedSnapshot: MaterialSnapshot?
    private var continuation: CheckedContinuation<MaterialSummarizerOutput, Error>?

    init(mode: Mode, output: MaterialSummarizerOutput) {
        self.mode = mode
        self.output = output
    }

    func summarize(
        _ snapshot: MaterialSnapshot,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput {
        started = true
        receivedSourceTitle = source.sourceTitle
        receivedSnapshot = snapshot
        if let error { throw error }
        switch mode {
        case .immediate:
            return groundedOutput(output, for: snapshot)
        case .suspended:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
            }
        }
    }

    func resume(with output: MaterialSummarizerOutput) {
        guard let snapshot = receivedSnapshot else { return }
        continuation?.resume(returning: groundedOutput(output, for: snapshot))
        continuation = nil
    }

    private func groundedOutput(
        _ output: MaterialSummarizerOutput,
        for snapshot: MaterialSnapshot
    ) -> MaterialSummarizerOutput {
        let evidenceBlocks = snapshot.blocks.filter { $0.role != .metadata }
        guard let first = evidenceBlocks.first else { return output }
        let second = evidenceBlocks.dropFirst().first ?? first
        let summary = InspirationSummary(
            thesis: DigestClaim(
                text: output.summary.thesis,
                evidenceBlockIDs: [first.id]
            ),
            takeaways: output.summary.takeaways.map {
                DigestClaim(text: $0, evidenceBlockIDs: [first.id])
            },
            chapters: output.summary.chapters.enumerated().map { index, chapter in
                let anchor = index == 0 ? first : second
                return DigestChapter(
                    title: chapter.title,
                    anchorBlockID: anchor.id,
                    points: chapter.points.map {
                        DigestClaim(text: $0, evidenceBlockIDs: [anchor.id])
                    }
                )
            },
            quotes: output.summary.quotes.map {
                DigestQuote(speaker: $0.speaker, text: $0.text, evidenceBlockID: second.id)
            },
            dropped: output.summary.dropped.map {
                DigestClaim(text: $0, evidenceBlockIDs: [first.id])
            }
        )
        return MaterialSummarizerOutput(
            summary: summary,
            endpointHost: output.endpointHost,
            model: output.model,
            summaryContractVersion: MaterialDigestSummaryContract.v3
        )
    }
}

private struct FixtureMaterialFileAccess: MaterialFileAccessing {
    let url: URL

    func withAccess<T: Sendable>(
        to reference: FileReference,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        #expect(!reference.bookmarkData.isEmpty)
        return try await body(url)
    }
}

private struct CoordinatorFixtureOCR: MaterialOCRRecognizing {
    let results: [Int: Result<[MaterialOCRLine], MaterialOCRRecognitionError>]

    func recognize(_ image: MaterialImageAsset) async throws -> [MaterialOCRLine] {
        try results[image.index, default: .success([])].get()
    }
}

private struct CoordinatorPassthroughAudioTrackExtractor: MaterialAudioTrackExtracting {
    func extractAudio(from url: URL, runID: MaterialDigestRunID) async throws -> URL { url }
    func cleanup(runID: MaterialDigestRunID) {}
}

private final class CoordinatorFixtureFrameSampler: MaterialVideoFrameSampling, @unchecked Sendable {
    let images: [MaterialImageAsset]
    init(images: [MaterialImageAsset]) { self.images = images }
    func sampleFrames(from url: URL) async throws -> [MaterialImageAsset] { images }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 800_000_000,
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
}
