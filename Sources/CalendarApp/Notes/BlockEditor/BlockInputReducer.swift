import Foundation
import WorkspaceDomain

enum BlockInputReducer {
    static func reduce(
        _ document: BlockDocument,
        selection: BlockEditorSelection,
        command: BlockInputCommand,
        environment: BlockInputEnvironment
    ) throws -> BlockInputResult {
        do {
            try BlockDocumentValidator.validate(document)
        } catch {
            throw BlockInputError.invalidInputDocument
        }
        try validate(selection, in: document)

        if environment.isComposingText, command.isCompositionSensitive {
            return .init(
                document: document,
                selection: selection,
                mutation: .none(.composingText),
                effect: .deferToTextSystem,
                undo: .none
            )
        }

        var context = ReductionContext(document: document, selection: selection, idSource: environment.idSource)
        switch command {
        case let .insertText(value):
            return try context.insertText(value)
        case let .insertTextApplyingMarkdownShortcut(value):
            return try context.insertTextApplyingMarkdownShortcut(value)
        case .enter:
            return try context.enter()
        case .softBreak:
            return try context.softBreak()
        case .backspace:
            return try context.backspace()
        case .indent:
            return try context.changeIndent(by: 1)
        case .outdent:
            return try context.changeIndent(by: -1)
        case let .moveHorizontal(direction, extending):
            return context.moveHorizontal(direction, extending: extending)
        case let .moveVertical(direction, extending):
            return context.moveVertical(direction, extending: extending)
        case let .convert(kind):
            return try context.convert(to: kind, slash: false)
        case .insertDivider:
            return try context.insertDivider()
        case .applyMarkdownShortcut:
            return try context.applyMarkdownShortcut()
        case let .applySlashConversion(kind):
            return try context.convert(to: kind, slash: true)
        case let .toggleInlineMark(mark):
            return try context.toggle(mark)
        case let .setLink(url):
            return try context.setLink(url)
        case let .setTaskCompletion(blockID, completedAt):
            return try context.setTaskCompletion(blockID: blockID, completedAt: completedAt)
        case .copySelection:
            return context.copySelection()
        case .cutSelection:
            return try context.cutSelection()
        case let .replaceSelection(payload):
            return try context.replaceSelection(payload)
        case .deleteSelection:
            return try context.deleteSelection(action: .deletion)
        case let .moveBlockRoots(roots, before: target):
            return try context.moveBlockRoots(roots, before: target)
        case let .applyDocumentBlocks(blocks, mode):
            return try context.applyDocumentBlocks(blocks, mode: mode)
        }
    }

    private static func validate(_ selection: BlockEditorSelection, in document: BlockDocument) throws {
        switch selection {
        case let .text(anchor, focus, preferredColumn, typingAttributes):
            guard preferredColumn.map({ $0 >= 0 }) ?? true,
                  BlockURLValidator.isValid(typingAttributes.linkURL),
                  validPosition(anchor, in: document),
                  validPosition(focus, in: document) else {
                throw BlockInputError.invalidSelection
            }
        case let .blocks(anchor, focus):
            guard document.blocks.contains(where: { $0.id == anchor }),
                  document.blocks.contains(where: { $0.id == focus }) else {
                throw BlockInputError.invalidSelection
            }
        }
    }

    private static func validPosition(_ position: BlockTextPosition, in document: BlockDocument) -> Bool {
        guard let block = document.blocks.first(where: { $0.id == position.blockID }) else { return false }
        if block.kind == .divider { return position.graphemeOffset == 0 }
        return position.graphemeOffset >= 0 && position.graphemeOffset <= block.text.count
    }
}

private extension BlockInputCommand {
    var isCompositionSensitive: Bool {
        switch self {
        case .insertText, .insertTextApplyingMarkdownShortcut, .enter, .softBreak, .backspace,
             .moveHorizontal, .moveVertical, .applyMarkdownShortcut, .applySlashConversion:
            true
        case .indent, .outdent, .convert, .insertDivider, .toggleInlineMark, .setLink, .setTaskCompletion,
             .copySelection, .cutSelection, .replaceSelection, .deleteSelection, .moveBlockRoots,
             .applyDocumentBlocks:
            false
        }
    }
}

private struct NormalizedTextRange {
    let startIndex: Int
    let start: BlockTextPosition
    let endIndex: Int
    let end: BlockTextPosition

    var isCollapsed: Bool { start == end }
}

private struct IdentifierGenerator {
    let source: BlockIDSource
    var fixedIndex = 0
    var used: Set<BlockID>

    init(source: BlockIDSource, existing: [BlockID]) {
        self.source = source
        used = Set(existing)
    }

    mutating func next() throws -> BlockID {
        let identifier: BlockID
        switch source {
        case .random:
            identifier = BlockID()
        case let .fixed(identifiers):
            guard fixedIndex < identifiers.count else { throw BlockInputError.insufficientBlockIDs }
            identifier = identifiers[fixedIndex]
            fixedIndex += 1
        }
        guard used.insert(identifier).inserted else {
            throw BlockInputError.duplicateBlockID(identifier)
        }
        return identifier
    }
}

private struct ReductionContext {
    var document: BlockDocument
    var selection: BlockEditorSelection
    var identifiers: IdentifierGenerator

    init(document: BlockDocument, selection: BlockEditorSelection, idSource: BlockIDSource) {
        self.document = document
        self.selection = selection
        identifiers = IdentifierGenerator(source: idSource, existing: document.blocks.map(\.id))
    }

    func noChange(_ reason: BlockInputNoChangeReason) -> BlockInputResult {
        .init(document: document, selection: selection, mutation: .none(reason), effect: .handled, undo: .none)
    }

    func selectionResult(_ newSelection: BlockEditorSelection) -> BlockInputResult {
        .init(document: document, selection: newSelection, mutation: .selectionOnly, effect: .handled, undo: .none)
    }

    mutating func setTaskCompletion(blockID: BlockID, completedAt: Date?) throws -> BlockInputResult {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }),
              document.blocks[index].kind == .task,
              document.blocks[index].taskState != nil else {
            return noChange(.unsupportedBlockKind)
        }
        guard document.blocks[index].taskState?.completedAt != completedAt else {
            return noChange(.samePosition)
        }
        var candidate = document
        candidate.blocks[index].taskState?.completedAt = completedAt
        return try documentResult(
            candidate,
            selection: selection,
            undo: .atomic(.taskCompletion)
        )
    }

    func documentResult(
        _ candidate: BlockDocument,
        selection newSelection: BlockEditorSelection,
        effect: BlockInputEffect = .handled,
        undo: BlockUndoDirective
    ) throws -> BlockInputResult {
        guard !candidate.blocks.isEmpty else { throw BlockInputError.invalidCandidate }
        do {
            try BlockDocumentValidator.validate(candidate)
        } catch {
            throw BlockInputError.invalidCandidate
        }
        return .init(document: candidate, selection: newSelection, mutation: .document, effect: effect, undo: undo)
    }

    func normalizedTextRange() -> NormalizedTextRange? {
        guard case let .text(anchor, focus, _, _) = selection,
              let anchorIndex = document.blocks.firstIndex(where: { $0.id == anchor.blockID }),
              let focusIndex = document.blocks.firstIndex(where: { $0.id == focus.blockID }) else { return nil }
        if anchorIndex < focusIndex || (anchorIndex == focusIndex && anchor.graphemeOffset <= focus.graphemeOffset) {
            return .init(startIndex: anchorIndex, start: anchor, endIndex: focusIndex, end: focus)
        }
        return .init(startIndex: focusIndex, start: focus, endIndex: anchorIndex, end: anchor)
    }

    func typingAttributes() -> BlockTypingAttributes {
        guard case let .text(_, _, _, attributes) = selection else {
            return .init(marks: [], linkURL: nil)
        }
        return attributes
    }

    func caretSelection(_ position: BlockTextPosition, in candidate: BlockDocument, preferredColumn: Int? = nil) -> BlockEditorSelection {
        let attributes = candidate.attributes(at: position, fallback: typingAttributes())
        return .text(anchor: position, focus: position, preferredColumn: preferredColumn, typingAttributes: attributes)
    }

    func selectedBlockRange(expandDescendants: Bool) -> ClosedRange<Int>? {
        guard case let .blocks(anchor, focus) = selection,
              let ai = document.blocks.firstIndex(where: { $0.id == anchor }),
              let fi = document.blocks.firstIndex(where: { $0.id == focus }) else { return nil }
        let lower = min(ai, fi)
        var upper = max(ai, fi)
        if expandDescendants {
            let selectedUpper = upper
            for root in lower...selectedUpper {
                var cursor = root + 1
                let level = document.blocks[root].indentLevel
                while cursor < document.blocks.count, document.blocks[cursor].indentLevel > level {
                    upper = max(upper, cursor)
                    cursor += 1
                }
            }
        }
        return lower...upper
    }
}

private extension DocumentBlock {
    var text: String { inlineContent.spans.map(\.text).joined() }

