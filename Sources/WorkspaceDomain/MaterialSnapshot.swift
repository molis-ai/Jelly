import Foundation

public enum MaterialBlockRole: String, Codable, Equatable, Sendable {
    case body
    case transcript
    case ocr
    case metadata
}

public enum MaterialLocator: Codable, Equatable, Sendable {
    case paragraph(index: Int)
    case timestamp(startSeconds: Double, endSeconds: Double)
    case page(number: Int)
    case image(index: Int)
}

public struct MaterialConfidence: Codable, Equatable, Sendable {
    public var basisPoints: Int

    public init(basisPoints: Int) {
        self.basisPoints = basisPoints
    }
}

public struct MaterialBlock: Identifiable, Codable, Equatable, Sendable {
    public let id: MaterialBlockID
    public var role: MaterialBlockRole
    public var text: String
    public var locator: MaterialLocator
    public var confidence: MaterialConfidence?

    public init(
        id: MaterialBlockID,
        role: MaterialBlockRole,
        text: String,
        locator: MaterialLocator,
        confidence: MaterialConfidence?
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.locator = locator
        self.confidence = confidence
    }
}

public enum MaterialCoverageIssue: String, Codable, Equatable, Sendable {
    case inaccessibleAsset
    case transcriptionFailed
    case ocrFailed
    case truncatedByLimit
    case visualSemanticsUnavailable
}

public enum MaterialInsufficiencyCode: String, Codable, Equatable, Sendable {
    case empty
    case metadataOnly
    case repetitiveNoise
    case unreadable
    case unsupported
}

public enum MaterialCoverage: Codable, Equatable, Sendable {
    case sufficient
    case partial(processed: Int, expected: Int?, issues: [MaterialCoverageIssue])
    case insufficient(code: MaterialInsufficiencyCode)
}

public struct MaterialAcquisitionProvenance: Codable, Equatable, Sendable {
    public var adapterIdentifier: String
    public var adapterVersion: String
    public var acquiredAt: Date
    public var diagnostics: String?

    public init(
        adapterIdentifier: String,
        adapterVersion: String,
        acquiredAt: Date,
        diagnostics: String? = nil
    ) {
        self.adapterIdentifier = adapterIdentifier
        self.adapterVersion = adapterVersion
        self.acquiredAt = acquiredAt
        self.diagnostics = diagnostics
    }
}

extension MaterialLocator {
    public var displayLabel: String {
        switch self {
        case let .timestamp(startSeconds, _):
            return Self.clockLabel(startSeconds)
        case let .page(number):
            return "第 \(number) 页"
        case let .image(index):
            return "图片 \(index)"
        case let .paragraph(index):
            return "正文第 \(index) 段"
        }
    }

    private static func clockLabel(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= MaterialDigestContentLimits.maximumTimestampSeconds
        else { return "--:--" }
        let total = max(0, Int(seconds.rounded(.towardZero)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

public struct MaterialSnapshot: Codable, Equatable, Sendable {
    public let sourceChecksum: String
    public let contentFingerprint: String
    public var blocks: [MaterialBlock]
    public var coverage: MaterialCoverage
    public var provenance: MaterialAcquisitionProvenance
    public var createdAt: Date

    public init(
        sourceChecksum: String,
        contentFingerprint: String,
        blocks: [MaterialBlock],
        coverage: MaterialCoverage,
        provenance: MaterialAcquisitionProvenance,
        createdAt: Date
    ) {
        self.sourceChecksum = sourceChecksum
        self.contentFingerprint = contentFingerprint
        self.blocks = blocks
        self.coverage = coverage
        self.provenance = provenance
        self.createdAt = createdAt
    }

    public var timestampedTranscript: TimestampedTranscript {
        TimestampedTranscript(
            segments: blocks.compactMap { block in
                guard case let .timestamp(start, end) = block.locator else { return nil }
                return TranscriptSegment(startSeconds: start, endSeconds: end, text: block.text)
            }
        )
    }
}

public struct DigestClaim: Codable, Equatable, Sendable {
    public var text: String
    public var evidenceBlockIDs: [MaterialBlockID]

    public init(text: String, evidenceBlockIDs: [MaterialBlockID] = []) {
        self.text = text
        self.evidenceBlockIDs = evidenceBlockIDs
    }
}
