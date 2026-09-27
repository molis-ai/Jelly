import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("TranscriptionRoutePolicyTests")
struct TranscriptionRoutePolicyTests {
    @Test func systemSpeechWinsWhenItIsAvailable() {
        let route = TranscriptionRoutePolicy.route(TranscriptionCapabilities(
            platformSpeechAvailable: true,
            cloudOptIn: true,
            cloudConfigured: true,
            whisperOptIn: true
        ))
        #expect(route == .platformSpeech)
    }

    @Test func senseVoiceIsTheLocalDefaultWhenSystemSpeechIsUnavailable() {
        let route = TranscriptionRoutePolicy.route(TranscriptionCapabilities(
            platformSpeechAvailable: false,
            cloudOptIn: true,
            cloudConfigured: true,
            whisperOptIn: true
        ))
        #expect(route == .localSenseVoice)
    }

    @Test func miniMaxSpeechURLStaysOnTheConfiguredHost() {
        #expect(
            MiniMaxSpeechEndpoint.speechURL(endpoint: "https://api.minimaxi.com/v1")?.absoluteString
                == "https://api.minimaxi.com/v1/speech_to_text"
        )
        #expect(MiniMaxSpeechEndpoint.speechURL(endpoint: "https://api.example.com/v1") == nil)
        #expect(MiniMaxSpeechEndpoint.shouldUploadWhole(byteCount: 1_000, durationSeconds: 30))
        #expect(!MiniMaxSpeechEndpoint.shouldUploadWhole(byteCount: 1_000, durationSeconds: 600))
        #expect(!MiniMaxSpeechEndpoint.shouldUploadWhole(byteCount: 50_000_000, durationSeconds: 10))
    }

    @Test func verboseJSONBecomesTimestampedSegments() throws {
        let json = """
        {"text":"你好","duration":2,"segments":[{"start":0.1,"end":1.2,"text":"你好"}]}
        """.data(using: .utf8)!
        let transcript = try MiniMaxSpeechEndpoint.transcript(fromJSON: json)
        #expect(transcript.segments.map(\.text) == ["你好"])
        #expect(transcript.segments[0].startSeconds == 0.1)
    }

    @Test func emptyCloudTranscriptIsNotUsableContent() {
        let json = #"{"text":"","duration":1}"#.data(using: .utf8)!
        #expect(throws: MaterialDigestPipelineError.insufficientContent) {
            try MiniMaxSpeechEndpoint.transcript(fromJSON: json)
        }
    }

    @Test func routerDoesNotAskForAWhisperDownloadWhenSystemSpeechExists() async {
        let transcriber = makeRouter(platformAvailable: true, allowCloud: false, allowWhisper: false)
        let requirement = await transcriber.modelRequirement()
        #expect(requirement == .ready)
    }

    @Test func missingSenseVoiceAsksForItsOwnDownloadInsteadOfWhisper() async {
        let transcriber = makeRouter(
            platformAvailable: false,
            allowCloud: false,
            allowWhisper: true,
            senseVoiceInstalled: false
        )
        let requirement = await transcriber.modelRequirement()
        #expect(requirement == .downloadRequired(approximateBytes: SenseVoiceMaterialTranscriber.approximateBytes))
    }

    @Test func routerUsesSenseVoiceAfterTheSystemTranscriberFails() async throws {
        let transcriber = makeRouter(
            platformAvailable: true,
            platformFails: true,
            allowCloud: true,
            allowWhisper: false
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip.m4a")
        let transcript = try await transcriber.transcribe(file) { _ in }
        #expect(transcript.segments.map(\.text) == ["SenseVoice"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MINIMAX"] == "1"))
    func liveMiniMaxSpeechDoesNotInventTextForSilence() async throws {
        let secret = try #require(ProcessInfo.processInfo.environment["MINIMAX_API_KEY"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilenceWAV(to: url)
        await #expect(throws: MaterialDigestPipelineError.insufficientContent) {
            try await LiveMiniMaxSpeechUploader().upload(
                fileURL: url,
                endpoint: URL(string: "https://api.minimaxi.com/v1/speech_to_text")!,
                authorization: "Bearer \(secret)"
            )
        }
    }

    @Test func phoneBuildUsesSenseVoiceAndNeverNeedsWhisper() async throws {
        let transcriber = makeRouter(
            platformAvailable: false,
            allowCloud: false,
            allowWhisper: true,
            whisperInstalled: false
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip.m4a")
        let transcript = try await transcriber.transcribe(file) { _ in }
        #expect(transcript.segments.map(\.text) == ["SenseVoice"])
    }

    @Test func senseVoiceFailureFallsThroughToCloudWhenUploadIsAllowed() async throws {
        let transcriber = makeRouter(
            platformAvailable: false,
            allowCloud: true,
            allowWhisper: false,
            senseVoiceFails: true
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip.m4a")
        let transcript = try await transcriber.transcribe(file) { _ in }
        #expect(transcript.segments.map(\.text) == ["云端转写"])
    }
}

private func makeRouter(
    platformAvailable: Bool,
    platformFails: Bool = false,
    allowCloud: Bool,
    allowWhisper: Bool,
    whisperInstalled: Bool = true,
    senseVoiceInstalled: Bool = true,
    senseVoiceFails: Bool = false
) -> RoutingMaterialTranscriber {
    let defaults = UserDefaults(suiteName: "jelly-route-\(UUID().uuidString)")!
    let settings = DigestSettingsStore(defaults: defaults)
    #expect(settings.save(endpoint: "https://api.minimaxi.com/v1", model: "MiniMax-M3"))
    settings.setAllowCloudTranscription(allowCloud)
    settings.setAllowLocalWhisper(allowWhisper)
    let credentials = InMemoryDigestCredentialStore()
    try? credentials.save("test-secret")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("jelly-whisper-\(UUID().uuidString)", isDirectory: true)
    return RoutingMaterialTranscriber(
        settings: TranscriptionSettingsReader(settings: settings, credentials: credentials),
        whisper: WhisperKitMaterialTranscriber(modelDirectory: directory),
        senseVoice: FakeSenseVoice(installed: senseVoiceInstalled, fails: senseVoiceFails),
        platform: FakeSpeechEngine(available: platformAvailable, fails: platformFails),
        cloud: FakeCloudUploader(),
        whisperInstalled: whisperInstalled
    )
}

private actor FakeSenseVoice: MaterialTranscribing {
    let installed: Bool
    let fails: Bool

    init(installed: Bool, fails: Bool) {
        self.installed = installed
        self.fails = fails
    }

    func modelRequirement() async -> MaterialModelRequirement {
        installed
            ? .ready
            : .downloadRequired(approximateBytes: SenseVoiceMaterialTranscriber.approximateBytes)
    }

    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        if fails { throw MaterialDigestPipelineError.transcriptionFailed }
        return TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "SenseVoice")
        ])
    }
}

private struct FakeSpeechEngine: SpeechTranscriptionEngine {
    var available: Bool
    var fails: Bool

    func isAvailable() async -> Bool { available }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        if fails { throw MaterialDigestPipelineError.transcriptionFailed }
        return TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "系统转写")
        ])
    }
}

private func writeSilenceWAV(to url: URL) throws {
    let sampleCount = 16_000
    var data = Data()
    func append(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    data.append(contentsOf: "RIFF".utf8)
    append(UInt32(36 + sampleCount * 2))
    data.append(contentsOf: "WAVEfmt ".utf8)
    append(16); append16(1); append16(1); append(16_000); append(32_000); append16(2); append16(16)
    data.append(contentsOf: "data".utf8)
    append(UInt32(sampleCount * 2))
    data.append(Data(count: sampleCount * 2))
    try data.write(to: url)
}

private struct FakeCloudUploader: CloudSpeechUploading {
    func upload(
        fileURL: URL,
        endpoint: URL,
        authorization: String
    ) async throws -> TimestampedTranscript {
        TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "云端转写")
        ])
    }
}
