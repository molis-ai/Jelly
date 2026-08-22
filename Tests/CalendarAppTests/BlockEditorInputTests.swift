import AppKit
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorInputTests")
struct BlockEditorInputTests {
    @Test func insertDividerLeavesOneEditableParagraphAfterTheRuleInOneUndoStep() throws {
        let emptyID = blockID(4994)
        let paragraphID = blockID(4995)
        let dividerID = blockID(4996)

        let replacingEmpty = try reduce(
            doc([block(emptyID, .paragraph, "")]),
            caret(emptyID, 0),
            .insertDivider,
            ids: [paragraphID]
        )
        #expect(replacingEmpty.document.blocks.map(\.kind) == [.divider, .paragraph])
        #expect(replacingEmpty.document.blocks.map(text) == ["", ""])
        #expect(replacingEmpty.selection == caret(paragraphID, 0))
        #expect(replacingEmpty.undo == .atomic(.conversion))

        let insertingAfterContent = try reduce(
            doc([block(emptyID, .paragraph, "正文")]),
            caret(emptyID, 2),
            .insertDivider,
            ids: [dividerID, paragraphID]
        )
        #expect(insertingAfterContent.document.blocks.map(\.kind) == [.paragraph, .divider, .paragraph])
        #expect(insertingAfterContent.document.blocks.map(text) == ["正文", "", ""])
        #expect(insertingAfterContent.selection == caret(paragraphID, 0))
        #expect(insertingAfterContent.undo == .atomic(.conversion))
    }

    @Test func completeEmptyListExitAndBackspaceSequenceLeavesNoStrayListRow() throws {
        let contentID = blockID(4997)
        let emptyID = blockID(4998)
        var result = try reduce(
            doc([block(contentID, .bullet, "gamma")]),
            caret(contentID, 5),
            .enter,
            ids: [emptyID]
        )
        #expect(result.document.blocks.map(\.kind) == [.bullet, .bullet])
        #expect(result.selection == caret(emptyID, 0))

        result = try reduce(result.document, result.selection, .enter)
        #expect(result.document.blocks.map(\.kind) == [.bullet, .paragraph])
        #expect(result.selection == caret(emptyID, 0))

        result = try reduce(result.document, result.selection, .convert(.bullet))
        #expect(result.document.blocks.map(\.kind) == [.bullet, .bullet])

        result = try reduce(result.document, result.selection, .backspace)
        #expect(result.document.blocks.map(\.kind) == [.bullet, .paragraph])
        #expect(text(result.document.blocks[1]).isEmpty)

        result = try reduce(result.document, result.selection, .backspace)
        #expect(result.document.blocks.map(\.kind) == [.bullet])
        #expect(result.document.blocks.map(text) == ["gamma"])
        #expect(result.selection == caret(contentID, 5))
    }

    @Test func ordinaryTypingCoalescesAdjacentEqualStylesIntoOneSpan() throws {
        let id = blockID(4999)
        var document = doc([block(id, .paragraph, "")])
        var selection = caret(id, 0)

        for character in "first" {
            let result = try reduce(
                document,
                selection,
                .insertTextApplyingMarkdownShortcut(String(character))
            )
            document = result.document
            selection = result.selection
        }

        #expect(document.blocks[0].inlineContent.spans == [.init(text: "first")])
    }

    @Test func taskCompletionTargetsOnlyATaskAndPreservesItsIdentityContentAndIndent() throws {
        let taskID = blockID(5000)
        let paragraphID = blockID(5001)
        let parentID = blockID(5002)
        let completedAt = Date(timeIntervalSince1970: 1_755_000_000)
        let task = DocumentBlock(
            id: taskID,
            kind: .task,
            inlineContent: .plain("正文里的待办"),
            taskState: .init(completedAt: nil),
            indentLevel: 1
        )
        let paragraph = block(paragraphID, .paragraph, "普通正文")
        let document = doc([block(parentID, .bullet, "父列表"), task, paragraph])

        let completed = try reduce(
            document,
            caret(paragraphID, 0),
            .setTaskCompletion(blockID: taskID, completedAt: completedAt)
        )
        #expect(completed.document.blocks[1].id == taskID)
        #expect(completed.document.blocks[1].kind == .task)
        #expect(text(completed.document.blocks[1]) == "正文里的待办")
        #expect(completed.document.blocks[1].indentLevel == 1)
        #expect(completed.document.blocks[1].taskState?.completedAt == completedAt)
        #expect(completed.document.blocks[2] == paragraph)
        #expect(completed.selection == caret(paragraphID, 0))
        #expect(completed.undo == .atomic(.taskCompletion))

        let reopened = try reduce(
            completed.document,
            completed.selection,
            .setTaskCompletion(blockID: taskID, completedAt: nil)
        )
        #expect(reopened.document.blocks[1].taskState?.completedAt == nil)
        #expect(reopened.undo == .atomic(.taskCompletion))

        let rejected = try reduce(
            document,
            caret(taskID, 0),
            .setTaskCompletion(blockID: paragraphID, completedAt: completedAt)
        )
        #expect(rejected.document == document)
        #expect(rejected.mutation == .none(.unsupportedBlockKind))
        #expect(rejected.undo == .none)
    }

    @Test func replacingSelectedTextInATaskKeepsCompletionDescriptionOnTheSameBlock() throws {
        let id = blockID(5100)
        let completed = Date(timeIntervalSince1970: 1_755_000_100)
        let document = doc([describedTask(id, "给物业打电话", description: "拿到明确上门时间", completed: completed)])

        let replaced = try reduce(
            document,
            textSelection(id, 1, id, 3),
            .insertText("新")
        )
        #expect(replaced.document.blocks[0].id == id)
        #expect(replaced.document.blocks[0].kind == .task)
        #expect(text(replaced.document.blocks[0]) == "给新打电话")
        #expect(replaced.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")
        #expect(replaced.document.blocks[0].taskState?.completedAt == completed)

        let pasted = try reduce(
            document,
            textSelection(id, 1, id, 3),
            .replaceSelection(.plainText("新"))
        )
        #expect(pasted.document.blocks[0].id == id)
        #expect(pasted.document.blocks[0].kind == .task)
        #expect(text(pasted.document.blocks[0]) == "给新打电话")
        #expect(pasted.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")
        #expect(pasted.document.blocks[0].taskState?.completedAt == completed)
    }

    @Test func enterSplitsATaskWithoutCopyingCompletionDescriptionOntoTheNewBlock() throws {
        let id = blockID(5101), next = blockID(5102)
        let completed = Date(timeIntervalSince1970: 1_755_000_101)
        let document = doc([describedTask(id, "给物业打电话", description: "拿到明确上门时间", completed: completed)])
        let result = try reduce(document, caret(id, 3), .enter, ids: [next])

        #expect(result.document.blocks.map(\.id) == [id, next])
        #expect(result.document.blocks.map(\.kind) == [.task, .task])
        #expect(result.document.blocks.map(text) == ["给物业", "打电话"])
        #expect(result.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")
        #expect(result.document.blocks[0].taskState?.completedAt == completed)
        #expect(result.document.blocks[1].taskState?.completionDescription == nil)
        #expect(result.document.blocks[1].taskState?.completedAt == nil)
    }

    @Test func joiningAcrossTasksKeepsTheReusedOriginalTaskCompletionDescription() throws {
        let first = blockID(5103), second = blockID(5104)
        let document = doc([
            describedTask(first, "给物业打电话", description: "拿到明确上门时间"),
            describedTask(second, "记录时间", description: "写进日历备注")
        ])
        let result = try reduce(
            document,
            textSelection(first, 3, second, 2),
            .deleteSelection
        )
        #expect(result.document.blocks.count == 1)
        #expect(result.document.blocks[0].id == first)
        #expect(result.document.blocks[0].kind == .task)
        #expect(text(result.document.blocks[0]) == "给物业时间")
        #expect(result.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")
    }

    @Test func convertingTaskToTaskKeepsCompletionDescriptionAndLeavingTaskDoesNot() throws {
        let id = blockID(5105)
        let document = doc([describedTask(id, "给物业打电话", description: "拿到明确上门时间")])

        let stillTask = try reduce(document, caret(id, 0), .convert(.task))
        #expect(stillTask.document.blocks[0].id == id)
        #expect(stillTask.document.blocks[0].kind == .task)
        #expect(stillTask.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")

        let paragraph = try reduce(document, caret(id, 0), .convert(.paragraph))
        #expect(paragraph.document.blocks[0].id == id)
        #expect(paragraph.document.blocks[0].kind == .paragraph)
        #expect(paragraph.document.blocks[0].taskState == nil)

        let promoted = try reduce(
            doc([block(id, .paragraph, "给物业打电话")]),
            caret(id, 0),
            .convert(.task)
        )
        #expect(promoted.document.blocks[0].kind == .task)
        #expect(promoted.document.blocks[0].taskState?.completionDescription == nil)
        #expect(promoted.document.blocks[0].taskState?.completedAt == nil)
    }

    @Test @MainActor func blockCopyRoundTripsTaskCompletionDescriptionThroughPasteboardAdapterWithoutCompletedAt() throws {
        let source = blockID(5106), target = blockID(5107)
        let completed = Date(timeIntervalSince1970: 1_755_000_107)
        let copied = try reduce(
            doc([describedTask(source, "给物业打电话", description: "拿到明确上门时间", completed: completed)]),
            BlockEditorSelection.blocks(anchor: source, focus: source),
            .copySelection
        )
        guard case let .writeClipboard(clipboard) = copied.effect else {
            Issue.record("block copy must write a private clipboard payload")
            return
        }
        #expect(clipboard.inlineContent == nil)
        #expect(clipboard.plainText == "给物业打电话")
        #expect(clipboard.richBlocks.count == 1)
        #expect(clipboard.richBlocks[0].kind == .task)
        #expect(clipboard.richBlocks[0].completionDescription == "拿到明确上门时间")

        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        #expect(adapter.write(payload: clipboard))
        #expect(pasteboard.string(forType: .string) == "给物业打电话")

        let restored = try #require(adapter.readPayload())
        guard case let .richText(blocks, fallback) = restored else {
            Issue.record("block copy must round-trip as rich text through the adapter, not inlineContent")
            return
        }
        #expect(fallback == "给物业打电话")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .task)
        #expect(blocks[0].completionDescription == "拿到明确上门时间")

        let pasted = try reduce(
            doc([block(target, .paragraph, "")]),
            caret(target, 0),
            .replaceSelection(restored)
        )
        #expect(pasted.document.blocks.count == 1)
        #expect(pasted.document.blocks[0].id == target)
        #expect(pasted.document.blocks[0].kind == .task)
        #expect(text(pasted.document.blocks[0]) == "给物业打电话")
        #expect(pasted.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")
        #expect(pasted.document.blocks[0].taskState?.completedAt == nil)
    }

    @Test func externalPlainTextPasteDoesNotInjectAHiddenCompletionDescription() throws {
        let id = blockID(5108)
        let result = try reduce(
            doc([describedTask(id, "给物业打电话", description: "拿到明确上门时间")]),
            caret(id, 6),
            .replaceSelection(.plainText("后续"))
        )
        #expect(result.document.blocks[0].id == id)
        #expect(result.document.blocks[0].kind == .task)
        #expect(text(result.document.blocks[0]) == "给物业打电话后续")
        #expect(result.document.blocks[0].taskState?.completionDescription == "拿到明确上门时间")

        let intoParagraph = try reduce(
            doc([block(id, .paragraph, "")]),
            caret(id, 0),
            .replaceSelection(.plainText("给物业打电话"))
        )
        #expect(intoParagraph.document.blocks[0].kind == .paragraph)
        #expect(intoParagraph.document.blocks[0].taskState == nil)
        #expect(text(intoParagraph.document.blocks[0]) == "给物业打电话")
    }

    @Test(arguments: UnicodeFixture.all)
    func insertionAndBackspaceRespectGraphemeBoundaries(_ fixture: UnicodeFixture) throws {
        let id = blockID(1)
        let document = doc([block(id, .paragraph, fixture.text)])
        let insertion = try reduce(document, caret(id, fixture.count), .insertText("好"))
        #expect(text(insertion.document.blocks[0]) == fixture.text + "好")
        #expect(insertion.selection == caret(id, fixture.count + 1))
        #expect(insertion.undo == .coalesceTyping(id))

        let deletion = try reduce(document, caret(id, fixture.count), .backspace)
        #expect(text(deletion.document.blocks[0]) == String(fixture.text.dropLast()))
        #expect(deletion.selection == caret(id, fixture.count - 1))
        #expect(deletion.undo == .atomic(.backspace))
    }

    @Test(arguments: UnicodeFixture.all)
    func splitDeleteFormatLinkAndPasteShareGraphemeOffsets(_ fixture: UnicodeFixture) throws {
        let id = blockID(240), next = blockID(241)
        let original = fixture.text + fixture.text
        let document = doc([block(id, .paragraph, original)])

        let split = try reduce(document, caret(id, 1), .enter, ids: [next])
        #expect(split.document.blocks.map(text) == [fixture.text, fixture.text])

        let selected = textSelection(id, 0, id, 1)
        let deleted = try reduce(document, selected, .deleteSelection)
        #expect(text(deleted.document.blocks[0]) == fixture.text)
        let reverseSelected = textSelection(id, 1, id, 0)
        #expect(try reduce(document, reverseSelected, .deleteSelection) == deleted)

        let formatted = try reduce(document, selected, .toggleInlineMark(.bold))
        #expect(formatted.document.blocks[0].inlineContent.spans.first(where: { !$0.text.isEmpty })?.marks == [.bold])
        #expect(try reduce(document, reverseSelected, .toggleInlineMark(.bold)) == formatted)

        let url = URL(string: "https://example.com/unicode")!
        let linked = try reduce(document, selected, .setLink(url))
        #expect(linked.document.blocks[0].inlineContent.spans.first(where: { !$0.text.isEmpty })?.linkURL == url)
        #expect(try reduce(document, reverseSelected, .setLink(url)) == linked)

        let pasted = try reduce(document, caret(id, 1), .replaceSelection(.plainText(fixture.text)))
        #expect(text(pasted.document.blocks[0]) == fixture.text + fixture.text + fixture.text)
        #expect(pasted.selection == caret(id, 2, attributes: attributesAt(pasted.document, id, 2)))
        let replacedForward = try reduce(document, selected, .replaceSelection(.plainText(fixture.text)))
        #expect(try reduce(document, reverseSelected, .replaceSelection(.plainText(fixture.text))) == replacedForward)
    }