    var isTextCapable: Bool {
        switch kind {
        case .divider: false
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .code, .link: true
        }
    }

    var supportsInlineFormatting: Bool {
        switch kind {
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .link: true
        case .code, .divider: false
        }
    }

    var supportsIndentation: Bool {
        switch kind {
        case .bullet, .ordered, .task: true
        case .paragraph, .heading1, .heading2, .heading3, .quote, .code, .divider, .link: false
        }
    }

    func pasteBlock(content: InlineContent? = nil) -> BlockPasteBlock {
        .init(
            kind: kind,
            inlineContent: content ?? inlineContent,
            indentLevel: indentLevel,
            codeInfoString: codeInfoString,
            completionDescription: kind == .task ? taskState?.completionDescription : nil
        )
    }
}

private extension BlockKind {
    var allowsIndentation: Bool {
        switch self {
        case .bullet, .ordered, .task: true
        case .paragraph, .heading1, .heading2, .heading3, .quote, .code, .divider, .link: false
        }
    }
}

private extension BlockDocument {
    func attributes(at position: BlockTextPosition, fallback: BlockTypingAttributes) -> BlockTypingAttributes {
        guard let block = blocks.first(where: { $0.id == position.blockID }), block.isTextCapable else { return fallback.validated }
        let offset = position.graphemeOffset
        if offset > 0, let span = block.inlineContent.span(containingGrapheme: offset - 1) {
            return .init(marks: span.marks, linkURL: span.linkURL).validated
        }
        if let span = block.inlineContent.span(containingGrapheme: offset) {
            return .init(marks: span.marks, linkURL: span.linkURL).validated
        }
        return fallback.validated
    }
}

private extension BlockTypingAttributes {
    var validated: BlockTypingAttributes {
        .init(marks: marks, linkURL: BlockURLValidator.isValid(linkURL) ? linkURL : nil)
    }
}

private extension ReductionContext {
    mutating func insertTextApplyingMarkdownShortcut(_ value: String) throws -> BlockInputResult {
        let startedCollapsed: Bool
        let originalCaret: BlockTextPosition?
        let preservedZeroLengthSpans: [InlineSpan]
        if case let .text(anchor, focus, _, _) = selection {
            startedCollapsed = anchor == focus
            originalCaret = startedCollapsed ? anchor : nil
            preservedZeroLengthSpans = startedCollapsed
                ? document.blocks.first(where: { $0.id == anchor.blockID })?
                    .inlineContent.zeroLengthSpans(upTo: anchor.graphemeOffset) ?? []
                : []
        } else {
            startedCollapsed = false
            originalCaret = nil
            preservedZeroLengthSpans = []
        }
        let inserted = try insertText(value)
        guard startedCollapsed, inserted.mutation == .document else { return inserted }

        document = inserted.document
        selection = inserted.selection
        let converted = try applyMarkdownShortcut()
        guard converted.mutation == .document else { return inserted }
        guard !preservedZeroLengthSpans.isEmpty,
              let originalCaret,
              let index = converted.document.blocks.firstIndex(where: { $0.id == originalCaret.blockID }),
              converted.document.blocks[index].kind != .code else { return converted }
        var candidate = converted.document
        candidate.blocks[index].inlineContent.spans.insert(contentsOf: preservedZeroLengthSpans, at: 0)
        return try documentResult(
            candidate,
            selection: converted.selection,
            effect: converted.effect,
            undo: converted.undo
        )
    }

    mutating func insertText(_ value: String) throws -> BlockInputResult {
        guard !value.isEmpty else { return noChange(.emptySelection) }
        var candidate = document
        let caret: BlockTextPosition
        if case .text = selection, let range = normalizedTextRange(), range.isCollapsed {
            caret = range.start
        } else {
            let deleted = try deletionCandidate(requireNonemptySelection: true)
            candidate = deleted.document
            caret = deleted.caret
        }
        guard let index = candidate.blocks.firstIndex(where: { $0.id == caret.blockID }),
              candidate.blocks[index].isTextCapable else { return noChange(.unsupportedBlockKind) }
        var attributes = typingAttributes().validated
        if candidate.blocks[index].kind == .code { attributes = .init(marks: [], linkURL: nil) }
        let (prefix, suffix) = candidate.blocks[index].inlineContent.split(at: caret.graphemeOffset)
        candidate.blocks[index].inlineContent = .mergingInsertion(
            .init(text: value, marks: attributes.marks, linkURL: attributes.linkURL),
            between: prefix,
            and: suffix
        )
        if candidate.blocks[index].kind == .code {
            candidate.blocks[index] = Self.makeBlock(
                id: candidate.blocks[index].id,
                kind: .code,
                content: candidate.blocks[index].inlineContent,
                codeInfo: candidate.blocks[index].codeInfoString
            )
        }
        let position = BlockTextPosition(blockID: caret.blockID, graphemeOffset: caret.graphemeOffset + value.count)
        let newSelection = BlockEditorSelection.text(
            anchor: position,
            focus: position,
            preferredColumn: nil,
            typingAttributes: attributes
        )
        return try documentResult(candidate, selection: newSelection, undo: .coalesceTyping(caret.blockID))
    }

    mutating func enter() throws -> BlockInputResult {
        var candidate = document
        let caret: BlockTextPosition
        if case .text = selection, let range = normalizedTextRange(), range.isCollapsed {
            caret = range.start
        } else {
            let deleted = try deletionCandidate(requireNonemptySelection: true)
            candidate = deleted.document
            caret = deleted.caret
        }
        guard let index = candidate.blocks.firstIndex(where: { $0.id == caret.blockID }) else {
            throw BlockInputError.invalidSelection
        }
        var block = candidate.blocks[index]
        if block.kind == .divider {
            let newID = try identifiers.next()
            candidate.blocks.insert(Self.makeBlock(id: newID, kind: .paragraph, content: .plain("")), at: index + 1)
            return try documentResult(candidate, selection: plainCaret(newID, 0), undo: .atomic(.enter))
        }
        guard block.isTextCapable else { return noChange(.unsupportedBlockKind) }
        if block.text.isEmpty, Self.exitsToParagraphOnEmptyEnter(block.kind) {
            let content: InlineContent = block.kind == .link ? .plain("") : block.inlineContent
            block = Self.makeBlock(id: block.id, kind: .paragraph, content: content)
            candidate.blocks[index] = block
            return try documentResult(candidate, selection: plainCaret(block.id, 0), undo: .atomic(.enter))
        }
        let (leftContent, rightContent) = block.inlineContent.split(at: caret.graphemeOffset)
        let newID = try identifiers.next()
        let rightKind: BlockKind
        switch block.kind {
        case .heading1, .heading2, .heading3, .link: rightKind = .paragraph
        case .paragraph, .bullet, .ordered, .task, .quote, .code: rightKind = block.kind
        case .divider: rightKind = .paragraph
        }
        var leftKind = block.kind
        if leftKind == .link, !leftContent.containsValidLink { leftKind = .paragraph }
        let leftTask = Self.preservedTaskState(kind: leftKind, from: block)
        candidate.blocks[index] = Self.makeBlock(
            id: block.id,
            kind: leftKind,
            content: leftContent,
            indent: leftKind.allowsIndentation ? block.indentLevel : 0,
            completedAt: leftTask.completedAt,
            completionDescription: leftTask.completionDescription,
            codeInfo: leftKind == .code ? block.codeInfoString : nil
        )
        candidate.blocks.insert(Self.makeBlock(
            id: newID,
            kind: rightKind,
            content: rightContent,
            indent: rightKind.allowsIndentation ? block.indentLevel : 0,
            completedAt: nil,
            codeInfo: rightKind == .code ? block.codeInfoString : nil
        ), at: index + 1)
        return try documentResult(candidate, selection: plainCaret(newID, 0), undo: .atomic(.enter))
    }

    mutating func softBreak() throws -> BlockInputResult {
        guard case .text = selection, let originalRange = normalizedTextRange() else {
            return noChange(.unsupportedBlockKind)
        }
        var candidate = document
        var caret = originalRange.start
        if !originalRange.isCollapsed {
            let deleted = try deletionCandidate(requireNonemptySelection: true)
            candidate = deleted.document
            caret = deleted.caret
        }
        guard let index = candidate.blocks.firstIndex(where: { $0.id == caret.blockID }),
              candidate.blocks[index].isTextCapable else { return noChange(.unsupportedBlockKind) }
        let attributes = candidate.blocks[index].kind == .code
            ? BlockTypingAttributes(marks: [], linkURL: nil)
            : typingAttributes().validated
        let (prefix, suffix) = candidate.blocks[index].inlineContent.split(at: caret.graphemeOffset)
        candidate.blocks[index].inlineContent = .concatenating([
            prefix,
            .init(spans: [.init(text: "\n", marks: attributes.marks, linkURL: attributes.linkURL)]),
            suffix
        ])
        if candidate.blocks[index].kind == .code {
            candidate.blocks[index] = Self.makeBlock(
                id: candidate.blocks[index].id,
                kind: .code,
                content: candidate.blocks[index].inlineContent,
                codeInfo: candidate.blocks[index].codeInfoString
            )
        }
        let position = BlockTextPosition(blockID: caret.blockID, graphemeOffset: caret.graphemeOffset + 1)
        return try documentResult(candidate, selection: caretSelection(position, in: candidate), undo: .atomic(.softBreak))
    }

