import CryptoKit
import Foundation
import Observation
import WorkspaceDomain

struct MaterialSource: Equatable, Sendable {
    enum Input: Equatable, Sendable {
        case url(URL)
        case text(String)
        case file(FileReference)
    }

    let inspirationID: InspirationID
    let input: Input
    let kind: ResolvedSourceKind
    let sourceChecksum: String
    let sourceTitle: String?
    let descriptor: MaterialSourceDescriptor

    init(
        inspirationID: InspirationID,
        url: URL,
        kind: ResolvedSourceKind,
        sourceChecksum: String,
        sourceTitle: String? = nil,
        descriptor: MaterialSourceDescriptor? = nil
    ) {
        self.inspirationID = inspirationID
        self.input = .url(url)
        self.kind = kind
        self.sourceChecksum = sourceChecksum
        self.sourceTitle = Self.normalizedSourceTitle(sourceTitle)
        self.descriptor = descriptor ?? MaterialSourceDescriptor(
            kind: MaterialSourceResolver.descriptorKind(for: url)
        )
    }

    init(
        inspirationID: InspirationID,
        text: String,
        sourceChecksum: String
    ) {
        self.inspirationID = inspirationID
        self.input = .text(text)
        self.kind = .plainText
        self.sourceChecksum = sourceChecksum
        self.sourceTitle = nil
        self.descriptor = MaterialSourceDescriptor(kind: .localText)
    }

    init(
        inspirationID: InspirationID,
        file: FileReference,
        kind: ResolvedSourceKind,
        sourceChecksum: String
    ) {
        self.inspirationID = inspirationID
        self.input = .file(file)
        self.kind = kind
        self.sourceChecksum = sourceChecksum
        self.sourceTitle = Self.normalizedSourceTitle(file.displayName)
        self.descriptor = MaterialSourceDescriptor(kind: .localFile)
    }

    var url: URL? {
        guard case let .url(url) = input else { return nil }
        return url
    }

    var text: String? {
        guard case let .text(text) = input else { return nil }
        return text
    }

    var fileReference: FileReference? {
        guard case let .file(file) = input else { return nil }
        return file
    }

    static func normalizedSourceTitle(_ sourceTitle: String?) -> String? {
        let safeTitle = sourceTitle.map { title in
            let canonical = title.precomposedStringWithCanonicalMapping
            let scalars = canonical.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    return Unicode.Scalar(0x20)
                }
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate, .privateUse, .unassigned:
                    return nil
                default:
                    return scalar
                }
            }
            return String(String.UnicodeScalarView(scalars))
        }
        let normalizedTitle = safeTitle?
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalizedTitle.flatMap {
            guard !$0.isEmpty else { return nil }
            return String(String.UnicodeScalarView(Array($0.unicodeScalars.prefix(200))))
        }
    }

    var inputFingerprint: String {
        guard let sourceTitle else { return sourceChecksum }
        let material = "material-digest-input-v1\u{0}\(sourceChecksum)\u{0}\(sourceTitle)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct MaterialBlockBatch: Equatable, Sendable {
    let blocks: [MaterialBlock]
    let coverage: MaterialCoverage
    let provenance: MaterialAcquisitionProvenance

    static func transcript(
        _ transcript: TimestampedTranscript,
        adapterIdentifier: String,
        acquiredAt: Date = Date()
    ) -> MaterialBlockBatch {
        let blocks = transcript.segments.map { segment in
            MaterialBlock(
                id: MaterialBlockID(),
                role: .transcript,
                text: segment.text,
                locator: .timestamp(
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds
                ),
                confidence: nil
            )
        }
        return MaterialBlockBatch(
            blocks: blocks,
            coverage: blocks.isEmpty ? .insufficient(code: .empty) : .sufficient,
            provenance: MaterialAcquisitionProvenance(
                adapterIdentifier: adapterIdentifier,
                adapterVersion: "1",
                acquiredAt: acquiredAt
            )
        )
    }

    var timestampedTranscript: TimestampedTranscript {
        TimestampedTranscript(
            segments: blocks.compactMap { block in
                guard case let .timestamp(start, end) = block.locator else { return nil }
                return TranscriptSegment(startSeconds: start, endSeconds: end, text: block.text)
            }
        )
    }
}

struct RemoteMediaAsset: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case audio
        case video
    }

    let kind: Kind
    let url: URL
    let requestHeaders: [String: String]
    let estimatedBytes: Int64?
}

struct MaterialCompositeAcquisition: Equatable, Sendable {
    let seedBlocks: [MaterialBlock]
    let images: [MaterialImageAsset]
    let remoteMedia: RemoteMediaAsset?
    let expectedAssetCount: Int
    let issues: [MaterialCoverageIssue]
    let provenance: MaterialAcquisitionProvenance
}