    @Test func directionAndOriginalSpanBoundariesSurviveFormatting() throws {
        let id = blockID(2)
        let zero = InlineSpan(text: "", marks: [.italic])
        let document = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "甲", marks: [.bold]), zero,
                .init(text: "乙", marks: [.bold]),
                .init(text: "丙")
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        let reverse = BlockEditorSelection.text(
            anchor: .init(blockID: id, graphemeOffset: 3),
            focus: .init(blockID: id, graphemeOffset: 1),
            preferredColumn: 9,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let result = try reduce(document, reverse, .toggleInlineMark(.italic))
        #expect(result.mutation == .document)
        #expect(result.selection == textSelection(
            id, 1, id, 3,
            attributes: .init(marks: [.italic], linkURL: nil)
        ))
        #expect(result.document.blocks[0].inlineContent == .init(spans: [
            .init(text: "甲", marks: [.bold]),
            zero,
            .init(text: "乙", marks: [.bold, .italic]),
            .init(text: "丙", marks: [.italic])
        ]))
        #expect(result.undo == .atomic(.formatting))
    }

    @Test func structuralFormattingConvertsEveryBlockTouchedByATextSelection() throws {
        let first = blockID(2001)
        let second = blockID(2002)
        let third = blockID(2003)
        let document = doc([
            block(first, .paragraph, "一"),
            block(second, .paragraph, "二"),
            block(third, .paragraph, "三")
        ])
        let selection = textSelection(first, 0, second, 1)

        let result = try reduce(document, selection, .convert(.task))

        #expect(result.document.blocks.map(\.kind) == [.task, .task, .paragraph])
        #expect(result.document.blocks[0].taskState?.completedAt == nil)
        #expect(result.document.blocks[1].taskState?.completedAt == nil)
        #expect(result.selection == selection)
        #expect(result.undo == .atomic(.conversion))
    }

    @Test func invalidSelectionsAndDocumentsThrowTypedErrorsWithoutIDs() throws {
        let id = blockID(3)
        let duplicate = doc([block(id, .paragraph, "甲"), block(id, .paragraph, "乙")])
        #expect(throws: BlockInputError.invalidInputDocument) {
            try reduce(duplicate, caret(id, 0), .insertText("x"), ids: [blockID(90)])
        }
        let valid = doc([block(id, .paragraph, "甲")])
        for selection in [caret(blockID(99), 0), caret(id, -1), caret(id, 2)] {
            #expect(throws: BlockInputError.invalidSelection) {
                try reduce(valid, selection, .enter, ids: [blockID(90)])
            }
        }
        let divider = blockID(4)
        #expect(throws: BlockInputError.invalidSelection) {
            try reduce(doc([block(divider, .divider, "")]), caret(divider, 1), .enter)
        }
    }

    @Test(arguments: EnterFixture.all)
    func enterMatrix(_ fixture: EnterFixture) throws {
        let original = fixture.document
        let result = try reduce(original, fixture.selection, .enter, ids: fixture.ids)
        #expect(result.document == fixture.expected)
        #expect(result.selection == fixture.expectedSelection)
        #expect(result.undo == .atomic(.enter))
    }

    @Test func enterCoversEveryKindAtStartMiddleEndAndEmpty() throws {
        let next = blockID(250)
        for kind in allBlockKinds {
            let id = blockID(249)
            if kind == .divider {
                let result = try reduce(doc([validBlock(id, kind, "")]), caret(id, 0), .enter, ids: [next])
                #expect(result.document.blocks.map(\.kind) == [.divider, .paragraph])
                continue
            }
            for offset in 0...2 {
                let original = validBlock(id, kind, "甲乙", completed: .distantPast, codeInfo: kind == .code ? "swift" : nil)
                let result = try reduce(doc([original]), caret(id, offset), .enter, ids: [next])
                #expect(result == expectedEnterResult(kind: kind, id: id, next: next, offset: offset), Comment(rawValue: "kind=\(kind) offset=\(offset)"))
            }

            let empty = try reduce(
                doc([validBlock(id, kind, "", codeInfo: kind == .code ? "swift" : nil)]),
                caret(id, 0),
                .enter,
                ids: [next]
            )
            if [.heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .link].contains(kind) {
                #expect(empty == .init(
                    document: doc([block(id, .paragraph, "")]),
                    selection: caret(id, 0),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.enter)
                ), Comment(rawValue: "empty kind=\(kind)"))
            } else if kind == .paragraph {
                #expect(empty == .init(
                    document: doc([
                        block(id, .paragraph, ""),
                        DocumentBlock(id: next, kind: .paragraph, inlineContent: .init(spans: []), taskState: nil, indentLevel: 0)
                    ]),
                    selection: caret(next, 0),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.enter)
                ))
            } else if kind == .code {
                #expect(empty == .init(
                    document: doc([block(id, .code, "", codeInfo: "swift"), block(next, .code, "", codeInfo: "swift")]),
                    selection: caret(next, 0),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.enter)
                ))
            } else {
                Issue.record("unexpected empty kind \(kind)")
            }
        }
    }

    @Test func enterWithNonemptySelectionUsesOneAtomicFullDeletionFallbackForEveryTextKind() throws {
        let fallback = blockID(252), next = blockID(253)
        for kind in allBlockKinds where kind != .divider {
            let id = blockID(251)
            let document = doc([validBlock(id, kind, "甲", codeInfo: kind == .code ? "swift" : nil)])
            let result = try reduce(document, textSelection(id, 0, id, 1), .enter, ids: [fallback, next])
            #expect(result == .init(
                document: doc([
                    block(fallback, .paragraph, ""),
                    DocumentBlock(id: next, kind: .paragraph, inlineContent: .init(spans: []), taskState: nil, indentLevel: 0)
                ]),
                selection: caret(next, 0),
                mutation: .document,
                effect: .handled,
                undo: .atomic(.enter)
            ), Comment(rawValue: "kind=\(kind)"))
        }
    }

    @Test func softBreakAndBackspaceCoverEveryKindAndEmptyShape() throws {
        for kind in allBlockKinds {
            let id = blockID(254)
            let emptyDocument = doc([validBlock(id, kind, "", codeInfo: kind == .code ? "swift" : nil)])
            let emptyBackspace = try reduce(emptyDocument, caret(id, 0), .backspace)
            if kind == .paragraph {
                #expect(emptyBackspace.mutation == .none(.documentBoundary))
            } else {
                #expect(emptyBackspace.document.blocks[0].kind == .paragraph, Comment(rawValue: "empty kind=\(kind)"))
                #expect(emptyBackspace.document.blocks[0].id == id)
            }

            let soft = try reduce(emptyDocument, caret(id, 0), .softBreak)
            if kind == .divider {
                #expect(soft.mutation == .none(.unsupportedBlockKind))
                continue
            }
            #expect(text(soft.document.blocks[0]) == "\n", Comment(rawValue: "soft kind=\(kind)"))

            let nonempty = doc([validBlock(id, kind, "甲乙", codeInfo: kind == .code ? "swift" : nil)])
            let backspace = try reduce(nonempty, caret(id, 2), .backspace)
            #expect(text(backspace.document.blocks[0]) == "甲", Comment(rawValue: "backspace kind=\(kind)"))
        }
    }

    @Test func codeSoftBreakAndDividerNoChangeAreExplicit() throws {
        let code = blockID(20)
        let codeDoc = doc([block(code, .code, "print(1)", codeInfo: "swift")])
        let soft = try reduce(codeDoc, caret(code, 5), .softBreak)
        #expect(text(soft.document.blocks[0]) == "print\n(1)")
        #expect(soft.document.blocks[0].codeInfoString == "swift")
        #expect(soft.undo == .atomic(.softBreak))

        let divider = blockID(21)
        let dividerDoc = doc([block(divider, .divider, "")])
        let unchanged = try reduce(dividerDoc, caret(divider, 0), .softBreak)
        #expect(unchanged.mutation == .none(.unsupportedBlockKind))
        #expect(unchanged.effect == .handled)
        #expect(unchanged.undo == .none)
    }

    @Test func crossBlockForwardAndReverseDeleteAreEquivalent() throws {
        let a = blockID(30), b = blockID(31), c = blockID(32)
        let document = doc([block(a, .paragraph, "甲乙"), block(b, .quote, "中"), block(c, .paragraph, "丙丁")])
        let forward = textSelection(a, 1, c, 1)
        let reverse = textSelection(c, 1, a, 1)
        let first = try reduce(document, forward, .deleteSelection)
        let second = try reduce(document, reverse, .deleteSelection)
        #expect(first == second)
        #expect(first.document.blocks.map(text) == ["甲丁"])
        #expect(first.document.blocks[0].id == a)
        #expect(first.selection == caret(a, 1, attributes: attributesAt(first.document, a, 1)))
        #expect(first.undo == .atomic(.deletion))
    }

    @Test func fullBlockDeletionConsumesExactlyOneFallbackIDAndIncludesDescendants() throws {
        let a = blockID(40), child = blockID(41), fallback = blockID(42)
        let document = doc([
            block(a, .bullet, "root", indent: 0),
            block(child, .task, "child", indent: 1)
        ])
        let selection = BlockEditorSelection.blocks(anchor: a, focus: a)
        let result = try reduce(document, selection, .deleteSelection, ids: [fallback])
        #expect(result.document == doc([block(fallback, .paragraph, "")]))
        #expect(result.selection == caret(fallback, 0))
        #expect(result.undo == .atomic(.deletion))
    }

    @Test func fullTextDeletionAlsoConsumesExactlyOneFallbackID() throws {
        let a = blockID(43), b = blockID(44), fallback = blockID(45)
        let document = doc([block(a, .heading1, "甲"), block(b, .quote, "乙")])
        let result = try reduce(document, textSelection(a, 0, b, 1), .deleteSelection, ids: [fallback])
        #expect(result.document == doc([block(fallback, .paragraph, "")]))
        #expect(result.selection == caret(fallback, 0))
    }

    @Test func copyAndCutHaveExactClipboardAndUndoSemantics() throws {
        let a = blockID(50), b = blockID(51), fallback = blockID(52)
        let document = doc([block(a, .paragraph, "甲"), block(b, .quote, "乙")])
        let selection = BlockEditorSelection.blocks(anchor: b, focus: a)
        let copied = try reduce(document, selection, .copySelection)
        #expect(copied.document == document)
        #expect(copied.mutation == .none(.samePosition))
        #expect(copied.effect == .writeClipboard(.init(
            plainText: "甲\n乙",
            richBlocks: [.init(kind: .paragraph, inlineContent: .plain("甲"), indentLevel: 0, codeInfoString: nil),
                         .init(kind: .quote, inlineContent: .plain("乙"), indentLevel: 0, codeInfoString: nil)]
        )))
        #expect(copied.undo == .none)

        let cut = try reduce(document, selection, .cutSelection, ids: [fallback])
        #expect(cut.document.blocks == [block(fallback, .paragraph, "")])
        #expect(cut.effect == copied.effect)
        #expect(cut.undo == .atomic(.cut))
    }

    @Test func sameBlockPartialCutAndPasteReturnsInlineWithoutCreatingANewParagraph() throws {
        let id = blockID(53)
        let original = doc([block(id, .paragraph, "Cut paste should stay safe")])
        let cut = try reduce(
            original,
            textSelection(id, 17, id, 26),
            .cutSelection
        )
        guard case let .writeClipboard(clipboard) = cut.effect else {
            Issue.record("cut must publish its exact clipboard payload")
            return
        }

        let pasted = try reduce(
            cut.document,
            cut.selection,
            .replaceSelection(.inlineContent(
                try #require(clipboard.inlineContent),
                fallbackPlainText: clipboard.plainText
            ))
        )

        #expect(pasted.document == original)
        #expect(pasted.document.blocks.count == 1)
        #expect(pasted.selection == caret(id, 26, attributes: attributesAt(pasted.document, id, 26)))
        #expect(pasted.undo == .atomic(.paste))
    }

    @Test func collapsedCopyAndEmptyPasteAreTypedNoChanges() throws {
        let id = blockID(60)
        let document = doc([block(id, .paragraph, "甲")])
        for command in [BlockInputCommand.copySelection, .replaceSelection(.plainText(""))] {
            let result = try reduce(document, caret(id, 0), command)
            #expect(result.document == document)
            #expect(result.mutation == .none(.emptySelection))
            #expect(result.effect == .handled)
            #expect(result.undo == .none)
        }
    }

    @Test func plainPasteNormalizesPhysicalLinesAndPreservesTrailingEmpties() throws {
        let id = blockID(70), n1 = blockID(71), n2 = blockID(72), n3 = blockID(73)
        let document = doc([block(id, .paragraph, "甲丁")])
        let result = try reduce(
            document,
            textSelection(id, 1, id, 1),
            .replaceSelection(.plainText("乙\r\n\r丙\n")),
            ids: [n1, n2, n3]
        )
        #expect(result.document.blocks.map(text) == ["甲乙", "", "丙", "丁"])
        #expect(result.document.blocks.map(\.id) == [id, n1, n2, n3])
        #expect(result.selection == caret(n3, 0, attributes: attributesAt(result.document, n3, 0)))
        #expect(result.undo == .atomic(.paste))
    }

    @Test func richPasteFallsBackAtomicallyBeforeConsumingIDs() throws {
        let id = blockID(80), next = blockID(81)
        let invalid = BlockPasteBlock(
            kind: .link,
            inlineContent: .plain("bad"),
            indentLevel: 0,
            codeInfoString: nil
        )
        let result = try reduce(
            doc([block(id, .paragraph, "甲")]),
            caret(id, 1),
            .replaceSelection(.richText(blocks: [invalid], fallbackPlainText: "\n乙")),
            ids: [next]
        )
        #expect(result.document.blocks.map(text) == ["甲", "乙"])
        #expect(result.document.blocks.map(\.id) == [id, next])
    }

    @Test func validatorRejectedRichCandidateFallsBackBeforeConsumingAnyID() throws {
        let id = blockID(82), fallbackID = blockID(83)
        let payload = BlockPastePayload.richText(blocks: [
            .init(kind: .bullet, inlineContent: .plain("orphan"), indentLevel: 1, codeInfoString: nil)
        ], fallbackPlainText: "\n原样")
        let result = try reduce(
            doc([block(id, .paragraph, "前缀")]),
            caret(id, 2),
            .replaceSelection(payload),
            ids: [fallbackID]
        )

        #expect(result.document == doc([
            block(id, .paragraph, "前缀"),
            block(fallbackID, .paragraph, "原样")
        ]))
        #expect(result.selection == caret(fallbackID, 2, attributes: attributesAt(result.document, fallbackID, 2)))
        #expect(result.undo == .atomic(.paste))
    }

    @Test func richSameBlockReplacementOwnsIDsAndTaskCompletionDeterministically() throws {
        let id = blockID(90), pasted = blockID(91), suffix = blockID(92)
        let completed = Date(timeIntervalSince1970: 10)
        let document = doc([block(id, .task, "甲乙丙", completed: completed)])
        let payload = BlockPastePayload.richText(blocks: [
            .init(kind: .task, inlineContent: .plain("中"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "中")
        let result = try reduce(document, textSelection(id, 1, id, 2), .replaceSelection(payload), ids: [pasted, suffix])
        #expect(result.document.blocks.map(\.id) == [id, pasted, suffix])
        #expect(result.document.blocks.map(text) == ["甲", "中", "丙"])
        #expect(result.document.blocks[0].taskState?.completedAt == completed)
        #expect(result.document.blocks[1].taskState?.completedAt == nil)
        #expect(result.document.blocks[2].taskState?.completedAt == nil)
        #expect(result.undo == .atomic(.paste))
    }

    @Test func richOffsetZeroReplacementLeavesOriginalCompletedTaskIDOnSoleSuffix() throws {
        let id = blockID(93), pastedID = blockID(94)
        let completed = Date(timeIntervalSince1970: 11)
        let document = doc([block(id, .task, "甲乙", completed: completed)])
        let payload = BlockPastePayload.richText(blocks: [
            .init(kind: .paragraph, inlineContent: .plain("新"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "新")
        let result = try reduce(document, textSelection(id, 0, id, 1), .replaceSelection(payload), ids: [pastedID])
        #expect(result.document.blocks.map(\.id) == [pastedID, id])
        #expect(result.document.blocks.map(text) == ["新", "乙"])
        #expect(result.document.blocks[1].kind == .task)
        #expect(result.document.blocks[1].taskState?.completedAt == completed)
    }

    @Test func richWholeBlockReplacementReusesOriginalIDForFirstPaste() throws {
        let id = blockID(95), second = blockID(96)
        let payload = BlockPastePayload.richText(blocks: [
            .init(kind: .quote, inlineContent: .plain("甲"), indentLevel: 0, codeInfoString: nil),
            .init(kind: .paragraph, inlineContent: .plain("乙"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "甲\n乙")
        let result = try reduce(doc([block(id, .paragraph, "旧")]), textSelection(id, 0, id, 1), .replaceSelection(payload), ids: [second])
        #expect(result.document.blocks.map(\.id) == [id, second])
        #expect(result.document.blocks.map(\.kind) == [.quote, .paragraph])
    }

    @Test func pasteParserValidatesRichPayloadByFirstIndexedError() throws {
        let valid = BlockPasteBlock(kind: .paragraph, inlineContent: .plain("ok"), indentLevel: 0, codeInfoString: nil)
        let invalid = BlockPasteBlock(kind: .quote, inlineContent: .plain("bad"), indentLevel: 2, codeInfoString: nil)
        #expect(throws: BlockPasteParserError.invalidIndent(index: 1)) {
            try BlockPasteParser.parse(.richText(blocks: [valid, invalid], fallbackPlainText: "fallback"))
        }
        #expect(try BlockPasteParser.parse(.plainText("a\r\nb\r")) == .plainLines(["a", "b", ""]))
    }

    @Test func pasteParserAllowsCanonicalTaskCompletionDescriptionAndRejectsOthers() throws {
        let task = BlockPasteBlock(
            kind: .task,
            inlineContent: .plain("给物业打电话"),
            indentLevel: 0,
            codeInfoString: nil,
            completionDescription: "拿到明确上门时间"
        )
        let parsed = try BlockPasteParser.parse(
            .richText(blocks: [task], fallbackPlainText: "给物业打电话")
        )
        guard case let .richBlocks(blocks) = parsed else {
            Issue.record("canonical task description must parse as rich blocks")
            return
        }
        #expect(blocks[0].completionDescription == "拿到明确上门时间")

        let padded = BlockPasteBlock(
            kind: .task,
            inlineContent: .plain("给物业打电话"),
            indentLevel: 0,
            codeInfoString: nil,
            completionDescription: "  拿到明确上门时间  "
        )
        #expect(throws: BlockPasteParserError.invalidBlock(index: 0)) {
            try BlockPasteParser.parse(.richText(blocks: [padded], fallbackPlainText: "给物业打电话"))
        }

        let paragraph = BlockPasteBlock(
            kind: .paragraph,
            inlineContent: .plain("正文"),
            indentLevel: 0,
            codeInfoString: nil,
            completionDescription: "不该出现"
        )
        #expect(throws: BlockPasteParserError.invalidBlock(index: 0)) {
            try BlockPasteParser.parse(.richText(blocks: [paragraph], fallbackPlainText: "正文"))
        }
    }

    @Test func markdownAndSlashConversionsAreExplicitAndPreserveID() throws {
        let id = blockID(100)
        let heading = try reduce(doc([block(id, .paragraph, "## 标题")]), caret(id, 3), .applyMarkdownShortcut)
        #expect(heading.document.blocks[0].id == id)
        #expect(heading.document.blocks[0].kind == .heading2)
        #expect(text(heading.document.blocks[0]) == "标题")

        let code = try reduce(doc([block(id, .paragraph, "```swift ")]), caret(id, 9), .applyMarkdownShortcut)
        #expect(code.document.blocks[0].kind == .code)
        #expect(code.document.blocks[0].codeInfoString == "swift")
        #expect(text(code.document.blocks[0]) == "")

        let slash = try reduce(doc([block(id, .paragraph, "/todo")]), caret(id, 5), .applySlashConversion(.task))
        #expect(slash.document.blocks[0].id == id)
        #expect(slash.document.blocks[0].kind == .task)
        #expect(text(slash.document.blocks[0]) == "")
    }

    @Test func compositionDefersEveryStructuralCommandWithoutMutation() throws {
        let id = blockID(110)
        let document = doc([block(id, .paragraph, "甲")])
        let commands: [BlockInputCommand] = [
            .insertText("乙"), .enter, .softBreak, .backspace,
            .moveHorizontal(.forward, extending: false),
            .moveVertical(.down, extending: false),
            .applyMarkdownShortcut, .applySlashConversion(.heading1)
        ]
        for command in commands {
            let result = try reduce(document, caret(id, 1), command, composing: true, ids: [blockID(111)])
            #expect(result.document == document)
            #expect(result.selection == caret(id, 1))
            #expect(result.mutation == .none(.composingText))
            #expect(result.effect == .deferToTextSystem)
            #expect(result.undo == .none)
        }
    }

    @Test func linkValidationIsAtomicAndLinkBlockDowngradesWhenLastURLIsRemoved() throws {
        let id = blockID(120)
        let url = URL(string: "https://example.com/a")!
        let document = doc([DocumentBlock(id: id, kind: .link, inlineContent: .init(spans: [
            .init(text: "链接", linkURL: url)
        ]), taskState: nil, indentLevel: 0)])
        #expect(throws: BlockInputError.invalidLink) {
            try reduce(document, textSelection(id, 0, id, 2), .setLink(URL(string: "mailto:test@example.com")!))
        }
        let removed = try reduce(document, textSelection(id, 0, id, 2), .setLink(nil))
        #expect(removed.document.blocks[0].kind == .paragraph)
        #expect(text(removed.document.blocks[0]) == "链接")
        #expect(removed.undo == .atomic(.link))
    }

    @Test func percentEncodedControlsRejectReducerParserAndRichPasteBeforeAnyIDIsConsumed() throws {
        let id = blockID(122), next = blockID(123)
        let document = doc([block(id, .paragraph, "甲乙")])
        let selection = textSelection(id, 1, id, 1)
        let controls = [
            URL(string: "https://example.com/%01")!,
            URL(string: "https://example.com/%00%FF")!
        ]

        for url in controls {
            #expect(throws: BlockInputError.invalidLink) {
                try reduce(document, selection, .setLink(url))
            }

            let malformedRich = BlockPastePayload.richText(blocks: [
                .init(
                    kind: .paragraph,
                    inlineContent: .init(spans: [.init(text: "坏", linkURL: url)]),
                    indentLevel: 0,
                    codeInfoString: nil
                )
            ], fallbackPlainText: "丙\n丁")
            #expect(throws: BlockPasteParserError.invalidLink(index: 0)) {
                try BlockPasteParser.parse(malformedRich)
            }

            let pasted = try reduce(document, selection, .replaceSelection(malformedRich), ids: [next])
            #expect(pasted == .init(
                document: doc([
                    DocumentBlock(
                        id: id,
                        kind: .paragraph,
                        inlineContent: .init(spans: [.init(text: "甲"), .init(text: "丙")]),
                        taskState: nil,
                        indentLevel: 0
                    ),
                    DocumentBlock(
                        id: next,
                        kind: .paragraph,
                        inlineContent: .init(spans: [.init(text: "丁"), .init(text: "乙")]),
                        taskState: nil,
                        indentLevel: 0
                    )
                ]),
                selection: caret(next, 1),
                mutation: .document,
                effect: .handled,
                undo: .atomic(.paste)
            ))
        }
    }

    @Test func collapsedFormattingChangesOnlyTypingAttributes() throws {
        let id = blockID(130)
        let document = doc([block(id, .paragraph, "甲")])
        let result = try reduce(document, caret(id, 1), .toggleInlineMark(.bold))
        #expect(result.document == document)
        #expect(result.mutation == .selectionOnly)
        #expect(result.selection == caret(id, 1, attributes: .init(marks: [.bold], linkURL: nil)))
        #expect(result.undo == .none)
    }

    @Test func collapsedFormattingIsRejectedAtomicallyForCodeAndDivider() throws {
        let url = URL(string: "https://example.com/rejected")!
        for (kind, value) in [(BlockKind.code, "code"), (.divider, "")] {
            let id = blockID(131)
            let document = doc([validBlock(id, kind, value)])
            let selection = caret(id, 0)
            for command in [BlockInputCommand.toggleInlineMark(.bold), .setLink(url), .setLink(nil)] {
                let result = try reduce(document, selection, command)
                #expect(result == .init(
                    document: document,
                    selection: selection,
                    mutation: .none(.unsupportedBlockKind),
                    effect: .handled,
                    undo: .none
                ), Comment(rawValue: "kind=\(kind) command=\(command)"))
            }
        }
    }

    @Test func horizontalMovementCollapsesRangesAndClearsPreferredColumn() throws {
        let a = blockID(140), b = blockID(141)
        let document = doc([block(a, .paragraph, "甲"), block(b, .paragraph, "乙")])
        let reverse = BlockEditorSelection.text(
            anchor: .init(blockID: b, graphemeOffset: 1),
            focus: .init(blockID: a, graphemeOffset: 0),
            preferredColumn: 7,
            typingAttributes: .init(marks: [.bold], linkURL: nil)
        )
        let backward = try reduce(document, reverse, .moveHorizontal(.backward, extending: false))
        #expect(backward.selection == caret(a, 0, attributes: attributesAt(document, a, 0)))
        let forward = try reduce(document, reverse, .moveHorizontal(.forward, extending: false))
        #expect(forward.selection == caret(b, 1, attributes: attributesAt(document, b, 1)))
        #expect(forward.mutation == .selectionOnly)
        #expect(forward.undo == .none)
    }

    @Test func movementExtensionBoundsAndAffinityReturnExactResults() throws {
        let a = blockID(142), b = blockID(143)
        let document = doc([
            DocumentBlock(
                id: a,
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "甲", marks: [.bold]),
                    .init(text: "乙", marks: [.italic])
                ]),
                taskState: nil,
                indentLevel: 0
            ),
            block(b, .paragraph, "丙")
        ])
        let start = caret(a, 0)
        let first = try reduce(document, start, .moveHorizontal(.forward, extending: true))
        #expect(first == .init(
            document: document,
            selection: .text(
                anchor: .init(blockID: a, graphemeOffset: 0),
                focus: .init(blockID: a, graphemeOffset: 1),
                preferredColumn: nil,
                typingAttributes: .init(marks: [.bold], linkURL: nil)
            ),
            mutation: .selectionOnly,
            effect: .handled,
            undo: .none
        ))
        let second = try reduce(document, first.selection, .moveHorizontal(.forward, extending: true))
        #expect(second.selection == .text(
            anchor: .init(blockID: a, graphemeOffset: 0),
            focus: .init(blockID: a, graphemeOffset: 2),
            preferredColumn: nil,
            typingAttributes: .init(marks: [.italic], linkURL: nil)
        ))
        let across = try reduce(document, caret(a, 2), .moveHorizontal(.forward, extending: false))
        #expect(across.selection == caret(b, 0, attributes: attributesAt(document, b, 0)))

        let leftBoundary = try reduce(document, start, .moveHorizontal(.backward, extending: false))
        #expect(leftBoundary == .init(
            document: document,
            selection: start,
            mutation: .none(.documentBoundary),
            effect: .handled,
            undo: .none
        ))
        let end = caret(b, 1)
        let rightBoundary = try reduce(document, end, .moveHorizontal(.forward, extending: false))
        #expect(rightBoundary == .init(
            document: document,
            selection: end,
            mutation: .none(.documentBoundary),
            effect: .handled,
            undo: .none
        ))
    }

    @Test func verticalMovementKeepsOriginalPreferredColumnAcrossShortLine() throws {
        let id = blockID(150)
        let document = doc([block(id, .paragraph, "1234\n甲\nabcde")])
        let down = try reduce(document, caret(id, 4), .moveVertical(.down, extending: false))
        #expect(down.selection == .text(
            anchor: .init(blockID: id, graphemeOffset: 6),
            focus: .init(blockID: id, graphemeOffset: 6),
            preferredColumn: 4,
            typingAttributes: attributesAt(document, id, 6)
        ))
        let again = try reduce(document, down.selection, .moveVertical(.down, extending: false))
        #expect(again.selection == .text(
            anchor: .init(blockID: id, graphemeOffset: 11),
            focus: .init(blockID: id, graphemeOffset: 11),
            preferredColumn: 4,
            typingAttributes: attributesAt(document, id, 11)
        ))
    }

    @Test func listIndentMovesRootAndDescendantsAndRequiresParent() throws {
        let parent = blockID(160), root = blockID(161), child = blockID(162)
        let document = doc([
            block(parent, .ordered, "p", indent: 0),
            block(root, .bullet, "r", indent: 0),
            block(child, .task, "c", indent: 1)
        ])
        let result = try reduce(document, BlockEditorSelection.blocks(anchor: root, focus: root), .indent)
        #expect(result.document.blocks.map(\.indentLevel) == [0, 1, 2])
        #expect(result.undo == .atomic(.indentation))

        let noParent = doc([block(root, .bullet, "r", indent: 0)])
        let unchanged = try reduce(noParent, caret(root, 0), .indent)
        #expect(unchanged.mutation == .none(.missingListParent))
    }

    @Test func listDepthAndClosureMatrixIsAtomicAtEveryBoundary() throws {
        let level0 = blockID(163), level1 = blockID(164), peerLevel2 = blockID(167)
        let level2 = blockID(165), level3 = blockID(166)
        let document = doc([
            block(level0, .bullet, "0", indent: 0),
            block(level1, .ordered, "1", indent: 1),
            block(peerLevel2, .bullet, "peer", indent: 2),
            block(level2, .task, "2", indent: 2),
            block(level3, .bullet, "3", indent: 3)
        ])
        let level2Selection = BlockEditorSelection.blocks(anchor: level2, focus: level2)
        let blocked = try reduce(document, level2Selection, .indent)
        #expect(blocked == .init(
            document: document,
            selection: level2Selection,
            mutation: .none(.indentationLimit),
            effect: .handled,
            undo: .none
        ))

        let level1Selection = BlockEditorSelection.blocks(anchor: level1, focus: level1)
        let outdented = try reduce(document, level1Selection, .outdent)
        #expect(outdented == .init(
            document: doc([
                block(level0, .bullet, "0", indent: 0),
                block(level1, .ordered, "1", indent: 0),
                block(peerLevel2, .bullet, "peer", indent: 1),
                block(level2, .task, "2", indent: 1),
                block(level3, .bullet, "3", indent: 2)
            ]),
            selection: level1Selection,
            mutation: .document,
            effect: .handled,
            undo: .atomic(.indentation)
        ))

        let rootSelection = BlockEditorSelection.blocks(anchor: level0, focus: level0)
        let rootOutdent = try reduce(document, rootSelection, .outdent)
        #expect(rootOutdent == .init(
            document: document,
            selection: rootSelection,
            mutation: .none(.indentationLimit),
            effect: .handled,
            undo: .none
        ))
    }

    @Test func codeIndentAndOutdentOperateOnSelectedLogicalLines() throws {
        let id = blockID(170)
        let document = doc([block(id, .code, "a\n  b\nc")])
        let indented = try reduce(document, textSelection(id, 0, id, 5), .indent)
        #expect(text(indented.document.blocks[0]) == "    a\n      b\nc")
        let outdented = try reduce(indented.document, indented.selection, .outdent)
        #expect(text(outdented.document.blocks[0]) == "a\n  b\nc")
    }

    @Test func codeOutdentAtLaterLineStartKeepsCaretAtThatLineStart() throws {
        let id = blockID(171)
        let document = doc([block(id, .code, "a\n    b")])
        let result = try reduce(document, caret(id, 2), .outdent)
        #expect(result.document == doc([block(id, .code, "a\nb")]))
        #expect(result.selection == caret(id, 2))
        #expect(result.undo == .atomic(.indentation))
    }

    @Test func stableIDDragMovesRootClosuresAndDeduplicatesDescendants() throws {
        let a = blockID(180), child = blockID(181), b = blockID(182), c = blockID(183)
        let document = doc([
            block(a, .bullet, "a", indent: 0),
            block(child, .task, "child", indent: 1),
            block(b, .paragraph, "b"),
            block(c, .paragraph, "c")
        ])
        let result = try reduce(document, caret(b, 0), .moveBlockRoots([child, a], before: nil))
        #expect(result.document.blocks.map(\.id) == [b, c, a, child])
        #expect(result.undo == .atomic(.drag))

        #expect(throws: BlockInputError.invalidMove) {
            try reduce(document, caret(b, 0), .moveBlockRoots([a, a], before: nil))
        }
        let same = try reduce(document, caret(b, 0), .moveBlockRoots([a], before: b))
        #expect(same.mutation == .none(.samePosition))
        #expect(same.undo == .none)

        let targetInsideClosure = try reduce(document, caret(b, 0), .moveBlockRoots([a], before: child))
        #expect(targetInsideClosure == .init(
            document: document,
            selection: caret(b, 0),
            mutation: .none(.samePosition),
            effect: .handled,
            undo: .none
        ))
        #expect(throws: BlockInputError.invalidMove) {
            try reduce(document, caret(b, 0), .moveBlockRoots([blockID(999)], before: nil))
        }
        #expect(throws: BlockInputError.invalidMove) {
            try reduce(document, caret(b, 0), .moveBlockRoots([a], before: blockID(998)))
        }
        #expect(throws: BlockInputError.invalidMove) {
            try reduce(document, caret(b, 0), .moveBlockRoots([child], before: nil))
        }
    }

    @Test func blockSelectionFromRootToFirstChildDeletesTheRootsEntireClosure() throws {
        let root = blockID(184), firstChild = blockID(185), grandchild = blockID(186)
        let laterChild = blockID(187), following = blockID(188)
        let document = doc([
            block(root, .bullet, "root", indent: 0),
            block(firstChild, .bullet, "first", indent: 1),
            block(grandchild, .task, "grandchild", indent: 2),
            block(laterChild, .ordered, "later", indent: 1),
            block(following, .paragraph, "following")
        ])
        let selection = BlockEditorSelection.blocks(anchor: root, focus: firstChild)
        let result = try reduce(document, selection, .deleteSelection)
        #expect(result.document == doc([block(following, .paragraph, "following")]))
        #expect(result.selection == caret(following, 0))
        #expect(result.undo == .atomic(.deletion))
    }

    @Test func blockCopyIsInclusiveWhileCutUsesDeduplicatedClosureUnion() throws {
        let root = blockID(194), firstChild = blockID(195), grandchild = blockID(196)
        let laterChild = blockID(197), laterGrandchild = blockID(198), divider = blockID(199)
        let document = doc([
            block(root, .bullet, "root", indent: 0),
            block(firstChild, .ordered, "first", indent: 1),
            block(grandchild, .task, "grand", indent: 2),
            block(laterChild, .bullet, "later", indent: 1),
            block(laterGrandchild, .ordered, "later-grand", indent: 2),
            block(divider, .divider, "")
        ])
        let reverseRootToChild = BlockEditorSelection.blocks(anchor: firstChild, focus: root)
        let copied = try reduce(document, reverseRootToChild, .copySelection)
        #expect(copied == .init(
            document: document,
            selection: reverseRootToChild,
            mutation: .none(.samePosition),
            effect: .writeClipboard(.init(
                plainText: "root\nfirst",
                richBlocks: [
                    .init(kind: .bullet, inlineContent: .plain("root"), indentLevel: 0, codeInfoString: nil),
                    .init(kind: .ordered, inlineContent: .plain("first"), indentLevel: 1, codeInfoString: nil)
                ]
            )),
            undo: .none
        ))

        let cut = try reduce(document, reverseRootToChild, .cutSelection)
        #expect(cut.document == doc([block(divider, .divider, "")]))
        #expect(cut.effect == .writeClipboard(.init(
            plainText: "root\nfirst\ngrand\nlater\nlater-grand",
            richBlocks: [
                .init(kind: .bullet, inlineContent: .plain("root"), indentLevel: 0, codeInfoString: nil),
                .init(kind: .ordered, inlineContent: .plain("first"), indentLevel: 1, codeInfoString: nil),
                .init(kind: .task, inlineContent: .plain("grand"), indentLevel: 2, codeInfoString: nil),
                .init(kind: .bullet, inlineContent: .plain("later"), indentLevel: 1, codeInfoString: nil),
                .init(kind: .ordered, inlineContent: .plain("later-grand"), indentLevel: 2, codeInfoString: nil)
            ]
        )))
        #expect(cut.selection == caret(divider, 0))
        #expect(cut.mutation == .document)
        #expect(cut.undo == .atomic(.cut))

        let multiRoot = BlockEditorSelection.blocks(anchor: firstChild, focus: laterChild)
        let multiCut = try reduce(document, multiRoot, .cutSelection)
        #expect(multiCut.document == doc([
            block(root, .bullet, "root", indent: 0),
            block(divider, .divider, "")
        ]))
        #expect(multiCut.effect == .writeClipboard(.init(
            plainText: "first\ngrand\nlater\nlater-grand",
            richBlocks: [
                .init(kind: .ordered, inlineContent: .plain("first"), indentLevel: 1, codeInfoString: nil),
                .init(kind: .task, inlineContent: .plain("grand"), indentLevel: 2, codeInfoString: nil),
                .init(kind: .bullet, inlineContent: .plain("later"), indentLevel: 1, codeInfoString: nil),
                .init(kind: .ordered, inlineContent: .plain("later-grand"), indentLevel: 2, codeInfoString: nil)
            ]
        )))

        let dividerSelection = BlockEditorSelection.blocks(anchor: divider, focus: divider)
        let dividerCopy = try reduce(document, dividerSelection, .copySelection)
        #expect(dividerCopy.effect == .writeClipboard(.init(
            plainText: "",
            richBlocks: [.init(kind: .divider, inlineContent: .plain(""), indentLevel: 0, codeInfoString: nil)]
        )))
    }

    @Test func emptyLinkEnterClearsZeroLengthURLMetadataWhenDowngrading() throws {
        let id = blockID(189)
        let document = doc([validBlock(id, .link, "")])
        let result = try reduce(document, caret(id, 0), .enter)
        #expect(result.document == doc([block(id, .paragraph, "")]))
        #expect(result.selection == caret(id, 0))
        #expect(result.undo == .atomic(.enter))
    }

    @Test(arguments: SoftBreakExactFixture.all)
    func softBreakEveryKindReturnsTheExactAtomicResult(_ fixture: SoftBreakExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, .softBreak) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: BackspaceExactFixture.all)
    func backspaceEveryKindReturnsTheExactBoundaryDeletionAndMergeResult(_ fixture: BackspaceExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, .backspace) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: MovementExactFixture.all)
    func movementBoundaryExtensionAndAffinityMatrixReturnsExactResults(_ fixture: MovementExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, fixture.command) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: CrossBlockUnicodeExactFixture.all)
    func crossBlockForwardAndReverseSelectionsPreserveEveryGrapheme(_ fixture: CrossBlockUnicodeExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, .deleteSelection) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: BlockSelectionErrorFixture.all)
    func blockSelectionsWithMissingStableIDsThrowExactErrors(_ fixture: BlockSelectionErrorFixture) {
        do {
            _ = try reduce(fixture.document, fixture.selection, .deleteSelection)
            Issue.record("expected \(fixture.expectedError): \(fixture.label)")
        } catch let error as BlockInputError {
            #expect(error == fixture.expectedError, Comment(rawValue: fixture.label))
        } catch {
            Issue.record("unexpected error \(error): \(fixture.label)")
        }
    }

    @Test(arguments: SpanBoundaryExactFixture.all)
    func zeroLengthAndAdjacentEqualSpansSurviveExactEdits(_ fixture: SpanBoundaryExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, fixture.command) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: IndentExactFixture.all)
    func multiRootListAndCodeEndpointIndentationReturnsExactResults(_ fixture: IndentExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, fixture.command) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: FormattingExactFixture.all)
    func inlineFormattingAdditionRemovalDirectionAndAtomicityReturnsExactResults(_ fixture: FormattingExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, fixture.command) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: InvalidLinkExactFixture.all)
    func invalidLinkShapesThrowBeforeAnyMutation(_ fixture: InvalidLinkExactFixture) {
        do {
            _ = try reduce(fixture.document, fixture.selection, .setLink(fixture.url))
            Issue.record("expected invalidLink: \(fixture.label)")
        } catch let error as BlockInputError {
            #expect(error == .invalidLink, Comment(rawValue: fixture.label))
        } catch {
            Issue.record("unexpected error \(error): \(fixture.label)")
        }
    }

    @Test(arguments: DestructiveBlockExactFixture.all)
    func destructiveBlockSelectionsUseTheExactClosureUnion(_ fixture: DestructiveBlockExactFixture) throws {
        #expect(
            try reduce(
                fixture.document,
                fixture.selection,
                fixture.command,
                ids: fixture.ids
            ) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: PasteMatrixExactFixture.all)
    func everySelectionShapeAndPastePayloadHasExactBoundaryAndIDOwnership(_ fixture: PasteMatrixExactFixture) throws {
        #expect(
            try reduce(
                fixture.document,
                fixture.selection,
                .replaceSelection(fixture.payload),
                ids: fixture.ids
            ) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: DragOrderingExactFixture.all)
    func multiRootDragNormalizesParameterOrderAndPreservesStableClosures(_ fixture: DragOrderingExactFixture) throws {
        #expect(
            try reduce(
                fixture.document,
                fixture.selection,
                .moveBlockRoots(fixture.roots, before: fixture.target)
            ) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test(arguments: ReductionOutcomeExactFixture.all)
    func successNoChangeAndErrorOutcomesAreMutuallyExclusive(_ fixture: ReductionOutcomeExactFixture) {
        do {
            let result = try reduce(
                fixture.document,
                fixture.selection,
                fixture.command,
                ids: fixture.ids
            )
            #expect(fixture.expected == .result(result), Comment(rawValue: fixture.label))
        } catch let error as BlockInputError {
            #expect(fixture.expected == .error(error), Comment(rawValue: fixture.label))
        } catch {
            Issue.record("unexpected error \(error): \(fixture.label)")
        }
    }

    @Test(arguments: MarkdownExactFixture.all)
    func everyMarkdownPrefixAndRejectionReturnsTheExactResult(_ fixture: MarkdownExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, .applyMarkdownShortcut) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test func insertingTextAndApplyingMarkdownIsOneExactReducerTransaction() throws {
        let id = blockID(470)
        let conversions: [(String, BlockKind, String?)] = [
            ("# ", .heading1, nil),
            ("## ", .heading2, nil),
            ("### ", .heading3, nil),
            ("- ", .bullet, nil),
            ("* ", .bullet, nil),
            ("1. ", .ordered, nil),
            ("[] ", .task, nil),
            ("[ ] ", .task, nil),
            ("> ", .quote, nil),
            ("``` ", .code, nil),
            ("```swift ", .code, "swift")
        ]
        for (prefix, kind, codeInfo) in conversions {
            let document = doc([block(id, .paragraph, "")])
            let result = try reduce(document, caret(id, 0), .insertTextApplyingMarkdownShortcut(prefix))
            let converted = DocumentBlock(
                id: id,
                kind: kind,
                inlineContent: .plain(""),
                taskState: kind == .task ? .init(completedAt: nil) : nil,
                indentLevel: 0,
                codeInfoString: codeInfo
            )
            #expect(result == .init(
                document: doc([converted]),
                selection: caret(id, 0),
                mutation: .document,
                effect: .handled,
                undo: .atomic(.conversion)
            ), Comment(rawValue: prefix.debugDescription))
        }

        let ordinaryCases: [(String, BlockDocument, BlockEditorSelection)] = [
            ("中文🙂", doc([block(id, .paragraph, "")]), caret(id, 0)),
            ("#", doc([block(id, .paragraph, "")]), caret(id, 0)),
            ("#### ", doc([block(id, .paragraph, "")]), caret(id, 0)),
            ("# ", doc([block(id, .paragraph, "x")]), caret(id, 1)),
            ("# ", doc([block(id, .heading1, "x")]), caret(id, 1)),
            ("# ", doc([block(id, .paragraph, "x")]), textSelection(id, 0, id, 1))
        ]
        let fallback = blockID(473)
        for (value, document, selection) in ordinaryCases {
            #expect(
                try reduce(document, selection, .insertTextApplyingMarkdownShortcut(value), ids: [fallback])
                    == reduce(document, selection, .insertText(value), ids: [fallback]),
                Comment(rawValue: value.debugDescription)
            )
        }

        let first = blockID(471), second = blockID(472)
        let crossDocument = doc([
            block(first, .paragraph, "甲乙"),
            block(second, .paragraph, "丙丁")
        ])
        let crossSelection = textSelection(first, 1, second, 1)
        #expect(
            try reduce(crossDocument, crossSelection, .insertTextApplyingMarkdownShortcut("# "))
                == reduce(crossDocument, crossSelection, .insertText("# "))
        )

        let composing = try reduce(
            doc([block(id, .paragraph, "")]), caret(id, 0),
            .insertTextApplyingMarkdownShortcut("# "), composing: true
        )
        #expect(composing == .init(
            document: doc([block(id, .paragraph, "")]),
            selection: caret(id, 0),
            mutation: .none(.composingText),
            effect: .deferToTextSystem,
            undo: .none
        ))
    }

    @Test func markdownPrefixReplacesEveryCompatibleRichTextBlockKind() throws {
        let id = blockID(476)
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sources: [(BlockKind, Int, Date?)] = [
            (.paragraph, 0, nil),
            (.heading1, 0, nil),
            (.heading2, 0, nil),
            (.heading3, 0, nil),
            (.bullet, 0, nil),
            (.ordered, 0, nil),
            (.task, 0, completedAt),
            (.quote, 0, nil)
        ]
        let conversions: [(String, BlockKind)] = [
            ("# ", .heading1),
            ("## ", .heading2),
            ("### ", .heading3),
            ("- ", .bullet),
            ("* ", .bullet),
            ("1. ", .ordered),
            ("[] ", .task),
            ("[ ] ", .task),
            ("> ", .quote),
            ("``` ", .code)
        ]

        for (sourceKind, sourceIndent, sourceCompletion) in sources {
            for (prefix, targetKind) in conversions {
                let document = doc([block(
                    id,
                    sourceKind,
                    prefix + "正文",
                    indent: sourceIndent,
                    completed: sourceCompletion
                )])
                let result = try reduce(document, caret(id, prefix.count), .applyMarkdownShortcut)
                let converted = result.document.blocks[0]

                #expect(converted.kind == targetKind, Comment(rawValue: "\(sourceKind) + \(prefix.debugDescription)"))
                #expect(text(converted) == "正文", Comment(rawValue: "\(sourceKind) + \(prefix.debugDescription)"))
                #expect(converted.indentLevel == ([BlockKind.bullet, .ordered, .task].contains(targetKind) ? sourceIndent : 0))
                #expect(converted.taskState?.completedAt == (sourceKind == .task && targetKind == .task ? completedAt : nil))
                #expect(result.selection == caret(id, 0))
                #expect(result.undo == .atomic(.conversion))
            }
        }
    }

    @Test func headingBulletHeadingJourneyConvertsAtTheSpaceKeystroke() throws {
        let first = blockID(477)
        let middle = blockID(478)
        let last = blockID(479)
        let document = doc([
            block(first, .heading1, "一、背景"),
            block(middle, .heading1, "- "),
            block(last, .heading1, "二、结论")
        ])

        let result = try reduce(document, caret(middle, 2), .applyMarkdownShortcut)

        #expect(result.document.blocks.map(\.kind) == [.heading1, .bullet, .heading1])
        #expect(result.document.blocks.map(text) == ["一、背景", "", "二、结论"])
        #expect(result.selection == caret(middle, 0))
        #expect(result.undo == .atomic(.conversion))
    }

    @Test func markdownPrefixRemainsLiteralInsideCodeAndStandaloneLinkBlocks() throws {
        let codeID = blockID(480)
        let linkID = blockID(481)
        let linked = InlineContent(spans: [.init(text: "- ", linkURL: exactLinkURL)])
        let code = doc([block(codeID, .code, "- ", codeInfo: "swift")])
        let link = doc([DocumentBlock(
            id: linkID,
            kind: .link,
            inlineContent: linked,
            taskState: nil,
            indentLevel: 0
        )])

        #expect(try reduce(code, caret(codeID, 2), .applyMarkdownShortcut) == exactNoChange(code, caret(codeID, 2), .samePosition))
        #expect(try reduce(link, caret(linkID, 2), .applyMarkdownShortcut) == exactNoChange(link, caret(linkID, 2), .samePosition))
    }

    @Test func compositeMarkdownConversionPreservesLeadingZeroLengthSpansAndAdjacentAttributesExactly() throws {
        let id = blockID(474)
        let zeroItalic = InlineSpan(text: "", marks: [.italic])
        let zeroCode = InlineSpan(text: "", marks: [.code], linkURL: exactLinkURL)
        let suffix: [InlineSpan] = [
            .init(text: "中", marks: [.bold]),
            .init(text: "文", marks: [.bold]),
            .init(text: "🙂", marks: [.italic])
        ]
        let original = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [zeroItalic, zeroCode] + suffix),
            taskState: nil,
            indentLevel: 0
        )])
        let conversions: [(String, BlockKind, String?)] = [
            ("# ", .heading1, nil),
            ("## ", .heading2, nil),
            ("### ", .heading3, nil),
            ("- ", .bullet, nil),
            ("* ", .bullet, nil),
            ("1. ", .ordered, nil),
            ("[] ", .task, nil),
            ("[ ] ", .task, nil),
            ("> ", .quote, nil),
            ("``` ", .code, nil),
            ("```swift ", .code, "swift")
        ]

        for (prefix, kind, codeInfo) in conversions {
            let expectedContent: InlineContent = kind == .code
                ? .plain("中文🙂")
                : .init(spans: [zeroItalic, zeroCode] + suffix)
            let expected = BlockInputResult(
                document: doc([DocumentBlock(
                    id: id,
                    kind: kind,
                    inlineContent: expectedContent,
                    taskState: kind == .task ? .init(completedAt: nil) : nil,
                    indentLevel: 0,
                    codeInfoString: codeInfo
                )]),
                selection: kind == .code
                    ? caret(id, 0)
                    : caret(id, 0, attributes: .init(marks: [.bold], linkURL: nil)),
                mutation: .document,
                effect: .handled,
                undo: .atomic(.conversion)
            )
            #expect(
                try reduce(original, caret(id, 0), .insertTextApplyingMarkdownShortcut(prefix)) == expected,
                Comment(rawValue: prefix.debugDescription)
            )
        }
    }

    @Test func completingMarkdownPrefixPreservesEveryEarlierZeroLengthSpanInOriginalOrder() throws {
        let id = blockID(475)
        let zeroItalic = InlineSpan(text: "", marks: [.italic])
        let zeroCode = InlineSpan(text: "", marks: [.code], linkURL: exactLinkURL)
        let suffix: [InlineSpan] = [
            .init(text: "中", marks: [.bold]),
            .init(text: "文", marks: [.bold]),
            .init(text: "🙂", marks: [.italic])
        ]
        let conversions: [(String, BlockKind, String?)] = [
            ("# ", .heading1, nil), ("## ", .heading2, nil), ("### ", .heading3, nil),
            ("- ", .bullet, nil), ("* ", .bullet, nil), ("1. ", .ordered, nil),
            ("[] ", .task, nil), ("[ ] ", .task, nil), ("> ", .quote, nil),
            ("``` ", .code, nil), ("```swift ", .code, "swift")
        ]

        for (prefix, kind, codeInfo) in conversions {
            let partial = String(prefix.dropLast())
            let original = doc([DocumentBlock(
                id: id,
                kind: .paragraph,
                inlineContent: .init(spans: [
                    zeroItalic,
                    .init(text: partial, marks: [.italic]),
                    zeroCode
                ] + suffix),
                taskState: nil,
                indentLevel: 0
            )])
            let expectedContent: InlineContent = kind == .code
                ? .plain("中文🙂")
                : .init(spans: [zeroItalic, zeroCode] + suffix)
            let expected = BlockInputResult(
                document: doc([DocumentBlock(
                    id: id,
                    kind: kind,
                    inlineContent: expectedContent,
                    taskState: kind == .task ? .init(completedAt: nil) : nil,
                    indentLevel: 0,
                    codeInfoString: codeInfo
                )]),
                selection: kind == .code
                    ? caret(id, 0)
                    : caret(id, 0, attributes: .init(marks: [.bold], linkURL: nil)),
                mutation: .document,
                effect: .handled,
                undo: .atomic(.conversion)
            )
            #expect(
                try reduce(
                    original,
                    caret(id, partial.count, attributes: .init(marks: [.italic], linkURL: nil)),
                    .insertTextApplyingMarkdownShortcut(String(prefix.suffix(1)))
                ) == expected,
                Comment(rawValue: prefix.debugDescription)
            )
        }
    }

    @Test(arguments: SlashExactFixture.all)
    func slashConversionAndInvalidSelectionShapesReturnExactResults(_ fixture: SlashExactFixture) throws {
        #expect(
            try reduce(fixture.document, fixture.selection, .applySlashConversion(fixture.kind)) == fixture.expected,
            Comment(rawValue: fixture.label)
        )
    }

    @Test func deterministicIDErrorsAreTypedAndCandidateValidationIsAtomic() throws {
        let id = blockID(190)
        let document = doc([block(id, .paragraph, "甲")])
        #expect(throws: BlockInputError.insufficientBlockIDs) {
            try reduce(document, caret(id, 1), .enter)
        }
        #expect(throws: BlockInputError.duplicateBlockID(id)) {
            try reduce(document, caret(id, 1), .enter, ids: [id])
        }
        let duplicate = blockID(191)
        #expect(throws: BlockInputError.duplicateBlockID(duplicate)) {
            try reduce(document, caret(id, 1), .replaceSelection(.plainText("a\nb\nc")), ids: [duplicate, duplicate])
        }
    }
}

