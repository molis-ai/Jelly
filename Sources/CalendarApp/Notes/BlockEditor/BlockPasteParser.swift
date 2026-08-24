import Foundation
import WorkspaceDomain

enum BlockURLValidator {
    static func isValid(_ url: URL?) -> Bool {
        guard let url else { return true }
        guard url.scheme != nil,
              url.host != nil,
              let decoded = url.absoluteString.removingPercentEncoding else {
            return false
        }
        return !decoded.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar.value == 127
        }
    }
}

enum BlockPasteParser: BlockPasteParsing {
    static func parse(_ payload: BlockPastePayload) throws -> ParsedBlockPastePayload {
        switch payload {
        case let .plainText(text):
            return .plainLines(normalizedLines(text))
        case let .inlineContent(content, _):
            let block = BlockPasteBlock(
                kind: .paragraph,
                inlineContent: content,
                indentLevel: 0,
                codeInfoString: nil
            )
            try validate(block, index: 0)
            return .richBlocks([block])
        case let .richText(blocks, _):
            for (index, block) in blocks.enumerated() {
                try validate(block, index: index)
            }
            return .richBlocks(blocks)
        }
    }

    static func normalizedLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func validate(_ block: BlockPasteBlock, index: Int) throws {
        guard (0...3).contains(block.indentLevel),
              supportsIndentation(block.kind) || block.indentLevel == 0 else {
            throw BlockPasteParserError.invalidIndent(index: index)
        }

        try validateCompletionDescription(block, index: index)

        if block.inlineContent.spans.contains(where: { span in
            guard let url = span.linkURL else { return false }
            return !BlockURLValidator.isValid(url)
        }) {
            throw BlockPasteParserError.invalidLink(index: index)
        }

        switch block.kind {
        case .code:
            guard block.inlineContent.spans.count == 1,
                  let span = block.inlineContent.spans.first,
                  span.marks.isEmpty,
                  span.linkURL == nil else {
                throw BlockPasteParserError.invalidBlock(index: index)
            }
            guard isCanonicalCodeInfo(block.codeInfoString) else {
                throw BlockPasteParserError.invalidCodeInfo(index: index)
            }
        case .divider:
            guard block.inlineContent.spans.count == 1,
                  let span = block.inlineContent.spans.first,
                  span.text.isEmpty,
                  span.marks.isEmpty,
                  span.linkURL == nil else {
                throw BlockPasteParserError.invalidBlock(index: index)
            }
            guard block.codeInfoString == nil else {
                throw BlockPasteParserError.invalidCodeInfo(index: index)
            }
        case .link:
            guard block.inlineContent.spans.contains(where: { span in
                span.linkURL.map { BlockURLValidator.isValid($0) } == true
            }) else {
                throw BlockPasteParserError.invalidLink(index: index)
            }
            guard block.codeInfoString == nil else {
                throw BlockPasteParserError.invalidCodeInfo(index: index)
            }
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote:
            guard block.codeInfoString == nil else {
                throw BlockPasteParserError.invalidCodeInfo(index: index)
            }
        }
    }

    private static func validateCompletionDescription(_ block: BlockPasteBlock, index: Int) throws {
        let canonical = TaskBlockState(
            completedAt: nil,
            completionDescription: block.completionDescription
        ).completionDescription
        switch block.kind {
        case .task:
            if block.completionDescription != canonical {
                throw BlockPasteParserError.invalidBlock(index: index)
            }
        default:
            if block.completionDescription != nil {
                throw BlockPasteParserError.invalidBlock(index: index)
            }
        }
    }

    private static func supportsIndentation(_ kind: BlockKind) -> Bool {
        switch kind {
        case .bullet, .ordered, .task:
            true
        case .paragraph, .heading1, .heading2, .heading3, .quote, .code, .divider, .link:
            false
        }
    }

    private static func isCanonicalCodeInfo(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return !trimmed.isEmpty && trimmed == value && !value.unicodeScalars.contains { scalar in
            scalar.value == 0 || scalar.value == 10 || scalar.value == 13
        }
    }
}
