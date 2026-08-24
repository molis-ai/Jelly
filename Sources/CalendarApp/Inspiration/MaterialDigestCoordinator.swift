import Foundation
import Observation
import WorkspaceDomain

@MainActor
@Observable
final class MaterialDigestCoordinator: MaterialDigestOperating {
    private enum TaskPurpose: Equatable {
        case pipeline
        case confirmedModelDownload
    }

    private struct TaskEntry {
        let token: UUID
        let runID: MaterialDigestRunID
        let purpose: TaskPurpose
        let task: Task<Void, Never>
    }

    private struct PendingComposite {
        let runID: MaterialDigestRunID
        let sourceChecksum: String
        let acquisition: MaterialCompositeAcquisition
    }

    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let acquirer: any MaterialAcquiring
    @ObservationIgnored private let audioDownloader: any MaterialAudioDownloading
    @ObservationIgnored private let transcriber: any MaterialTranscribing
    @ObservationIgnored private let summarizer: any MaterialSummarizing
    @ObservationIgnored private let fileAccess: any MaterialFileAccessing
    @ObservationIgnored private let textExtractor: TextMaterialExtractor
    @ObservationIgnored private let htmlExtractor: HTMLMaterialExtractor
    @ObservationIgnored private let imageExtractor: ImageMaterialExtractor
    @ObservationIgnored private let pdfExtractor: PDFMaterialExtractor
    @ObservationIgnored private let mediaExtractor: MediaMaterialExtractor
    @ObservationIgnored private var tasks: [InspirationID: TaskEntry] = [:]
    @ObservationIgnored private var pendingComposites: [InspirationID: PendingComposite] = [:]
    private var progressValues: [InspirationID: Double] = [:]

    init(
        store: WorkspaceStore,
        acquirer: any MaterialAcquiring,
        audioDownloader: any MaterialAudioDownloading,
        transcriber: any MaterialTranscribing,
        summarizer: any MaterialSummarizing,
        fileAccess: any MaterialFileAccessing = LocalMaterialFileAccess(),
        textExtractor: TextMaterialExtractor = TextMaterialExtractor(),
        htmlExtractor: HTMLMaterialExtractor = HTMLMaterialExtractor(),
        imageExtractor: ImageMaterialExtractor = ImageMaterialExtractor(),
        pdfExtractor: PDFMaterialExtractor = PDFMaterialExtractor(),
        mediaExtractor: MediaMaterialExtractor? = nil
    ) {
        self.store = store
        self.acquirer = acquirer
        self.audioDownloader = audioDownloader
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.fileAccess = fileAccess
        self.textExtractor = textExtractor
        self.htmlExtractor = htmlExtractor
        self.imageExtractor = imageExtractor
        self.pdfExtractor = pdfExtractor
        self.mediaExtractor = mediaExtractor ?? MediaMaterialExtractor(transcriber: transcriber)
    }

    func start(
        inspirationID: InspirationID,
        mode: MaterialDigestStartMode = .reusePreparedSnapshot
    ) async {
        guard let source = materialSource(for: inspirationID) else { return }
        let digest = store.state.materialDigests[inspirationID]
        let resolvedMode: MaterialDigestStartMode
        if mode == .reusePreparedSnapshot,
           let snapshot = digest?.pendingSnapshot ?? digest?.preparedSnapshot,
           snapshot.sourceChecksum == source.sourceChecksum {
            resolvedMode = .reusePreparedSnapshot
        } else {
            resolvedMode = .refreshSource
        }
        let digestID = digest?.id ?? MaterialDigestID()
        let runID = MaterialDigestRunID()
        let outcome = try? await store.sendWorkspace(
            .startMaterialDigest(
                .init(
                    inspirationID: inspirationID,
                    digestID: digestID,
                    runID: runID,
                    expectedSourceChecksum: source.sourceChecksum,
                    mode: resolvedMode
                )
            )
        )
        guard case .committed = outcome else { return }
        if let stale = pendingComposites.removeValue(forKey: inspirationID) {
            cleanupExternalArtifacts(runID: stale.runID)
        }
        launch(
            inspirationID: inspirationID,
            runID: runID,
            checksum: source.sourceChecksum,
            purpose: .pipeline
        ) {
            if resolvedMode == .reusePreparedSnapshot {
                try await self.summarizePreparedSnapshot(source: source, runID: runID)
            } else {
                try await self.runFromResolving(source: source, runID: runID)
            }
        }
    }

