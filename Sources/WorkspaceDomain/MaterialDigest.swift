import Foundation

public enum MaterialDigestStage: String, Codable, Equatable, Sendable {
    case resolvingSource
    case fetchingSource
    case extractingText
    case transcribing
    case recognizingImages
    case preparingSummary
    case summarizing
    case awaitingModelDownloadConsent
    case downloadingModel
}

public enum MaterialDigestSummaryContract {
    public static let v1 = "summary-contract-v1"
    public static let v2 = "summary-contract-v2"
    public static let v3 = "summary-contract-v3"
    public static let current = v3

    public static func enforcesEvidenceAndTranscriptEnd(_ version: String) -> Bool {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized != v1
    }

    public static func isLegacy(_ version: String) -> Bool {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == v1 || normalized == v2
    }
}

public enum MaterialDigestContentLimits {
    public static let maximumTimestampSeconds: Double = 604_800
    public static let maximumTranscriptSegments = 50_000
    public static let maximumTranscriptCharacters = 2_000_000
    public static let maximumSegmentCharacters = 10_000
    public static let maximumThesisCharacters = 4_000
    public static let minimumTakeaways = 1
    public static let maximumTakeaways = 7
    public static let takeawayCountRange = minimumTakeaways...maximumTakeaways
    public static let maximumTakeawayCharacters = 2_000
    public static let maximumChapters = 100
    public static let maximumChapterPoints = 20
    public static let maximumChapterTitleCharacters = 500
    public static let maximumPointCharacters = 1_000
    public static let maximumQuotes = 100
    public static let maximumQuoteCharacters = 2_000
    public static let maximumSpeakerCharacters = 200
    public static let maximumDroppedItems = 100
    public static let maximumDroppedItemCharacters = 1_000
    public static let maximumSummaryCharacters = 200_000
    public static let maximumMaterialBlocks = 10_000
    public static let maximumMaterialCharacters = 2_000_000
}

public struct MaterialDigestRun: Codable, Equatable, Sendable {
    public let id: MaterialDigestRunID
    public var stage: MaterialDigestStage
    public let startedAt: Date
    public var updatedAt: Date
    public var modelDownloadApproximateBytes: Int64?

    public init(
        id: MaterialDigestRunID,
        stage: MaterialDigestStage,
        startedAt: Date,
        updatedAt: Date,
        modelDownloadApproximateBytes: Int64? = nil
    ) {
        self.id = id
        self.stage = stage
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.modelDownloadApproximateBytes = modelDownloadApproximateBytes
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public struct TimestampedTranscript: Codable, Equatable, Sendable {
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }
}

public struct DigestChapter: Equatable, Sendable {
    public var startSeconds: Double
    public var title: String
    public var pointClaims: [DigestClaim]
    public var anchorBlockID: MaterialBlockID?

    public var points: [String] {
        get { pointClaims.map(\.text) }
        set { pointClaims = newValue.map { DigestClaim(text: $0, evidenceBlockIDs: []) } }
    }

    public init(startSeconds: Double, title: String, points: [String]) {
        self.startSeconds = startSeconds
        self.title = title
        self.pointClaims = points.map { DigestClaim(text: $0, evidenceBlockIDs: []) }
        self.anchorBlockID = nil
    }

    public init(
        title: String,
        anchorBlockID: MaterialBlockID?,
        points: [DigestClaim],
        startSeconds: Double = 0
    ) {
        self.startSeconds = startSeconds
        self.title = title
        self.pointClaims = points
        self.anchorBlockID = anchorBlockID
    }
}

public struct DigestQuote: Equatable, Sendable {
    public var speaker: String?
    public var startSeconds: Double
    public var text: String
    public var evidenceBlockID: MaterialBlockID?

    public init(
        speaker: String?,
        startSeconds: Double,
        text: String,
        evidenceBlockID: MaterialBlockID? = nil
    ) {
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.text = text
        self.evidenceBlockID = evidenceBlockID
    }

    public init(speaker: String?, text: String, evidenceBlockID: MaterialBlockID?) {
        self.init(speaker: speaker, startSeconds: 0, text: text, evidenceBlockID: evidenceBlockID)
    }
}

public struct InspirationSummary: Equatable, Sendable {
    public var thesisClaim: DigestClaim
    public var takeawayClaims: [DigestClaim]
    public var chapters: [DigestChapter]
    public var quotes: [DigestQuote]
    public var droppedClaims: [DigestClaim]

