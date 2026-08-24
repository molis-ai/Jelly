import Foundation
import WhisperKit
import WorkspaceDomain

struct WhisperKitLoadPolicy: Equatable, Sendable {
    static let fastLoadMinimumPhysicalMemoryBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024

    let prewarm: Bool

    static func automatic(physicalMemoryBytes: UInt64) -> Self {
        Self(prewarm: physicalMemoryBytes < fastLoadMinimumPhysicalMemoryBytes)
    }

    static func automatic(processInfo: ProcessInfo = ProcessInfo.processInfo) -> Self {
        automatic(physicalMemoryBytes: processInfo.physicalMemory)
    }
}

protocol WhisperKitEngine: Sendable {
    func download(
        variant: String,
        downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    func transcribe(
        modelFolder: URL,
        audioPath: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment]
}

actor WhisperKitMaterialTranscriber: MaterialTranscribing {
    static let variant = "large-v3-v20240930_626MB"
    static let approximateBytes: Int64 = 626_000_000
    static var transcriptionDecodeOptionsSkipSpecialTokens: Bool {
        transcriptionDecodeOptions.skipSpecialTokens
    }
    static var transcriptionDecodeOptions: DecodingOptions {
        DecodingOptions(skipSpecialTokens: true, suppressBlank: true)
    }

    private let modelDirectory: URL
    private let engine: any WhisperKitEngine
    private var resolvedModelFolder: URL?

    init(
        modelDirectory: URL,
        engine: any WhisperKitEngine = LiveWhisperKitEngine()
    ) {
        self.modelDirectory = modelDirectory
        self.engine = engine
    }

    func modelRequirement() async -> MaterialModelRequirement {
        if usableModelFolder() != nil {
            return .ready
        }
        return .downloadRequired(approximateBytes: Self.approximateBytes)
    }

    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        if usableModelFolder() != nil { return }
        try Task.checkCancellation()
        let downloadedFolder: URL
        do {
            downloadedFolder = try await engine.download(
                variant: Self.variant,
                downloadBase: modelDirectory,
                progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.modelDownloadFailed
        }
        try Task.checkCancellation()
        guard isUsableModelFolder(downloadedFolder) else {
            throw MaterialDigestPipelineError.modelDownloadFailed
        }
        resolvedModelFolder = downloadedFolder
    }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        try Task.checkCancellation()
        guard let folder = usableModelFolder() else {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        let segments: [TranscriptSegment]
        do {
            segments = try await engine.transcribe(
                modelFolder: folder,
                audioPath: fileURL.path,
                progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        try Task.checkCancellation()
        let transcript = TimestampedTranscript(segments: Self.normalized(segments))
        guard MaterialTranscriptSemantics.hasSemanticContent(transcript),
              !MaterialTranscriptSemantics.isLikelyRepetitiveTranscriptionNoise(transcript)
        else {
            throw MaterialDigestPipelineError.insufficientContent
        }
        return transcript
    }

    private func usableModelFolder() -> URL? {
        if let resolvedModelFolder, isUsableModelFolder(resolvedModelFolder) {
            return resolvedModelFolder
        }
        let parents = [
            modelDirectory,
            modelDirectory.appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml",
                isDirectory: true
            )
        ]
        for parent in parents {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            if let folder = contents.first(where: {
                $0.lastPathComponent.contains(Self.variant) && isUsableModelFolder($0)
            }) {
                resolvedModelFolder = folder
                return folder
            }
        }
        return nil
    }

    private func isUsableModelFolder(_ url: URL) -> Bool {
        let rootPath = modelDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let folderPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard folderPath.hasPrefix(rootPath + "/") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              url.lastPathComponent.contains(Self.variant)
        else { return false }
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("\(name).mlmodelc", isDirectory: true).path
            ) || FileManager.default.fileExists(
                atPath: url.appendingPathComponent("\(name).mlpackage", isDirectory: true).path
            )
        }
    }

    private static func normalized(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let cleaned = segments
            .map {
                TranscriptSegment(
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    text: MaterialTranscriptSemantics.strippingWhisperSpecialTokens($0.text)
                )
            }
            .filter {
                MaterialTranscriptSemantics.hasSemanticContent($0.text)
                    && $0.startSeconds.isFinite
                    && $0.endSeconds.isFinite
                    && $0.startSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds
                    && $0.endSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds
            }
            .sorted { $0.startSeconds < $1.startSeconds }
        var previousStart = -Double.infinity
        return cleaned.map { segment in
            let start = max(0, max(segment.startSeconds, previousStart))
            let end = max(segment.endSeconds, start)
            previousStart = start
            return TranscriptSegment(startSeconds: start, endSeconds: end, text: segment.text)
        }
    }
}

actor LiveWhisperKitEngine: WhisperKitEngine {
    private let loadPolicy: WhisperKitLoadPolicy
    private var cachedKit: WhisperKit?
    private var cachedModelFolder: URL?

    init(loadPolicy: WhisperKitLoadPolicy = .automatic()) {
        self.loadPolicy = loadPolicy
    }

    nonisolated static func makeConfiguration(
        modelFolder: URL,
        loadPolicy: WhisperKitLoadPolicy
    ) -> WhisperKitConfig {
        WhisperKitConfig(
            modelFolder: modelFolder.path,
            prewarm: loadPolicy.prewarm,
            load: true,
            download: false
        )
    }

    func download(
        variant: String,
        downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { downloadProgress in
                if !Task.isCancelled {
                    progress(downloadProgress.fractionCompleted)
                }
            }
        )
        try Task.checkCancellation()
        return folder
    }

    func transcribe(
        modelFolder: URL,
        audioPath: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let kit: WhisperKit
        if let cachedKit, cachedModelFolder == modelFolder {
            kit = cachedKit
        } else {
            let loaded = try await WhisperKit(
                Self.makeConfiguration(modelFolder: modelFolder, loadPolicy: loadPolicy)
            )
            cachedKit = loaded
            cachedModelFolder = modelFolder
            kit = loaded
        }
        let results = try await kit.transcribe(
            audioPath: audioPath,
            decodeOptions: WhisperKitMaterialTranscriber.transcriptionDecodeOptions,
            callback: { _ in
                if Task.isCancelled { return false }
                progress(0.5)
                return nil
            }
        )
        try Task.checkCancellation()
        progress(1)
        return results.flatMap(\.segments).map { segment in
            TranscriptSegment(
                startSeconds: Double(segment.start),
                endSeconds: Double(segment.end),
                text: segment.text
            )
        }
    }
}