    func confirmModelDownload(inspirationID: InspirationID) async {
        guard let digest = store.state.materialDigests[inspirationID],
              let run = digest.currentRun,
              run.stage == .awaitingModelDownloadConsent,
              let source = materialSource(for: inspirationID),
              source.sourceChecksum == digest.sourceChecksum
        else { return }
        let runID = run.id
        if let existing = tasks[inspirationID],
           existing.runID == runID,
           existing.purpose == .confirmedModelDownload {
            return
        }
        launch(
            inspirationID: inspirationID,
            runID: runID,
            checksum: source.sourceChecksum,
            purpose: .confirmedModelDownload
        ) {
            try await self.runConfirmedDownload(source: source, runID: runID)
        }
    }

    func cancel(inspirationID: InspirationID) async {
        let runningTask = tasks[inspirationID]?.task
        if let digest = store.state.materialDigests[inspirationID],
           let run = digest.currentRun {
            _ = try? await store.sendWorkspace(
                .cancelMaterialDigest(
                    .init(
                        inspirationID: inspirationID,
                        runID: run.id,
                        sourceChecksum: digest.sourceChecksum
                    )
                )
            )
        }
        runningTask?.cancel()
        pendingComposites.removeValue(forKey: inspirationID)
        progressValues.removeValue(forKey: inspirationID)
    }

    func stopExternalWork(inspirationID: InspirationID) async {
        let taskRunID = tasks[inspirationID]?.runID
        let pendingRunID = pendingComposites[inspirationID]?.runID
        let currentRunID = store.state.materialDigests[inspirationID]?.currentRun?.id
        tasks[inspirationID]?.task.cancel()
        tasks[inspirationID] = nil
        pendingComposites.removeValue(forKey: inspirationID)
        progressValues.removeValue(forKey: inspirationID)
        for runID in Set([taskRunID, pendingRunID, currentRunID].compactMap { $0 }) {
            cleanupExternalArtifacts(runID: runID)
        }
    }

    func progress(for inspirationID: InspirationID) -> Double? {
        progressValues[inspirationID]
    }

    func reconcileInterruptedRuns() async {
        let activeRunIDs = Set(store.state.materialDigests.values.compactMap { $0.currentRun?.id })
        audioDownloader.cleanupOrphans(keeping: activeRunIDs)
        for (inspirationID, digest) in store.state.materialDigests {
            guard let run = digest.currentRun else { continue }
            _ = try? await store.sendWorkspace(
                .markInterruptedMaterialDigest(
                    .init(
                        inspirationID: inspirationID,
                        runID: run.id,
                        sourceChecksum: digest.sourceChecksum
                    )
                )
            )
            if run.stage != .awaitingModelDownloadConsent {
                tasks[inspirationID]?.task.cancel()
                audioDownloader.cleanup(runID: run.id)
                progressValues.removeValue(forKey: inspirationID)
            }
        }
    }

