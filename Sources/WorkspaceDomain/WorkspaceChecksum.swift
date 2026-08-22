import CryptoKit
import Foundation

public enum WorkspaceChecksum {
    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizedNoteSnapshotData(_ note: Note) throws -> Data {
        let encoder = JSONEncoder.workspaceDeterministic
        return try encoder.encode(NormalizedNoteSnapshot(note: note))
    }

    public static func noteSnapshotChecksum(_ note: Note) throws -> String {
        let data = try normalizedNoteSnapshotData(note)
        return sha256Hex(data)
    }

    public static func inspirationSourceChecksum(_ inspiration: Inspiration) -> String {
        var data = Data("inspiration-source-v1".utf8)
        appendLengthPrefixed(Data(inspiration.id.rawValue.uuidString.utf8), to: &data)
        appendLengthPrefixed(Data(inspiration.inputKind.rawValue.utf8), to: &data)
        switch inspiration.inputKind {
        case .text:
            appendLengthPrefixed(Data((inspiration.rawText ?? "").utf8), to: &data)
        case .url:
            appendLengthPrefixed(Data((inspiration.rawURL?.absoluteString ?? "").utf8), to: &data)
        case .file:
            if let file = inspiration.rawFile {
                appendLengthPrefixed(file.bookmarkData, to: &data)
                appendLengthPrefixed(Data(file.displayName.utf8), to: &data)
            } else {
                appendLengthPrefixed(Data(), to: &data)
                appendLengthPrefixed(Data(), to: &data)
            }
        }
        return sha256Hex(data)
    }

    public static func diagnosticsChecksum(_ diagnostics: [BlockMarkdownDiagnostic]) -> String {
        var data = Data("legacy-diagnostics-v1".utf8)
        var count = UInt64(diagnostics.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for diagnostic in diagnostics {
            var line = UInt64(diagnostic.lineNumber).bigEndian
            withUnsafeBytes(of: &line) { data.append(contentsOf: $0) }
            appendLengthPrefixed(Data(diagnostic.message.utf8), to: &data)
        }
        return sha256Hex(data)
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

public extension JSONEncoder {
    static var workspaceDeterministic: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

public extension JSONDecoder {
    static var workspaceDeterministic: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct NormalizedNoteSnapshot: Codable {
    let noteID: UUID
    let title: String
    let document: NormalizedBlockDocument
    let categoryID: UUID
    let archivedAt: Date?

    init(note: Note) {
        noteID = note.id.rawValue
        title = note.title
        document = .init(document: note.document)
        categoryID = note.categoryID
        archivedAt = note.archivedAt
    }
}

private struct NormalizedBlockDocument: Codable {
    let schemaVersion: Int
    let blocks: [NormalizedDocumentBlock]

    init(document: BlockDocument) {
        schemaVersion = document.schemaVersion
        blocks = document.blocks.map(NormalizedDocumentBlock.init)
    }
}

private struct NormalizedDocumentBlock: Codable {
    let id: UUID
    let kind: BlockKind
    let spans: [NormalizedInlineSpan]
    let completedAt: Date?
    let completionDescription: String?
    let indentLevel: Int
    let codeInfoString: String?

    init(block: DocumentBlock) {
        id = block.id.rawValue
        kind = block.kind
        spans = block.inlineContent.spans.map(NormalizedInlineSpan.init)
        completedAt = block.taskState?.completedAt
        completionDescription = block.taskState?.completionDescription
        indentLevel = block.indentLevel
        codeInfoString = block.codeInfoString
    }
}

private struct NormalizedInlineSpan: Codable {
    let text: String
    let marks: [InlineMark]
    let linkURL: String?

    init(span: InlineSpan) {
        text = span.text
        marks = span.marks.sorted { $0.rawValue < $1.rawValue }
        linkURL = span.linkURL?.absoluteString
    }
}
