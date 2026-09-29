import Foundation

public enum CaptureInputKind: String, Codable, Equatable, Sendable {
    case text
    case url
    case file
}

public enum ResolvedSourceKind: String, Codable, Equatable, Sendable {
    case plainText
    case article
    case socialPost
    case video
    case audio
    case image
    case document
    case unknown
}

public enum InspirationLifecycle: String, Codable, Equatable, Sendable {
    case active
    case archived
}

public enum MetadataFetchStatus: String, Codable, Equatable, Sendable {
    case notRequested
    case loading
    case succeeded
    case failed
}

public struct FileReference: Codable, Equatable, Sendable {
    public let bookmarkData: Data
    public let displayName: String

    public init(bookmarkData: Data, displayName: String) {
        self.bookmarkData = bookmarkData
        self.displayName = displayName
    }
}

public struct SourceMetadata: Codable, Equatable, Sendable {
    public var title: String?
    public var siteName: String?
    public var domain: String?
    public var thumbnailURL: URL?
    public var fetchStatus: MetadataFetchStatus

    public init(
        title: String?,
        siteName: String?,
        domain: String?,
        thumbnailURL: URL?,
        fetchStatus: MetadataFetchStatus
    ) {
        self.title = title
        self.siteName = siteName
        self.domain = domain
        self.thumbnailURL = thumbnailURL
        self.fetchStatus = fetchStatus
    }
}

public struct Inspiration: Identifiable, Codable, Equatable, Sendable {
    public let id: InspirationID
    public let inputKind: CaptureInputKind
    public var rawText: String?
    public var rawURL: URL?
    public var rawFile: FileReference?
    public var resolvedSourceKind: ResolvedSourceKind
    public var resolvedMetadata: SourceMetadata?
    public var categoryID: UUID
    public var lifecycle: InspirationLifecycle
    /// Set when the user triaged it in 回顾 ("留着") or turned it into a to-do.
    public var lastReviewedAt: Date?
    public var expansion: InspirationExpansion?
    public var perspective: InspirationPerspective?
    /// Calendar items created from this inspiration, oldest first.
    public var scheduledItemIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: InspirationID,
        inputKind: CaptureInputKind,
        rawText: String?,
        rawURL: URL?,
        rawFile: FileReference?,
        resolvedSourceKind: ResolvedSourceKind,
        resolvedMetadata: SourceMetadata?,
        categoryID: UUID,
        lifecycle: InspirationLifecycle,
        lastReviewedAt: Date? = nil,
        expansion: InspirationExpansion? = nil,
        perspective: InspirationPerspective? = nil,
        scheduledItemIDs: [UUID] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.inputKind = inputKind
        self.rawText = rawText
        self.rawURL = rawURL
        self.rawFile = rawFile
        self.resolvedSourceKind = resolvedSourceKind
        self.resolvedMetadata = resolvedMetadata
        self.categoryID = categoryID
        self.lifecycle = lifecycle
        self.lastReviewedAt = lastReviewedAt
        self.expansion = expansion
        self.perspective = perspective
        self.scheduledItemIDs = scheduledItemIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case inputKind
        case rawText
        case rawURL
        case rawFile
        case resolvedSourceKind
        case resolvedMetadata
        case categoryID
        case lifecycle
        case lastReviewedAt
        case expansion
        case perspective
        case scheduledItemIDs
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(InspirationID.self, forKey: .id)
        inputKind = try container.decode(CaptureInputKind.self, forKey: .inputKind)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        rawURL = try container.decodeIfPresent(URL.self, forKey: .rawURL)
        rawFile = try container.decodeIfPresent(FileReference.self, forKey: .rawFile)
        resolvedSourceKind = try container.decode(ResolvedSourceKind.self, forKey: .resolvedSourceKind)
        resolvedMetadata = try container.decodeIfPresent(SourceMetadata.self, forKey: .resolvedMetadata)
        categoryID = try container.decode(UUID.self, forKey: .categoryID)
        lifecycle = try container.decode(InspirationLifecycle.self, forKey: .lifecycle)
        lastReviewedAt = try container.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        expansion = try container.decodeIfPresent(InspirationExpansion.self, forKey: .expansion)
        perspective = try container.decodeIfPresent(InspirationPerspective.self, forKey: .perspective)
        scheduledItemIDs = try container.decodeIfPresent([UUID].self, forKey: .scheduledItemIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inputKind, forKey: .inputKind)
        try container.encodeIfPresent(rawText, forKey: .rawText)
        try container.encodeIfPresent(rawURL, forKey: .rawURL)
        try container.encodeIfPresent(rawFile, forKey: .rawFile)
        try container.encode(resolvedSourceKind, forKey: .resolvedSourceKind)
        try container.encodeIfPresent(resolvedMetadata, forKey: .resolvedMetadata)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encodeIfPresent(lastReviewedAt, forKey: .lastReviewedAt)
        try container.encodeIfPresent(expansion, forKey: .expansion)
        try container.encodeIfPresent(perspective, forKey: .perspective)
        if !scheduledItemIDs.isEmpty {
            try container.encode(scheduledItemIDs, forKey: .scheduledItemIDs)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public static func text(
        id: InspirationID = InspirationID(),
        rawText: String,
        categoryID: UUID,
        now: Date
    ) -> Inspiration {
        Inspiration(
            id: id,
            inputKind: .text,
            rawText: rawText,
            rawURL: nil,
            rawFile: nil,
            resolvedSourceKind: .plainText,
            resolvedMetadata: nil,
            categoryID: categoryID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
    }
}

extension Inspiration {
    public var supportsMaterialDigest: Bool {
        switch inputKind {
        case .text:
            return false
        case .url:
            return [.article, .socialPost, .video, .audio, .unknown]
                .contains(resolvedSourceKind)
        case .file:
            return [.plainText, .article, .image, .document, .video, .audio]
                .contains(resolvedSourceKind)
        }
    }
}