    public var thesis: String {
        get { thesisClaim.text }
        set { thesisClaim.text = newValue }
    }

    public var takeaways: [String] {
        get { takeawayClaims.map(\.text) }
        set { takeawayClaims = newValue.map { DigestClaim(text: $0, evidenceBlockIDs: []) } }
    }

    public var dropped: [String] {
        get { droppedClaims.map(\.text) }
        set { droppedClaims = newValue.map { DigestClaim(text: $0, evidenceBlockIDs: []) } }
    }

    public init(
        thesis: DigestClaim,
        takeaways: [DigestClaim],
        chapters: [DigestChapter],
        quotes: [DigestQuote],
        dropped: [DigestClaim]
    ) {
        self.thesisClaim = thesis
        self.takeawayClaims = takeaways
        self.chapters = chapters
        self.quotes = quotes
        self.droppedClaims = dropped
    }

    public init(
        thesis: String,
        takeaways: [String],
        chapters: [DigestChapter],
        quotes: [DigestQuote],
        dropped: [String]
    ) {
        self.init(
            thesis: DigestClaim(text: thesis, evidenceBlockIDs: []),
            takeaways: takeaways.map { DigestClaim(text: $0, evidenceBlockIDs: []) },
            chapters: chapters,
            quotes: quotes,
            dropped: dropped.map { DigestClaim(text: $0, evidenceBlockIDs: []) }
        )
    }
}

public struct DigestProvenance: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var generatedAt: Date
    public var inputFingerprint: String
    public var summaryContractVersion: String

    public init(
        modelIdentifier: String,
        generatedAt: Date,
        inputFingerprint: String,
        summaryContractVersion: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.generatedAt = generatedAt
        self.inputFingerprint = inputFingerprint
        self.summaryContractVersion = summaryContractVersion
    }
}

public struct MaterialDigestResult: Codable, Equatable, Sendable {
    public var contentFingerprint: String
    public var summary: InspirationSummary
    public var provenance: DigestProvenance
    public var completedAt: Date

    public init(
        summary: InspirationSummary,
        provenance: DigestProvenance,
        completedAt: Date,
        contentFingerprint: String = ""
    ) {
        self.contentFingerprint = contentFingerprint
        self.summary = summary
        self.provenance = provenance
        self.completedAt = completedAt
    }
}

public struct MaterialDigestFailure: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case unsupportedSource
        case restrictedSource
        case sourceUnavailable
        case modelDownloadFailed
        case transcriptionFailed
        case modelNotConfigured
        case authenticationFailed
        case accessDenied
        case summarizationFailed
        case invalidSummary
        case insufficientContent
        case cancelled
        case interrupted
    }

    public var code: Code
    public var userMessage: String
    public var occurredAt: Date

    public init(code: Code, userMessage: String, occurredAt: Date) {
        self.code = code
        self.userMessage = userMessage
        self.occurredAt = occurredAt
    }
}

public struct MaterialDigestNoteWrite: Codable, Equatable, Sendable {
    public let noteID: NoteID
    public let resultFingerprint: String
    public let blockIDs: [BlockID]
    public let writtenAt: Date

    public init(noteID: NoteID, resultFingerprint: String, blockIDs: [BlockID], writtenAt: Date) {
        self.noteID = noteID
        self.resultFingerprint = resultFingerprint
        self.blockIDs = blockIDs
        self.writtenAt = writtenAt
    }
}