    mutating func backspace() throws -> BlockInputResult {
        guard case .text = selection, let range = normalizedTextRange() else {
            return try deleteSelection(action: .backspace)
        }
        if !range.isCollapsed { return try deleteSelection(action: .backspace) }
        var candidate = document
        let index = range.startIndex
        var block = candidate.blocks[index]
        let offset = range.start.graphemeOffset
        if offset > 0 {
            let (prefix, rest) = block.inlineContent.split(at: offset - 1)
            let (_, suffix) = rest.split(at: 1)
            block.inlineContent = .concatenating([prefix, suffix])
            if block.kind == .code {
                block = Self.makeBlock(id: block.id, kind: .code, content: block.inlineContent, codeInfo: block.codeInfoString)
            }
            if block.kind == .link, !block.inlineContent.containsValidLink {
                block = Self.makeBlock(id: block.id, kind: .paragraph, content: block.inlineContent)
            }
            candidate.blocks[index] = block
            let position = BlockTextPosition(blockID: block.id, graphemeOffset: offset - 1)
            return try documentResult(candidate, selection: caretSelection(position, in: candidate), undo: .atomic(.backspace))
        }
        if block.text.isEmpty, block.kind != .paragraph {
            block = Self.makeBlock(id: block.id, kind: .paragraph, content: .plain(""))
            candidate.blocks[index] = block
            return try documentResult(candidate, selection: plainCaret(block.id, 0), undo: .atomic(.backspace))
        }
        guard index > 0 else { return noChange(.documentBoundary) }
        var previousIndex = index - 1
        while previousIndex >= 0, candidate.blocks[previousIndex].kind == .divider {
            candidate.blocks.remove(at: previousIndex)
            previousIndex -= 1
        }
        if previousIndex < 0 {
            let current = candidate.blocks.first(where: { $0.id == block.id })!
            return try documentResult(candidate, selection: plainCaret(current.id, 0), undo: .atomic(.backspace))
        }
        guard candidate.blocks[previousIndex].isTextCapable else { return noChange(.unsupportedBlockKind) }
        let currentIndex = candidate.blocks.firstIndex(where: { $0.id == block.id })!
        let previous = candidate.blocks[previousIndex]
        let joinOffset = previous.text.count
        var merged = previous
        merged.inlineContent = .concatenating([previous.inlineContent, candidate.blocks[currentIndex].inlineContent])
        if merged.kind == .code {
            merged = Self.makeBlock(id: merged.id, kind: .code, content: merged.inlineContent, codeInfo: merged.codeInfoString)
        }
        if merged.kind == .link, !merged.inlineContent.containsValidLink {
            merged = Self.makeBlock(id: merged.id, kind: .paragraph, content: merged.inlineContent)
        }
        candidate.blocks[previousIndex] = merged
        candidate.blocks.remove(at: currentIndex)
        let position = BlockTextPosition(blockID: merged.id, graphemeOffset: joinOffset)
        return try documentResult(candidate, selection: caretSelection(position, in: candidate), undo: .atomic(.backspace))
    }
}

private extension ReductionContext {
    mutating func deleteSelection(action: BlockUndoAction) throws -> BlockInputResult {
        if case .text = selection, normalizedTextRange()?.isCollapsed == true {
            return noChange(.emptySelection)
        }
        let deleted = try deletionCandidate(requireNonemptySelection: true)
        return try documentResult(
            deleted.document,
            selection: caretSelection(deleted.caret, in: deleted.document),
            undo: .atomic(action)
        )
    }

    mutating func deletionCandidate(requireNonemptySelection: Bool) throws -> (document: BlockDocument, caret: BlockTextPosition) {
        var candidate = document
        switch selection {
        case .blocks:
            guard let range = selectedBlockRange(expandDescendants: true) else { throw BlockInputError.invalidSelection }
            candidate.blocks.removeSubrange(range)
            if candidate.blocks.isEmpty {
                let id = try identifiers.next()
                candidate.blocks = [Self.makeBlock(id: id, kind: .paragraph, content: .plain(""))]
                return (candidate, .init(blockID: id, graphemeOffset: 0))
            }
            let target = min(range.lowerBound, candidate.blocks.count - 1)
            return (candidate, .init(blockID: candidate.blocks[target].id, graphemeOffset: 0))
        case .text:
            guard let range = normalizedTextRange() else { throw BlockInputError.invalidSelection }
            if range.isCollapsed, requireNonemptySelection { throw BlockInputError.invalidSelection }
            let startBlock = candidate.blocks[range.startIndex]
            let endBlock = candidate.blocks[range.endIndex]
            if range.startIndex == 0,
               range.start.graphemeOffset == 0,
               range.endIndex == candidate.blocks.count - 1,
               range.end.graphemeOffset == endBlock.text.count {
                let id = try identifiers.next()
                candidate.blocks = [Self.makeBlock(id: id, kind: .paragraph, content: .plain(""))]
                return (candidate, .init(blockID: id, graphemeOffset: 0))
            }
            guard startBlock.isTextCapable, endBlock.isTextCapable else { throw BlockInputError.invalidCandidate }
            let (prefix, _) = startBlock.inlineContent.split(at: range.start.graphemeOffset)
            let (_, suffix) = endBlock.inlineContent.split(at: range.end.graphemeOffset)
            let startTask = Self.preservedTaskState(kind: startBlock.kind, from: startBlock)
            var replacement = Self.makeBlock(
                id: startBlock.id,
                kind: startBlock.kind,
                content: .concatenating([prefix, suffix]),
                indent: startBlock.indentLevel,
                completedAt: startTask.completedAt,
                completionDescription: startTask.completionDescription,
                codeInfo: startBlock.codeInfoString
            )
            if replacement.kind == .link, !replacement.inlineContent.containsValidLink {
                replacement = Self.makeBlock(id: replacement.id, kind: .paragraph, content: replacement.inlineContent)
            }
            candidate.blocks.replaceSubrange(range.startIndex...range.endIndex, with: [replacement])
            return (candidate, .init(blockID: replacement.id, graphemeOffset: range.start.graphemeOffset))
        }
    }

    func copySelection() -> BlockInputResult {
        guard let payload = clipboardPayload(expandBlockDescendants: false) else { return noChange(.emptySelection) }
        return .init(
            document: document,
            selection: selection,
            mutation: .none(.samePosition),
            effect: .writeClipboard(payload),
            undo: .none
        )
    }

    mutating func cutSelection() throws -> BlockInputResult {
        guard let payload = clipboardPayload(expandBlockDescendants: true) else { return noChange(.emptySelection) }
        let deleted = try deletionCandidate(requireNonemptySelection: true)
        return try documentResult(
            deleted.document,
            selection: caretSelection(deleted.caret, in: deleted.document),
            effect: .writeClipboard(payload),
            undo: .atomic(.cut)
        )
    }

    func clipboardPayload(expandBlockDescendants: Bool) -> BlockClipboardPayload? {
        switch selection {
        case .blocks:
            guard let range = selectedBlockRange(expandDescendants: expandBlockDescendants) else { return nil }
            let blocks = Array(document.blocks[range])
            return .init(
                plainText: blocks.map(\.text).joined(separator: "\n"),
                richBlocks: blocks.map { $0.pasteBlock() },
                inlineContent: nil
            )
        case .text:
            guard let range = normalizedTextRange(), !range.isCollapsed else { return nil }
            var rich: [BlockPasteBlock] = []
            var plain: [String] = []
            for index in range.startIndex...range.endIndex {
                let block = document.blocks[index]
                let lower = index == range.startIndex ? range.start.graphemeOffset : 0
                let upper = index == range.endIndex ? range.end.graphemeOffset : block.text.count
                let (_, middle, _) = block.inlineContent.slicing(lower, upper)
                var fragment = block.pasteBlock(content: middle)
                if fragment.kind == .link, !middle.containsValidLink {
                    fragment = .init(kind: .paragraph, inlineContent: middle, indentLevel: 0, codeInfoString: nil)
                }
                rich.append(fragment)
                plain.append(middle.plainText)
            }
            return .init(
                plainText: plain.joined(separator: "\n"),
                richBlocks: rich,
                inlineContent: range.startIndex == range.endIndex ? rich.first?.inlineContent : nil
            )
        }
    }

    static func exitsToParagraphOnEmptyEnter(_ kind: BlockKind) -> Bool {
        switch kind {
        case .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .link: true
        case .paragraph, .code, .divider: false
        }
    }

