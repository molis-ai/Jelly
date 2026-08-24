import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WorkspaceDomain

protocol MaterialAudioTrackExtracting: Sendable {
    func extractAudio(from url: URL, runID: MaterialDigestRunID) async throws -> URL
    func cleanup(runID: MaterialDigestRunID)
}

protocol MaterialVideoFrameSampling: Sendable {
    func sampleFrames(from url: URL) async throws -> [MaterialImageAsset]
}

final class TemporaryMaterialAudioTrackExtractor: MaterialAudioTrackExtracting, @unchecked Sendable {
    private let rootDirectory: URL

    init(rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Jelly-MaterialDigest-LocalMedia",
        isDirectory: true
    )) {
        self.rootDirectory = rootDirectory
    }

    func extractAudio(from url: URL, runID: MaterialDigestRunID) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        let directory = runDirectory(runID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("audio.m4a")
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        session.outputURL = output
        session.outputFileType = .m4a
        let box = AVAssetExportBox(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        try Task.checkCancellation()
        guard session.status == .completed,
              FileManager.default.fileExists(atPath: output.path)
        else {
            cleanup(runID: runID)
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        return output
    }

    func cleanup(runID: MaterialDigestRunID) {
        try? FileManager.default.removeItem(at: runDirectory(runID))
    }

    private func runDirectory(_ runID: MaterialDigestRunID) -> URL {
        rootDirectory.appendingPathComponent(runID.rawValue.uuidString, isDirectory: true)
    }
}

private final class AVAssetExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

struct AVFoundationVideoFrameSampler: MaterialVideoFrameSampling, Sendable {
    private let maximumFrames: Int
    private let maximumDimension: CGFloat

    init(maximumFrames: Int = 5, maximumDimension: CGFloat = 1_600) {
        self.maximumFrames = maximumFrames
        self.maximumDimension = maximumDimension
    }

    func sampleFrames(from url: URL) async throws -> [MaterialImageAsset] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let fractions = [0.0, 0.25, 0.5, 0.75, 0.999]
        let selected = Array(fractions.prefix(maximumFrames))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        var images: [MaterialImageAsset] = []
        for (index, fraction) in selected.enumerated() {
            try Task.checkCancellation()
            let time = CMTime(seconds: min(seconds - 0.001, max(0, seconds * fraction)), preferredTimescale: 600)
            do {
                let result = try await generator.image(at: time)
                if let data = Self.pngData(result.image) {
                    images.append(MaterialImageAsset(index: index + 1, data: data))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return images
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

struct MediaMaterialExtractor: Sendable {
    let transcriber: any MaterialTranscribing
    let audioTrackExtractor: any MaterialAudioTrackExtracting
    let frameSampler: any MaterialVideoFrameSampling
    let ocr: any MaterialOCRRecognizing

    init(
        transcriber: any MaterialTranscribing,
        audioTrackExtractor: any MaterialAudioTrackExtracting = TemporaryMaterialAudioTrackExtractor(),
        frameSampler: any MaterialVideoFrameSampling = AVFoundationVideoFrameSampler(),
        ocr: any MaterialOCRRecognizing = VisionMaterialOCRRecognizer()
    ) {
        self.transcriber = transcriber
        self.audioTrackExtractor = audioTrackExtractor
        self.frameSampler = frameSampler
        self.ocr = ocr
    }

    func extract(
        url: URL,
        kind: RemoteMediaAsset.Kind,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MaterialBlockBatch {
        switch kind {
        case .audio:
            let transcript = try await transcriber.transcribe(url, progress: progress)
            let batch = MaterialBlockBatch.transcript(
                transcript,
                adapterIdentifier: "local-audio-whisper"
            )
            guard !batch.blocks.isEmpty else {
                throw MaterialDigestPipelineError.insufficientContent
            }
            return batch
        case .video:
            return try await extractVideo(
                url: url,
                runID: runID,
                progress: progress
            )
        }
    }

    private func extractVideo(
        url: URL,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MaterialBlockBatch {
        defer { audioTrackExtractor.cleanup(runID: runID) }
        var blocks: [MaterialBlock] = []
        var issues: [MaterialCoverageIssue] = [.visualSemanticsUnavailable]
        var processed = 0

        do {
            let audioURL = try await audioTrackExtractor.extractAudio(from: url, runID: runID)
            let transcript = try await transcriber.transcribe(audioURL, progress: progress)
            let transcriptBlocks = MaterialBlockBatch.transcript(
                transcript,
                adapterIdentifier: "local-video-whisper"
            ).blocks
            if !transcriptBlocks.isEmpty {
                blocks.append(contentsOf: transcriptBlocks)
                processed += 1
            } else {
                issues.append(.transcriptionFailed)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            issues.append(.transcriptionFailed)
        }

        do {
            let frames = try await frameSampler.sampleFrames(from: url)
            let imageBatch = try await ImageMaterialExtractor(recognizer: ocr).extract(frames)
            if !imageBatch.blocks.isEmpty {
                blocks.append(contentsOf: imageBatch.blocks)
                processed += 1
            }
            for issue in imageBatch.coverage.issues where !issues.contains(issue) {
                issues.append(issue)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            issues.append(.ocrFailed)
        }

        guard !blocks.isEmpty else {
            return MaterialBlockBatch(
                blocks: [],
                coverage: .insufficient(code: .unreadable),
                provenance: provenance
            )
        }
        return MaterialBlockBatch(
            blocks: blocks,
            coverage: .partial(
                processed: processed,
                expected: 2,
                issues: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
            ),
            provenance: provenance
        )
    }

    private var provenance: MaterialAcquisitionProvenance {
        MaterialAcquisitionProvenance(
            adapterIdentifier: "avfoundation-media",
            adapterVersion: "1",
            acquiredAt: Date()
        )
    }
}

private extension MaterialCoverage {
    var issues: [MaterialCoverageIssue] {
        if case let .partial(_, _, issues) = self { return issues }
        return []
    }
}
