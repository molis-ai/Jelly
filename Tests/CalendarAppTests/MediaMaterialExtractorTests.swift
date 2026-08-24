import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MediaMaterialExtractorTests")
struct MediaMaterialExtractorTests {
    @Test func videoCombinesTranscriptAndUniqueFrameOCRWithExplicitVisualBoundary() async throws {
        let transcriber = FixtureMediaTranscriber(transcript: TimestampedTranscript(segments: [
            .init(startSeconds: 0, endSeconds: 10, text: "口播正文")
        ]))
        let frames = FixtureVideoFrameSampler(images: (1...3).map {
            MaterialImageAsset(index: $0, data: Data([UInt8($0)]))
        })
        let ocr = FixtureMediaOCR(results: [
            1: [.init(text: "封面标题", confidence: 0.98)],
            2: [.init(text: "封面标题", confidence: 0.97)],
            3: [.init(text: "结尾行动", confidence: 0.95)]
        ])
        let extractor = MediaMaterialExtractor(
            transcriber: transcriber,
            audioTrackExtractor: PassthroughAudioTrackExtractor(),
            frameSampler: frames,
            ocr: ocr
        )

        let batch = try await extractor.extract(
            url: URL(fileURLWithPath: "/tmp/sample.mp4"),
            kind: .video,
            runID: MaterialDigestRunID(),
            progress: { _ in }
        )

        #expect(batch.blocks.map(\.role) == [.transcript, .ocr, .ocr])
        #expect(batch.blocks.map(\.text) == ["口播正文", "封面标题", "结尾行动"])
        guard case let .partial(processed, expected, issues) = batch.coverage else {
            Issue.record("video must expose its visual understanding boundary")
            return
        }
        #expect(processed == 2)
        #expect(expected == 2)
        #expect(issues.contains(.visualSemanticsUnavailable))
    }

    @Test func audioUsesTranscriptWithoutFrameWork() async throws {
        let transcriber = FixtureMediaTranscriber(transcript: TimestampedTranscript(segments: [
            .init(startSeconds: 0, endSeconds: 4, text: "音频正文")
        ]))
        let frames = FixtureVideoFrameSampler(images: [])
        let extractor = MediaMaterialExtractor(
            transcriber: transcriber,
            audioTrackExtractor: PassthroughAudioTrackExtractor(),
            frameSampler: frames,
            ocr: FixtureMediaOCR(results: [:])
        )

        let batch = try await extractor.extract(
            url: URL(fileURLWithPath: "/tmp/sample.m4a"),
            kind: .audio,
            runID: MaterialDigestRunID(),
            progress: { _ in }
        )

        #expect(batch.blocks.map(\.text) == ["音频正文"])
        #expect(batch.coverage == .sufficient)
        #expect(frames.invocationCount == 0)
    }
}

private struct PassthroughAudioTrackExtractor: MaterialAudioTrackExtracting {
    func extractAudio(from url: URL, runID: MaterialDigestRunID) async throws -> URL { url }
    func cleanup(runID: MaterialDigestRunID) {}
}

private final class FixtureMediaTranscriber: MaterialTranscribing, @unchecked Sendable {
    let transcript: TimestampedTranscript
    init(transcript: TimestampedTranscript) { self.transcript = transcript }
    func modelRequirement() async -> MaterialModelRequirement { .ready }
    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript { transcript }
}

private final class FixtureVideoFrameSampler: MaterialVideoFrameSampling, @unchecked Sendable {
    private let lock = NSLock()
    let images: [MaterialImageAsset]
    private var invocations = 0
    init(images: [MaterialImageAsset]) { self.images = images }
    var invocationCount: Int { lock.withLock { invocations } }
    func sampleFrames(from url: URL) async throws -> [MaterialImageAsset] {
        lock.withLock { invocations += 1 }
        return images
    }
}

private struct FixtureMediaOCR: MaterialOCRRecognizing {
    let results: [Int: [MaterialOCRLine]]
    func recognize(_ image: MaterialImageAsset) async throws -> [MaterialOCRLine] {
        results[image.index] ?? []
    }
}