    static func makeBlock(
        id: BlockID,
        kind: BlockKind,
        content: InlineContent,
        indent: Int = 0,
        completedAt: Date? = nil,
        completionDescription: String? = nil,
        codeInfo: String? = nil
    ) -> DocumentBlock {
        let canonicalContent: InlineContent
        switch kind {
        case .code: canonicalContent = .plain(content.plainText)
        case .divider: canonicalContent = .plain("")
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .link:
            canonicalContent = content
        }
        return .init(
            id: id,
            kind: kind,
            inlineContent: canonicalContent,
            taskState: kind == .task
                ? .init(completedAt: completedAt, completionDescription: completionDescription)
                : nil,
            indentLevel: kind.allowsIndentation ? indent : 0,
            codeInfoString: kind == .code ? canonicalCodeInfo(codeInfo) : nil
        )
    }

    static func preservedTaskState(
        kind: BlockKind,
        from block: DocumentBlock
    ) -> (completedAt: Date?, completionDescription: String?) {
        guard kind == .task, block.kind == .task else { return (nil, nil) }
        return (block.taskState?.completedAt, block.taskState?.completionDescription)
    }

    static func canonicalCodeInfo(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return value.isEmpty ? nil : value
    }

    func plainCaret(_ id: BlockID, _ offset: Int) -> BlockEditorSelection {
        .text(
            anchor: .init(blockID: id, graphemeOffset: offset),
            focus: .init(blockID: id, graphemeOffset: offset),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
    }
}

private extension ReductionContext {
    mutating func toggle(_ mark: InlineMark) throws -> BlockInputResult {
        guard case let .text(anchor, focus, _, attributes) = selection,
              let range = normalizedTextRange() else { return noChange(.unsupportedBlockKind) }
        guard document.blocks[range.startIndex].supportsInlineFormatting else {
            return noChange(.unsupportedBlockKind)
        }
        if range.isCollapsed {
            var updated = attributes
            if updated.marks.contains(mark) { updated.marks.remove(mark) } else { updated.marks.insert(mark) }
            return selectionResult(.text(anchor: anchor, focus: focus, preferredColumn: nil, typingAttributes: updated.validated))
        }
        guard selectedTextBlocks(in: range).allSatisfy(\.supportsInlineFormatting) else {
            return noChange(.unsupportedBlockKind)
        }
        let selectedSpans = selectedInlineSpans(in: range).filter { !$0.text.isEmpty }
        guard !selectedSpans.isEmpty else { return noChange(.emptySelection) }
        let remove = selectedSpans.allSatisfy { $0.marks.contains(mark) }
        var candidate = document
        for index in range.startIndex...range.endIndex {
            let lower = index == range.startIndex ? range.start.graphemeOffset : 0
            let upper = index == range.endIndex ? range.end.graphemeOffset : candidate.blocks[index].text.count
            candidate.blocks[index].inlineContent = candidate.blocks[index].inlineContent.transforming(lower, upper) { span in
                var span = span
                if !span.text.isEmpty {
                    if remove { span.marks.remove(mark) } else { span.marks.insert(mark) }
                }
                return span
            }
        }
        var updatedAttributes = attributes
        if remove { updatedAttributes.marks.remove(mark) } else { updatedAttributes.marks.insert(mark) }
        let preservedSelection = BlockEditorSelection.text(
            anchor: range.start,
            focus: range.end,
            preferredColumn: nil,
            typingAttributes: updatedAttributes.validated
        )
        return try documentResult(candidate, selection: preservedSelection, undo: .atomic(.formatting))
    }

    mutating func setLink(_ url: URL?) throws -> BlockInputResult {
        guard BlockURLValidator.isValid(url) else { throw BlockInputError.invalidLink }
        guard case let .text(anchor, focus, _, attributes) = selection,
              let range = normalizedTextRange() else { return noChange(.unsupportedBlockKind) }
        guard document.blocks[range.startIndex].supportsInlineFormatting else {
            return noChange(.unsupportedBlockKind)
        }
        if range.isCollapsed {
            if url == nil,
               let activeURL = attributes.linkURL,
               let linkedRange = contiguousLinkRange(
                   in: document.blocks[range.startIndex],
                   at: range.start.graphemeOffset,
                   matching: activeURL
               ) {
                var candidate = document
                candidate.blocks[range.startIndex].inlineContent = candidate.blocks[range.startIndex].inlineContent.transforming(
                    linkedRange.lowerBound,
                    linkedRange.upperBound
                ) { span in
                    var span = span
                    if !span.text.isEmpty { span.linkURL = nil }
                    return span
                }
                if candidate.blocks[range.startIndex].kind == .link,
                   !candidate.blocks[range.startIndex].inlineContent.containsValidLink {
                    let block = candidate.blocks[range.startIndex]
                    candidate.blocks[range.startIndex] = Self.makeBlock(
                        id: block.id,
                        kind: .paragraph,
                        content: block.inlineContent
                    )
                }
                return try documentResult(
                    candidate,
                    selection: caretSelection(range.start, in: candidate),
                    undo: .atomic(.link)
                )
            }
            var updated = attributes
            updated.linkURL = url
            return selectionResult(.text(anchor: anchor, focus: focus, preferredColumn: nil, typingAttributes: updated.validated))
        }
        guard selectedTextBlocks(in: range).allSatisfy(\.supportsInlineFormatting) else {
            return noChange(.unsupportedBlockKind)
        }
        var candidate = document
        for index in range.startIndex...range.endIndex {
            let lower = index == range.startIndex ? range.start.graphemeOffset : 0
            let upper = index == range.endIndex ? range.end.graphemeOffset : candidate.blocks[index].text.count
            candidate.blocks[index].inlineContent = candidate.blocks[index].inlineContent.transforming(lower, upper) { span in
                var span = span
                if !span.text.isEmpty { span.linkURL = url }
                return span
            }
            if candidate.blocks[index].kind == .link, !candidate.blocks[index].inlineContent.containsValidLink {
                candidate.blocks[index] = Self.makeBlock(
                    id: candidate.blocks[index].id,
                    kind: .paragraph,
                    content: candidate.blocks[index].inlineContent
                )
            }
        }
        var updatedAttributes = attributes
        updatedAttributes.linkURL = url
        let preservedSelection = BlockEditorSelection.text(
            anchor: range.start,
            focus: range.end,
            preferredColumn: nil,
            typingAttributes: updatedAttributes.validated
        )
        return try documentResult(candidate, selection: preservedSelection, undo: .atomic(.link))
    }

    func contiguousLinkRange(
        in block: DocumentBlock,
        at offset: Int,
        matching url: URL
    ) -> Range<Int>? {
        let spans = block.inlineContent.spans
        var cursor = 0
        var matchingIndex: Int?
        var trailingIndex: Int?
        for (index, span) in spans.enumerated() {
            let end = cursor + span.text.count
            if span.linkURL == url {
                if cursor <= offset, offset < end {
                    matchingIndex = index
                    break
                }
                if end == offset { trailingIndex = index }
            }
            cursor = end
        }
        guard var lowerIndex = matchingIndex ?? trailingIndex else { return nil }
        var upperIndex = lowerIndex
        while lowerIndex > spans.startIndex, spans[lowerIndex - 1].linkURL == url {
            lowerIndex -= 1
        }
        while upperIndex + 1 < spans.endIndex, spans[upperIndex + 1].linkURL == url {
            upperIndex += 1
        }
        let lower = spans[..<lowerIndex].reduce(0) { $0 + $1.text.count }
        let upper = lower + spans[lowerIndex...upperIndex].reduce(0) { $0 + $1.text.count }
        return lower..<upper
    }

    mutating func convert(to kind: BlockKind, slash: Bool) throws -> BlockInputResult {
        guard case let .text(anchor, focus, _, typingAttributes) = selection,
              let range = normalizedTextRange() else {
            return noChange(.unsupportedBlockKind)
        }
        if !slash, anchor != focus {
            var candidate = document
            for index in range.startIndex...range.endIndex {
                let block = candidate.blocks[index]
                guard let converted = convertedBlock(
                    block,
                    kind: kind,
                    content: block.inlineContent
                ) else {
                    return noChange(.unsupportedBlockKind)
                }
                candidate.blocks[index] = converted
            }
            let nextSelection = BlockEditorSelection.text(
                anchor: anchor,
                focus: focus,
                preferredColumn: nil,
                typingAttributes: candidate.attributes(
                    at: focus,
                    fallback: typingAttributes
                )
            )
            return try documentResult(
                candidate,
                selection: nextSelection,
                undo: .atomic(.conversion)
            )
        }
        guard anchor == focus,
              let index = document.blocks.firstIndex(where: { $0.id == anchor.blockID }) else {
            return noChange(.unsupportedBlockKind)
        }
        var candidate = document
        var block = candidate.blocks[index]
        var content = block.inlineContent
        var newOffset = anchor.graphemeOffset
        if slash {
            let prefix = String(block.text.prefix(anchor.graphemeOffset))
            guard prefix.hasPrefix("/") else { return noChange(.samePosition) }
            let (_, suffix) = content.split(at: anchor.graphemeOffset)
            content = suffix
            newOffset = 0
        }
        guard let converted = convertedBlock(block, kind: kind, content: content) else {
            return noChange(.unsupportedBlockKind)
        }
        block = converted
        candidate.blocks[index] = block
        let position = BlockTextPosition(blockID: block.id, graphemeOffset: min(newOffset, block.text.count))
        return try documentResult(candidate, selection: caretSelection(position, in: candidate), undo: .atomic(.conversion))
    }

