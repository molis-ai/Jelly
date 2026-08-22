import Foundation

public enum BlockDocumentValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case duplicateBlockID(BlockID)
    case invalidIndent(BlockID, Int)
    case orphanedIndent(BlockID, Int)
    case missingTaskState(BlockID)
    case unexpectedTaskState(BlockID)
    case unexpectedCodeInfo(BlockID)
    case invalidCodeInfo(BlockID)
    case invalidCodeInlineContent(BlockID)
    case dividerHasContent(BlockID)
    case invalidDividerInlineContent(BlockID)
    case invalidLink(BlockID)
    case invalidCompletionDescription(BlockID)
}

public enum BlockDocumentValidator {
    public static func validate(_ document: BlockDocument) throws {
        guard document.schemaVersion == BlockDocument.currentSchemaVersion else {
            throw BlockDocumentValidationError.unsupportedSchema(document.schemaVersion)
        }

        var identifiers = Set<BlockID>()
        var activeIndentLevels = Set<Int>()

        for block in document.blocks {
            guard identifiers.insert(block.id).inserted else {
                throw BlockDocumentValidationError.duplicateBlockID(block.id)
            }
            try validateBlockLocal(block)
            guard block.kind.supportsIndentation || block.indentLevel == 0 else {
                throw BlockDocumentValidationError.invalidIndent(block.id, block.indentLevel)
            }

            guard block.kind.supportsIndentation else {
                activeIndentLevels.removeAll()
                continue
            }
            if block.indentLevel > 0, !activeIndentLevels.contains(block.indentLevel - 1) {
                throw BlockDocumentValidationError.orphanedIndent(block.id, block.indentLevel)
            }
            activeIndentLevels = Set(activeIndentLevels.filter { $0 <= block.indentLevel })
            activeIndentLevels.insert(block.indentLevel)
        }
    }

    static func validateBlockLocal(_ block: DocumentBlock) throws {
        guard (0...3).contains(block.indentLevel) else {
            throw BlockDocumentValidationError.invalidIndent(block.id, block.indentLevel)
        }
        switch block.kind {
        case .task:
            guard let taskState = block.taskState else {
                throw BlockDocumentValidationError.missingTaskState(block.id)
            }
            if let description = taskState.completionDescription {
                guard description == TaskBlockState.canonicalCompletionDescription(description) else {
                    throw BlockDocumentValidationError.invalidCompletionDescription(block.id)
                }
            }
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .quote, .code, .divider, .link:
            guard block.taskState == nil else {
                throw BlockDocumentValidationError.unexpectedTaskState(block.id)
            }
        }
        if block.kind != .code, block.codeInfoString != nil {
            throw BlockDocumentValidationError.unexpectedCodeInfo(block.id)
        }
        if block.kind == .code, let codeInfoString = block.codeInfoString {
            guard codeInfoString == DocumentBlock.canonicalCodeInfoString(codeInfoString),
                  !codeInfoString.unicodeScalars.contains(where: { scalar in
                      scalar.value == 0 || scalar.value == 10 || scalar.value == 13
                  }) else {
                throw BlockDocumentValidationError.invalidCodeInfo(block.id)
            }
        }
        if block.kind == .code {
            guard block.inlineContent.spans.count == 1,
                  let span = block.inlineContent.spans.first,
                  span.marks.isEmpty,
                  span.linkURL == nil else {
                throw BlockDocumentValidationError.invalidCodeInlineContent(block.id)
            }
        }
        if block.kind == .divider {
            guard block.inlineContent.spans.count == 1,
                  let span = block.inlineContent.spans.first,
                  span.text.isEmpty,
                  span.marks.isEmpty,
                  span.linkURL == nil else {
                if block.inlineContent.spans.count == 1,
                   let span = block.inlineContent.spans.first,
                   !span.text.isEmpty {
                    throw BlockDocumentValidationError.dividerHasContent(block.id)
                }
                throw BlockDocumentValidationError.invalidDividerInlineContent(block.id)
            }
        }
        if block.kind == .link,
           !block.inlineContent.spans.contains(where: hasValidLinkURL) {
            throw BlockDocumentValidationError.invalidLink(block.id)
        }
    }

    private static func hasValidLinkURL(_ span: InlineSpan) -> Bool {
        guard let url = span.linkURL else { return false }
        return url.scheme != nil && url.host != nil
    }
}
