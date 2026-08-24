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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
            return resolvedSourceKind == .plainText
        case .url:
            return [.article, .socialPost, .video, .audio, .unknown]
                .contains(resolvedSourceKind)
        case .file:
            return [.plainText, .article, .image, .document, .video, .audio]
                .contains(resolvedSourceKind)
        }
    }
}