    mutating func applyMarkdownShortcut() throws -> BlockInputResult {
        guard case let .text(anchor, focus, _, _) = selection,
              anchor == focus,
              let index = document.blocks.firstIndex(where: { $0.id == anchor.blockID }),
              Self.acceptsMarkdownBlockShortcut(document.blocks[index].kind) else {
            return noChange(.samePosition)
        }
        let block = document.blocks[index]
        let prefix = String(block.text.prefix(anchor.graphemeOffset))
        let conversion: (kind: BlockKind, recognized: String, info: String?)?
        switch prefix {
        case "# ": conversion = (.heading1, prefix, nil)
        case "## ": conversion = (.heading2, prefix, nil)
        case "### ": conversion = (.heading3, prefix, nil)
        case "- ", "* ": conversion = (.bullet, prefix, nil)
        case "1. ": conversion = (.ordered, prefix, nil)
        case "[] ", "[ ] ": conversion = (.task, prefix, nil)
        case "> ": conversion = (.quote, prefix, nil)
        default:
            if prefix.hasPrefix("```"), prefix.hasSuffix(" ") {
                let raw = String(prefix.dropFirst(3).dropLast())
                let info = Self.canonicalCodeInfo(raw)
                guard !raw.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
                    return noChange(.samePosition)
                }
                conversion = (.code, prefix, info)
            } else {
                conversion = nil
            }
        }
        guard let conversion else { return noChange(.samePosition) }
        let (_, suffix) = block.inlineContent.split(at: conversion.recognized.count)
        guard var converted = convertedBlock(block, kind: conversion.kind, content: suffix) else {
            return noChange(.unsupportedBlockKind)
        }
        if conversion.kind == .code {
            converted = Self.makeBlock(id: block.id, kind: .code, content: suffix, codeInfo: conversion.info)
        }
        var candidate = document
        candidate.blocks[index] = converted
        let position = BlockTextPosition(blockID: block.id, graphemeOffset: 0)
        return try documentResult(candidate, selection: caretSelection(position, in: candidate), undo: .atomic(.conversion))
    }

    static func acceptsMarkdownBlockShortcut(_ kind: BlockKind) -> Bool {
        switch kind {
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote:
            true
        case .code, .divider, .link:
            false
        }
    }

    mutating func insertDivider() throws -> BlockInputResult {
        guard case let .text(anchor, focus, _, _) = selection,
              anchor == focus,
              let index = document.blocks.firstIndex(where: { $0.id == focus.blockID }) else {
            return noChange(.unsupportedBlockKind)
        }

        var candidate = document
        let current = candidate.blocks[index]

        if current.kind == .divider {
            if candidate.blocks.indices.contains(index + 1),
               candidate.blocks[index + 1].kind == .paragraph {
                let following = candidate.blocks[index + 1]
                return selectionResult(plainCaret(following.id, 0))
            }
            let paragraphID = try identifiers.next()
            candidate.blocks.insert(Self.makeBlock(id: paragraphID, kind: .paragraph, content: .plain("")), at: index + 1)
            return try documentResult(candidate, selection: plainCaret(paragraphID, 0), undo: .atomic(.conversion))
        }

        if current.text.isEmpty {
            candidate.blocks[index] = Self.makeBlock(id: current.id, kind: .divider, content: .plain(""))
            let paragraphID = try identifiers.next()
            candidate.blocks.insert(Self.makeBlock(id: paragraphID, kind: .paragraph, content: .plain("")), at: index + 1)
            return try documentResult(candidate, selection: plainCaret(paragraphID, 0), undo: .atomic(.conversion))
        }

        let dividerID = try identifiers.next()
        let paragraphID = try identifiers.next()
        candidate.blocks.insert(Self.makeBlock(id: dividerID, kind: .divider, content: .plain("")), at: index + 1)
        candidate.blocks.insert(Self.makeBlock(id: paragraphID, kind: .paragraph, content: .plain("")), at: index + 2)
        return try documentResult(candidate, selection: plainCaret(paragraphID, 0), undo: .atomic(.conversion))
    }

    func convertedBlock(_ block: DocumentBlock, kind: BlockKind, content: InlineContent) -> DocumentBlock? {
        if kind == .divider, !content.plainText.isEmpty { return nil }
        if kind == .link, !content.containsValidLink { return nil }
        let task = Self.preservedTaskState(kind: kind, from: block)
        return Self.makeBlock(
            id: block.id,
            kind: kind,
            content: content,
            indent: kind.allowsIndentation ? block.indentLevel : 0,
            completedAt: task.completedAt,
            completionDescription: task.completionDescription,
            codeInfo: kind == .code && block.kind == .code ? block.codeInfoString : nil
        )
    }

    func selectedTextBlocks(in range: NormalizedTextRange) -> ArraySlice<DocumentBlock> {
        document.blocks[range.startIndex...range.endIndex]
    }

    func selectedInlineSpans(in range: NormalizedTextRange) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        for index in range.startIndex...range.endIndex {
            let block = document.blocks[index]
            let lower = index == range.startIndex ? range.start.graphemeOffset : 0
            let upper = index == range.endIndex ? range.end.graphemeOffset : block.text.count
            let (_, middle, _) = block.inlineContent.slicing(lower, upper)
            spans.append(contentsOf: middle.spans)
        }
        return spans
    }
}

private extension InlineContent {
    func transforming(_ lower: Int, _ upper: Int, transform: (InlineSpan) -> InlineSpan) -> InlineContent {
        let (prefix, middle, suffix) = slicing(lower, upper)
        return .concatenating([prefix, .init(spans: middle.spans.map(transform)), suffix])
    }
}

private extension ReductionContext {
    mutating func changeIndent(by delta: Int) throws -> BlockInputResult {
        if case .text = selection, let range = normalizedTextRange(),
           range.startIndex == range.endIndex,
           document.blocks[range.startIndex].kind == .code {
            return try changeCodeIndent(by: delta, range: range)
        }
        let roots = selectedRootIndices()
        guard !roots.isEmpty else { return noChange(.unsupportedBlockKind) }
        guard roots.allSatisfy({ document.blocks[$0].supportsIndentation }) else {
            return noChange(.unsupportedBlockKind)
        }
        if delta > 0 {
            guard roots.allSatisfy({ root in
                let end = descendantEnd(of: root, in: document.blocks)
                return document.blocks[root...end].allSatisfy { $0.indentLevel < 3 }
            }) else {
                return noChange(.indentationLimit)
            }
            for root in roots {
                let level = document.blocks[root].indentLevel
                guard hasListParent(before: root, level: level) else { return noChange(.missingListParent) }
            }
        } else {
            guard roots.allSatisfy({ document.blocks[$0].indentLevel > 0 }) else {
                return noChange(.indentationLimit)
            }
        }
        var candidate = document
        for root in roots.reversed() {
            let end = descendantEnd(of: root, in: document.blocks)
            for index in root...end { candidate.blocks[index].indentLevel += delta }
        }
        return try documentResult(candidate, selection: selection.clearingPreferredColumn, undo: .atomic(.indentation))
    }

    mutating func changeCodeIndent(by delta: Int, range: NormalizedTextRange) throws -> BlockInputResult {
        var candidate = document
        let block = candidate.blocks[range.startIndex]
        let characters = Array(block.text)
        let lines = logicalLines(in: characters)
        let selected = lines.indices.filter { index in
            let line = lines[index]
            let endsAfterLineStarts = range.isCollapsed
                ? line.start <= range.end.graphemeOffset
                : line.start < range.end.graphemeOffset
            return endsAfterLineStarts && line.end >= range.start.graphemeOffset
        }
        guard !selected.isEmpty else { return noChange(.samePosition) }
        var lineStrings = lines.map { String(characters[$0.start..<$0.end]) }
        var changes: [(line: LogicalLine, delta: Int, removed: Int)] = []
        guard case let .text(anchor, focus, _, attributes) = selection else { throw BlockInputError.invalidSelection }
        for index in selected {
            let line = lines[index]
            let change: Int
            if delta > 0 {
                lineStrings[index] = "    " + lineStrings[index]
                change = 4
                changes.append((line, change, 0))
            } else {
                let removable = min(4, lineStrings[index].prefix(while: { $0 == " " }).count)
                lineStrings[index].removeFirst(removable)
                change = -removable
                changes.append((line, change, removable))
            }
        }
        let newText = lineStrings.joined(separator: "\n")
        guard newText != block.text else { return noChange(.indentationLimit) }
        candidate.blocks[range.startIndex] = Self.makeBlock(
            id: block.id,
            kind: .code,
            content: .plain(newText),
            codeInfo: block.codeInfoString
        )
        let newSelection = BlockEditorSelection.text(
            anchor: .init(blockID: anchor.blockID, graphemeOffset: mappedCodeOffset(anchor.graphemeOffset, changes: changes)),
            focus: .init(blockID: focus.blockID, graphemeOffset: mappedCodeOffset(focus.graphemeOffset, changes: changes)),
            preferredColumn: nil,
            typingAttributes: attributes
        )
        return try documentResult(candidate, selection: newSelection, undo: .atomic(.indentation))
    }