public struct MaterialDigest: Identifiable, Codable, Equatable, Sendable {
    public let id: MaterialDigestID
    public let inspirationID: InspirationID
    public let sourceChecksum: String
    public var currentRun: MaterialDigestRun?
    public var preparedSnapshot: MaterialSnapshot?
    public var pendingSnapshot: MaterialSnapshot?
    public var result: MaterialDigestResult?
    public var lastFailure: MaterialDigestFailure?
    public var noteWrite: MaterialDigestNoteWrite?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: MaterialDigestID,
        inspirationID: InspirationID,
        sourceChecksum: String,
        currentRun: MaterialDigestRun?,
        result: MaterialDigestResult?,
        lastFailure: MaterialDigestFailure?,
        noteWrite: MaterialDigestNoteWrite? = nil,
        preparedSnapshot: MaterialSnapshot? = nil,
        pendingSnapshot: MaterialSnapshot? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.inspirationID = inspirationID
        self.sourceChecksum = sourceChecksum
        self.currentRun = currentRun
        self.preparedSnapshot = preparedSnapshot
        self.pendingSnapshot = pendingSnapshot
        self.result = result
        self.lastFailure = lastFailure
        self.noteWrite = noteWrite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension DigestChapter: Codable {
    enum CodingKeys: String, CodingKey {
        case startSeconds
        case title
        case points
        case anchorBlockID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        startSeconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        anchorBlockID = try container.decodeIfPresent(MaterialBlockID.self, forKey: .anchorBlockID)
        if let claims = try? container.decode([DigestClaim].self, forKey: .points) {
            pointClaims = claims
        } else {
            pointClaims = try container.decode([String].self, forKey: .points)
                .map { DigestClaim(text: $0, evidenceBlockIDs: []) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        let encodesAsLegacy = anchorBlockID == nil
            && pointClaims.allSatisfy(\.evidenceBlockIDs.isEmpty)
        if encodesAsLegacy {
            try container.encode(startSeconds, forKey: .startSeconds)
            try container.encode(points, forKey: .points)
        } else {
            try container.encodeIfPresent(anchorBlockID, forKey: .anchorBlockID)
            try container.encode(pointClaims, forKey: .points)
            if startSeconds != 0 {
                try container.encode(startSeconds, forKey: .startSeconds)
            }
        }
    }
}

extension DigestQuote: Codable {
    enum CodingKeys: String, CodingKey {
        case speaker
        case startSeconds
        case text
        case evidenceBlockID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        startSeconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        text = try container.decode(String.self, forKey: .text)
        evidenceBlockID = try container.decodeIfPresent(MaterialBlockID.self, forKey: .evidenceBlockID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(speaker, forKey: .speaker)
        try container.encode(text, forKey: .text)
        if let evidenceBlockID {
            try container.encode(evidenceBlockID, forKey: .evidenceBlockID)
            if startSeconds != 0 {
                try container.encode(startSeconds, forKey: .startSeconds)
            }
        } else {
            try container.encode(startSeconds, forKey: .startSeconds)
        }
    }
}

extension InspirationSummary: Codable {
    enum CodingKeys: String, CodingKey {
        case thesis
        case takeaways
        case chapters
        case quotes
        case dropped
    }

    public var encodesAsLegacyContract: Bool {
        thesisClaim.evidenceBlockIDs.isEmpty
            && takeawayClaims.allSatisfy(\.evidenceBlockIDs.isEmpty)
            && droppedClaims.allSatisfy(\.evidenceBlockIDs.isEmpty)
            && chapters.allSatisfy { chapter in
                chapter.anchorBlockID == nil
                    && chapter.pointClaims.allSatisfy(\.evidenceBlockIDs.isEmpty)
            }
            && quotes.allSatisfy { $0.evidenceBlockID == nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let claim = try? container.decode(DigestClaim.self, forKey: .thesis) {
            thesisClaim = claim
        } else {
            thesisClaim = DigestClaim(
                text: try container.decode(String.self, forKey: .thesis),
                evidenceBlockIDs: []
            )
        }
        if let claims = try? container.decode([DigestClaim].self, forKey: .takeaways) {
            takeawayClaims = claims
        } else {
            takeawayClaims = try container.decode([String].self, forKey: .takeaways)
                .map { DigestClaim(text: $0, evidenceBlockIDs: []) }
        }
        if let claims = try? container.decode([DigestClaim].self, forKey: .dropped) {
            droppedClaims = claims
        } else {
            droppedClaims = try container.decodeIfPresent([String].self, forKey: .dropped)?
                .map { DigestClaim(text: $0, evidenceBlockIDs: []) } ?? []
        }
        chapters = try container.decode([DigestChapter].self, forKey: .chapters)
        quotes = try container.decode([DigestQuote].self, forKey: .quotes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if encodesAsLegacyContract {
            try container.encode(thesis, forKey: .thesis)
            try container.encode(takeaways, forKey: .takeaways)
            try container.encode(dropped, forKey: .dropped)
        } else {
            try container.encode(thesisClaim, forKey: .thesis)
            try container.encode(takeawayClaims, forKey: .takeaways)
            try container.encode(droppedClaims, forKey: .dropped)
        }
        try container.encode(chapters, forKey: .chapters)
        try container.encode(quotes, forKey: .quotes)
    }
}