enum MaterialAcquisition: Equatable, Sendable {
    case blocks(MaterialBlockBatch)
    case remoteMedia(RemoteMediaAsset)
    case composite(MaterialCompositeAcquisition)

    static func transcript(_ transcript: TimestampedTranscript) -> MaterialAcquisition {
        .blocks(.transcript(transcript, adapterIdentifier: "legacy-transcript"))
    }

    static func remoteAudio(_ asset: RemoteAudioAsset) -> MaterialAcquisition {
        .remoteMedia(
            RemoteMediaAsset(
                kind: .audio,
                url: asset.url,
                requestHeaders: asset.requestHeaders,
                estimatedBytes: asset.estimatedBytes
            )
        )
    }
}

struct RemoteAudioAsset: Equatable, Sendable {
    let url: URL
    let requestHeaders: [String: String]
    let estimatedBytes: Int64?

    init(url: URL, requestHeaders: [String: String], estimatedBytes: Int64?) {
        self.url = url
        self.requestHeaders = requestHeaders
        self.estimatedBytes = estimatedBytes
    }

    init(_ media: RemoteMediaAsset) {
        self.init(
            url: media.url,
            requestHeaders: media.requestHeaders,
            estimatedBytes: media.estimatedBytes
        )
    }
}

struct MaterialSummarizerOutput: Equatable, Sendable {
    let summary: InspirationSummary
    let endpointHost: String
    let model: String
    let summaryContractVersion: String
}

enum MaterialModelRequirement: Equatable, Sendable {
    case ready
    case downloadRequired(approximateBytes: Int64)
}

enum MaterialDigestPipelineError: Error, Equatable, Sendable {
    case unsupportedSource
    case restrictedSource
    case sourceUnavailable
    case modelDownloadFailed
    case transcriptionFailed
    case modelNotConfigured
    case authenticationFailed
    case accessDenied
    case summarizationFailed
    case contextTooLong
    case jsonSchemaUnsupported
    case invalidSummary
    case insufficientContent
    case cancelled
}

enum MaterialTranscriptSemantics {
    static let shortSparseMaximumDurationSeconds: Double = 30
    static let shortSparseMaximumSemanticMass = 3
    static let shortSparseMaximumSemanticDiversityMass = 4

    static func hasSemanticContent(_ transcript: TimestampedTranscript) -> Bool {
        transcript.segments.contains { hasSemanticContent($0.text) }
    }

    static func hasSemanticContent(_ text: String) -> Bool {
        strippingWhisperSpecialTokens(text).unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    static let repetitiveNoiseMinimumSemanticSegmentCount = 3
    static let repetitiveNoiseMaximumSemanticDiversityMass = 4

    static func isLikelyRepetitiveTranscriptionNoise(
        _ transcript: TimestampedTranscript
    ) -> Bool {
        let fingerprints = transcript.segments.compactMap { segment -> String? in
            let fingerprint = normalizedSemanticFingerprint(segment.text)
            return fingerprint.isEmpty ? nil : fingerprint
        }
        guard fingerprints.count >= repetitiveNoiseMinimumSemanticSegmentCount,
              fingerprints.allSatisfy({ $0 == fingerprints[0] }),
              semanticDiversityMass(transcript) <= repetitiveNoiseMaximumSemanticDiversityMass
        else {
            return false
        }
        return true
    }

    static func isShortAndSparse(_ transcript: TimestampedTranscript) -> Bool {
        let duration = transcript.segments.reduce(0.0) { max($0, $1.endSeconds) }
        guard duration.isFinite, duration <= shortSparseMaximumDurationSeconds else {
            return false
        }
        let mass = semanticMass(transcript)
        let diversity = semanticDiversityMass(transcript)
        return mass <= shortSparseMaximumSemanticMass
            || (diversity <= shortSparseMaximumSemanticDiversityMass && mass > diversity)
    }

    static func semanticMass(_ transcript: TimestampedTranscript) -> Int {
        transcript.segments.reduce(0) { $0 + semanticMass($1.text) }
    }

    static func semanticMass(_ text: String) -> Int {
        let stripped = strippingWhisperSpecialTokens(text)
        var mass = 0
        var inWesternWord = false
        for scalar in stripped.unicodeScalars {
            if isWesternAlphanumeric(scalar) {
                inWesternWord = true
                continue
            }
            if inWesternWord {
                mass += 1
                inWesternWord = false
            }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                mass += 1
            }
        }
        if inWesternWord { mass += 1 }
        return mass
    }

