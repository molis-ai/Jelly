import AVFoundation
import FluidAudio
import Foundation
import WorkspaceDomain

actor SenseVoiceMaterialTranscriber: MaterialTranscribing {
    static let approximateBytes: Int64 = 250_000_000
    /// The converted encoder serves about 108 seconds. Stay under that.
    static let maximumSliceSeconds = 90.0

    private var manager: SenseVoiceManager?

    func modelRequirement() async -> MaterialModelRequirement {
        if manager != nil || Self.modelsPresent() { return .ready }
        return .downloadRequired(approximateBytes: Self.approximateBytes)
    }

    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        if manager != nil { return }
        do {
            manager = try await SenseVoiceManager.load(precision: .int8) { update in
                progress(update.fractionCompleted)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.modelDownloadFailed
        }
    }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        if manager == nil {
            try await prepareModel(progress: progress)
        }
        guard let manager else { throw MaterialDigestPipelineError.transcriptionFailed }
        let slices = try await Self.slices(of: fileURL)
        var segments: [TranscriptSegment] = []
        var offset = 0.0
        for slice in slices {
            try Task.checkCancellation()
            let text = try await manager.transcribe(audioURL: slice.url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if MaterialTranscriptSemantics.hasSemanticContent(text) {
                segments.append(TranscriptSegment(
                    startSeconds: offset,
                    endSeconds: offset + slice.duration,
                    text: text
                ))
            }
            offset += slice.duration
            if slice.isTemporary {
                try? FileManager.default.removeItem(at: slice.url)
            }
            progress(min(1, offset / max(offset, 1)))
        }
        let transcript = TimestampedTranscript(segments: segments)
        guard MaterialTranscriptSemantics.hasSemanticContent(transcript) else {
            throw MaterialDigestPipelineError.insufficientContent
        }
        return transcript
    }

    private static func modelsPresent() -> Bool {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return false }
        let directory = support
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("sensevoice-small-coreml", isDirectory: true)
        return SenseVoiceModels.modelsExist(at: directory, precision: .int8)
    }

    private static func slices(of fileURL: URL) async throws -> [SpeechAudioSlice] {
        let asset = AVURLAsset(url: fileURL)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > maximumSliceSeconds else {
            return [SpeechAudioSlice(url: fileURL, duration: max(0, seconds), isTemporary: false)]
        }
        var slices: [SpeechAudioSlice] = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-sensevoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var start = 0.0
        var index = 0
        while start < seconds {
            let end = min(seconds, start + maximumSliceSeconds)
            let output = directory.appendingPathComponent("slice-\(index).m4a")
            try await export(asset, from: start, to: end, output: output)
            slices.append(SpeechAudioSlice(url: output, duration: end - start, isTemporary: true))
            start = end
            index += 1
        }
        return slices
    }

    private static func export(
        _ asset: AVURLAsset,
        from start: Double,
        to end: Double,
        output: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw MaterialDigestPipelineError.transcriptionFailed }
        session.outputURL = output
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MaterialDigestPipelineError.transcriptionFailed)
                }
            }
        }
    }
}

private struct SpeechAudioSlice: Sendable {
    var url: URL
    var duration: Double
    var isTemporary: Bool
}
