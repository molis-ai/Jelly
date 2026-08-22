import AppKit
import Foundation
import WorkspaceDomain

struct BlockDocumentTextProjection: Equatable {
    struct Segment: Equatable {
        let blockID: BlockID
        let kind: BlockKind
        let contentRange: NSRange
        let displayRange: NSRange
    }

    let attributedString: NSAttributedString
    let segments: [Segment]
    let document: BlockDocument

    init(
        document: BlockDocument,
        appearance: CalendarSemanticAppearance,
        completionDescriptionWidth: CGFloat = NoteEditorLayout.maximumContentWidth - 32
    ) {
        self.document = document
        let output = NSMutableAttributedString()
        var builtSegments: [Segment] = []
        builtSegments.reserveCapacity(document.blocks.count)

        for (index, block) in document.blocks.enumerated() {
            let location = output.length
            let blockString = NSMutableAttributedString(
                attributedString: BlockTextStyle.attributedString(
                    for: block,
                    appearance: appearance,
                    completionDescriptionWidth: completionDescriptionWidth
                )
            )
            if index > 0 {
                Self.applyLeadingCompletionSpacing(
                    to: blockString,
                    previous: document.blocks[index - 1],
                    completionDescriptionWidth: completionDescriptionWidth
                )
            }
            output.append(blockString)
            let displayLength = blockString.length
            builtSegments.append(.init(
                blockID: block.id,
                kind: block.kind,
                contentRange: .init(
                    location: location,
                    length: block.kind == .divider ? 0 : displayLength
                ),
                displayRange: .init(location: location, length: displayLength)
            ))
            if index < document.blocks.count - 1 {
                output.append(BlockTextStyle.separator(appearance: appearance))
            }
        }

        attributedString = NSAttributedString(attributedString: output)
        segments = builtSegments
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.document == rhs.document
            && lhs.segments == rhs.segments
            && lhs.attributedString.isEqual(to: rhs.attributedString)
    }

    func textPosition(
        atUTF16Offset offset: Int,
        affinity: SelectionAffinity
    ) throws -> BlockTextPosition {
        try validateOffset(offset, allowEnd: true)
        guard !segments.isEmpty else { throw BlockEditorBridgeError.utf16OffsetOutOfRange }
        _ = affinity

        for (index, segment) in segments.enumerated() {
            let displayEnd = try checkedEnd(segment.displayRange)
            if segment.kind == .divider,
               offset == segment.displayRange.location || offset == displayEnd {
                return .init(blockID: segment.blockID, graphemeOffset: 0)
            }
            let contentEnd = try checkedEnd(segment.contentRange)
            if offset >= segment.contentRange.location, offset <= contentEnd {
                let localOffset = offset - segment.contentRange.location
                return try BlockSelectionBridge.graphemePosition(
                    blockID: segment.blockID,
                    utf16Offset: localOffset,
                    document: document
                )
            }
            if index == segments.count - 1, offset == attributedString.length {
                return try endPosition(for: segment.blockID)
            }
        }
        throw BlockEditorBridgeError.utf16OffsetOutOfRange
    }

    func utf16Offset(for position: BlockTextPosition) throws -> Int {
        guard let segment = segments.first(where: { $0.blockID == position.blockID }) else {
            throw BlockEditorBridgeError.missingBlock(position.blockID)
        }
        let local = try BlockSelectionBridge.utf16Offset(position: position, document: document)
        let (result, overflow) = segment.contentRange.location.addingReportingOverflow(local)
        guard !overflow else { throw BlockEditorBridgeError.integerOverflow }
        return result
    }

    func nsRange(for selection: BlockEditorSelection) throws -> NSRange {
        guard case let .text(anchor, focus, _, _) = selection else {
            throw BlockEditorBridgeError.crossBlockRange
        }
        let anchorOffset = try utf16Offset(for: anchor)
        let focusOffset = try utf16Offset(for: focus)
        return NSRange(
            location: min(anchorOffset, focusOffset),
            length: max(anchorOffset, focusOffset) - min(anchorOffset, focusOffset)
        )
    }

    func selection(
        for range: NSRange,
        preserving direction: SelectionDirection,
        typingAttributes: BlockTypingAttributes
    ) throws -> BlockEditorSelection {
        let end = try validate(range: range)
        let startPosition = try textPosition(atUTF16Offset: range.location, affinity: .downstream)
        let endPosition = try textPosition(atUTF16Offset: end, affinity: .upstream)
        let anchor = direction == .forward ? startPosition : endPosition
        let focus = direction == .forward ? endPosition : startPosition
        return .text(
            anchor: anchor,
            focus: focus,
            preferredColumn: nil,
            typingAttributes: typingAttributes
        )
    }

    func plainText(in range: NSRange) throws -> String {
        _ = try validate(range: range)
        let selected = attributedString.attributedSubstring(from: range)
        var result = ""
        selected.enumerateAttribute(
            .jellyDivider,
            in: .init(location: 0, length: selected.length),
            options: []
        ) { value, attributeRange, _ in
            guard (value as? Bool) != true else { return }
            result += selected.attributedSubstring(from: attributeRange).string
        }
        return result
    }

    private static func applyLeadingCompletionSpacing(
        to attributed: NSMutableAttributedString,
        previous: DocumentBlock,
        completionDescriptionWidth: CGFloat
    ) {
        guard attributed.length > 0,
              previous.inlineContent.spans.allSatisfy(\.text.isEmpty),
              let extra = TaskCompletionDescriptionMetrics.reservedParagraphSpacing(
                  for: previous,
                  width: completionDescriptionWidth
              ),
              let range = BlockTextStyle.paragraphRange(
                  in: attributed.string as NSString,
                  atUTF16Offset: 0
              ) else { return }
        let existing = attributed.attribute(
            .paragraphStyle,
            at: range.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle)
            ?? (BlockTextStyle.paragraphStyle(
                for: previous.kind,
                indentLevel: previous.indentLevel
            ).mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        style.paragraphSpacingBefore += extra
        attributed.addAttribute(
            .paragraphStyle,
            value: style,
            range: range
        )
    }

    private func endPosition(for blockID: BlockID) throws -> BlockTextPosition {
        guard let block = document.blocks.first(where: { $0.id == blockID }) else {
            throw BlockEditorBridgeError.missingBlock(blockID)
        }
        return .init(
            blockID: blockID,
            graphemeOffset: block.kind == .divider
                ? 0
                : block.inlineContent.spans.map(\.text).joined().count
        )
    }

    private func validateOffset(_ offset: Int, allowEnd: Bool) throws {
        if offset == NSNotFound { throw BlockEditorBridgeError.nsNotFound }
        if offset < 0 { throw BlockEditorBridgeError.negativeUTF16Offset }
        let upperBound = allowEnd ? attributedString.length : max(0, attributedString.length - 1)
        if offset > upperBound { throw BlockEditorBridgeError.utf16OffsetOutOfRange }
    }

    private func validate(range: NSRange) throws -> Int {
        if range.location == NSNotFound || range.length == NSNotFound {
            throw BlockEditorBridgeError.nsNotFound
        }
        if range.location < 0 || range.length < 0 {
            throw BlockEditorBridgeError.negativeUTF16Offset
        }
        let end = try checkedEnd(range)
        guard end <= attributedString.length else {
            throw BlockEditorBridgeError.utf16OffsetOutOfRange
        }
        return end
    }

    private func checkedEnd(_ range: NSRange) throws -> Int {
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        guard !overflow else { throw BlockEditorBridgeError.integerOverflow }
        return end
    }
}
