import Foundation
import WorkspaceDomain

struct BlockTextPosition: Equatable, Sendable {
    let blockID: BlockID
    let graphemeOffset: Int
}

struct BlockTypingAttributes: Equatable, Sendable {
    var marks: Set<InlineMark>
    var linkURL: URL?
}

enum SelectionAffinity: Equatable, Sendable {
    case upstream
    case downstream
}

enum SelectionDirection: Equatable, Sendable {
    case forward
    case reverse
}

enum BlockEditorSelection: Equatable, Sendable {
    case text(
        anchor: BlockTextPosition,
        focus: BlockTextPosition,
        preferredColumn: Int?,
        typingAttributes: BlockTypingAttributes
    )
    case blocks(anchor: BlockID, focus: BlockID)
}

enum BlockHorizontalDirection: Equatable, Sendable {
    case backward
    case forward
}

enum BlockVerticalDirection: Equatable, Sendable {
    case up
    case down
}

enum BlockDocumentIngestMode: Equatable, Sendable {
    case replace
    case append
}

enum BlockInputCommand: Equatable, Sendable {
    case insertText(String)
    case insertTextApplyingMarkdownShortcut(String)
    case enter
    case softBreak
    case backspace
    case indent
    case outdent
    case moveHorizontal(BlockHorizontalDirection, extending: Bool)
    case moveVertical(BlockVerticalDirection, extending: Bool)
    case convert(BlockKind)
    case insertDivider
    case applyMarkdownShortcut
    case applySlashConversion(BlockKind)
    case toggleInlineMark(InlineMark)
    case setLink(URL?)
    case setTaskCompletion(blockID: BlockID, completedAt: Date?)
    case copySelection
    case cutSelection
    case replaceSelection(BlockPastePayload)
    case deleteSelection
    case moveBlockRoots([BlockID], before: BlockID?)
    /// Dedicated Markdown/document ingestion path. Clipboard paste stays completion-free;
    /// this command may carry exact checked-task `completedAt` values.
    case applyDocumentBlocks(blocks: [DocumentBlock], mode: BlockDocumentIngestMode)
}

struct BlockInputEnvironment: Sendable {
    let isComposingText: Bool
    let idSource: BlockIDSource
}

enum BlockInputMutation: Equatable, Sendable {
    case none(BlockInputNoChangeReason)
    case selectionOnly
    case document
}

enum BlockInputNoChangeReason: Equatable, Sendable {
    case composingText
    case documentBoundary
    case textSystemOwnsMovement
    case unsupportedBlockKind
    case emptySelection
    case missingListParent
    case indentationLimit
    case samePosition
}

enum BlockInputEffect: Equatable, Sendable {
    case handled
    case deferToTextSystem
    case writeClipboard(BlockClipboardPayload)
}

enum BlockUndoDirective: Equatable, Sendable {
    case none
    case breakCoalescing
    case coalesceTyping(BlockID)
    case atomic(BlockUndoAction)
}

enum BlockUndoAction: Equatable, Sendable {
    case enter
    case softBreak
    case backspace
    case indentation
    case conversion
    case formatting
    case link
    case cut
    case paste
    case deletion
    case drag
    case documentIngest
    case taskCompletion
}

struct BlockInputResult: Equatable, Sendable {
    let document: BlockDocument
    let selection: BlockEditorSelection
    let mutation: BlockInputMutation
    let effect: BlockInputEffect
    let undo: BlockUndoDirective
}

enum BlockInputError: Error, Equatable, Sendable {
    case invalidInputDocument
    case invalidSelection
    case insufficientBlockIDs
    case duplicateBlockID(BlockID)
    case invalidLink
    case invalidMove
    case invalidCandidate
}

enum BlockPastePayload: Equatable, Sendable {
    case plainText(String)
    case inlineContent(InlineContent, fallbackPlainText: String)
    case richText(blocks: [BlockPasteBlock], fallbackPlainText: String)
}

struct BlockPasteBlock: Equatable, Sendable {
    let kind: BlockKind
    let inlineContent: InlineContent
    let indentLevel: Int
    let codeInfoString: String?
    let completionDescription: String?

    init(
        kind: BlockKind,
        inlineContent: InlineContent,
        indentLevel: Int,
        codeInfoString: String?,
        completionDescription: String? = nil
    ) {
        self.kind = kind
        self.inlineContent = inlineContent
        self.indentLevel = indentLevel
        self.codeInfoString = codeInfoString
        self.completionDescription = completionDescription
    }
}

struct BlockClipboardPayload: Equatable, Sendable {
    let plainText: String
    let richBlocks: [BlockPasteBlock]
    let inlineContent: InlineContent?

    init(
        plainText: String,
        richBlocks: [BlockPasteBlock],
        inlineContent: InlineContent? = nil
    ) {
        self.plainText = plainText
        self.richBlocks = richBlocks
        self.inlineContent = inlineContent
    }
}

enum ParsedBlockPastePayload: Equatable, Sendable {
    case plainLines([String])
    case richBlocks([BlockPasteBlock])
}

enum BlockPasteParserError: Error, Equatable, Sendable {
    case invalidBlock(index: Int)
    case invalidIndent(index: Int)
    case invalidLink(index: Int)
    case invalidCodeInfo(index: Int)
}

protocol BlockPasteParsing {
    static func parse(_ payload: BlockPastePayload) throws -> ParsedBlockPastePayload
}