    func mappedCodeOffset(
        _ offset: Int,
        changes: [(line: LogicalLine, delta: Int, removed: Int)]
    ) -> Int {
        var mapped = offset
        for change in changes {
            if offset > change.line.end {
                mapped += change.delta
            } else if offset >= change.line.start {
                if change.delta > 0 {
                    mapped += change.delta
                } else {
                    mapped -= min(change.removed, offset - change.line.start)
                }
            }
        }
        return max(0, mapped)
    }

    func selectedRootIndices() -> [Int] {
        let raw: [Int]
        switch selection {
        case .blocks:
            guard let range = selectedBlockRange(expandDescendants: false) else { return [] }
            raw = Array(range)
        case .text:
            guard let range = normalizedTextRange() else { return [] }
            raw = Array(range.startIndex...range.endIndex)
        }
        var roots: [Int] = []
        for index in raw {
            if let previous = roots.last, index <= descendantEnd(of: previous, in: document.blocks) { continue }
            roots.append(index)
        }
        return roots
    }

    func descendantEnd(of root: Int, in blocks: [DocumentBlock]) -> Int {
        var end = root
        var cursor = root + 1
        while cursor < blocks.count, blocks[cursor].indentLevel > blocks[root].indentLevel {
            end = cursor
            cursor += 1
        }
        return end
    }

    func hasListParent(before index: Int, level: Int) -> Bool {
        guard index > 0 else { return false }
        var cursor = index - 1
        while cursor >= 0, document.blocks[cursor].supportsIndentation {
            if document.blocks[cursor].indentLevel == level { return true }
            cursor -= 1
        }
        return false
    }

    func moveHorizontal(_ direction: BlockHorizontalDirection, extending: Bool) -> BlockInputResult {
        guard case let .text(anchor, focus, _, _) = selection,
              let range = normalizedTextRange() else { return noChange(.unsupportedBlockKind) }
        if !extending, !range.isCollapsed {
            let target = direction == .backward ? range.start : range.end
            return selectionResult(caretSelection(target, in: document))
        }
        guard let next = horizontalPosition(from: focus, direction: direction) else {
            return noChange(.documentBoundary)
        }
        let newAnchor = extending ? anchor : next
        let newSelection = BlockEditorSelection.text(
            anchor: newAnchor,
            focus: next,
            preferredColumn: nil,
            typingAttributes: document.attributes(at: next, fallback: typingAttributes())
        )
        return selectionResult(newSelection)
    }

    func horizontalPosition(from position: BlockTextPosition, direction: BlockHorizontalDirection) -> BlockTextPosition? {
        guard let index = document.blocks.firstIndex(where: { $0.id == position.blockID }) else { return nil }
        let block = document.blocks[index]
        switch direction {
        case .backward:
            if position.graphemeOffset > 0 {
                return .init(blockID: block.id, graphemeOffset: position.graphemeOffset - 1)
            }
            guard index > 0 else { return nil }
            let previous = document.blocks[index - 1]
            return .init(blockID: previous.id, graphemeOffset: previous.kind == .divider ? 0 : previous.text.count)
        case .forward:
            if position.graphemeOffset < block.text.count {
                return .init(blockID: block.id, graphemeOffset: position.graphemeOffset + 1)
            }
            guard index + 1 < document.blocks.count else { return nil }
            return .init(blockID: document.blocks[index + 1].id, graphemeOffset: 0)
        }
    }

    func moveVertical(_ direction: BlockVerticalDirection, extending: Bool) -> BlockInputResult {
        guard case let .text(anchor, focus, preferredColumn, _) = selection,
              let blockIndex = document.blocks.firstIndex(where: { $0.id == focus.blockID }) else {
            return noChange(.unsupportedBlockKind)
        }
        let block = document.blocks[blockIndex]
        if block.kind == .divider {
            let sourceColumn = preferredColumn ?? 0
            let next: BlockTextPosition
            switch direction {
            case .up:
                guard blockIndex > 0 else { return noChange(.documentBoundary) }
                let previous = document.blocks[blockIndex - 1]
                let target = logicalLines(in: Array(previous.text)).last!
                next = .init(
                    blockID: previous.id,
                    graphemeOffset: previous.kind == .divider
                        ? 0
                        : target.start + min(sourceColumn, target.end - target.start)
                )
            case .down:
                guard blockIndex + 1 < document.blocks.count else { return noChange(.documentBoundary) }
                let following = document.blocks[blockIndex + 1]
                let target = logicalLines(in: Array(following.text)).first!
                next = .init(
                    blockID: following.id,
                    graphemeOffset: following.kind == .divider
                        ? 0
                        : target.start + min(sourceColumn, target.end - target.start)
                )
            }
            return selectionResult(.text(
                anchor: extending ? anchor : next,
                focus: next,
                preferredColumn: sourceColumn,
                typingAttributes: document.attributes(at: next, fallback: typingAttributes())
            ))
        }
        let characters = Array(block.text)
        let lines = logicalLines(in: characters)
        guard let lineIndex = lines.firstIndex(where: { focus.graphemeOffset >= $0.start && focus.graphemeOffset <= $0.end }) else {
            return noChange(.textSystemOwnsMovement)
        }
        let line = lines[lineIndex]
        let sourceColumn = preferredColumn ?? (focus.graphemeOffset - line.start)
        let next: BlockTextPosition
        switch direction {
        case .up:
            guard focus.graphemeOffset == line.start else { return noChange(.textSystemOwnsMovement) }
            if lineIndex > 0 {
                let target = lines[lineIndex - 1]
                next = .init(blockID: block.id, graphemeOffset: target.start + min(sourceColumn, target.end - target.start))
            } else {
                guard blockIndex > 0 else { return noChange(.documentBoundary) }
                let previous = document.blocks[blockIndex - 1]
                let previousLines = logicalLines(in: Array(previous.text))
                let target = previousLines.last!
                next = .init(blockID: previous.id, graphemeOffset: previous.kind == .divider ? 0 : target.start + min(sourceColumn, target.end - target.start))
            }
        case .down:
            guard focus.graphemeOffset == line.end else { return noChange(.textSystemOwnsMovement) }
            if lineIndex + 1 < lines.count {
                let target = lines[lineIndex + 1]
                next = .init(blockID: block.id, graphemeOffset: target.start + min(sourceColumn, target.end - target.start))
            } else {
                guard blockIndex + 1 < document.blocks.count else { return noChange(.documentBoundary) }
                let following = document.blocks[blockIndex + 1]
                let target = logicalLines(in: Array(following.text)).first!
                next = .init(blockID: following.id, graphemeOffset: following.kind == .divider ? 0 : target.start + min(sourceColumn, target.end - target.start))
            }
        }
        let newSelection = BlockEditorSelection.text(
            anchor: extending ? anchor : next,
            focus: next,
            preferredColumn: sourceColumn,
            typingAttributes: document.attributes(at: next, fallback: typingAttributes())
        )
        return selectionResult(newSelection)
    }
}

private extension BlockEditorSelection {
    var clearingPreferredColumn: BlockEditorSelection {
        switch self {
        case let .text(anchor, focus, _, attributes):
            .text(anchor: anchor, focus: focus, preferredColumn: nil, typingAttributes: attributes)
        case .blocks:
            self
        }
    }
}

private struct LogicalLine {
    let start: Int
    let end: Int
}

private func logicalLines(in characters: [Character]) -> [LogicalLine] {
    var result: [LogicalLine] = []
    var start = 0
    for (index, character) in characters.enumerated() where character == "\n" {
        result.append(.init(start: start, end: index))
        start = index + 1
    }
    result.append(.init(start: start, end: characters.count))
    return result
}

private extension ReductionContext {
    mutating func replaceSelection(_ payload: BlockPastePayload) throws -> BlockInputResult {
        switch payload {
        case .plainText:
            guard case let .plainLines(lines) = try BlockPasteParser.parse(payload) else {
                throw BlockInputError.invalidCandidate
            }
            return try replaceWithPlainLines(lines)
        case let .inlineContent(content, fallback):
            guard case .text = selection,
                  let range = normalizedTextRange(),
                  range.startIndex == range.endIndex
            else { return try replaceWithFallbackPlainText(fallback) }
            return try replaceWithInlineContent(content, range: range)
        case let .richText(_, fallback):
            let richBlocks: [BlockPasteBlock]
            do {
                guard case let .richBlocks(blocks) = try BlockPasteParser.parse(payload) else {
                    throw BlockInputError.invalidCandidate
                }
                richBlocks = blocks
            } catch {
                return try replaceWithFallbackPlainText(fallback)
            }
            var richAttempt = self
            do {
                return try richAttempt.replaceWithRichBlocks(richBlocks)
            } catch BlockInputError.invalidCandidate {
                return try replaceWithFallbackPlainText(fallback)
            }
        }
    }