    private func launch(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        checksum: String,
        purpose: TaskPurpose,
        operation: @escaping () async throws -> Void
    ) {
        let token = UUID()
        tasks[inspirationID]?.task.cancel()
        progressValues.removeValue(forKey: inspirationID)
        let task = Task { [weak self] in
            defer {
                self?.finishTask(inspirationID: inspirationID, runID: runID, token: token)
            }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError {
                guard self.isTaskCurrent(inspirationID: inspirationID, token: token) else { return }
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: .cancelled
                )
            } catch let error as MaterialDigestPipelineError {
                guard self.isTaskCurrent(inspirationID: inspirationID, token: token) else { return }
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: error
                )
            } catch {
                guard self.isTaskCurrent(inspirationID: inspirationID, token: token) else { return }
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: nil
                )
            }
        }
        tasks[inspirationID] = TaskEntry(token: token, runID: runID, purpose: purpose, task: task)
    }

    private func isTaskCurrent(inspirationID: InspirationID, token: UUID) -> Bool {
        tasks[inspirationID]?.token == token
    }

    private func finishTask(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        token: UUID
    ) {
        guard let current = tasks[inspirationID] else { return }
        guard current.token == token else {
            if current.runID != runID { cleanupExternalArtifacts(runID: runID) }
            return
        }
        tasks[inspirationID] = nil
        progressValues.removeValue(forKey: inspirationID)
        cleanupExternalArtifacts(runID: runID)
        if store.state.materialDigests[inspirationID]?.currentRun?.stage
            != .awaitingModelDownloadConsent {
            pendingComposites.removeValue(forKey: inspirationID)
        }
    }

    private func cleanupExternalArtifacts(runID: MaterialDigestRunID) {
        audioDownloader.cleanup(runID: runID)
        mediaExtractor.audioTrackExtractor.cleanup(runID: runID)
    }

    private func runConfirmedDownload(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try await advance(.downloadingModel, source: source, runID: runID)
        try await transcriber.prepareModel(progress: progressHandler(
            inspirationID: source.inspirationID,
            runID: runID
        ))
        try Task.checkCancellation()
        try await advance(.fetchingSource, source: source, runID: runID)
        if let pending = pendingComposites[source.inspirationID],
           pending.runID == runID,
           pending.sourceChecksum == source.sourceChecksum {
            pendingComposites.removeValue(forKey: source.inspirationID)
            try await runComposite(pending.acquisition, source: source, runID: runID)
            return
        }
        try await runFromResolving(source: source, runID: runID)
    }

    private func runFromResolving(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try Task.checkCancellation()
        if store.state.materialDigests[source.inspirationID]?.currentRun?.stage == .resolvingSource {
            try await advance(.fetchingSource, source: source, runID: runID)
        }
        switch source.descriptor.kind {
        case .localText:
            try await runDirectText(source: source, runID: runID)
            return
        case .localFile:
            try await runLocalFile(source: source, runID: runID)
            return
        case .bilibiliVideo, .xiaoyuzhouEpisode, .publicWebArticle, .xiaohongshuNote:
            break
        }
        let acquisition: MaterialAcquisition
        do {
            acquisition = try await acquirer.acquire(source)
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            return
        }
        let contextualSource = try await sourceWaitingForLatestTitle(source, runID: runID)
        switch acquisition {
        case let .blocks(batch):
            try await persistAndSummarize(batch, source: contextualSource, runID: runID)
        case let .remoteMedia(asset):
            try await runAudio(RemoteAudioAsset(asset), source: contextualSource, runID: runID)
        case let .composite(value):
            try await runComposite(value, source: contextualSource, runID: runID)
        }
    }

    private func runComposite(
        _ acquisition: MaterialCompositeAcquisition,
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        var blocks = acquisition.seedBlocks
        var issues = acquisition.issues
        var processedAssets = 0

        if !acquisition.images.isEmpty || (acquisition.expectedAssetCount > 0 && acquisition.remoteMedia == nil) {
            try await advance(.recognizingImages, source: source, runID: runID)
            let imageBatch = try await imageExtractor.extract(acquisition.images)
            blocks.append(contentsOf: imageBatch.blocks)
            switch imageBatch.coverage {
            case .sufficient:
                processedAssets += acquisition.images.count
            case let .partial(processed, _, imageIssues):
                processedAssets += processed
                Self.appendUnique(imageIssues, to: &issues)
            case .insufficient:
                if !issues.contains(.ocrFailed) { issues.append(.ocrFailed) }
            }
        }

        if let media = acquisition.remoteMedia {
            let requirement = await transcriber.modelRequirement()
            switch requirement {
            case let .downloadRequired(approximateBytes):
                pendingComposites[source.inspirationID] = PendingComposite(
                    runID: runID,
                    sourceChecksum: source.sourceChecksum,
                    acquisition: acquisition
                )
                try await advance(
                    .awaitingModelDownloadConsent,
                    source: source,
                    runID: runID,
                    modelDownloadApproximateBytes: approximateBytes
                )
                return
            case .ready:
                try await advance(.transcribing, source: source, runID: runID)
            }
            do {
                let fileURL = try await audioDownloader.download(
                    RemoteAudioAsset(media),
                    runID: runID,
                    progress: progressHandler(inspirationID: source.inspirationID, runID: runID)
                )
                let mediaBatch = try await mediaExtractor.extract(
                    url: fileURL,
                    kind: media.kind,
                    runID: runID,
                    progress: progressHandler(inspirationID: source.inspirationID, runID: runID)
                )
                blocks.append(contentsOf: mediaBatch.blocks)
                if !mediaBatch.blocks.isEmpty { processedAssets += 1 }
                switch mediaBatch.coverage {
                case .sufficient:
                    break
                case let .partial(_, _, mediaIssues):
                    Self.appendUnique(mediaIssues, to: &issues)
                case .insufficient:
                    if !issues.contains(.transcriptionFailed) { issues.append(.transcriptionFailed) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !issues.contains(.inaccessibleAsset) { issues.append(.inaccessibleAsset) }
            }
        }

        let semanticBlocks = blocks.filter {
            $0.role != .metadata && MaterialTranscriptSemantics.hasSemanticContent($0.text)
        }
        let coverage: MaterialCoverage
        if semanticBlocks.isEmpty {
            coverage = .insufficient(code: .metadataOnly)
        } else if issues.isEmpty,
                  processedAssets >= acquisition.expectedAssetCount {
            coverage = .sufficient
        } else {
            coverage = .partial(
                processed: min(processedAssets, acquisition.expectedAssetCount),
                expected: acquisition.expectedAssetCount > 0 ? acquisition.expectedAssetCount : nil,
                issues: issues
            )
        }
        try await persistAndSummarize(
            MaterialBlockBatch(
                blocks: blocks,
                coverage: coverage,
                provenance: acquisition.provenance
            ),
            source: source,
            runID: runID
        )
    }

    private static func appendUnique(
        _ additions: [MaterialCoverageIssue],
        to issues: inout [MaterialCoverageIssue]
    ) {
        for issue in additions where !issues.contains(issue) { issues.append(issue) }
    }

    private func runDirectText(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        guard let text = source.text else { throw MaterialDigestPipelineError.sourceUnavailable }
        try await advance(.extractingText, source: source, runID: runID)
        let batch = try await textExtractor.extract(.direct(text: text))
        try await persistAndSummarize(batch, source: source, runID: runID)
    }

    private func runLocalFile(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        guard let reference = source.fileReference else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        if source.kind == .audio || source.kind == .video {
            let requirement = await transcriber.modelRequirement()
            switch requirement {
            case let .downloadRequired(approximateBytes):
                try await advance(
                    .awaitingModelDownloadConsent,
                    source: source,
                    runID: runID,
                    modelDownloadApproximateBytes: approximateBytes
                )
                return
            case .ready:
                try await advance(.transcribing, source: source, runID: runID)
            }
        } else if source.kind == .image {
            try await advance(.recognizingImages, source: source, runID: runID)
        } else {
            try await advance(.extractingText, source: source, runID: runID)
        }

        let kind = source.kind
        let textExtractor = textExtractor
        let htmlExtractor = htmlExtractor
        let imageExtractor = imageExtractor
        let pdfExtractor = pdfExtractor
        let mediaExtractor = mediaExtractor
        let progress = progressHandler(inspirationID: source.inspirationID, runID: runID)
        let batch = try await fileAccess.withAccess(to: reference) { url in
            switch kind {
            case .plainText:
                return try await textExtractor.extract(.file(url: url, utiIdentifier: nil))
            case .article:
                let data = try Self.boundedFileData(
                    at: url,
                    maximumBytes: MaterialDigestContentLimits.maximumMaterialCharacters * 4 + 4
                )
                return try htmlExtractor.extract(data: data, baseURL: url)
            case .image:
                let data = try Self.boundedFileData(at: url, maximumBytes: 100_000_000)
                return try await imageExtractor.extract([
                    MaterialImageAsset(index: 1, data: data)
                ])
            case .document:
                return try await pdfExtractor.extract(url: url)
            case .audio:
                return try await mediaExtractor.extract(
                    url: url,
                    kind: .audio,
                    runID: runID,
                    progress: progress
                )
            case .video:
                return try await mediaExtractor.extract(
                    url: url,
                    kind: .video,
                    runID: runID,
                    progress: progress
                )
            case .socialPost, .unknown:
                throw MaterialDigestPipelineError.unsupportedSource
            }
        }
        try await persistAndSummarize(batch, source: source, runID: runID)
    }

    private func persistAndSummarize(
        _ batch: MaterialBlockBatch,
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try await saveSnapshot(
            Self.snapshot(from: batch, sourceChecksum: source.sourceChecksum),
            source: source,
            runID: runID
        )
        if case .insufficient = batch.coverage {
            throw MaterialDigestPipelineError.insufficientContent
        }
        try await summarizePreparedSnapshot(source: source, runID: runID)
    }

    nonisolated private static func boundedFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumBytes {
            throw MaterialDigestPipelineError.contextTooLong
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard data.count <= maximumBytes else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        return data
    }

    private func runAudio(
        _ asset: RemoteAudioAsset,
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        let requirement = await transcriber.modelRequirement()
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            return
        }
        switch requirement {
        case let .downloadRequired(approximateBytes):
            try await advance(
                .awaitingModelDownloadConsent,
                source: source,
                runID: runID,
                modelDownloadApproximateBytes: approximateBytes
            )
            return
        case .ready:
            let fileURL = try await audioDownloader.download(
                asset,
                runID: runID,
                progress: progressHandler(inspirationID: source.inspirationID, runID: runID)
            )
            try Task.checkCancellation()
            guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
                return
            }
            let contextualSource = sourceWithLatestTitle(source)
            try await advance(.transcribing, source: contextualSource, runID: runID)
            let transcript: TimestampedTranscript
            do {
                transcript = try await transcriber.transcribe(
                    fileURL,
                    progress: progressHandler(
                        inspirationID: contextualSource.inspirationID,
                        runID: runID
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MaterialDigestPipelineError {
                throw error
            } catch {
                throw MaterialDigestPipelineError.transcriptionFailed
            }
            try await saveSnapshot(
                Self.snapshot(
                    from: .transcript(transcript, adapterIdentifier: "whisper"),
                    sourceChecksum: contextualSource.sourceChecksum
                ),
                source: sourceWithLatestTitle(contextualSource),
                runID: runID
            )
            try await summarizePreparedSnapshot(
                source: sourceWithLatestTitle(contextualSource),
                runID: runID
            )
        }
    }

    private func summarizePreparedSnapshot(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        guard let snapshot = store.state.materialDigests[source.inspirationID]?.pendingSnapshot,
              snapshot.sourceChecksum == source.sourceChecksum
        else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard summarizer.isConfigured else {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
        try await advance(.summarizing, source: source, runID: runID)
        let output: MaterialSummarizerOutput
        do {
            output = try await summarizer.summarize(snapshot, source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        try Task.checkCancellation()
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum),
              store.state.materialDigests[source.inspirationID]?.pendingSnapshot?.contentFingerprint
                == snapshot.contentFingerprint
        else {
            return
        }
        let contentFingerprint = snapshot.contentFingerprint
        _ = try await store.sendWorkspace(
            .completeMaterialDigest(
                .init(
                    expectation: .init(
                        inspirationID: source.inspirationID,
                        runID: runID,
                        sourceChecksum: source.sourceChecksum
                    ),
                    expectedContentFingerprint: contentFingerprint,
                    summary: output.summary,
                    provenance: DigestProvenance(
                        modelIdentifier: "\(output.endpointHost)/\(output.model)",
                        generatedAt: Date.distantPast,
                        inputFingerprint: source.inputFingerprint,
                        summaryContractVersion: output.summaryContractVersion
                    )
                )
            )
        )
    }

    private func saveSnapshot(
        _ snapshot: MaterialSnapshot,
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try Task.checkCancellation()
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            throw CancellationError()
        }
        let outcome = try await store.sendWorkspace(
            .saveMaterialSnapshot(
                .init(
                    expectation: .init(
                        inspirationID: source.inspirationID,
                        runID: runID,
                        sourceChecksum: source.sourceChecksum
                    ),
                    snapshot: snapshot
                )
            )
        )
        guard case .committed = outcome else {
            throw CancellationError()
        }
    }

    private static func snapshot(
        from batch: MaterialBlockBatch,
        sourceChecksum: String
    ) throws -> MaterialSnapshot {
        let draft = MaterialSnapshot(
            sourceChecksum: sourceChecksum,
            contentFingerprint: "pending",
            blocks: batch.blocks,
            coverage: batch.coverage,
            provenance: batch.provenance,
            createdAt: Date()
        )
        let fingerprint = try WorkspaceChecksum.materialSnapshotContentFingerprint(draft)
        return MaterialSnapshot(
            sourceChecksum: sourceChecksum,
            contentFingerprint: fingerprint,
            blocks: batch.blocks,
            coverage: batch.coverage,
            provenance: batch.provenance,
            createdAt: draft.createdAt
        )
    }

    private func advance(
        _ stage: MaterialDigestStage,
        source: MaterialSource,
        runID: MaterialDigestRunID,
        modelDownloadApproximateBytes: Int64? = nil
    ) async throws {
        try Task.checkCancellation()
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            throw CancellationError()
        }
        let outcome = try await store.sendWorkspace(
            .advanceMaterialDigestStage(
                .init(
                    expectation: .init(
                        inspirationID: source.inspirationID,
                        runID: runID,
                        sourceChecksum: source.sourceChecksum
                    ),
                    stage: stage,
                    modelDownloadApproximateBytes: modelDownloadApproximateBytes
                )
            )
        )
        guard case .committed = outcome else {
            throw CancellationError()
        }
        progressValues.removeValue(forKey: source.inspirationID)
    }

    private func progressHandler(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID
    ) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.publishProgress(fraction, inspirationID: inspirationID, runID: runID)
            }
        }
    }

    private func publishProgress(
        _ fraction: Double,
        inspirationID: InspirationID,
        runID: MaterialDigestRunID
    ) {
        guard fraction.isFinite,
              tasks[inspirationID]?.runID == runID,
              store.state.materialDigests[inspirationID]?.currentRun?.id == runID
        else { return }
        let clamped = min(1, max(0, fraction))
        let quantized = Double(Int((clamped * 100).rounded(.down))) / 100
        guard progressValues[inspirationID] != quantized else { return }
        progressValues[inspirationID] = quantized
    }

    private func failIfCurrent(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        checksum: String,
        error: MaterialDigestPipelineError?
    ) async {
        guard isCurrent(inspirationID: inspirationID, runID: runID, checksum: checksum) else { return }
        if error == .cancelled {
            _ = try? await store.sendWorkspace(
                .cancelMaterialDigest(
                    .init(inspirationID: inspirationID, runID: runID, sourceChecksum: checksum)
                )
            )
            return
        }
        let mapped = Self.mappedFailure(error)
        _ = try? await store.sendWorkspace(
            .failMaterialDigest(
                .init(
                    expectation: .init(
                        inspirationID: inspirationID,
                        runID: runID,
                        sourceChecksum: checksum
                    ),
                    code: mapped.code,
                    userMessage: mapped.message
                )
            )
        )
    }

    private func isCurrent(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        checksum: String
    ) -> Bool {
        guard let digest = store.state.materialDigests[inspirationID],
              let run = digest.currentRun
        else { return false }
        return run.id == runID && digest.sourceChecksum == checksum
    }

    private func materialSource(for inspirationID: InspirationID) -> MaterialSource? {
        guard let inspiration = store.state.inspirations[inspirationID],
              inspiration.lifecycle == .active,
              inspiration.supportsMaterialDigest,
              let source = MaterialSourceResolver.resolve(inspiration)
        else { return nil }
        return source
    }

    private func sourceWithLatestTitle(_ source: MaterialSource) -> MaterialSource {
        guard let latest = materialSource(for: source.inspirationID),
              latest.sourceChecksum == source.sourceChecksum,
              latest.sourceTitle != nil
        else { return source }
        return latest
    }

    private func sourceWaitingForLatestTitle(
        _ source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws -> MaterialSource {
        let observedTitle = source.sourceTitle
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard isCurrent(
                inspirationID: source.inspirationID,
                runID: runID,
                checksum: source.sourceChecksum
            ) else {
                throw CancellationError()
            }
            let latest = sourceWithLatestTitle(source)
            let fetchStatus = store.state.inspirations[source.inspirationID]?
                .resolvedMetadata?.fetchStatus
            if latest.sourceTitle != observedTitle || fetchStatus != .loading {
                return latest
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return sourceWithLatestTitle(source)
    }

    private static func mappedFailure(
        _ error: MaterialDigestPipelineError?
    ) -> (code: MaterialDigestFailure.Code, message: String) {
        switch error {
        case .unsupportedSource:
            (.unsupportedSource, "这类材料还不能提炼。")
        case .restrictedSource:
            (.restrictedSource, "来源受限，无法读取材料。")
        case .sourceUnavailable:
            (.sourceUnavailable, "暂时无法读取材料，原始材料仍然保留。")
        case .modelDownloadFailed:
            (.modelDownloadFailed, "模型下载失败，可以稍后重试。")
        case .transcriptionFailed:
            (.transcriptionFailed, "本机识别失败，原始材料仍然保留。")
        case .modelNotConfigured:
            (.modelNotConfigured, "尚未配置摘要模型，请先在设置中填写。")
        case .authenticationFailed:
            (.authenticationFailed, "摘要接口拒绝了密钥，请在设置中检查后重试。")
        case .accessDenied:
            (.accessDenied, "当前密钥没有该模型的访问权限，请检查模型或权限。")
        case .summarizationFailed:
            (.summarizationFailed, "摘要请求失败，可以稍后重试。")
        case .contextTooLong:
            (.summarizationFailed, "材料超过当前模型可处理长度")
        case .jsonSchemaUnsupported:
            (.summarizationFailed, "当前接口不支持可校验的 JSON 摘要，请更换兼容端点。")
        case .invalidSummary:
            (.invalidSummary, "模型返回的摘要无法校验，没有写入占位内容。")
        case .insufficientContent:
            (.insufficientContent, "没有识别到可提炼的内容，原始材料仍然保留。")
        case .cancelled, .none:
            (.summarizationFailed, "提炼未完成，原始材料仍然保留。")
        }
    }
}
