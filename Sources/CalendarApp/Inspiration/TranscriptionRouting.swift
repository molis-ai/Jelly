import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif
import WorkspaceDomain

enum TranscriptionRoute: Equatable, Sendable {
    case platformSpeech
    case localSenseVoice
    case cloud
    case localWhisper
    case unavailable
}

struct TranscriptionCapabilities: Equatable, Sendable {
    var platformSpeechAvailable: Bool
    var cloudOptIn: Bool
    var cloudConfigured: Bool
    var whisperOptIn: Bool
}

enum TranscriptionRoutePolicy {
    /// System speech needs no download. Otherwise the on-device model is
    /// SenseVoice-Small. Cloud upload and Whisper stay behind explicit switches.
    static func route(_ capabilities: TranscriptionCapabilities) -> TranscriptionRoute {
        if capabilities.platformSpeechAvailable { return .platformSpeech }
        return .localSenseVoice
    }
}

enum MiniMaxSpeechEndpoint {
    static let maximumUploadBytes: Int64 = 45_000_000
    static let maximumUploadSeconds = 480.0

    static func supportsSpeech(endpoint: String) -> Bool {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        return host == "api.minimaxi.com"
            || host == "api.minimax.io"
            || host.hasSuffix(".minimaxi.com")
            || host.hasSuffix(".minimax.io")
    }

    static func speechURL(endpoint: String) -> URL? {
        guard supportsSpeech(endpoint: endpoint),
              var components = URLComponents(string: endpoint)
        else { return nil }
        let path = components.path
        if path == "/v1" || path.hasSuffix("/v1") {
            components.path = path + "/speech_to_text"
        } else if path.isEmpty || path == "/" {
            components.path = "/v1/speech_to_text"
        } else {
            return nil
        }
        return components.url
    }

    static func shouldUploadWhole(byteCount: Int64, durationSeconds: Double?) -> Bool {
        guard byteCount <= maximumUploadBytes else { return false }
        guard let durationSeconds, durationSeconds.isFinite else { return true }
        return durationSeconds <= maximumUploadSeconds
    }