struct UnicodeFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let text: String
    var count: Int { text.count }
    var testDescription: String { label }

    static let all: [UnicodeFixture] = [
        .init(label: "ASCII", text: "A"),
        .init(label: "Chinese", text: "中"),
        .init(label: "combining", text: "e\u{301}"),
        .init(label: "flag", text: "🇨🇳"),
        .init(label: "skin tone", text: "👍🏽"),
        .init(label: "ZWJ family", text: "👨‍👩‍👧‍👦")
    ]
}

struct EnterFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let ids: [BlockID]
    let expected: BlockDocument
    let expectedSelection: BlockEditorSelection
    var testDescription: String { label }

    static let all: [EnterFixture] = {
        let next = blockID(209)
        return [
            split("paragraph", .paragraph, "甲乙", 1, .paragraph, nil, next),
            split("heading", .heading2, "甲乙", 1, .paragraph, nil, next),
            split("bullet", .bullet, "甲乙", 1, .bullet, nil, next, indent: 0),
            split("ordered", .ordered, "甲乙", 1, .ordered, nil, next, indent: 0),
            split("task", .task, "甲乙", 1, .task, nil, next, indent: 0, completed: .distantPast),
            split("quote", .quote, "甲乙", 1, .quote, nil, next),
            split("code", .code, "甲乙", 1, .code, "swift", next),
            emptyExit("empty heading", .heading1),
            emptyExit("empty list", .bullet),
            emptyExit("empty task", .task),
            emptyExit("empty quote", .quote),
            dividerEnter(next)
        ]
    }()

    private static func split(
        _ label: String,
        _ leftKind: BlockKind,
        _ value: String,
        _ offset: Int,
        _ rightKind: BlockKind,
        _ info: String?,
        _ next: BlockID,
        indent: Int = 0,
        completed: Date? = nil
    ) -> EnterFixture {
        let id = blockID(200)
        let left = block(id, leftKind, "甲", indent: indent, completed: completed, codeInfo: info)
        let right = block(next, rightKind, "乙", indent: indent, codeInfo: info)
        return .init(label: label, document: doc([block(id, leftKind, value, indent: indent, completed: completed, codeInfo: info)]), selection: caret(id, offset), ids: [next], expected: doc([left, right]), expectedSelection: caret(next, 0))
    }

    private static func emptyExit(_ label: String, _ kind: BlockKind) -> EnterFixture {
        let id = blockID(220)
        return .init(label: label, document: doc([block(id, kind, "")]), selection: caret(id, 0), ids: [], expected: doc([block(id, .paragraph, "")]), expectedSelection: caret(id, 0))
    }

    private static func dividerEnter(_ next: BlockID) -> EnterFixture {
        let id = blockID(230)
        return .init(label: "divider", document: doc([block(id, .divider, "")]), selection: caret(id, 0), ids: [next], expected: doc([block(id, .divider, ""), block(next, .paragraph, "")]), expectedSelection: caret(next, 0))
    }
}

