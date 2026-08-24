import Foundation

public struct NoteID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct InspirationID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct BlockID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct MaterialDigestID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct MaterialDigestRunID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct MaterialBlockID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        if let uuid = try? decoder.singleValueContainer().decode(UUID.self) {
            rawValue = uuid
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawValue = try container.decode(UUID.self, forKey: .rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case rawValue
    }
}