    static func semanticDiversityMass(_ transcript: TimestampedTranscript) -> Int {
        var westernWords = Set<String>()
        var nonWesternScalars = Set<Unicode.Scalar>()
        for segment in transcript.segments {
            collectDiversity(
                from: segment.text,
                westernWords: &westernWords,
                nonWesternScalars: &nonWesternScalars
            )
        }
        return westernWords.count + nonWesternScalars.count
    }

    static func semanticDiversityMass(_ text: String) -> Int {
        var westernWords = Set<String>()
        var nonWesternScalars = Set<Unicode.Scalar>()
        collectDiversity(
            from: text,
            westernWords: &westernWords,
            nonWesternScalars: &nonWesternScalars
        )
        return westernWords.count + nonWesternScalars.count
    }

    private static func collectDiversity(
        from text: String,
        westernWords: inout Set<String>,
        nonWesternScalars: inout Set<Unicode.Scalar>
    ) {
        let stripped = strippingWhisperSpecialTokens(text)
        var currentWord = ""
        for scalar in stripped.unicodeScalars {
            if isWesternAlphanumeric(scalar) {
                currentWord.unicodeScalars.append(scalar)
                continue
            }
            if !currentWord.isEmpty {
                westernWords.insert(currentWord.lowercased())
                currentWord = ""
            }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                nonWesternScalars.insert(scalar)
            }
        }
        if !currentWord.isEmpty {
            westernWords.insert(currentWord.lowercased())
        }
    }

    private static let westernAlphanumerics = CharacterSet(charactersIn: "0"..."9")
        .union(CharacterSet(charactersIn: "A"..."Z"))
        .union(CharacterSet(charactersIn: "a"..."z"))

    private static func isWesternAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        westernAlphanumerics.contains(scalar)
    }

    private static func normalizedSemanticFingerprint(_ text: String) -> String {
        let stripped = strippingWhisperSpecialTokens(text).lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in stripped.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    static func strippingWhisperSpecialTokens(_ text: String) -> String {
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let start = result.range(of: "<|", range: searchStart..<result.endIndex) {
            guard let end = result.range(of: "|>", range: start.upperBound..<result.endIndex) else {
                break
            }
            let inner = String(result[start.upperBound..<end.lowerBound])
            if isAllowlistedWhisperControlToken(inner) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
                searchStart = start.lowerBound
            } else {
                searchStart = end.upperBound
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAllowlistedWhisperControlToken(_ inner: String) -> Bool {
        if namedWhisperControlTokens.contains(inner) { return true }
        if isWhisperLanguageToken(inner) { return true }
        return isWhisperTimestampToken(inner)
    }

    private static let namedWhisperControlTokens: Set<String> = [
        "startoftranscript",
        "endoftext",
        "transcribe",
        "translate",
        "nospeech",
        "notimestamps",
        "startofprev",
        "startoflm"
    ]

    private static func isWhisperLanguageToken(_ inner: String) -> Bool {
        (2...3).contains(inner.count)
            && inner.unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
    }

    private static func isWhisperTimestampToken(_ inner: String) -> Bool {
        let parts = inner.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts[0].count <= 3
        else { return false }
        return parts.count == 1 || parts[1].count <= 3
    }
}

protocol MaterialAcquiring: Sendable {
    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition
}

protocol MaterialAudioDownloading: Sendable {
    func download(
        _ asset: RemoteAudioAsset,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    func cleanup(runID: MaterialDigestRunID)
    func cleanupOrphans(keeping activeRunIDs: Set<MaterialDigestRunID>)
}

extension MaterialAudioDownloading {
    func cleanupOrphans(keeping activeRunIDs: Set<MaterialDigestRunID>) {}
}

protocol MaterialTranscribing: Sendable {
    func modelRequirement() async -> MaterialModelRequirement
    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript
}

protocol MaterialSummarizing: Sendable {
    var isConfigured: Bool { get }
    func summarize(
        _ snapshot: MaterialSnapshot,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput
}

@MainActor
protocol MaterialDigestOperating: AnyObject, Observable {
    func start(inspirationID: InspirationID, mode: MaterialDigestStartMode) async
    func confirmModelDownload(inspirationID: InspirationID) async
    func cancel(inspirationID: InspirationID) async
    func stopExternalWork(inspirationID: InspirationID) async
    func reconcileInterruptedRuns() async
    func progress(for inspirationID: InspirationID) -> Double?
}

extension MaterialDigestOperating {
    func start(inspirationID: InspirationID) async {
        await start(inspirationID: inspirationID, mode: .reusePreparedSnapshot)
    }
}