struct SoftBreakExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [SoftBreakExactFixture] = {
        let id = blockID(300)
        return allBlockKinds.flatMap { kind -> [SoftBreakExactFixture] in
            let original = validBlock(
                id,
                kind,
                kind == .divider ? "" : "甲乙",
                completed: kind == .task ? exactCompletedDate : nil,
                codeInfo: kind == .code ? "swift" : nil
            )
            let document = doc([original])
            if kind == .divider {
                let selection = caret(id, 0)
                return [.init(
                    label: "divider-unsupported",
                    document: document,
                    selection: selection,
                    expected: exactNoChange(document, selection, .unsupportedBlockKind)
                )]
            }
            let cases: [(String, BlockEditorSelection, Int, Int?)] = [
                ("start", caret(id, 0), 0, nil),
                ("middle", caret(id, 1), 1, nil),
                ("end", caret(id, 2), 2, nil),
                ("range", textSelection(id, 0, id, 1), 0, 1)
            ]
            return cases.map { name, selection, insertionOffset, deletedUpper in
                let expectedBlock = exactSoftBreakBlock(
                    id: id,
                    kind: kind,
                    insertionOffset: insertionOffset,
                    deletedUpper: deletedUpper
                )
                let expectedDocument = doc([expectedBlock])
                let position = BlockTextPosition(blockID: id, graphemeOffset: insertionOffset + 1)
                let expectedSelection = BlockEditorSelection.text(
                    anchor: position,
                    focus: position,
                    preferredColumn: nil,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
                return .init(
                    label: "\(kind)-\(name)",
                    document: document,
                    selection: selection,
                    expected: .init(
                        document: expectedDocument,
                        selection: expectedSelection,
                        mutation: .document,
                        effect: .handled,
                        undo: .atomic(.softBreak)
                    )
                )
            }
        }
    }()
}

