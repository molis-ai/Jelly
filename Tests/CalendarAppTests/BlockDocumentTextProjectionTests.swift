import AppKit
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockDocumentTextProjectionTests")
struct BlockDocumentTextProjectionTests {
    @Test func projectsEveryBlockKindIntoOneContinuousString() throws {
        let kinds: [BlockKind] = [
            .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered,
            .task, .quote, .code, .divider, .link
        ]
        let blocks = kinds.enumerated().map { index, kind in
            projectionBlock(id: index + 1, kind: kind, text: "第\(index + 1)段")
        }
        let projection = BlockDocumentTextProjection(
            document: .init(blocks: blocks),
            appearance: CalendarTheme.light
        )

        let expected = blocks.map { block in
            block.kind == .divider ? "" : projectionText(block)
        }.joined(separator: "\n")
        #expect(projection.attributedString.string == expected)
        #expect(projection.segments.count == blocks.count)
        for (index, segment) in projection.segments.enumerated() {
            #expect(segment.blockID == blocks[index].id)
            #expect(segment.kind == blocks[index].kind)
            #expect(segment.displayRange.length == (blocks[index].kind == .divider
                ? 0
                : projectionText(blocks[index]).utf16.count))
            #expect(segment.contentRange.length == (blocks[index].kind == .divider
                ? 0
                : projectionText(blocks[index]).utf16.count))
        }
    }

    @Test func nestedListTextUsesTheSameTwentyPointIndentStepAsItsControls() throws {
        let root = projectionBlock(id: 12, kind: .bullet, text: "父项")
        var nestedBullet = projectionBlock(id: 13, kind: .bullet, text: "子项")
        nestedBullet.indentLevel = 1
        var nestedTask = projectionBlock(id: 14, kind: .task, text: "子任务")
        nestedTask.indentLevel = 2
        let projection = BlockDocumentTextProjection(
            document: .init(blocks: [root, nestedBullet, nestedTask]),
            appearance: CalendarTheme.light
        )

        func paragraphStyle(at segment: Int) throws -> NSParagraphStyle {
            try #require(projection.attributedString.attribute(
                .paragraphStyle,
                at: projection.segments[segment].contentRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle)
        }

        #expect(try paragraphStyle(at: 0).headIndent == 22)
        #expect(try paragraphStyle(at: 1).headIndent == 42)
        #expect(try paragraphStyle(at: 2).headIndent == 62)
    }

    @Test func everyGraphemeBoundaryRoundTripsThroughTheGlobalUTF16CoordinateSpace() throws {
        let samples = ["ASCII", "中文", "e\u{301}", "🇨🇳", "👍🏽", "👨‍👩‍👧‍👦", "软\n换行"]
        for (index, sample) in samples.enumerated() {
            let block = projectionBlock(id: 20 + index, kind: .paragraph, text: sample)
            let projection = BlockDocumentTextProjection(
                document: .init(blocks: [block]),
                appearance: CalendarTheme.light
            )
            var utf16Offset = 0
            for graphemeOffset in 0..<sample.count {
                let position = BlockTextPosition(blockID: block.id, graphemeOffset: graphemeOffset)
                #expect(try projection.utf16Offset(for: position) == utf16Offset)
                #expect(try projection.textPosition(
                    atUTF16Offset: utf16Offset,
                    affinity: .downstream
                ) == position)
                utf16Offset += String(sample[sample.index(sample.startIndex, offsetBy: graphemeOffset)]).utf16.count
            }
            let end = BlockTextPosition(blockID: block.id, graphemeOffset: sample.count)
            #expect(try projection.utf16Offset(for: end) == utf16Offset)
            #expect(try projection.textPosition(atUTF16Offset: utf16Offset, affinity: .upstream) == end)
        }
    }

    @Test func consecutiveAndTrailingEmptyBlocksKeepDistinctInsertionPoints() throws {
        let blocks = [
            projectionBlock(id: 40, kind: .paragraph, text: "甲"),
            projectionBlock(id: 41, kind: .paragraph, text: ""),
            projectionBlock(id: 42, kind: .paragraph, text: ""),
            projectionBlock(id: 43, kind: .paragraph, text: "乙"),
            projectionBlock(id: 44, kind: .paragraph, text: "")
        ]
        let projection = BlockDocumentTextProjection(
            document: .init(blocks: blocks),
            appearance: CalendarTheme.light
        )

        #expect(projection.attributedString.string == "甲\n\n\n乙\n")
        let expectedOffsets = [0, 2, 3, 4, 6]
        for (block, offset) in zip(blocks, expectedOffsets) {
            let position = BlockTextPosition(blockID: block.id, graphemeOffset: 0)
            #expect(try projection.utf16Offset(for: position) == offset)
            #expect(try projection.textPosition(atUTF16Offset: offset, affinity: .downstream) == position)
        }
        #expect(try projection.textPosition(atUTF16Offset: 1, affinity: .upstream)
            == .init(blockID: blocks[0].id, graphemeOffset: 1))
    }

    @Test func forwardAndReverseCrossBlockSelectionsPreserveDirection() throws {
        let first = projectionBlock(id: 50, kind: .paragraph, text: "甲👍🏽")
        let second = projectionBlock(id: 51, kind: .paragraph, text: "乙文")
        let projection = BlockDocumentTextProjection(
            document: .init(blocks: [first, second]),
            appearance: CalendarTheme.light
        )
        let attributes = BlockTypingAttributes(marks: [.bold], linkURL: nil)
        let forward = BlockEditorSelection.text(
            anchor: .init(blockID: first.id, graphemeOffset: 1),
            focus: .init(blockID: second.id, graphemeOffset: 1),
            preferredColumn: nil,
            typingAttributes: attributes
        )
        let reverse = BlockEditorSelection.text(
            anchor: .init(blockID: second.id, graphemeOffset: 1),
            focus: .init(blockID: first.id, graphemeOffset: 1),
            preferredColumn: nil,
            typingAttributes: attributes
        )

        let range = try projection.nsRange(for: forward)
        #expect(range == .init(location: 1, length: 6))
        #expect(try projection.nsRange(for: reverse) == range)
        #expect(try projection.selection(
            for: range,
            preserving: .forward,
            typingAttributes: attributes
        ) == forward)
        #expect(try projection.selection(
            for: range,
            preserving: .reverse,
            typingAttributes: attributes
        ) == reverse)
    }

    @Test func dividerUsesItsEmptyLineForLayoutAndNeverLeaksIntoCopiedPlainText() throws {
        let blocks = [
            projectionBlock(id: 60, kind: .paragraph, text: "上\u{FFFC}"),
            projectionBlock(id: 61, kind: .divider, text: ""),
            projectionBlock(id: 62, kind: .paragraph, text: "下")
        ]
        let projection = BlockDocumentTextProjection(
            document: .init(blocks: blocks),
            appearance: CalendarTheme.light
        )
        let whole = NSRange(location: 0, length: projection.attributedString.length)

        #expect(projection.attributedString.string == "上\u{FFFC}\n\n下")
        #expect(try projection.plainText(in: whole) == "上\u{FFFC}\n\n下")
        #expect(try projection.utf16Offset(for: .init(blockID: blocks[1].id, graphemeOffset: 0)) == 3)
        #expect(try projection.textPosition(atUTF16Offset: 3, affinity: .downstream)
            == .init(blockID: blocks[1].id, graphemeOffset: 0))
        #expect(try projection.textPosition(atUTF16Offset: 4, affinity: .upstream)
            == .init(blockID: blocks[2].id, graphemeOffset: 0))
    }

    @Test func rejectsInvalidGlobalRangesMissingBlocksAndMidGraphemeOffsets() throws {
        let block = projectionBlock(id: 70, kind: .paragraph, text: "e\u{301}")
        let projection = BlockDocumentTextProjection(
            document: .init(blocks: [block]),
            appearance: CalendarTheme.light
        )

        #expect(throws: BlockEditorBridgeError.midGraphemeBoundary) {
            try projection.textPosition(atUTF16Offset: 1, affinity: .downstream)
        }
        #expect(throws: BlockEditorBridgeError.utf16OffsetOutOfRange) {
            try projection.textPosition(atUTF16Offset: 3, affinity: .downstream)
        }
        #expect(throws: BlockEditorBridgeError.missingBlock(projectionBlockID(71))) {
            try projection.utf16Offset(for: .init(blockID: projectionBlockID(71), graphemeOffset: 0))
        }
        #expect(throws: BlockEditorBridgeError.nsNotFound) {
            try projection.plainText(in: .init(location: NSNotFound, length: 0))
        }
        #expect(throws: BlockEditorBridgeError.integerOverflow) {
            try projection.plainText(in: .init(location: Int.max - 1, length: 2))
        }
    }

    @Test func oneCharacterEditInFiveHundredBlocksReplacesOnlyThatCharacter() throws {
        let oldBlocks = (0..<500).map {
            projectionBlock(id: 1_000 + $0, kind: .paragraph, text: "第\($0)段")
        }
        var newBlocks = oldBlocks
        newBlocks[250].inlineContent = .plain("第250段！")
        let old = BlockDocumentTextProjection(
            document: .init(blocks: oldBlocks),
            appearance: CalendarTheme.light
        )
        let new = BlockDocumentTextProjection(
            document: .init(blocks: newBlocks),
            appearance: CalendarTheme.light
        )

        let diff = try #require(BlockDocumentProjectionDiff.make(from: old, to: new))
        #expect(diff.changedBlockIDs == [oldBlocks[250].id])
        #expect(diff.oldRange == .init(
            location: NSMaxRange(old.segments[250].displayRange),
            length: 0
        ))
        #expect(diff.replacement.string == "！")
        let rebuilt = NSMutableAttributedString(attributedString: old.attributedString)
        rebuilt.replaceCharacters(in: diff.oldRange, with: diff.replacement)
        #expect(rebuilt.isEqual(to: new.attributedString))
    }

    @Test func insertionAndDeletionDiffsReconstructTheExactProjection() throws {
        let a = projectionBlock(id: 2_001, kind: .paragraph, text: "A")
        let b = projectionBlock(id: 2_002, kind: .paragraph, text: "B")
        let x = projectionBlock(id: 2_003, kind: .paragraph, text: "X")
        let cases: [([DocumentBlock], [DocumentBlock])] = [
            ([a, b], [x, a, b]),
            ([a, b], [a, x, b]),
            ([a, b], [a, b, x]),
            ([x, a, b], [a, b]),
            ([a, x, b], [a, b]),
            ([a, b, x], [a, b])
        ]

        for (oldBlocks, newBlocks) in cases {
            let old = BlockDocumentTextProjection(
                document: .init(blocks: oldBlocks), appearance: CalendarTheme.light
            )
            let new = BlockDocumentTextProjection(
                document: .init(blocks: newBlocks), appearance: CalendarTheme.light
            )
            let diff = try #require(BlockDocumentProjectionDiff.make(from: old, to: new))
            let rebuilt = NSMutableAttributedString(attributedString: old.attributedString)
            rebuilt.replaceCharacters(in: diff.oldRange, with: diff.replacement)
            #expect(rebuilt.isEqual(to: new.attributedString))
        }
    }

    @Test func completionDescriptionDoesNotEnterEditableProjection() throws {
        let block = try DocumentBlock.task(text: "给物业打电话", completionDescription: "拿到明确时间")
        let projection = BlockDocumentTextProjection(
            document: .init(blocks: [block]),
            appearance: CalendarTheme.light,
            completionDescriptionWidth: 320
        )
        #expect(projection.attributedString.string == "给物业打电话")
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: block.id, graphemeOffset: 0),
            focus: .init(blockID: block.id, graphemeOffset: "给物业打电话".count),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        #expect(try projection.nsRange(for: selection).length
            == ("给物业打电话" as NSString).length)
        #expect(try projection.plainText(in: .init(
            location: 0,
            length: projection.attributedString.length
        )) == "给物业打电话")
    }
}

private func projectionBlockID(_ value: Int) -> BlockID {
    BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", value))!)
}

private func projectionBlock(id: Int, kind: BlockKind, text: String) -> DocumentBlock {
    let inlineContent: InlineContent
    if kind == .divider {
        inlineContent = .plain("")
    } else if kind == .link {
        inlineContent = .init(spans: [
            .init(text: text, linkURL: URL(string: "https://example.com/\(id)")!)
        ])
    } else {
        inlineContent = .plain(text)
    }
    return .init(
        id: projectionBlockID(id),
        kind: kind,
        inlineContent: inlineContent,
        taskState: kind == .task ? .init(completedAt: nil) : nil,
        indentLevel: 0
    )
}

private func projectionText(_ block: DocumentBlock) -> String {
    block.inlineContent.spans.map(\.text).joined()
}
