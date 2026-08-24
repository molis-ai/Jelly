import Foundation

public enum BlockKind: String, Codable, Equatable, Sendable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bullet
    case ordered
    case task
    case quote
    case code
    case divider
    case link

    var supportsIndentation: Bool {
        switch self {
        case .bullet, .ordered, .task:
            true
        case .paragraph, .heading1, .heading2, .heading3, .quote, .code, .divider, .link:
            false
        }
    }
}

public enum InlineMark: String, Codable, Hashable, Sendable {
    case bold
    case italic
    case code
}

public struct InlineSpan: Codable, Equatable, Sendable {
    public var text: String
    public var marks: Set<InlineMark>
    public var linkURL: URL?

    public init(text: String, marks: Set<InlineMark> = [], linkURL: URL? = nil) {
        self.text = text
        self.marks = marks
        self.linkURL = linkURL
    }
}

public struct InlineContent: Codable, Equatable, Sendable {
    public var spans: [InlineSpan]

    public init(spans: [InlineSpan]) {
        self.spans = spans
    }

    public static func plain(_ text: String) -> InlineContent {
        InlineContent(spans: [.init(text: text)])
    }

    var isEmpty: Bool {
        spans.allSatisfy { $0.text.isEmpty && $0.linkURL == nil }
    }
}

public struct TaskBlockState: Codable, Equatable, Sendable {
    public var completedAt: Date?
    public var completionDescription: String?

    private enum CodingKeys: String, CodingKey {
        case completedAt
        case completionDescription
    }

    public init(completedAt: Date?, completionDescription: String? = nil) {
        self.completedAt = completedAt
        self.completionDescription = Self.canonicalCompletionDescription(completionDescription)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        completionDescription = Self.canonicalCompletionDescription(
            try container.decodeIfPresent(String.self, forKey: .completionDescription)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(completionDescription, forKey: .completionDescription)
    }

    static func canonicalCompletionDescription(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct DocumentBlock: Identifiable, Codable, Equatable, Sendable {
    public let id: BlockID
    public var kind: BlockKind
    public var inlineContent: InlineContent
    public var taskState: TaskBlockState?
    public var indentLevel: Int
    public var codeInfoString: String?

    public init(
        id: BlockID,
        kind: BlockKind,
        inlineContent: InlineContent,
        taskState: TaskBlockState?,
        indentLevel: Int,
        codeInfoString: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.inlineContent = inlineContent
        self.taskState = taskState
        self.indentLevel = indentLevel
        self.codeInfoString = Self.canonicalCodeInfoString(codeInfoString)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case inlineContent
        case taskState
        case indentLevel
        case codeInfoString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BlockID.self, forKey: .id)
        kind = try container.decode(BlockKind.self, forKey: .kind)
        inlineContent = try container.decode(InlineContent.self, forKey: .inlineContent)
        taskState = try container.decodeIfPresent(TaskBlockState.self, forKey: .taskState)
        indentLevel = try container.decode(Int.self, forKey: .indentLevel)
        codeInfoString = Self.canonicalCodeInfoString(
            try container.decodeIfPresent(String.self, forKey: .codeInfoString)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(inlineContent, forKey: .inlineContent)
        try container.encodeIfPresent(taskState, forKey: .taskState)
        try container.encode(indentLevel, forKey: .indentLevel)
        try container.encodeIfPresent(codeInfoString, forKey: .codeInfoString)
    }

    static func canonicalCodeInfoString(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func task(
        id: BlockID = BlockID(),
        text: String,
        indentLevel: Int = 0,
        completedAt: Date? = nil,
        completionDescription: String? = nil
    ) throws -> DocumentBlock {
        let block = DocumentBlock(
            id: id,
            kind: .task,
            inlineContent: .plain(text),
            taskState: .init(completedAt: completedAt, completionDescription: completionDescription),
            indentLevel: indentLevel
        )
        try BlockDocumentValidator.validateBlockLocal(block)
        return block
    }
}

public struct BlockDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var blocks: [DocumentBlock]

    public init(schemaVersion: Int = currentSchemaVersion, blocks: [DocumentBlock]) {
        self.schemaVersion = schemaVersion
        self.blocks = blocks
    }

    public static func empty() -> BlockDocument {
        BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain(""),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }
}