struct BackspaceExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [BackspaceExactFixture] = {
        let id = blockID(310), previous = blockID(311), divider = blockID(312)
        return allBlockKinds.flatMap { kind -> [BackspaceExactFixture] in
            if kind == .divider {
                let document = doc([validBlock(id, .divider, "")])
                let selection = caret(id, 0)
                return [.init(
                    label: "divider-empty-exit",
                    document: document,
                    selection: selection,
                    expected: .init(
                        document: doc([block(id, .paragraph, "")]),
                        selection: caret(id, 0),
                        mutation: .document,
                        effect: .handled,
                        undo: .atomic(.backspace)
                    )
                )]
            }

            let current = validBlock(
                id,
                kind,
                "甲乙",
                completed: kind == .task ? exactCompletedDate : nil,
                codeInfo: kind == .code ? "swift" : nil
            )
            let single = doc([current])
            let start = caret(id, 0)
            let deletedBlock = exactBackspaceDeletedBlock(id: id, kind: kind)
            let deletedDocument = doc([deletedBlock])
            let deletedSelection = caret(
                id,
                0,
                attributes: kind == .link
                    ? .init(marks: [], linkURL: exactLinkURL)
                    : .init(marks: [], linkURL: nil)
            )
            let deleteResult = BlockInputResult(
                document: deletedDocument,
                selection: deletedSelection,
                mutation: .document,
                effect: .handled,
                undo: .atomic(.backspace)
            )

            let previousBlock = block(previous, .paragraph, "前")
            let merged = exactMergedBlock(previous: previous, current: current)
            let mergedDocument = doc([merged])
            let mergedResult = BlockInputResult(
                document: mergedDocument,
                selection: caret(previous, 1),
                mutation: .document,
                effect: .handled,
                undo: .atomic(.backspace)
            )
            let mergeDocument = doc([previousBlock, current])
            let dividerDocument = doc([previousBlock, block(divider, .divider, ""), current])

            return [
                .init(
                    label: "\(kind)-start",
                    document: single,
                    selection: start,
                    expected: exactNoChange(single, start, .documentBoundary)
                ),
                .init(
                    label: "\(kind)-middle",
                    document: single,
                    selection: caret(id, 1),
                    expected: deleteResult
                ),
                .init(
                    label: "\(kind)-range",
                    document: single,
                    selection: textSelection(id, 0, id, 1),
                    expected: deleteResult
                ),
                .init(
                    label: "\(kind)-merge",
                    document: mergeDocument,
                    selection: caret(id, 0),
                    expected: mergedResult
                ),
                .init(
                    label: "\(kind)-preceding-divider",
                    document: dividerDocument,
                    selection: caret(id, 0),
                    expected: mergedResult
                )
            ]
        }
    }()
}

