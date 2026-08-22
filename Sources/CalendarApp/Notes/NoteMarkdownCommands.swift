import AppKit
import Foundation
import WorkspaceDomain

enum NoteFileFormat: String, CaseIterable, Identifiable, Equatable, Sendable {
    case markdown
    case html

    var id: Self { self }

    var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        }
    }

    var exportDescription: String {
        switch self {
        case .markdown: "适合继续编辑、版本管理和其他笔记工具"
        case .html: "适合浏览器查看，并保留常用富文本样式"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "text.document"
        case .html: "chevron.left.forwardslash.chevron.right"
        }
    }

    static func detect(from url: URL) -> NoteFileFormat? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown": .markdown
        case "html", "htm": .html
        default: nil
        }
    }
}

struct NoteFileImportResult: Equatable, Sendable {
    let document: BlockDocument
    let diagnostics: [String]
}

struct NoteFileImportPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let format: NoteFileFormat
    let fileName: String
    let result: NoteFileImportResult
    let mode: BlockDocumentIngestMode

    init(
        id: UUID = UUID(),
        format: NoteFileFormat,
        fileName: String,
        result: NoteFileImportResult,
        mode: BlockDocumentIngestMode
    ) {
        self.id = id
        self.format = format
        self.fileName = fileName
        self.result = result
        self.mode = mode
    }
}

enum NoteFileCommands {
    static func planImport(
        contents: String,
        format: NoteFileFormat,
        fileName: String,
        mode: BlockDocumentIngestMode,
        checkedTaskCompletedAt: Date
    ) throws -> NoteFileImportPlan {
        let result: NoteFileImportResult
        switch format {
        case .markdown:
            let imported = try BlockMarkdownCodec.importMarkdown(
                contents,
                idSource: .random,
                checkedTaskCompletedAt: checkedTaskCompletedAt
            )
            result = .init(
                document: imported.document,
                diagnostics: imported.diagnostics.map(\.message)
            )
        case .html:
            let imported = try BlockHTMLCodec.importHTML(
                contents,
                checkedTaskCompletedAt: checkedTaskCompletedAt
            )
            result = .init(
                document: imported.document,
                diagnostics: imported.diagnostics.map(\.message)
            )
        }
        guard !result.document.blocks.isEmpty else { throw NoteMarkdownCommandError.emptyImport }
        try BlockDocumentValidator.validate(result.document)
        return .init(format: format, fileName: fileName, result: result, mode: mode)
    }

    static func export(
        _ document: BlockDocument,
        format: NoteFileFormat,
        title: String
    ) throws -> String {
        switch format {
        case .markdown: try BlockMarkdownCodec.exportMarkdown(document)
        case .html: try BlockHTMLCodec.exportHTML(document, title: title)
        }
    }

    static func writeExport(
        contents: String,
        to url: URL
    ) throws {
        let data = Data(contents.utf8)
        try data.write(to: url, options: .atomic)
        let readback = try Data(contentsOf: url)
        guard readback == data else { throw NoteMarkdownCommandError.readbackMismatch }
    }
}

enum NoteMarkdownImportModeChoice: Equatable, Sendable {
    case replace
    case append
    case cancel
}

struct NoteMarkdownImportPlan: Equatable, Sendable {
    let result: BlockMarkdownImportResult
    let mode: BlockDocumentIngestMode
}

enum NoteMarkdownCommandError: Error, Equatable, Sendable {
    case userCancelled
    case emptyImport
    case writeFailed
    case readbackMismatch
    case invalidDocument
}

struct NoteMarkdownLiveSnapshot: Equatable, Sendable {
    let noteID: NoteID
    let editSessionID: UUID
    let document: BlockDocument
}

enum NoteMarkdownExportSource {
    static func document(
        persistedNoteID: NoteID,
        persistedDocument: BlockDocument,
        editorIdentity: NoteEditorIdentity?,
        liveSnapshot: NoteMarkdownLiveSnapshot?
    ) -> BlockDocument {
        guard let editorIdentity,
              editorIdentity.noteID == persistedNoteID,
              let liveSnapshot,
              liveSnapshot.noteID == persistedNoteID,
              liveSnapshot.noteID == editorIdentity.noteID
        else { return persistedDocument }
        return liveSnapshot.document
    }
}

/// Pure helpers for Note Markdown import/export. Presentation owns panels;
/// this type never mutates the editor session itself.
enum NoteMarkdownCommands {
    static func planImport(
        markdown: String,
        mode: BlockDocumentIngestMode,
        checkedTaskCompletedAt: Date
    ) throws -> NoteMarkdownImportPlan {
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .random,
            checkedTaskCompletedAt: checkedTaskCompletedAt
        )
        guard !result.document.blocks.isEmpty else { throw NoteMarkdownCommandError.emptyImport }
        try BlockDocumentValidator.validate(result.document)
        return .init(result: result, mode: mode)
    }

    static func exportMarkdown(from document: BlockDocument) throws -> String {
        try BlockMarkdownCodec.exportMarkdown(document)
    }

    static func writeExport(
        markdown: String,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let data = Data(markdown.utf8)
        try data.write(to: url, options: .atomic)
        let readback = try Data(contentsOf: url)
        guard readback == data else { throw NoteMarkdownCommandError.readbackMismatch }
    }
}