    mutating func replaceWithInlineContent(
        _ inserted: InlineContent,
        range: NormalizedTextRange
    ) throws -> BlockInputResult {
        let block = document.blocks[range.startIndex]
        guard block.isTextCapable else { return noChange(.unsupportedBlockKind) }
        let (prefix, _) = block.inlineContent.split(at: range.start.graphemeOffset)
        let (_, suffix) = block.inlineContent.split(at: range.end.graphemeOffset)
        let currentTask = Self.preservedTaskState(kind: block.kind, from: block)
        var replacement = Self.makeBlock(
            id: block.id,
            kind: block.kind,
            content: InlineContent.concatenating([prefix, inserted, suffix]).coalescingAdjacentStyles(),
            indent: block.indentLevel,
            completedAt: currentTask.completedAt,
            completionDescription: currentTask.completionDescription,
            codeInfo: block.codeInfoString
        )
        if replacement.kind == .link, !replacement.inlineContent.containsValidLink {
            replacement = Self.makeBlock(
                id: replacement.id,
                kind: .paragraph,
                content: replacement.inlineContent
            )
        }
        var candidate = document
        candidate.blocks[range.startIndex] = replacement
        let caret = BlockTextPosition(
            blockID: replacement.id,
            graphemeOffset: prefix.plainText.count + inserted.plainText.count
        )
        return try documentResult(
            candidate,
            selection: caretSelection(caret, in: candidate),
            undo: .atomic(.paste)
        )
    }

    mutating func replaceWithFallbackPlainText(_ fallback: String) throws -> BlockInputResult {
        guard case let .plainLines(lines) = try BlockPasteParser.parse(.plainText(fallback)) else {
            throw BlockInputError.invalidCandidate
        }
        return try replaceWithPlainLines(lines)
    }

    mutating func replaceWithPlainLines(_ lines: [String]) throws -> BlockInputResult {
        let lines = lines.isEmpty ? [""] : lines
        if case .text = selection, normalizedTextRange()?.isCollapsed == true,
           lines.count == 1, lines[0].isEmpty {
            return noChange(.emptySelection)
        }
        switch selection {
        case .blocks:
            guard let range = selectedBlockRange(expandDescendants: true) else { throw BlockInputError.invalidSelection }
            let reuseID = document.blocks[range.lowerBound].id
            var replacements: [DocumentBlock] = []
            for (index, line) in lines.enumerated() {
                let id = index == 0 ? reuseID : try identifiers.next()
                replacements.append(Self.makeBlock(id: id, kind: .paragraph, content: .plain(line)))
            }
            var candidate = document
            candidate.blocks.replaceSubrange(range, with: replacements)
            let last = replacements.last!
            let caret = BlockTextPosition(blockID: last.id, graphemeOffset: last.text.count)
            return try documentResult(candidate, selection: caretSelection(caret, in: candidate), undo: .atomic(.paste))
        case .text:
            guard let range = normalizedTextRange() else { throw BlockInputError.invalidSelection }
            let startBlock = document.blocks[range.startIndex]
            let endBlock = document.blocks[range.endIndex]
            guard startBlock.isTextCapable, endBlock.isTextCapable else { return noChange(.unsupportedBlockKind) }
            let (prefix, _) = startBlock.inlineContent.split(at: range.start.graphemeOffset)
            let (_, suffix) = endBlock.inlineContent.split(at: range.end.graphemeOffset)
            let attributes = typingAttributes().validated
            func inserted(_ value: String) -> InlineContent {
                value.isEmpty ? .init(spans: []) : .init(spans: [.init(text: value, marks: attributes.marks, linkURL: attributes.linkURL)])
            }
            var replacements: [DocumentBlock] = []
            let startTask = Self.preservedTaskState(kind: startBlock.kind, from: startBlock)
            if lines.count == 1 {
                var first = Self.makeBlock(
                    id: startBlock.id,
                    kind: startBlock.kind,
                    content: .concatenating([prefix, inserted(lines[0]), suffix]),
                    indent: startBlock.indentLevel,
                    completedAt: startTask.completedAt,
                    completionDescription: startTask.completionDescription,
                    codeInfo: startBlock.codeInfoString
                )
                if first.kind == .link, !first.inlineContent.containsValidLink {
                    first = Self.makeBlock(id: first.id, kind: .paragraph, content: first.inlineContent)
                }
                replacements = [first]
            } else {
                var first = Self.makeBlock(
                    id: startBlock.id,
                    kind: startBlock.kind,
                    content: .concatenating([prefix, inserted(lines[0])]),
                    indent: startBlock.indentLevel,
                    completedAt: startTask.completedAt,
                    completionDescription: startTask.completionDescription,
                    codeInfo: startBlock.codeInfoString
                )
                if first.kind == .link, !first.inlineContent.containsValidLink {
                    first = Self.makeBlock(id: first.id, kind: .paragraph, content: first.inlineContent)
                }
                replacements.append(first)
                for index in 1..<lines.count {
                    let id = try identifiers.next()
                    let content = index == lines.count - 1
                        ? InlineContent.concatenating([inserted(lines[index]), suffix])
                        : inserted(lines[index])
                    replacements.append(Self.makeBlock(id: id, kind: .paragraph, content: content))
                }
            }
            var candidate = document
            candidate.blocks.replaceSubrange(range.startIndex...range.endIndex, with: replacements)
            let last = replacements.last!
            let caretOffset = lines.count == 1
                ? prefix.plainText.count + lines[0].count
                : lines.last!.count
            let caret = BlockTextPosition(blockID: last.id, graphemeOffset: caretOffset)
            return try documentResult(candidate, selection: caretSelection(caret, in: candidate), undo: .atomic(.paste))
        }
    }

    mutating func replaceWithRichBlocks(_ pasted: [BlockPasteBlock]) throws -> BlockInputResult {
        if pasted.isEmpty {
            if case .text = selection, normalizedTextRange()?.isCollapsed == true {
                return noChange(.emptySelection)
            }
            return try deleteSelection(action: .paste)
        }
        switch selection {
        case .blocks:
            guard let range = selectedBlockRange(expandDescendants: true) else { throw BlockInputError.invalidSelection }
            let reuseID = document.blocks[range.lowerBound].id
            var replacements: [DocumentBlock] = []
            for (index, block) in pasted.enumerated() {
                let id = index == 0 ? reuseID : try identifiers.next()
                replacements.append(Self.makePastedBlock(block, id: id))
            }
            var candidate = document
            candidate.blocks.replaceSubrange(range, with: replacements)
            let last = replacements.last!
            let caret = BlockTextPosition(blockID: last.id, graphemeOffset: last.kind == .divider ? 0 : last.text.count)
            return try documentResult(candidate, selection: caretSelection(caret, in: candidate), undo: .atomic(.paste))
        case .text:
            guard let range = normalizedTextRange() else { throw BlockInputError.invalidSelection }
            let startBlock = document.blocks[range.startIndex]
            let endBlock = document.blocks[range.endIndex]
            guard startBlock.isTextCapable, endBlock.isTextCapable else { return noChange(.unsupportedBlockKind) }
            let (prefix, _) = startBlock.inlineContent.split(at: range.start.graphemeOffset)
            let (_, suffix) = endBlock.inlineContent.split(at: range.end.graphemeOffset)
            let hasPrefix = !prefix.plainText.isEmpty
            let hasSuffix = !suffix.plainText.isEmpty
            var replacements: [DocumentBlock] = []
            if hasPrefix {
                let startTask = Self.preservedTaskState(kind: startBlock.kind, from: startBlock)
                var fragment = Self.makeBlock(
                    id: startBlock.id,
                    kind: startBlock.kind,
                    content: prefix,
                    indent: startBlock.indentLevel,
                    completedAt: startTask.completedAt,
                    completionDescription: startTask.completionDescription,
                    codeInfo: startBlock.codeInfoString
                )
                if fragment.kind == .link, !fragment.inlineContent.containsValidLink {
                    fragment = Self.makeBlock(id: fragment.id, kind: .paragraph, content: fragment.inlineContent)
                }
                replacements.append(fragment)
            }
            var pastedResult: [DocumentBlock] = []
            for (index, block) in pasted.enumerated() {
                let id: BlockID
                if !hasPrefix, !hasSuffix, index == 0 {
                    id = startBlock.id
                } else {
                    id = try identifiers.next()
                }
                pastedResult.append(Self.makePastedBlock(block, id: id))
            }
            replacements.append(contentsOf: pastedResult)
            if hasSuffix {
                let suffixID: BlockID
                let retainEndID = range.startIndex != range.endIndex || !hasPrefix
                if retainEndID { suffixID = endBlock.id } else { suffixID = try identifiers.next() }
                let suffixTask = suffixID == endBlock.id
                    ? Self.preservedTaskState(kind: endBlock.kind, from: endBlock)
                    : (completedAt: Date?.none, completionDescription: String?.none)
                var fragment = Self.makeBlock(
                    id: suffixID,
                    kind: endBlock.kind,
                    content: suffix,
                    indent: endBlock.indentLevel,
                    completedAt: suffixTask.completedAt,
                    completionDescription: suffixTask.completionDescription,
                    codeInfo: endBlock.codeInfoString
                )
                if fragment.kind == .link, !fragment.inlineContent.containsValidLink {
                    fragment = Self.makeBlock(id: fragment.id, kind: .paragraph, content: fragment.inlineContent)
                }
                replacements.append(fragment)
            }
            var candidate = document
            candidate.blocks.replaceSubrange(range.startIndex...range.endIndex, with: replacements)
            let lastPasted = pastedResult.last!
            let caret = BlockTextPosition(
                blockID: lastPasted.id,
                graphemeOffset: lastPasted.kind == .divider ? 0 : lastPasted.text.count
            )
            return try documentResult(candidate, selection: caretSelection(caret, in: candidate), undo: .atomic(.paste))
        }
    }