struct MovementExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let command: BlockInputCommand
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [MovementExactFixture] = {
        let a = blockID(320), b = blockID(321), divider = blockID(322)
        let multiline = doc([block(a, .paragraph, "abc\nx")])
        let boldItalic = doc([
            block(a, .paragraph, "xx"),
            DocumentBlock(
                id: b,
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "甲", marks: [.bold]),
                    .init(text: "乙丙", marks: [.italic])
                ]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let linkDocument = doc([
            DocumentBlock(
                id: a,
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "甲", linkURL: exactLinkURL),
                    .init(text: "乙")
                ]),
                taskState: nil,
                indentLevel: 0
            ),
            block(b, .paragraph, "丙")
        ])

        func moved(
            _ document: BlockDocument,
            _ selection: BlockEditorSelection,
            _ command: BlockInputCommand,
            _ expectedSelection: BlockEditorSelection
        ) -> MovementExactFixture {
            .init(
                label: "\(command)-\(selection)",
                document: document,
                selection: selection,
                command: command,
                expected: .init(
                    document: document,
                    selection: expectedSelection,
                    mutation: .selectionOnly,
                    effect: .handled,
                    undo: .none
                )
            )
        }

        let secondLineStart = BlockEditorSelection.text(
            anchor: .init(blockID: a, graphemeOffset: 4),
            focus: .init(blockID: a, graphemeOffset: 4),
            preferredColumn: 2,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let firstLineEnd = caret(a, 3)
        let extendingDown = BlockEditorSelection.text(
            anchor: .init(blockID: a, graphemeOffset: 3),
            focus: .init(blockID: a, graphemeOffset: 5),
            preferredColumn: 3,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let verticalAffinity = BlockEditorSelection.text(
            anchor: .init(blockID: b, graphemeOffset: 2),
            focus: .init(blockID: b, graphemeOffset: 2),
            preferredColumn: 2,
            typingAttributes: .init(marks: [.italic], linkURL: nil)
        )
        let horizontalBackwardExtend = BlockEditorSelection.text(
            anchor: .init(blockID: a, graphemeOffset: 2),
            focus: .init(blockID: a, graphemeOffset: 1),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: exactLinkURL)
        )
        let horizontalCross = caret(a, 2)
        let dividerPrevious = blockID(323), dividerFollowing = blockID(324)
        let dividerDocument = doc([
            DocumentBlock(
                id: dividerPrevious,
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "上界", marks: [.bold], linkURL: exactLinkURL)
                ]),
                taskState: nil,
                indentLevel: 0
            ),
            block(divider, .divider, ""),
            DocumentBlock(
                id: dividerFollowing,
                kind: .paragraph,
                inlineContent: .init(spans: [
                    .init(text: "下", marks: [.italic]),
                    .init(text: "界")
                ]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let dividerSelection = BlockEditorSelection.text(
            anchor: .init(blockID: divider, graphemeOffset: 0),
            focus: .init(blockID: divider, graphemeOffset: 0),
            preferredColumn: nil,
            typingAttributes: .init(marks: [.code], linkURL: nil)
        )
        let dividerOnlyDocument = doc([block(divider, .divider, "")])
        let dividerOnlySelection = caret(divider, 0)
        let preferredPrevious = blockID(325), preferredDivider = blockID(326), preferredFollowing = blockID(327)
        let preferredDividerDocument = doc([
            block(preferredPrevious, .paragraph, "abcd"),
            block(preferredDivider, .divider, ""),
            block(preferredFollowing, .paragraph, "wxyz")
        ])
        let preferredDividerSelection = BlockEditorSelection.text(
            anchor: .init(blockID: preferredDivider, graphemeOffset: 0),
            focus: .init(blockID: preferredDivider, graphemeOffset: 0),
            preferredColumn: 4,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let reverseDividerSelection = BlockEditorSelection.text(
            anchor: .init(blockID: preferredDivider, graphemeOffset: 0),
            focus: .init(blockID: preferredDivider, graphemeOffset: 0),
            preferredColumn: 0,
            typingAttributes: .init(marks: [], linkURL: nil)
        )

        return [
            moved(
                multiline,
                secondLineStart,
                .moveVertical(.up, extending: false),
                .text(
                    anchor: .init(blockID: a, graphemeOffset: 2),
                    focus: .init(blockID: a, graphemeOffset: 2),
                    preferredColumn: 2,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
            ),
            moved(multiline, firstLineEnd, .moveVertical(.down, extending: true), extendingDown),
            moved(boldItalic, caret(a, 2), .moveVertical(.down, extending: false), verticalAffinity),
            .init(
                label: "vertical-internal-defer",
                document: multiline,
                selection: caret(a, 1),
                command: .moveVertical(.down, extending: false),
                expected: exactNoChange(multiline, caret(a, 1), .textSystemOwnsMovement)
            ),
            moved(
                dividerDocument,
                dividerSelection,
                .moveVertical(.up, extending: false),
                .text(
                    anchor: .init(blockID: dividerPrevious, graphemeOffset: 0),
                    focus: .init(blockID: dividerPrevious, graphemeOffset: 0),
                    preferredColumn: 0,
                    typingAttributes: .init(marks: [.bold], linkURL: exactLinkURL)
                )
            ),
            moved(
                dividerDocument,
                dividerSelection,
                .moveVertical(.down, extending: false),
                .text(
                    anchor: .init(blockID: dividerFollowing, graphemeOffset: 0),
                    focus: .init(blockID: dividerFollowing, graphemeOffset: 0),
                    preferredColumn: 0,
                    typingAttributes: .init(marks: [.italic], linkURL: nil)
                )
            ),
            moved(
                dividerDocument,
                dividerSelection,
                .moveVertical(.up, extending: true),
                .text(
                    anchor: .init(blockID: divider, graphemeOffset: 0),
                    focus: .init(blockID: dividerPrevious, graphemeOffset: 0),
                    preferredColumn: 0,
                    typingAttributes: .init(marks: [.bold], linkURL: exactLinkURL)
                )
            ),
            moved(
                dividerDocument,
                dividerSelection,
                .moveVertical(.down, extending: true),
                .text(
                    anchor: .init(blockID: divider, graphemeOffset: 0),
                    focus: .init(blockID: dividerFollowing, graphemeOffset: 0),
                    preferredColumn: 0,
                    typingAttributes: .init(marks: [.italic], linkURL: nil)
                )
            ),
            .init(
                label: "vertical-divider-document-start",
                document: dividerOnlyDocument,
                selection: dividerOnlySelection,
                command: .moveVertical(.up, extending: false),
                expected: exactNoChange(dividerOnlyDocument, dividerOnlySelection, .documentBoundary)
            ),
            moved(
                preferredDividerDocument,
                caret(preferredPrevious, 4),
                .moveVertical(.down, extending: false),
                .text(
                    anchor: .init(blockID: preferredDivider, graphemeOffset: 0),
                    focus: .init(blockID: preferredDivider, graphemeOffset: 0),
                    preferredColumn: 4,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
            ),
            moved(
                preferredDividerDocument,
                preferredDividerSelection,
                .moveVertical(.down, extending: false),
                .text(
                    anchor: .init(blockID: preferredFollowing, graphemeOffset: 4),
                    focus: .init(blockID: preferredFollowing, graphemeOffset: 4),
                    preferredColumn: 4,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
            ),
            moved(
                preferredDividerDocument,
                caret(preferredFollowing, 0),
                .moveVertical(.up, extending: false),
                reverseDividerSelection
            ),
            moved(
                preferredDividerDocument,
                reverseDividerSelection,
                .moveVertical(.up, extending: false),
                .text(
                    anchor: .init(blockID: preferredPrevious, graphemeOffset: 0),
                    focus: .init(blockID: preferredPrevious, graphemeOffset: 0),
                    preferredColumn: 0,
                    typingAttributes: .init(marks: [], linkURL: nil)
                )
            ),
            .init(
                label: "vertical-divider-document-end",
                document: dividerOnlyDocument,
                selection: dividerOnlySelection,
                command: .moveVertical(.down, extending: false),
                expected: exactNoChange(dividerOnlyDocument, dividerOnlySelection, .documentBoundary)
            ),
            .init(
                label: "vertical-document-start",
                document: multiline,
                selection: caret(a, 0),
                command: .moveVertical(.up, extending: false),
                expected: exactNoChange(multiline, caret(a, 0), .documentBoundary)
            ),
            .init(
                label: "vertical-document-end",
                document: multiline,
                selection: caret(a, 5),
                command: .moveVertical(.down, extending: false),
                expected: exactNoChange(multiline, caret(a, 5), .documentBoundary)
            ),
            moved(linkDocument, horizontalCross, .moveHorizontal(.backward, extending: true), horizontalBackwardExtend),
            moved(
                linkDocument,
                caret(b, 0),
                .moveHorizontal(.backward, extending: false),
                caret(a, 2)
            ),
            moved(
                linkDocument,
                caret(a, 0),
                .moveHorizontal(.forward, extending: false),
                caret(a, 1, attributes: .init(marks: [], linkURL: exactLinkURL))
            ),
            moved(
                linkDocument,
                caret(a, 2),
                .moveHorizontal(.backward, extending: false),
                caret(a, 1, attributes: .init(marks: [], linkURL: exactLinkURL))
            )
        ]
    }()
}

struct CrossBlockUnicodeExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [CrossBlockUnicodeExactFixture] = UnicodeFixture.all.flatMap { unicode -> [CrossBlockUnicodeExactFixture] in
        let a = blockID(330), b = blockID(331)
        let document = doc([
            block(a, .paragraph, "前" + unicode.text),
            block(b, .quote, unicode.text + "后")
        ])
        let expectedDocument = doc([DocumentBlock(
            id: a,
            kind: .paragraph,
            inlineContent: .init(spans: [.init(text: "前"), .init(text: "后")]),
            taskState: nil,
            indentLevel: 0
        )])
        let expected = BlockInputResult(
            document: expectedDocument,
            selection: caret(a, 1),
            mutation: .document,
            effect: .handled,
            undo: .atomic(.deletion)
        )
        return [
            .init(
                label: "\(unicode.label)-forward",
                document: document,
                selection: textSelection(a, 1, b, 1),
                expected: expected
            ),
            .init(
                label: "\(unicode.label)-reverse",
                document: document,
                selection: textSelection(b, 1, a, 1),
                expected: expected
            )
        ]
    }
}

struct BlockSelectionErrorFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let expectedError: BlockInputError
    var testDescription: String { label }

    static let all: [BlockSelectionErrorFixture] = {
        let a = blockID(340), b = blockID(341), missing = blockID(999)
        let document = doc([block(a, .paragraph, "甲"), block(b, .paragraph, "乙")])
        return [
            .init(label: "missing-anchor", document: document, selection: .blocks(anchor: missing, focus: a), expectedError: .invalidSelection),
            .init(label: "missing-focus", document: document, selection: .blocks(anchor: a, focus: missing), expectedError: .invalidSelection),
            .init(label: "both-missing", document: document, selection: .blocks(anchor: missing, focus: blockID(998)), expectedError: .invalidSelection)
        ]
    }()
}

struct SpanBoundaryExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let command: BlockInputCommand
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [SpanBoundaryExactFixture] = {
        let id = blockID(350)
        let zeroItalic = InlineSpan(text: "", marks: [.italic])
        let zeroCode = InlineSpan(text: "", marks: [.code])
        let document = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "甲", marks: [.bold]),
                zeroItalic,
                .init(text: "乙", marks: [.bold]),
                .init(text: "丙", marks: [.bold]),
                zeroCode
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        let selection = textSelection(id, 1, id, 2)
        let deletedDocument = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "甲", marks: [.bold]), zeroItalic,
                .init(text: "丙", marks: [.bold]), zeroCode
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        let linkedDocument = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "甲", marks: [.bold]), zeroItalic,
                .init(text: "乙", marks: [.bold], linkURL: exactLinkURL),
                .init(text: "丙", marks: [.bold]), zeroCode
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        let pastedDocument = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "甲", marks: [.bold]), zeroItalic,
                .init(text: "中"),
                .init(text: "丙", marks: [.bold]), zeroCode
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        return [
            .init(
                label: "delete",
                document: document,
                selection: selection,
                command: .deleteSelection,
                expected: .init(
                    document: deletedDocument,
                    selection: caret(id, 1, attributes: .init(marks: [.bold], linkURL: nil)),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.deletion)
                )
            ),
            .init(
                label: "link",
                document: document,
                selection: selection,
                command: .setLink(exactLinkURL),
                expected: .init(
                    document: linkedDocument,
                    selection: textSelection(
                        id, 1, id, 2,
                        attributes: .init(marks: [], linkURL: exactLinkURL)
                    ),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.link)
                )
            ),
            .init(
                label: "paste",
                document: document,
                selection: selection,
                command: .replaceSelection(.plainText("中")),
                expected: .init(
                    document: pastedDocument,
                    selection: caret(id, 2),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.paste)
                )
            )
        ]
    }()
}

struct IndentExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let command: BlockInputCommand
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [IndentExactFixture] = {
        let parent = blockID(360), a = blockID(361), aChild = blockID(362)
        let b = blockID(363), bChild = blockID(364)
        let flat = doc([
            block(parent, .bullet, "parent", indent: 0),
            block(a, .ordered, "a", indent: 0),
            block(aChild, .task, "a-child", indent: 1),
            block(b, .bullet, "b", indent: 0),
            block(bChild, .ordered, "b-child", indent: 1)
        ])
        let nested = doc([
            block(parent, .bullet, "parent", indent: 0),
            block(a, .ordered, "a", indent: 1),
            block(aChild, .task, "a-child", indent: 2),
            block(b, .bullet, "b", indent: 1),
            block(bChild, .ordered, "b-child", indent: 2)
        ])
        let listSelection = BlockEditorSelection.blocks(anchor: a, focus: b)

        let code = blockID(365)
        let indentSource = doc([block(code, .code, "  a\n    b\n c", codeInfo: "swift")])
        let indented = doc([block(code, .code, "      a\n        b\n c", codeInfo: "swift")])
        let outdentSource = doc([block(code, .code, "    a\n  b\n c", codeInfo: "swift")])
        let outdented = doc([block(code, .code, "a\nb\n c", codeInfo: "swift")])

        func codeFixture(
            _ label: String,
            document: BlockDocument,
            selection: BlockEditorSelection,
            command: BlockInputCommand,
            expectedDocument: BlockDocument,
            expectedSelection: BlockEditorSelection
        ) -> IndentExactFixture {
            .init(
                label: label,
                document: document,
                selection: selection,
                command: command,
                expected: .init(
                    document: expectedDocument,
                    selection: expectedSelection,
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.indentation)
                )
            )
        }

        return [
            .init(
                label: "multi-root-indent",
                document: flat,
                selection: listSelection,
                command: .indent,
                expected: .init(
                    document: nested,
                    selection: listSelection,
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.indentation)
                )
            ),
            .init(
                label: "multi-root-outdent",
                document: nested,
                selection: listSelection,
                command: .outdent,
                expected: .init(
                    document: flat,
                    selection: listSelection,
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.indentation)
                )
            ),
            codeFixture(
                "code-indent-forward-endpoint",
                document: indentSource,
                selection: textSelection(code, 1, code, 10),
                command: .indent,
                expectedDocument: indented,
                expectedSelection: textSelection(code, 5, code, 18)
            ),
            codeFixture(
                "code-indent-reverse-endpoint",
                document: indentSource,
                selection: textSelection(code, 10, code, 1),
                command: .indent,
                expectedDocument: indented,
                expectedSelection: textSelection(code, 18, code, 5)
            ),
            codeFixture(
                "code-outdent-forward-endpoint",
                document: outdentSource,
                selection: textSelection(code, 0, code, 10),
                command: .outdent,
                expectedDocument: outdented,
                expectedSelection: textSelection(code, 0, code, 4)
            ),
            codeFixture(
                "code-outdent-reverse-endpoint",
                document: outdentSource,
                selection: textSelection(code, 10, code, 0),
                command: .outdent,
                expectedDocument: outdented,
                expectedSelection: textSelection(code, 4, code, 0)
            )
        ]
    }()
}