    static func transcript(fromJSON data: Data) throws -> TimestampedTranscript {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text = (object?["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let duration = object?["duration"] as? Double
        let rawSegments = object?["segments"] as? [[String: Any]] ?? []
        let segments = rawSegments.compactMap { item -> TranscriptSegment? in
            let piece = (item["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !piece.isEmpty,
                  let start = item["start"] as? Double,
                  let end = item["end"] as? Double
            else { return nil }
            return TranscriptSegment(
                startSeconds: start,
                endSeconds: max(start, end),
                text: piece
            )
        }
        let transcript: TimestampedTranscript
        if segments.isEmpty, !text.isEmpty {
            let end = duration ?? 0
            transcript = TimestampedTranscript(segments: [
                TranscriptSegment(startSeconds: 0, endSeconds: max(0, end), text: text)
            ])
        } else {
            transcript = TimestampedTranscript(segments: segments)
        }
        guard MaterialTranscriptSemantics.hasSemanticContent(transcript) else {
            throw MaterialDigestPipelineError.insufficientContent
        }
        return transcript
    }
}

protocol SpeechTranscriptionEngine: Sendable {
    func isAvailable() async -> Bool
    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript
}

protocol CloudSpeechUploading: Sendable {
    func upload(
        fileURL: URL,
        endpoint: URL,
        authorization: String
    ) async throws -> TimestampedTranscript
}

actor RoutingMaterialTranscriber: MaterialTranscribing {
    private let settings: TranscriptionSettingsReader
    private let senseVoice: any MaterialTranscribing
    private let whisper: WhisperKitMaterialTranscriber
    private let platform: any SpeechTranscriptionEngine
    private let cloud: any CloudSpeechUploading
    /// iPhone keeps this false so a phone never downloads Whisper.
    private let whisperInstalled: Bool

    init(
        settings: TranscriptionSettingsReader,
        whisper: WhisperKitMaterialTranscriber,
        senseVoice: (any MaterialTranscribing)? = nil,
        platform: any SpeechTranscriptionEngine = LivePlatformSpeechEngine(),
        cloud: any CloudSpeechUploading = LiveMiniMaxSpeechUploader(),
        whisperInstalled: Bool = true
    ) {
        self.settings = settings
        self.senseVoice = senseVoice ?? SenseVoiceMaterialTranscriber()
        self.whisper = whisper
        self.platform = platform
        self.cloud = cloud
        self.whisperInstalled = whisperInstalled
    }

    func modelRequirement() async -> MaterialModelRequirement {
        switch await route() {
        case .platformSpeech, .cloud, .unavailable:
            return .ready
        case .localSenseVoice:
            return await senseVoice.modelRequirement()
        case .localWhisper:
            return await whisper.modelRequirement()
        }
    }

    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        switch await route() {
        case .localSenseVoice:
            try await senseVoice.prepareModel(progress: progress)
        case .localWhisper:
            try await whisper.prepareModel(progress: progress)
        case .platformSpeech, .cloud, .unavailable:
            return
        }
    }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        let capabilities = await capabilities()
        switch TranscriptionRoutePolicy.route(capabilities) {
        case .platformSpeech:
            do {
                return try await platform.transcribe(fileURL, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch MaterialDigestPipelineError.insufficientContent {
                throw MaterialDigestPipelineError.insufficientContent
            } catch {
                return try await fallbackAfterPlatform(fileURL, capabilities: capabilities, progress: progress)
            }
        case .localSenseVoice:
            do {
                return try await senseVoice.transcribe(fileURL, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch MaterialDigestPipelineError.insufficientContent {
                throw MaterialDigestPipelineError.insufficientContent
            } catch {
                return try await fallbackAfterLocal(fileURL, capabilities: capabilities, progress: progress)
            }
        case .cloud:
            return try await upload(fileURL, progress: progress)
        case .localWhisper:
            return try await whisper.transcribe(fileURL, progress: progress)
        case .unavailable:
            throw MaterialDigestPipelineError.transcriptionUnavailable
        }
    }

    private func fallbackAfterLocal(
        _ fileURL: URL,
        capabilities: TranscriptionCapabilities,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        if capabilities.cloudOptIn, capabilities.cloudConfigured {
            return try await upload(fileURL, progress: progress)
        }
        if capabilities.whisperOptIn {
            return try await whisper.transcribe(fileURL, progress: progress)
        }
        throw MaterialDigestPipelineError.transcriptionFailed
    }

    private func fallbackAfterPlatform(
        _ fileURL: URL,
        capabilities: TranscriptionCapabilities,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        do {
            return try await senseVoice.transcribe(fileURL, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch MaterialDigestPipelineError.insufficientContent {
            throw MaterialDigestPipelineError.insufficientContent
        } catch {
            return try await fallbackAfterLocal(fileURL, capabilities: capabilities, progress: progress)
        }
    }

    private func upload(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        let snapshot = settingsSnapshot()
        guard let endpoint = MiniMaxSpeechEndpoint.speechURL(endpoint: snapshot.endpoint),
              let secret = snapshot.secret,
              !secret.isEmpty
        else { throw MaterialDigestPipelineError.transcriptionUnavailable }
        return try await cloud.upload(
            fileURL: fileURL,
            endpoint: endpoint,
            authorization: "Bearer \(secret)"
        )
    }

    private func route() async -> TranscriptionRoute {
        TranscriptionRoutePolicy.route(await capabilities())
    }

    private func capabilities() async -> TranscriptionCapabilities {
        let snapshot = settingsSnapshot()
        return TranscriptionCapabilities(
            platformSpeechAvailable: await platform.isAvailable(),
            cloudOptIn: snapshot.allowCloud,
            cloudConfigured: MiniMaxSpeechEndpoint.supportsSpeech(endpoint: snapshot.endpoint)
                && !(snapshot.secret ?? "").isEmpty,
            whisperOptIn: whisperInstalled && snapshot.allowWhisper
        )
    }

    private func settingsSnapshot() -> TranscriptionSettingsSnapshot {
        settings.snapshot()
    }
}

final class TranscriptionSettingsReader: @unchecked Sendable {
    private let settings: DigestSettingsStore
    private let credentials: any DigestCredentialStoring

    init(settings: DigestSettingsStore, credentials: any DigestCredentialStoring) {
        self.settings = settings
        self.credentials = credentials
    }

    func snapshot() -> TranscriptionSettingsSnapshot {
        TranscriptionSettingsSnapshot(
            allowCloud: settings.cloudSpeechUploadEnabled,
            allowWhisper: settings.allowLocalWhisper,
            endpoint: settings.endpoint,
            secret: try? credentials.load()
        )
    }
}

struct TranscriptionSettingsSnapshot: Sendable {
    var allowCloud: Bool
    var allowWhisper: Bool
    var endpoint: String
    var secret: String?
}

struct LivePlatformSpeechEngine: SpeechTranscriptionEngine {
    func isAvailable() async -> Bool {
        #if canImport(Speech)
        guard #available(macOS 26.0, iOS 26.0, *) else { return false }
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) != nil
        #else
        return false
        #endif
    }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        #if canImport(Speech)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw MaterialDigestPipelineError.transcriptionUnavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN"))
        else { throw MaterialDigestPipelineError.transcriptionUnavailable }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = SpeechAnalyzer(modules: [module])
        progress(0.1)
        async let analysis: Void = {
            _ = try await analyzer.analyzeSequence(from: audioFile)
        }()
        var segments: [TranscriptSegment] = []
        for try await result in module.results {
            guard result.isFinal else { continue }
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = result.range.start.seconds
            let end = result.range.end.seconds
            segments.append(TranscriptSegment(
                startSeconds: start.isFinite ? start : 0,
                endSeconds: end.isFinite ? max(start, end) : 0,
                text: text
            ))
        }
        try await analysis
        progress(1)
        let transcript = TimestampedTranscript(segments: segments)
        guard MaterialTranscriptSemantics.hasSemanticContent(transcript) else {
            throw MaterialDigestPipelineError.insufficientContent
        }
        return transcript
        #else
        throw MaterialDigestPipelineError.transcriptionUnavailable
        #endif
    }
}

struct LiveMiniMaxSpeechUploader: CloudSpeechUploading {
    func upload(
        fileURL: URL,
        endpoint: URL,
        authorization: String
    ) async throws -> TimestampedTranscript {
        let pieces = try await MiniMaxAudioSlicer.slices(of: fileURL)
        var combined: [TranscriptSegment] = []
        var offset = 0.0
        for piece in pieces {
            let data = try Data(contentsOf: piece.url)
            let transcript = try await Self.post(
                data: data,
                filename: piece.url.lastPathComponent,
                endpoint: endpoint,
                authorization: authorization
            )
            combined.append(contentsOf: transcript.segments.map {
                TranscriptSegment(
                    startSeconds: $0.startSeconds + offset,
                    endSeconds: $0.endSeconds + offset,
                    text: $0.text
                )
            })
            offset += piece.duration
            if piece.isTemporary {
                try? FileManager.default.removeItem(at: piece.url)
            }
        }
        let transcript = TimestampedTranscript(segments: combined)
        guard MaterialTranscriptSemantics.hasSemanticContent(transcript) else {
            throw MaterialDigestPipelineError.insufficientContent
        }
        return transcript
    }

    private static func post(
        data: Data,
        filename: String,
        endpoint: URL,
        authorization: String
    ) async throws -> TimestampedTranscript {
        let boundary = "jelly-speech-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nasr-1.0\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authorization.replacingOccurrences(of: "Bearer ", with: ""))", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("zh", forHTTPHeaderField: "language")
        request.httpBody = body
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw MaterialDigestPipelineError.authenticationFailed }
        guard (200..<300).contains(status) else {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        return try MiniMaxSpeechEndpoint.transcript(fromJSON: responseData)
    }
}

private struct MiniMaxAudioSlice: Sendable {
    var url: URL
    var duration: Double
    var isTemporary: Bool
}

private enum MiniMaxAudioSlicer {
    static func slices(of fileURL: URL) async throws -> [MiniMaxAudioSlice] {
        let byteCount = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let asset = AVURLAsset(url: fileURL)
        let seconds = try? await asset.load(.duration).seconds
        if MiniMaxSpeechEndpoint.shouldUploadWhole(byteCount: byteCount, durationSeconds: seconds) {
            return [MiniMaxAudioSlice(url: fileURL, duration: seconds ?? 0, isTemporary: false)]
        }
        let duration = seconds ?? 0
        guard duration.isFinite, duration > 0 else {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        var slices: [MiniMaxAudioSlice] = []
        var start = 0.0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var index = 0
        while start < duration {
            let end = min(duration, start + MiniMaxSpeechEndpoint.maximumUploadSeconds)
            let output = directory.appendingPathComponent("slice-\(index).m4a")
            try await export(asset, from: start, to: end, output: output)
            slices.append(MiniMaxAudioSlice(url: output, duration: end - start, isTemporary: true))
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