    static func makePastedBlock(_ block: BlockPasteBlock, id: BlockID) -> DocumentBlock {
        makeBlock(
            id: id,
            kind: block.kind,
            content: block.inlineContent,
            indent: block.indentLevel,
            completedAt: nil,
            completionDescription: block.kind == .task ? block.completionDescription : nil,
            codeInfo: block.codeInfoString
        )
    }
}

private extension ReductionContext {
    mutating func moveBlockRoots(_ requested: [BlockID], before target: BlockID?) throws -> BlockInputResult {
        guard !requested.isEmpty else { throw BlockInputError.invalidMove }
        var seen = Set<BlockID>()
        for id in requested where !seen.insert(id).inserted { throw BlockInputError.invalidMove }
        let indices = try requested.map { id -> Int in
            guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { throw BlockInputError.invalidMove }
            return index
        }
        if let target, !document.blocks.contains(where: { $0.id == target }) { throw BlockInputError.invalidMove }

        let sorted = indices.sorted()
        var roots: [Int] = []
        for index in sorted {
            if roots.contains(where: { index > $0 && index <= descendantEnd(of: $0, in: document.blocks) }) {
                continue
            }
            roots.append(index)
        }
        var movedIndices = Set<Int>()
        var moved: [DocumentBlock] = []
        for root in roots {
            let end = descendantEnd(of: root, in: document.blocks)
            for index in root...end {
                movedIndices.insert(index)
                moved.append(document.blocks[index])
            }
        }
        if let target,
           let targetIndex = document.blocks.firstIndex(where: { $0.id == target }),
           movedIndices.contains(targetIndex) {
            return noChange(.samePosition)
        }
        var remaining = document.blocks.enumerated().compactMap { movedIndices.contains($0.offset) ? nil : $0.element }
        let insertionIndex: Int
        if let target {
            guard let index = remaining.firstIndex(where: { $0.id == target }) else { throw BlockInputError.invalidMove }
            insertionIndex = index
        } else {
            insertionIndex = remaining.count
        }
        remaining.insert(contentsOf: moved, at: insertionIndex)
        guard remaining != document.blocks else { return noChange(.samePosition) }
        let candidate = BlockDocument(schemaVersion: document.schemaVersion, blocks: remaining)
        do {
            try BlockDocumentValidator.validate(candidate)
        } catch {
            throw BlockInputError.invalidMove
        }
        return .init(
            document: candidate,
            selection: selection.clearingPreferredColumn,
            mutation: .document,
            effect: .handled,
            undo: .atomic(.drag)
        )
    }

    /// Full-document ingestion used by Markdown 导入. Validates IDs and schema
    /// before any effect, and preserves exact checked-task timestamps.
    mutating func applyDocumentBlocks(
        _ blocks: [DocumentBlock],
        mode: BlockDocumentIngestMode
    ) throws -> BlockInputResult {
        guard !blocks.isEmpty else { throw BlockInputError.invalidCandidate }
        var seen = Set<BlockID>()
        for block in blocks {
            if !seen.insert(block.id).inserted {
                throw BlockInputError.duplicateBlockID(block.id)
            }
        }
        let nextBlocks: [DocumentBlock]
        switch mode {
        case .replace:
            nextBlocks = blocks
        case .append:
            let existingIDs = Set(document.blocks.map(\.id))
            for block in blocks where existingIDs.contains(block.id) {
                throw BlockInputError.duplicateBlockID(block.id)
            }
            nextBlocks = document.blocks + blocks
        }
        let candidate = BlockDocument(schemaVersion: document.schemaVersion, blocks: nextBlocks)
        do {
            try BlockDocumentValidator.validate(candidate)
        } catch {
            throw BlockInputError.invalidCandidate
        }
        let focus = nextBlocks[nextBlocks.count - 1]
        let caretOffset = focus.kind == .divider ? 0 : focus.text.count
        let nextSelection = BlockEditorSelection.text(
            anchor: .init(blockID: focus.id, graphemeOffset: caretOffset),
            focus: .init(blockID: focus.id, graphemeOffset: caretOffset),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        return .init(
            document: candidate,
            selection: nextSelection,
            mutation: .document,
            effect: .handled,
            undo: .atomic(.documentIngest)
        )
    }
}

private extension InlineContent {
    func zeroLengthSpans(upTo offset: Int) -> [InlineSpan] {
        var cursor = 0
        var matches: [InlineSpan] = []
        for span in spans {
            if span.text.isEmpty, cursor <= offset {
                matches.append(span)
            }
            cursor += span.text.count
        }
        return matches
    }

    func span(containingGrapheme target: Int) -> InlineSpan? {
        guard target >= 0 else { return nil }
        var cursor = 0
        for span in spans {
            let count = span.text.count
            if target >= cursor, target < cursor + count { return span }
            cursor += count
        }
        return nil
    }

    func split(at offset: Int) -> (InlineContent, InlineContent) {
        var left: [InlineSpan] = []
        var right: [InlineSpan] = []
        var cursor = 0
        for span in spans {
            let length = span.text.count
            if length == 0 {
                if cursor <= offset { left.append(span) } else { right.append(span) }
            } else if offset <= cursor {
                right.append(span)
            } else if offset >= cursor + length {
                left.append(span)
            } else {
                let local = offset - cursor
                let splitIndex = span.text.index(span.text.startIndex, offsetBy: local)
                var leftSpan = span
                var rightSpan = span
                leftSpan.text = String(span.text[..<splitIndex])
                rightSpan.text = String(span.text[splitIndex...])
                left.append(leftSpan)
                right.append(rightSpan)
            }
            cursor += length
        }
        return (.init(spans: left), .init(spans: right))
    }

    func slicing(_ lower: Int, _ upper: Int) -> (InlineContent, InlineContent, InlineContent) {
        let (prefix, rest) = split(at: lower)
        let (middle, suffix) = rest.split(at: upper - lower)
        return (prefix, middle, suffix)
    }

    static func concatenating(_ values: [InlineContent]) -> InlineContent {
        .init(spans: values.flatMap(\.spans))
    }

    static func mergingInsertion(
        _ insertion: InlineSpan,
        between prefix: InlineContent,
        and suffix: InlineContent
    ) -> InlineContent {
        var leading = prefix.spans
        var merged = insertion
        if let previous = leading.last,
           previous.marks == merged.marks,
           previous.linkURL == merged.linkURL {
            leading.removeLast()
            merged.text = previous.text + merged.text
        }
        var trailing = suffix.spans
        if let next = trailing.first,
           next.marks == merged.marks,
           next.linkURL == merged.linkURL {
            trailing.removeFirst()
            merged.text += next.text
        }
        return .init(spans: leading + [merged] + trailing)
    }

    func coalescingAdjacentStyles() -> InlineContent {
        var merged: [InlineSpan] = []
        for span in spans {
            if let last = merged.last,
               last.marks == span.marks,
               last.linkURL == span.linkURL {
                merged[merged.count - 1].text += span.text
            } else {
                merged.append(span)
            }
        }
        return .init(spans: merged)
    }

    var containsValidLink: Bool {
        spans.contains { span in
            guard let url = span.linkURL else { return false }
            return BlockURLValidator.isValid(url)
        }
    }

    var plainText: String { spans.map(\.text).joined() }
}

private extension String {
    func droppingGraphemes(in range: Range<Int>) -> String {
        let lower = index(startIndex, offsetBy: range.lowerBound)
        let upper = index(startIndex, offsetBy: range.upperBound)
        return String(self[..<lower] + self[upper...])
    }
}