struct FormattingExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let command: BlockInputCommand
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [FormattingExactFixture] = {
        let a = blockID(370), b = blockID(371), c = blockID(372)
        let addDocument = doc([DocumentBlock(
            id: a,
            kind: .paragraph,
            inlineContent: .init(spans: [.init(text: "甲", marks: [.bold]), .init(text: "乙")]),
            taskState: nil,
            indentLevel: 0
        )])
        let addedDocument = doc([DocumentBlock(
            id: a,
            kind: .paragraph,
            inlineContent: .init(spans: [.init(text: "甲", marks: [.bold]), .init(text: "乙", marks: [.bold])]),
            taskState: nil,
            indentLevel: 0
        )])
        let removedDocument = doc([DocumentBlock(
            id: a,
            kind: .paragraph,
            inlineContent: .init(spans: [.init(text: "甲"), .init(text: "乙")]),
            taskState: nil,
            indentLevel: 0
        )])
        let crossDocument = doc([
            DocumentBlock(
                id: a,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "甲", marks: [.italic])]),
                taskState: nil,
                indentLevel: 0
            ),
            block(b, .quote, "乙")
        ])
        let crossExpected = doc([
            DocumentBlock(
                id: a,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "甲", marks: [.bold, .italic])]),
                taskState: nil,
                indentLevel: 0
            ),
            DocumentBlock(
                id: b,
                kind: .quote,
                inlineContent: .init(spans: [.init(text: "乙", marks: [.bold])]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let mixed = doc([block(a, .paragraph, "甲"), block(b, .code, "code"), block(c, .paragraph, "乙")])
        let mixedForward = textSelection(a, 0, c, 1)
        let mixedReverse = textSelection(c, 1, a, 0)

        let typingDocument = doc([block(a, .paragraph, "甲乙")])
        let typingSelection = BlockEditorSelection.text(
            anchor: .init(blockID: a, graphemeOffset: 1),
            focus: .init(blockID: a, graphemeOffset: 1),
            preferredColumn: 7,
            typingAttributes: .init(marks: [.bold], linkURL: exactLinkURL)
        )
        let typedDocument = doc([DocumentBlock(
            id: a,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "甲"),
                .init(text: "中", marks: [.bold], linkURL: exactLinkURL),
                .init(text: "乙")
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        let linkedDocument = doc([DocumentBlock(
            id: a,
            kind: .paragraph,
            inlineContent: .init(spans: [.init(text: "甲", linkURL: exactLinkURL), .init(text: "乙")]),
            taskState: nil,
            indentLevel: 0
        )])

        func documentResult(
            _ label: String,
            document: BlockDocument,
            selection: BlockEditorSelection,
            command: BlockInputCommand,
            expectedDocument: BlockDocument,
            expectedSelection: BlockEditorSelection,
            undo: BlockUndoDirective
        ) -> FormattingExactFixture {
            .init(
                label: label,
                document: document,
                selection: selection,
                command: command,
                expected: .init(
                    document: expectedDocument,
                    selection: expectedSelection,
                    mutation: .document,
                    effect: .handled,
                    undo: undo
                )
            )
        }

        let addSelection = textSelection(a, 0, a, 2)
        return [
            documentResult(
                "mark-add-when-not-all",
                document: addDocument,
                selection: addSelection,
                command: .toggleInlineMark(.bold),
                expectedDocument: addedDocument,
                expectedSelection: textSelection(
                    a, 0, a, 2,
                    attributes: .init(marks: [.bold], linkURL: nil)
                ),
                undo: .atomic(.formatting)
            ),
            documentResult(
                "mark-remove-when-all",
                document: addedDocument,
                selection: addSelection,
                command: .toggleInlineMark(.bold),
                expectedDocument: removedDocument,
                expectedSelection: textSelection(a, 0, a, 2),
                undo: .atomic(.formatting)
            ),
            documentResult(
                "cross-block-forward",
                document: crossDocument,
                selection: textSelection(a, 0, b, 1),
                command: .toggleInlineMark(.bold),
                expectedDocument: crossExpected,
                expectedSelection: textSelection(
                    a, 0, b, 1,
                    attributes: .init(marks: [.bold], linkURL: nil)
                ),
                undo: .atomic(.formatting)
            ),
            documentResult(
                "cross-block-reverse",
                document: crossDocument,
                selection: textSelection(b, 1, a, 0),
                command: .toggleInlineMark(.bold),
                expectedDocument: crossExpected,
                expectedSelection: textSelection(
                    a, 0, b, 1,
                    attributes: .init(marks: [.bold], linkURL: nil)
                ),
                undo: .atomic(.formatting)
            ),
            .init(
                label: "mixed-code-mark-forward",
                document: mixed,
                selection: mixedForward,
                command: .toggleInlineMark(.italic),
                expected: exactNoChange(mixed, mixedForward, .unsupportedBlockKind)
            ),
            .init(
                label: "mixed-code-link-reverse",
                document: mixed,
                selection: mixedReverse,
                command: .setLink(exactLinkURL),
                expected: exactNoChange(mixed, mixedReverse, .unsupportedBlockKind)
            ),
            documentResult(
                "typing-attributes-insert",
                document: typingDocument,
                selection: typingSelection,
                command: .insertText("中"),
                expectedDocument: typedDocument,
                expectedSelection: caret(a, 2, attributes: .init(marks: [.bold], linkURL: exactLinkURL)),
                undo: .coalesceTyping(a)
            ),
            documentResult(
                "link-caret-affinity-at-zero",
                document: typingDocument,
                selection: textSelection(a, 0, a, 1),
                command: .setLink(exactLinkURL),
                expectedDocument: linkedDocument,
                expectedSelection: textSelection(
                    a, 0, a, 1,
                    attributes: .init(marks: [], linkURL: exactLinkURL)
                ),
                undo: .atomic(.link)
            )
        ]
    }()
}

struct InvalidLinkExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let url: URL
    var testDescription: String { label }

    static let all: [InvalidLinkExactFixture] = {
        let id = blockID(380)
        let document = doc([block(id, .paragraph, "甲")])
        let selection = textSelection(id, 0, id, 1)
        let control = "https://example.com/" + String(UnicodeScalar(1)!)
        return [
            .init(label: "relative", document: document, selection: selection, url: URL(string: "relative/path")!),
            .init(label: "scheme-only", document: document, selection: selection, url: URL(string: "https:")!),
            .init(label: "mailto", document: document, selection: selection, url: URL(string: "mailto:test@example.com")!),
            .init(label: "control", document: document, selection: selection, url: URL(string: control)!)
        ]
    }()
}

struct DestructiveBlockExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let command: BlockInputCommand
    let ids: [BlockID]
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [DestructiveBlockExactFixture] = {
        let root = blockID(390), child = blockID(391), grandchild = blockID(392)
        let later = blockID(393), laterChild = blockID(394), divider = blockID(395), tail = blockID(396)
        let inserted = blockID(397)
        let document = doc([
            block(root, .bullet, "root", indent: 0),
            block(child, .task, "child", indent: 1, completed: exactCompletedDate),
            block(grandchild, .ordered, "grand", indent: 2),
            block(later, .ordered, "later", indent: 0),
            block(laterChild, .bullet, "later-child", indent: 1),
            block(divider, .divider, ""),
            block(tail, .paragraph, "tail")
        ])
        let forward = BlockEditorSelection.blocks(anchor: root, focus: later)
        let reverse = BlockEditorSelection.blocks(anchor: later, focus: root)
        let deletedDocument = doc([block(divider, .divider, ""), block(tail, .paragraph, "tail")])
        let plainDocument = doc([
            block(root, .paragraph, "甲"),
            block(inserted, .paragraph, "乙"),
            block(divider, .divider, ""),
            block(tail, .paragraph, "tail")
        ])

        func destructive(
            _ label: String,
            selection: BlockEditorSelection,
            command: BlockInputCommand,
            ids: [BlockID] = [],
            expectedDocument: BlockDocument,
            expectedSelection: BlockEditorSelection,
            undo: BlockUndoDirective
        ) -> DestructiveBlockExactFixture {
            .init(
                label: label,
                document: document,
                selection: selection,
                command: command,
                ids: ids,
                expected: .init(
                    document: expectedDocument,
                    selection: expectedSelection,
                    mutation: .document,
                    effect: .handled,
                    undo: undo
                )
            )
        }

        let throughDividerForward = BlockEditorSelection.blocks(anchor: child, focus: divider)
        let throughDividerReverse = BlockEditorSelection.blocks(anchor: divider, focus: child)
        let rich = BlockPastePayload.richText(blocks: [
            .init(kind: .quote, inlineContent: .plain("新"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "新")
        let richDocument = doc([
            block(root, .bullet, "root", indent: 0),
            block(child, .quote, "新"),
            block(tail, .paragraph, "tail")
        ])
        let emptyRich = BlockPastePayload.richText(blocks: [], fallbackPlainText: "")
        let emptyDocument = doc([block(root, .bullet, "root", indent: 0), block(tail, .paragraph, "tail")])

        return [
            destructive(
                "delete-forward-multi-root-descendants",
                selection: forward,
                command: .deleteSelection,
                expectedDocument: deletedDocument,
                expectedSelection: caret(divider, 0),
                undo: .atomic(.deletion)
            ),
            destructive(
                "delete-reverse-multi-root-descendants",
                selection: reverse,
                command: .deleteSelection,
                expectedDocument: deletedDocument,
                expectedSelection: caret(divider, 0),
                undo: .atomic(.deletion)
            ),
            destructive(
                "plain-replacement-forward-multi-root",
                selection: forward,
                command: .replaceSelection(.plainText("甲\n乙")),
                ids: [inserted],
                expectedDocument: plainDocument,
                expectedSelection: caret(inserted, 1),
                undo: .atomic(.paste)
            ),
            destructive(
                "plain-replacement-reverse-multi-root",
                selection: reverse,
                command: .replaceSelection(.plainText("甲\n乙")),
                ids: [inserted],
                expectedDocument: plainDocument,
                expectedSelection: caret(inserted, 1),
                undo: .atomic(.paste)
            ),
            destructive(
                "rich-replacement-forward-through-divider",
                selection: throughDividerForward,
                command: .replaceSelection(rich),
                expectedDocument: richDocument,
                expectedSelection: caret(child, 1),
                undo: .atomic(.paste)
            ),
            destructive(
                "rich-replacement-reverse-through-divider",
                selection: throughDividerReverse,
                command: .replaceSelection(rich),
                expectedDocument: richDocument,
                expectedSelection: caret(child, 1),
                undo: .atomic(.paste)
            ),
            destructive(
                "empty-rich-removes-deduplicated-union",
                selection: throughDividerForward,
                command: .replaceSelection(emptyRich),
                expectedDocument: emptyDocument,
                expectedSelection: caret(tail, 0),
                undo: .atomic(.paste)
            )
        ]
    }()
}

struct PasteMatrixExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let payload: BlockPastePayload
    let ids: [BlockID]
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [PasteMatrixExactFixture] = {
        let a = blockID(400), b = blockID(401), tail = blockID(402)
        let n1 = blockID(410), n2 = blockID(411), n3 = blockID(412)
        let plain = BlockPastePayload.plainText("新\n次")
        let rich = BlockPastePayload.richText(blocks: [
            .init(kind: .task, inlineContent: .plain("新"), indentLevel: 0, codeInfoString: nil),
            .init(kind: .divider, inlineContent: .plain(""), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "新\n")
        let empty = BlockPastePayload.richText(blocks: [], fallbackPlainText: "")
        let fallback = BlockPastePayload.richText(blocks: [
            .init(kind: .link, inlineContent: .plain("bad"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "回\n退")

        func fixture(
            _ label: String,
            document: BlockDocument,
            selection: BlockEditorSelection,
            payload: BlockPastePayload,
            ids: [BlockID] = [],
            expectedDocument: BlockDocument,
            expectedSelection: BlockEditorSelection,
            mutation: BlockInputMutation = .document,
            undo: BlockUndoDirective = .atomic(.paste)
        ) -> PasteMatrixExactFixture {
            .init(
                label: label,
                document: document,
                selection: selection,
                payload: payload,
                ids: ids,
                expected: .init(
                    document: expectedDocument,
                    selection: expectedSelection,
                    mutation: mutation,
                    effect: .handled,
                    undo: undo
                )
            )
        }

        let collapsedDocument = doc([block(a, .task, "甲乙", completed: exactCompletedDate)])
        let collapsed = caret(a, 1)
        let collapsedPlain = doc([
            DocumentBlock(
                id: a,
                kind: .task,
                inlineContent: .init(spans: [.init(text: "甲"), .init(text: "新")]),
                taskState: .init(completedAt: exactCompletedDate),
                indentLevel: 0
            ),
            DocumentBlock(
                id: n1,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "次"), .init(text: "乙")]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let collapsedFallback = doc([
            DocumentBlock(
                id: a,
                kind: .task,
                inlineContent: .init(spans: [.init(text: "甲"), .init(text: "回")]),
                taskState: .init(completedAt: exactCompletedDate),
                indentLevel: 0
            ),
            DocumentBlock(
                id: n1,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "退"), .init(text: "乙")]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let collapsedRich = doc([
            block(a, .task, "甲", completed: exactCompletedDate),
            block(n1, .task, "新"),
            block(n2, .divider, ""),
            block(n3, .task, "乙")
        ])

        let sameDocument = doc([block(a, .task, "甲乙丙", completed: exactCompletedDate)])
        let same = textSelection(a, 1, a, 2)
        let samePlain = doc([
            DocumentBlock(
                id: a,
                kind: .task,
                inlineContent: .init(spans: [.init(text: "甲"), .init(text: "新")]),
                taskState: .init(completedAt: exactCompletedDate),
                indentLevel: 0
            ),
            DocumentBlock(
                id: n1,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "次"), .init(text: "丙")]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let sameFallback = doc([
            DocumentBlock(
                id: a,
                kind: .task,
                inlineContent: .init(spans: [.init(text: "甲"), .init(text: "回")]),
                taskState: .init(completedAt: exactCompletedDate),
                indentLevel: 0
            ),
            DocumentBlock(
                id: n1,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "退"), .init(text: "丙")]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let sameRich = doc([
            block(a, .task, "甲", completed: exactCompletedDate),
            block(n1, .task, "新"),
            block(n2, .divider, ""),
            block(n3, .task, "丙")
        ])
        let sameEmpty = doc([DocumentBlock(
            id: a,
            kind: .task,
            inlineContent: .init(spans: [.init(text: "甲"), .init(text: "丙")]),
            taskState: .init(completedAt: exactCompletedDate),
            indentLevel: 0
        )])

        let crossDocument = doc([
            block(a, .task, "甲乙", completed: exactCompletedDate),
            block(b, .paragraph, "丙丁")
        ])
        let cross = textSelection(a, 1, b, 1)
        let crossPlain = doc([
            DocumentBlock(
                id: a,
                kind: .task,
                inlineContent: .init(spans: [.init(text: "甲"), .init(text: "新")]),
                taskState: .init(completedAt: exactCompletedDate),
                indentLevel: 0
            ),
            DocumentBlock(
                id: n1,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "次"), .init(text: "丁")]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let crossFallback = doc([
            DocumentBlock(
                id: a,
                kind: .task,
                inlineContent: .init(spans: [.init(text: "甲"), .init(text: "回")]),
                taskState: .init(completedAt: exactCompletedDate),
                indentLevel: 0
            ),
            DocumentBlock(
                id: n1,
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "退"), .init(text: "丁")]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let crossRich = doc([
            block(a, .task, "甲", completed: exactCompletedDate),
            block(n1, .task, "新"),
            block(n2, .divider, ""),
            block(b, .paragraph, "丁")
        ])
        let crossEmpty = doc([DocumentBlock(
            id: a,
            kind: .task,
            inlineContent: .init(spans: [.init(text: "甲"), .init(text: "丁")]),
            taskState: .init(completedAt: exactCompletedDate),
            indentLevel: 0
        )])

        let blockDocument = doc([
            block(a, .task, "根", completed: exactCompletedDate),
            block(b, .task, "子", indent: 1, completed: exactCompletedDate),
            block(tail, .paragraph, "尾")
        ])
        let blocks = BlockEditorSelection.blocks(anchor: a, focus: a)
        let blockPlain = doc([block(a, .paragraph, "新"), block(n1, .paragraph, "次"), block(tail, .paragraph, "尾")])
        let blockFallback = doc([block(a, .paragraph, "回"), block(n1, .paragraph, "退"), block(tail, .paragraph, "尾")])
        let blockRich = doc([block(a, .task, "新"), block(n1, .divider, ""), block(tail, .paragraph, "尾")])
        let blockEmpty = doc([block(tail, .paragraph, "尾")])

        return [
            fixture("collapsed-plain", document: collapsedDocument, selection: collapsed, payload: plain, ids: [n1], expectedDocument: collapsedPlain, expectedSelection: caret(n1, 1)),
            fixture("collapsed-rich", document: collapsedDocument, selection: collapsed, payload: rich, ids: [n1, n2, n3], expectedDocument: collapsedRich, expectedSelection: caret(n2, 0)),
            fixture(
                "collapsed-empty",
                document: collapsedDocument,
                selection: collapsed,
                payload: empty,
                expectedDocument: collapsedDocument,
                expectedSelection: collapsed,
                mutation: .none(.emptySelection),
                undo: .none
            ),
            fixture("collapsed-fallback", document: collapsedDocument, selection: collapsed, payload: fallback, ids: [n1], expectedDocument: collapsedFallback, expectedSelection: caret(n1, 1)),

            fixture("same-plain", document: sameDocument, selection: same, payload: plain, ids: [n1], expectedDocument: samePlain, expectedSelection: caret(n1, 1)),
            fixture("same-rich", document: sameDocument, selection: same, payload: rich, ids: [n1, n2, n3], expectedDocument: sameRich, expectedSelection: caret(n2, 0)),
            fixture("same-empty", document: sameDocument, selection: same, payload: empty, expectedDocument: sameEmpty, expectedSelection: caret(a, 1), undo: .atomic(.paste)),
            fixture("same-fallback", document: sameDocument, selection: same, payload: fallback, ids: [n1], expectedDocument: sameFallback, expectedSelection: caret(n1, 1)),

            fixture("cross-plain", document: crossDocument, selection: cross, payload: plain, ids: [n1], expectedDocument: crossPlain, expectedSelection: caret(n1, 1)),
            fixture("cross-rich", document: crossDocument, selection: cross, payload: rich, ids: [n1, n2], expectedDocument: crossRich, expectedSelection: caret(n2, 0)),
            fixture("cross-empty", document: crossDocument, selection: cross, payload: empty, expectedDocument: crossEmpty, expectedSelection: caret(a, 1), undo: .atomic(.paste)),
            fixture("cross-fallback", document: crossDocument, selection: cross, payload: fallback, ids: [n1], expectedDocument: crossFallback, expectedSelection: caret(n1, 1)),

            fixture("blocks-plain", document: blockDocument, selection: blocks, payload: plain, ids: [n1], expectedDocument: blockPlain, expectedSelection: caret(n1, 1)),
            fixture("blocks-rich", document: blockDocument, selection: blocks, payload: rich, ids: [n1], expectedDocument: blockRich, expectedSelection: caret(n1, 0)),
            fixture("blocks-empty", document: blockDocument, selection: blocks, payload: empty, expectedDocument: blockEmpty, expectedSelection: caret(tail, 0), undo: .atomic(.paste)),
            fixture("blocks-fallback", document: blockDocument, selection: blocks, payload: fallback, ids: [n1], expectedDocument: blockFallback, expectedSelection: caret(n1, 1))
        ]
    }()
}

struct DragOrderingExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let roots: [BlockID]
    let target: BlockID?
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [DragOrderingExactFixture] = {
        let first = blockID(420), a = blockID(421), aChild = blockID(422)
        let b = blockID(423), bChild = blockID(424), tail = blockID(425)
        let document = doc([
            block(first, .paragraph, "first"),
            block(a, .bullet, "a", indent: 0),
            block(aChild, .task, "a-child", indent: 1, completed: exactCompletedDate),
            block(b, .ordered, "b", indent: 0),
            block(bChild, .bullet, "b-child", indent: 1),
            block(tail, .quote, "tail")
        ])
        let expectedDocument = doc([
            block(a, .bullet, "a", indent: 0),
            block(aChild, .task, "a-child", indent: 1, completed: exactCompletedDate),
            block(b, .ordered, "b", indent: 0),
            block(bChild, .bullet, "b-child", indent: 1),
            block(first, .paragraph, "first"),
            block(tail, .quote, "tail")
        ])
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: tail, graphemeOffset: 3),
            focus: .init(blockID: tail, graphemeOffset: 1),
            preferredColumn: 7,
            typingAttributes: .init(marks: [.italic], linkURL: nil)
        )
        let expectedSelection = BlockEditorSelection.text(
            anchor: .init(blockID: tail, graphemeOffset: 3),
            focus: .init(blockID: tail, graphemeOffset: 1),
            preferredColumn: nil,
            typingAttributes: .init(marks: [.italic], linkURL: nil)
        )
        let expected = BlockInputResult(
            document: expectedDocument,
            selection: expectedSelection,
            mutation: .document,
            effect: .handled,
            undo: .atomic(.drag)
        )
        return [
            .init(label: "reverse-roots", document: document, selection: selection, roots: [b, a], target: first, expected: expected),
            .init(label: "descendants-before-roots", document: document, selection: selection, roots: [bChild, b, aChild, a], target: first, expected: expected),
            .init(label: "interleaved-parameters", document: document, selection: selection, roots: [aChild, b, a, bChild], target: first, expected: expected)
        ]
    }()
}

enum ReductionOutcomeExpectation: Equatable, Sendable {
    case result(BlockInputResult)
    case error(BlockInputError)
}

struct ReductionOutcomeExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let command: BlockInputCommand
    let ids: [BlockID]
    let expected: ReductionOutcomeExpectation
    var testDescription: String { label }

    static let all: [ReductionOutcomeExactFixture] = {
        let id = blockID(430)
        let document = doc([block(id, .paragraph, "甲")])
        let inserted = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [.init(text: "甲乙")]),
            taskState: nil,
            indentLevel: 0
        )])
        let collapsed = caret(id, 1)
        return [
            .init(
                label: "success",
                document: document,
                selection: collapsed,
                command: .insertText("乙"),
                ids: [],
                expected: .result(.init(
                    document: inserted,
                    selection: caret(id, 2),
                    mutation: .document,
                    effect: .handled,
                    undo: .coalesceTyping(id)
                ))
            ),
            .init(
                label: "no-change",
                document: document,
                selection: collapsed,
                command: .deleteSelection,
                ids: [],
                expected: .result(exactNoChange(document, collapsed, .emptySelection))
            ),
            .init(
                label: "error",
                document: document,
                selection: collapsed,
                command: .enter,
                ids: [],
                expected: .error(.insufficientBlockIDs)
            )
        ]
    }()
}

struct MarkdownExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [MarkdownExactFixture] = {
        let id = blockID(440)
        let conversions: [(String, BlockKind, String?)] = [
            ("# ", .heading1, nil),
            ("## ", .heading2, nil),
            ("### ", .heading3, nil),
            ("- ", .bullet, nil),
            ("* ", .bullet, nil),
            ("1. ", .ordered, nil),
            ("[] ", .task, nil),
            ("[ ] ", .task, nil),
            ("> ", .quote, nil),
            ("``` ", .code, nil),
            ("```swift ", .code, "swift")
        ]
        var fixtures = conversions.map { prefix, kind, codeInfo -> MarkdownExactFixture in
            let document = doc([block(id, .paragraph, prefix + "正文")])
            return .init(
                label: "recognized-\(String(describing: kind))-\(prefix.debugDescription)",
                document: document,
                selection: caret(id, prefix.count),
                expected: .init(
                    document: doc([block(id, kind, "正文", codeInfo: codeInfo)]),
                    selection: caret(id, 0),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.conversion)
                )
            )
        }
        let rejections: [(String, BlockDocument, BlockEditorSelection)] = [
            ("partial", doc([block(id, .paragraph, "#")]), caret(id, 1)),
            ("unrecognized", doc([block(id, .paragraph, "#### ")]), caret(id, 5)),
            ("nonleading", doc([block(id, .paragraph, "x# ")]), caret(id, 3)),
            ("caret-before-complete-prefix", doc([block(id, .paragraph, "# 正文")]), caret(id, 1)),
            ("noncollapsed", doc([block(id, .paragraph, "# 正文")]), textSelection(id, 0, id, 2)),
            ("code-block", doc([block(id, .code, "# ")]), caret(id, 2))
        ]
        fixtures.append(contentsOf: rejections.map { label, document, selection in
            .init(
                label: label,
                document: document,
                selection: selection,
                expected: exactNoChange(document, selection, .samePosition)
            )
        })
        return fixtures
    }()
}

struct SlashExactFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let kind: BlockKind
    let expected: BlockInputResult
    var testDescription: String { label }

    static let all: [SlashExactFixture] = {
        let id = blockID(450)
        let kinds = allBlockKinds.filter { $0 != .link }
        var fixtures = kinds.map { kind -> SlashExactFixture in
            let document = doc([block(id, .paragraph, "/cmd")])
            let expectedBlock: DocumentBlock
            if kind == .code || kind == .divider {
                expectedBlock = block(id, kind, "")
            } else {
                expectedBlock = DocumentBlock(
                    id: id,
                    kind: kind,
                    inlineContent: .init(spans: []),
                    taskState: kind == .task ? .init(completedAt: nil) : nil,
                    indentLevel: 0
                )
            }
            return .init(
                label: "success-\(kind)",
                document: document,
                selection: caret(id, 4),
                kind: kind,
                expected: .init(
                    document: doc([expectedBlock]),
                    selection: caret(id, 0),
                    mutation: .document,
                    effect: .handled,
                    undo: .atomic(.conversion)
                )
            )
        }
        let linkDocument = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "/"),
                .init(text: "链接", linkURL: exactLinkURL)
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        fixtures.append(.init(
            label: "success-link",
            document: linkDocument,
            selection: caret(id, 1),
            kind: .link,
            expected: .init(
                document: doc([DocumentBlock(
                    id: id,
                    kind: .link,
                    inlineContent: .init(spans: [.init(text: "链接", linkURL: exactLinkURL)]),
                    taskState: nil,
                    indentLevel: 0
                )]),
                selection: caret(id, 0, attributes: .init(marks: [], linkURL: exactLinkURL)),
                mutation: .document,
                effect: .handled,
                undo: .atomic(.conversion)
            )
        ))

        let noSlash = doc([block(id, .paragraph, "cmd")])
        let nonleading = doc([block(id, .paragraph, "x/cmd")])
        let noncollapsed = doc([block(id, .paragraph, "/cmd")])
        let emptyLink = doc([block(id, .paragraph, "/link")])
        let noSlashSelection = caret(id, 3)
        let nonleadingSelection = caret(id, 5)
        let range = textSelection(id, 0, id, 4)
        let blockSelection = BlockEditorSelection.blocks(anchor: id, focus: id)
        fixtures.append(contentsOf: [
            .init(label: "no-slash", document: noSlash, selection: noSlashSelection, kind: .task, expected: exactNoChange(noSlash, noSlashSelection, .samePosition)),
            .init(label: "nonleading", document: nonleading, selection: nonleadingSelection, kind: .task, expected: exactNoChange(nonleading, nonleadingSelection, .samePosition)),
            .init(label: "noncollapsed", document: noncollapsed, selection: range, kind: .task, expected: exactNoChange(noncollapsed, range, .unsupportedBlockKind)),
            .init(label: "block-selection", document: noncollapsed, selection: blockSelection, kind: .task, expected: exactNoChange(noncollapsed, blockSelection, .unsupportedBlockKind)),
            .init(label: "empty-link", document: emptyLink, selection: caret(id, 5), kind: .link, expected: exactNoChange(emptyLink, caret(id, 5), .unsupportedBlockKind))
        ])
        return fixtures
    }()
}

private func blockID(_ value: Int) -> BlockID {
    BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
}

private let exactLinkURL = URL(string: "https://example.com/block")!
private let exactCompletedDate = Date(timeIntervalSince1970: 12_345)

private func exactNoChange(
    _ document: BlockDocument,
    _ selection: BlockEditorSelection,
    _ reason: BlockInputNoChangeReason
) -> BlockInputResult {
    .init(
        document: document,
        selection: selection,
        mutation: .none(reason),
        effect: .handled,
        undo: .none
    )
}

private func exactSoftBreakBlock(
    id: BlockID,
    kind: BlockKind,
    insertionOffset: Int,
    deletedUpper: Int?
) -> DocumentBlock {
    let source = Array("甲乙")
    let upper = deletedUpper ?? insertionOffset
    let left = String(source[..<insertionOffset])
    let right = String(source[upper...])
    let originalURL = kind == .link ? exactLinkURL : nil
    var spans: [InlineSpan] = []
    if !left.isEmpty { spans.append(.init(text: left, linkURL: originalURL)) }
    spans.append(.init(text: "\n"))
    if !right.isEmpty { spans.append(.init(text: right, linkURL: originalURL)) }
    let content = kind == .code
        ? InlineContent.plain(left + "\n" + right)
        : InlineContent(spans: spans)
    return .init(
        id: id,
        kind: kind,
        inlineContent: content,
        taskState: kind == .task ? .init(completedAt: exactCompletedDate) : nil,
        indentLevel: 0,
        codeInfoString: kind == .code ? "swift" : nil
    )
}

private func exactBackspaceDeletedBlock(id: BlockID, kind: BlockKind) -> DocumentBlock {
    .init(
        id: id,
        kind: kind,
        inlineContent: kind == .code
            ? .plain("乙")
            : .init(spans: [.init(text: "乙", linkURL: kind == .link ? exactLinkURL : nil)]),
        taskState: kind == .task ? .init(completedAt: exactCompletedDate) : nil,
        indentLevel: 0,
        codeInfoString: kind == .code ? "swift" : nil
    )
}

private func exactMergedBlock(previous: BlockID, current: DocumentBlock) -> DocumentBlock {
    .init(
        id: previous,
        kind: .paragraph,
        inlineContent: .init(spans: [.init(text: "前")] + current.inlineContent.spans),
        taskState: nil,
        indentLevel: 0
    )
}

private func describedTask(
    _ id: BlockID,
    _ text: String,
    description: String,
    completed: Date? = nil
) -> DocumentBlock {
    try! DocumentBlock.task(
        id: id,
        text: text,
        completedAt: completed,
        completionDescription: description
    )
}

private func block(
    _ id: BlockID,
    _ kind: BlockKind,
    _ text: String,
    indent: Int = 0,
    completed: Date? = nil,
    codeInfo: String? = nil
) -> DocumentBlock {
    .init(
        id: id,
        kind: kind,
        inlineContent: .plain(text),
        taskState: kind == .task ? .init(completedAt: completed) : nil,
        indentLevel: indent,
        codeInfoString: codeInfo
    )
}

private let allBlockKinds: [BlockKind] = [
    .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered,
    .task, .quote, .code, .divider, .link
]

private func expectedEnterResult(kind: BlockKind, id: BlockID, next: BlockID, offset: Int) -> BlockInputResult {
    let source = Array("甲乙")
    let leftText = String(source[..<offset])
    let rightText = String(source[offset...])
    let linkURL = URL(string: "https://example.com/block")!

    func fragment(_ value: String, linked: Bool = false, canonicalEmpty: Bool = false) -> InlineContent {
        if value.isEmpty, !canonicalEmpty { return .init(spans: []) }
        return .init(spans: [.init(text: value, linkURL: linked ? linkURL : nil)])
    }

    let leftKind: BlockKind = kind == .link && leftText.isEmpty ? .paragraph : kind
    let rightKind: BlockKind
    switch kind {
    case .heading1, .heading2, .heading3, .link: rightKind = .paragraph
    case .paragraph, .bullet, .ordered, .task, .quote, .code: rightKind = kind
    case .divider: rightKind = .paragraph
    }
    let left = DocumentBlock(
        id: id,
        kind: leftKind,
        inlineContent: fragment(leftText, linked: leftKind == .link, canonicalEmpty: leftKind == .code),
        taskState: leftKind == .task ? .init(completedAt: .distantPast) : nil,
        indentLevel: 0,
        codeInfoString: leftKind == .code ? "swift" : nil
    )
    let right = DocumentBlock(
        id: next,
        kind: rightKind,
        inlineContent: fragment(rightText, linked: kind == .link && !rightText.isEmpty, canonicalEmpty: rightKind == .code),
        taskState: rightKind == .task ? .init(completedAt: nil) : nil,
        indentLevel: 0,
        codeInfoString: rightKind == .code ? "swift" : nil
    )
    return .init(
        document: doc([left, right]),
        selection: caret(next, 0),
        mutation: .document,
        effect: .handled,
        undo: .atomic(.enter)
    )
}

private func validBlock(
    _ id: BlockID,
    _ kind: BlockKind,
    _ text: String,
    completed: Date? = nil,
    codeInfo: String? = nil
) -> DocumentBlock {
    if kind == .link {
        return .init(
            id: id,
            kind: .link,
            inlineContent: .init(spans: [.init(text: text, linkURL: URL(string: "https://example.com/block")!)]),
            taskState: nil,
            indentLevel: 0
        )
    }
    return block(id, kind, text, completed: completed, codeInfo: codeInfo)
}

private func doc(_ blocks: [DocumentBlock]) -> BlockDocument { .init(blocks: blocks) }
private func text(_ block: DocumentBlock) -> String { block.inlineContent.spans.map(\.text).joined() }
private func caret(
    _ id: BlockID,
    _ offset: Int,
    attributes: BlockTypingAttributes = .init(marks: [], linkURL: nil)
) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: id, graphemeOffset: offset),
        focus: .init(blockID: id, graphemeOffset: offset),
        preferredColumn: nil,
        typingAttributes: attributes
    )
}

private func textSelection(
    _ a: BlockID,
    _ ao: Int,
    _ f: BlockID,
    _ fo: Int,
    attributes: BlockTypingAttributes = .init(marks: [], linkURL: nil)
) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: a, graphemeOffset: ao),
        focus: .init(blockID: f, graphemeOffset: fo),
        preferredColumn: nil,
        typingAttributes: attributes
    )
}

private func reduce(
    _ document: BlockDocument,
    _ selection: BlockEditorSelection,
    _ command: BlockInputCommand,
    composing: Bool = false,
    ids: [BlockID] = []
) throws -> BlockInputResult {
    try BlockInputReducer.reduce(
        document,
        selection: selection,
        command: command,
        environment: .init(isComposingText: composing, idSource: .fixed(ids))
    )
}

private func attributesAt(_ document: BlockDocument, _ id: BlockID, _ offset: Int) -> BlockTypingAttributes {
    let block = document.blocks.first { $0.id == id }!
    let spans = block.inlineContent.spans
    var cursor = 0
    let target = offset > 0 ? offset - 1 : offset
    for span in spans where !span.text.isEmpty {
        let count = span.text.count
        if target >= cursor && target < cursor + count {
            return .init(marks: span.marks, linkURL: span.linkURL)
        }
        cursor += count
    }
    return .init(marks: [], linkURL: nil)
}
