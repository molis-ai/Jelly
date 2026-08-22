import AppKit
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorAccessibilityTests")
@MainActor
struct BlockEditorAccessibilityTests {
    @Test func continuousAccessibilityTreeHasOneBodyNoPerBlockStopsAndActionableTasks() throws {
        let paragraph = projectionBlock(BlockID(), .paragraph, "正文")
        let task = projectionBlock(BlockID(), .task, "可执行待办")
        let document = BlockDocument(blocks: [paragraph, task])
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
            initialSelection: projectionCaret(paragraph.id, 0),
            focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
        host.frame = .init(x: 0, y: 0, width: 600, height: 180)
        session.attach(host: host, hostToken: UUID())
        host.layoutSubtreeIfNeeded()

        let bodies = accessibilityDescendants(of: host, as: ContinuousBlockEditorTextView.self)
        let textAreas = accessibilityDescendants(of: host, as: NSTextView.self).filter {
            $0.accessibilityRole() == .textArea
        }
        let buttons = accessibilityDescendants(of: host, as: NSButton.self)
        let taskButton = try #require(buttons.first)
        #expect(bodies.count == 1)
        #expect(textAreas.count == 1)
        #expect(taskButton.accessibilityRole() == .checkBox)
        #expect(taskButton.accessibilityLabel() == "完成待办")
        #expect(taskButton.accessibilityValue() as? String == "未完成")

        taskButton.performClick(taskButton)
        #expect(session.document.blocks[1].taskState?.completedAt != nil)
        #expect(taskButton.accessibilityLabel() == "重开待办")
        #expect(taskButton.accessibilityValue() as? String == "已完成")
    }

    @Test func taskCompletionDescriptionIsStaticTextAndDoesNotBecomeAnEditableBody() throws {
        let paragraph = projectionBlock(BlockID(), .paragraph, "正文")
        let task = try DocumentBlock.task(
            text: "给物业打电话",
            completionDescription: "拿到明确上门时间"
        )
        let document = BlockDocument(blocks: [paragraph, task])
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
            initialSelection: projectionCaret(paragraph.id, 0),
            focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
        host.frame = .init(x: 0, y: 0, width: 600, height: 220)
        session.attach(host: host, hostToken: UUID())
        host.layoutSubtreeIfNeeded()

        let bodies = accessibilityDescendants(of: host, as: ContinuousBlockEditorTextView.self)
        let textAreas = accessibilityDescendants(of: host, as: NSTextView.self).filter {
            $0.accessibilityRole() == .textArea
        }
        let label = try #require(accessibilityDescendants(of: host, as: NSTextField.self).first {
            $0.accessibilityIdentifier() == "task-block-completion-\(task.id.rawValue.uuidString)"
        })
        #expect(bodies.count == 1)
        #expect(textAreas.count == 1)
        #expect(label.accessibilityRole() == .staticText)
        #expect(label.accessibilityLabel() == "完成说明")
        #expect(label.accessibilityValue() == "拿到明确上门时间")
        #expect(label.isEditable == false)
        #expect(host.taskCompletionDescriptionOverlay.hitTest(label.frame.origin) == nil)
    }

    @Test func reducedMotionKeepsAllEditorStatesAndActionsAvailable() {
        let reduced = CalendarMotionPolicy(reduceMotion: true)
        #expect(reduced.snapAnimation == nil)
        #expect(reduced.overlayAnimation == nil)
        #expect(reduced.shouldPresentOverlays)
        #expect(reduced.shouldAlignToWeek)
        #expect(BlockFormattingAction.allCases.count == 13)
        #expect(BlockFormattingAction.allCases.allSatisfy { !$0.accessibilityLabel.isEmpty })
    }

    @Test func fixedFormattingBarDefinesEveryHumanAndAgentReadableAction() {
        let actions = BlockFormattingAction.allCases
        #expect(actions.map(\.accessibilityIdentifier) == [
            "block-format-paragraph", "block-format-heading-1", "block-format-heading-2",
            "block-format-heading-3", "block-format-bold", "block-format-italic",
            "block-format-code", "block-format-bullet", "block-format-ordered",
            "block-format-task", "block-format-quote", "block-format-divider", "block-format-link"
        ])
        #expect(actions.allSatisfy { !$0.accessibilityLabel.isEmpty })
        #expect(Set(actions.map(\.accessibilityLabel)).count == actions.count)
    }

    @Test func pasteboardRetainsAllCharactersInPlainFallbackAndDropsUnsupportedStyling() throws {
        let text = "甲\u{FFFC}乙"
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: .init(location: 0, length: attributed.length))
        let adapter = BlockPasteboardAdapter(pasteboard: .withUniqueName())

        try adapter.write(attributedString: attributed)
        let payload = try #require(adapter.readPayload())
        #expect(payload.fallbackPlainText == text)
        #expect(payload.fallbackPlainText == attributed.string)
    }

    @Test func accessibilityDescriptionUsesStableBlockIdentityAndDeterministicPosition() {
        let first = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000801")!)
        let second = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000802")!)
        let description = BlockAccessibilityDescriptor(
            blockID: second, index: 1, totalCount: 2, kind: .paragraph, value: "内容", isSelected: true
        )

        #expect(description.identifier == second.rawValue.uuidString)
        #expect(description.positionAnnouncement == "第 2 项，共 2 项")
        #expect(description.role == .textArea)
        #expect(description.isSelected)
        #expect(description.reorderActions == ["Move Up", "Move Down"])
        #expect(first != second)
    }

    @Test func slashMenuDismissalDoesNotReopenForSameRevision() {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000803")!)
        var menu = BlockSlashMenuState.open(blockID: id, queryRange: 0..<2, query: "he", revision: 3)
        menu.dismiss(revision: 3)

        #expect(menu.shouldOpen(blockID: id, queryRange: 0..<2, query: "he", revision: 3) == false)
        #expect(menu.shouldOpen(blockID: id, queryRange: 0..<3, query: "hea", revision: 4))
    }

    @Test func richAttributedPasteSplitsPhysicalLinesAndInvalidCustomDataFallsBackToFullString() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        let attributed = NSAttributedString(string: "甲\r\n乙\n丙")
        try adapter.write(attributedString: attributed)
        let rich = try #require(adapter.readPayload())
        guard case let .richText(blocks, fallbackPlainText) = rich else {
            Issue.record("expected v1 rich payload")
            return
        }
        #expect(blocks.map { $0.inlineContent.spans.map(\.text).joined() } == ["甲", "乙", "丙"])
        #expect(fallbackPlainText == attributed.string)

        pasteboard.clearContents()
        _ = pasteboard.setString("完整回退文本", forType: .string)
        _ = pasteboard.setData(Data("{\"version\":3,\"plainText\":\"错误\",\"blocks\":[]}".utf8), forType: BlockPasteboardAdapter.privateType)
        #expect(adapter.readPayload() == .plainText("完整回退文本"))
    }

    @Test func plainPasteboardFailureBlocksPublicationWhileCustomFailureRetainsMandatoryPlainText() {
        let payload = BlockClipboardPayload(plainText: "完整文本", richBlocks: [])
        let plainFailureBoard = NSPasteboard.withUniqueName()
        let plainFailure = BlockPasteboardAdapter(
            pasteboard: plainFailureBoard,
            plainTextWriter: { _, _ in false },
            customDataWriter: { _, _ in true }
        )
        #expect(plainFailure.write(payload: payload) == false)
        #expect(plainFailureBoard.string(forType: .string) == nil)

        let customFailureBoard = NSPasteboard.withUniqueName()
        let customFailure = BlockPasteboardAdapter(
            pasteboard: customFailureBoard,
            plainTextWriter: { board, text in board.setString(text, forType: .string) },
            customDataWriter: { _, _ in false }
        )
        #expect(customFailure.write(payload: payload))
        #expect(customFailureBoard.string(forType: .string) == "完整文本")
    }

    @Test func sameBlockTextClipboardRoundTripsAsInlineContent() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        let content = InlineContent(spans: [
            .init(text: "保留", marks: [.bold]),
            .init(text: "行内", marks: [.italic])
        ])
        let payload = BlockClipboardPayload(
            plainText: "保留行内",
            richBlocks: [
                .init(kind: .paragraph, inlineContent: content, indentLevel: 0, codeInfoString: nil)
            ],
            inlineContent: content
        )

        #expect(adapter.write(payload: payload))
        #expect(adapter.readPayload() == .inlineContent(content, fallbackPlainText: "保留行内"))
        #expect(pasteboard.string(forType: .string) == "保留行内")
    }

    @Test func pasteboardCorruptInvalidAndUnsafeRichDataFallBackWithoutIDsOrUnsupportedStyles() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        let attributed = NSMutableAttributedString(string: "甲\u{FFFC}乙")
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: .init(location: 0, length: attributed.length))
        attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: .init(location: 0, length: attributed.length))
        attributed.addAttribute(.link, value: try #require(URL(string: "https://example.com/%00")), range: .init(location: 0, length: attributed.length))
        try adapter.write(attributedString: attributed)
        let rich = try #require(adapter.readPayload())
        guard case let .richText(blocks, fallback) = rich else {
            Issue.record("expected private v1 payload")
            return
        }
        #expect(fallback == attributed.string)
        #expect(blocks[0].inlineContent.spans.map(\.text).joined() == "甲\u{FFFC}乙")
        #expect(blocks[0].inlineContent.spans.allSatisfy { !$0.marks.contains(.code) && $0.linkURL == nil })
        let encoded = try #require(pasteboard.data(forType: BlockPasteboardAdapter.privateType))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("00000000-0000-0000-0000-000000000809"))

        pasteboard.clearContents()
        _ = pasteboard.setString("完整普通回退", forType: .string)
        _ = pasteboard.setData(Data("not JSON".utf8), forType: BlockPasteboardAdapter.privateType)
        #expect(adapter.readPayload() == .plainText("完整普通回退"))

        let validPayload = BlockClipboardPayload(
            plainText: "有效普通文本",
            richBlocks: [.init(kind: .paragraph, inlineContent: .plain("有效普通文本"), indentLevel: 0, codeInfoString: nil)]
        )
        #expect(adapter.write(payload: validPayload))
        let validData = try #require(pasteboard.data(forType: BlockPasteboardAdapter.privateType))
        var envelope = try #require(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        var blockDTOs = try #require(envelope["blocks"] as? [[String: Any]])
        blockDTOs[0]["indentLevel"] = -1
        envelope["blocks"] = blockDTOs
        let invalidData = try JSONSerialization.data(withJSONObject: envelope)
        pasteboard.clearContents()
        _ = pasteboard.setString("有效普通文本", forType: .string)
        _ = pasteboard.setData(invalidData, forType: BlockPasteboardAdapter.privateType)
        #expect(adapter.readPayload() == .plainText("有效普通文本"))
    }

    @Test func externalRTFPasteUsesSupportedInlineMarksAndPreservesPlainFallback() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        let attributed = NSMutableAttributedString(string: "粗体\n普通")
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: .init(location: 0, length: 2))
        attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: .init(location: 0, length: attributed.length))
        let rtf = try attributed.data(
            from: .init(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.clearContents()
        _ = pasteboard.setString(attributed.string, forType: .string)
        _ = pasteboard.setData(rtf, forType: .rtf)

        let payload = try #require(adapter.readPayload())
        guard case let .richText(blocks, fallback) = payload else {
            Issue.record("external RTF should not be downgraded while supported spans exist")
            return
        }
        #expect(fallback == "粗体\n普通")
        #expect(blocks.map { $0.inlineContent.spans.map(\.text).joined() } == ["粗体", "普通"])
        #expect(blocks[0].inlineContent.spans.allSatisfy { $0.marks.contains(.bold) })
        #expect(blocks.allSatisfy { $0.kind == .paragraph })
    }

    @Test func selectorMatrixDefersCompositionAndRoutesSupportedCommandsOnce() {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000804")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("甲"), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 1), focus: .init(blockID: id, graphemeOffset: 1), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let view = BlockEditorTextView()
        let hostToken = UUID()
        session.attach(blockID: id, hostToken: hostToken, textView: view)
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(session.selection == .text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)))
        view.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 0, length: 0))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(session.document == document)
    }

    @Test func slashStateOpensOnlyForLeadingCollapsedParagraphAndCompositionClosesIt() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000805")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        _ = try session.dispatch(.insertText("/he"))
        #expect(session.slashMenuState?.blockID == id)
        #expect(session.slashMenuState?.query == "he")

        let view = BlockEditorTextView()
        let hostToken = UUID()
        session.attach(blockID: id, hostToken: hostToken, textView: view)
        view.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 3, length: 0))
        #expect(session.slashMenuState == nil)
        view.cancelOperation(nil)
        #expect(session.slashMenuState?.query == "he")
    }

    @Test func slashDismissalIsRevisionBoundAndStaleConfirmationCannotDispatch() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000806")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        _ = try session.dispatch(.insertText("/h"))
        let opened = try #require(session.slashMenuState)
        session.dismissSlashMenu(expected: opened)
        #expect(session.slashMenuState == nil)
        #expect(session.confirmSlash(kind: .heading1, expected: opened) == false)
        _ = try session.dispatch(.insertText("e"))
        #expect(session.slashMenuState?.query == "he")
        let current = try #require(session.slashMenuState)
        #expect(session.confirmSlash(kind: .heading1, expected: current))
        #expect(session.document.blocks[0].kind == .heading1)
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "")
    }

    @Test func slashTextViewSelectorsClampConfirmAndDismissExactlyOnce() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000807")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        var callbacks = 0
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 })
        let view = BlockEditorTextView()
        session.attach(blockID: id, hostToken: UUID(), textView: view)
        _ = try session.dispatch(.insertText("/q"))
        let opened = try #require(session.slashMenuState)
        #expect(opened.selectedIndex == 0)
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let movedDown = try #require(session.slashMenuState)
        #expect(movedDown.selectedIndex == 1)
        view.doCommand(by: #selector(NSResponder.moveUp(_:)))
        let movedUp = try #require(session.slashMenuState)
        #expect(movedUp.selectedIndex == 0)
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(session.document.blocks[0].kind == .paragraph)
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "")
        #expect(callbacks == 2)
        #expect(session.undoManager.canUndo)
        #expect(session.confirmSlash(kind: .heading1, expected: movedUp) == false)
        #expect(callbacks == 2)

        let dismissSession = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let dismissView = BlockEditorTextView()
        dismissSession.attach(blockID: id, hostToken: UUID(), textView: dismissView)
        _ = try dismissSession.dispatch(.insertText("/keep"))
        dismissView.cancelOperation(nil)
        #expect(dismissSession.slashMenuState == nil)
        #expect(dismissSession.document.blocks[0].inlineContent.spans.map(\.text).joined() == "/keep")
        #expect(dismissSession.handleSlashSelector(#selector(NSResponder.cancelOperation(_:))) == false)
    }

    @Test func slashNeverOpensForCompositionPartialNonleadingSelectionOrNonparagraph() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000808")!)
        let textSelection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let nonleading = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(),
            initialDocument: .init(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("x/partial"), taskState: nil, indentLevel: 0)]),
            initialSelection: .text(anchor: .init(blockID: id, graphemeOffset: 9), focus: .init(blockID: id, graphemeOffset: 9), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)),
            focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let nonleadingView = BlockEditorTextView()
        let nonleadingToken = UUID()
        nonleading.attach(blockID: id, hostToken: nonleadingToken, textView: nonleadingView)
        nonleading.updateNativeSelection(blockID: id, range: .init(location: 9, length: 0), hostToken: nonleadingToken)
        #expect(nonleading.slashMenuState == nil)

        let selectionSession = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(),
            initialDocument: .init(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("/partial"), taskState: nil, indentLevel: 0)]),
            initialSelection: textSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let selectionView = BlockEditorTextView()
        let selectionToken = UUID()
        selectionSession.attach(blockID: id, hostToken: selectionToken, textView: selectionView)
        selectionSession.updateNativeSelection(blockID: id, range: .init(location: 0, length: 1), hostToken: selectionToken)
        #expect(selectionSession.slashMenuState == nil)

        let headingSession = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(),
            initialDocument: .init(blocks: [.init(id: id, kind: .heading1, inlineContent: .plain("/title"), taskState: nil, indentLevel: 0)]),
            initialSelection: textSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let headingView = BlockEditorTextView()
        let headingToken = UUID()
        headingSession.attach(blockID: id, hostToken: headingToken, textView: headingView)
        headingSession.updateNativeSelection(blockID: id, range: .init(location: 6, length: 0), hostToken: headingToken)
        #expect(headingSession.slashMenuState == nil)

        let composition = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: .init(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)]), initialSelection: textSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let compositionView = BlockEditorTextView()
        let compositionToken = UUID()
        composition.attach(blockID: id, hostToken: compositionToken, textView: compositionView)
        _ = try composition.dispatch(.insertText("/compose"))
        compositionView.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 8, length: 0))
        let before = composition.document
        compositionView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        compositionView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        compositionView.cancelOperation(nil)
        #expect(composition.document == before)
        #expect(composition.slashMenuState?.query == "compose")
    }

    @Test func textViewRoutesEveryStructuralAndMovementSelectorWithoutDuplicatePublication() {
        let structural: [(Selector, Bool)] = [
            (#selector(NSResponder.insertNewline(_:)), true),
            (#selector(NSResponder.insertLineBreak(_:)), true),
            (#selector(NSResponder.deleteBackward(_:)), true),
            (#selector(NSResponder.insertTab(_:)), false),
            (#selector(NSResponder.insertBacktab(_:)), false)
        ]
        for (selector, mutates) in structural {
            let fixture = selectorFixture(selection: 1..<1)
            fixture.view.doCommand(by: selector)
            #expect(fixture.counter.value == (mutates ? 1 : 0))
            #expect(fixture.counter.value <= 1)
        }

        let movements: [Selector] = [
            #selector(NSResponder.moveLeft(_:)),
            #selector(NSResponder.moveRight(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveRightAndModifySelection(_:)),
            #selector(NSResponder.moveUpAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:))
        ]
        for selector in movements {
            let fixture = selectorFixture(selection: 1..<1)
            fixture.view.doCommand(by: selector)
            #expect(fixture.counter.value == 0)
            #expect(fixture.session.undoManager.canUndo == false)
        }
    }

    @Test func textViewRoutesInsertClipboardAndSupportedFormattingShortcutsExactlyOnce() throws {
        let selectedInsert = selectorFixture(selection: 0..<1)
        selectedInsert.view.insertText("Z", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(selectedInsert.counter.value == 1)
        #expect(selectedInsert.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "Zbc")

        let explicitInsert = selectorFixture(selection: 0..<0)
        explicitInsert.view.insertText("Z", replacementRange: .init(location: 1, length: 1))
        #expect(explicitInsert.counter.value == 1)
        #expect(explicitInsert.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "aZc")

        let copy = selectorFixture(selection: 0..<1)
        copy.view.copy(nil)
        #expect(copy.counter.value == 0)
        #expect(copy.session.undoManager.canUndo == false)

        let cut = selectorFixture(selection: 0..<1)
        cut.view.cut(nil)
        #expect(cut.counter.value == 1)
        #expect(cut.session.undoManager.canUndo)

        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString("粘", forType: .string)
        let paste = selectorFixture(selection: 1..<1)
        paste.view.paste(nil)
        #expect(paste.counter.value == 1)
        #expect(paste.session.undoManager.canUndo)

        for (key, modifiers) in [("b", NSEvent.ModifierFlags.command), ("i", .command), ("c", [.command, .shift])] {
            let formatting = selectorFixture(selection: 0..<1)
            #expect(formatting.view.performKeyEquivalent(with: try keyEvent(characters: key, modifiers: modifiers)))
            #expect(formatting.counter.value == 1)
            #expect(formatting.session.undoManager.canUndo)
        }
    }

    @Test func composingDefersEverySensitiveSelectorThenCommitsOnlyAtTerminalTransition() throws {
        let fixture = selectorFixture(selection: 1..<1)
        let before = fixture.session.document
        fixture.view.setMarkedText("pin", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        let composingSelectors: [Selector] = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertLineBreak(_:)),
            #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)),
            #selector(NSResponder.moveLeft(_:)),
            #selector(NSResponder.moveRight(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveRightAndModifySelection(_:)),
            #selector(NSResponder.moveUpAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:))
        ]
        for selector in composingSelectors {
            fixture.view.doCommand(by: selector)
            #expect(fixture.session.document == before)
            #expect(fixture.counter.value == 0)
        }
        #expect(fixture.session.handleSlashSelector(#selector(NSResponder.insertNewline(_:))) == false)
        fixture.view.insertText("中", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(fixture.counter.value == 1)
        #expect(fixture.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中bc")
        fixture.view.unmarkText()
        #expect(fixture.counter.value == 1)

        fixture.view.setMarkedText("x", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        fixture.view.cancelOperation(nil)
        #expect(fixture.counter.value == 1)
        #expect(fixture.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中bc")
    }

    @Test func installedTextViewRejectsInvalidBridgeEmptyPasteAndCutWithoutNativeStorageBypass() {
        let fixture = selectorFixture(selection: 1..<1)
        let original = fixture.session.document
        fixture.view.applyAuthoritativeProjection(text: "abc", selectedRange: .init(location: 0, length: 1))
        fixture.view.insertText("X", replacementRange: .init(location: 99, length: 0))
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        #expect(fixture.counter.value == 0)

        NSPasteboard.general.clearContents()
        fixture.view.paste(nil)
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        fixture.view.cut(nil)
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        #expect(fixture.counter.value == 0)
    }

    @Test func invalidAndStaleMarkedRangesPlusUnsupportedSelectorsCannotEscapeAuthoritativeStorage() throws {
        let fixture = selectorFixture(selection: 1..<1)
        let original = fixture.session.document
        fixture.view.setMarkedText(
            "X", selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: 99, length: 0)
        )
        #expect(fixture.session.document == original)
        #expect(fixture.session.isComposing == false)
        #expect(fixture.view.string == "abc")

        let id = fixture.session.document.blocks[0].id
        let replacement = BlockEditorTextView()
        fixture.session.attach(blockID: id, hostToken: UUID(), textView: replacement)
        fixture.view.setMarkedText(
            "stale", selectedRange: .init(location: 5, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        #expect(fixture.session.isComposing == false)

        let selectors: [Selector] = [
            #selector(NSResponder.deleteForward(_:)),
            #selector(NSResponder.deleteWordBackward(_:)),
            #selector(NSResponder.deleteWordForward(_:)),
            #selector(NSResponder.deleteToBeginningOfLine(_:)),
            #selector(NSResponder.deleteToEndOfLine(_:)),
            #selector(NSResponder.deleteToBeginningOfParagraph(_:)),
            #selector(NSResponder.deleteToEndOfParagraph(_:)),
            #selector(NSResponder.transpose(_:)),
            #selector(NSResponder.transposeWords(_:)),
            #selector(NSResponder.uppercaseWord(_:)),
            #selector(NSResponder.lowercaseWord(_:)),
            #selector(NSResponder.capitalizeWord(_:)),
            #selector(NSResponder.yank(_:))
        ]
        for selector in selectors {
            let protected = selectorFixture(selection: 1..<1)
            protected.view.doCommand(by: selector)
            #expect(protected.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "abc")
            #expect(protected.view.string == "abc", Comment(rawValue: selector.description))
            #expect(protected.counter.value == 0)
        }

        let service = selectorFixture(selection: 1..<2)
        let serviceBoard = NSPasteboard.withUniqueName()
        serviceBoard.clearContents()
        _ = serviceBoard.setString("SERVICE", forType: .string)
        #expect(service.view.readSelection(from: serviceBoard, type: .string) == false)
        #expect(service.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "abc")
        #expect(service.view.string == "abc")

        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString("PASTE", forType: .string)
        let paste = selectorFixture(selection: 1..<2)
        paste.view.paste(nil)
        #expect(paste.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "aPASTEc")
        #expect(paste.view.string == "aPASTEc")
        #expect(paste.counter.value == 1)
    }

    @Test func composingSelectorsReallyDeferThroughTheTextSystemThenTerminallyRejoinSessionTruth() {
        let fixture = selectorFixture(selection: 1..<1)
        let original = fixture.session.document
        fixture.view.setMarkedText(
            "pin", selectedRange: .init(location: 3, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        let beforeTextSystemCommand = fixture.view.string
        fixture.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(fixture.view.string != beforeTextSystemCommand)
        #expect(fixture.session.document == original)
        #expect(fixture.counter.value == 0)
        fixture.view.cancelOperation(nil)
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        #expect(fixture.session.isComposing == false)
    }

    @Test func anyPresentInvalidPrivatePayloadUsesCompleteAppKitStringWithoutApplyingRichData() throws {
        let board = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: board)
        let rtfSource = NSAttributedString(string: "CONFLICTING RTF")
        let rtf = try rtfSource.data(
            from: .init(location: 0, length: rtfSource.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let privateCandidates: [Data] = [
            Data("not json".utf8),
            Data("{\"version\":3,\"plainText\":\"PRIVATE\",\"blocks\":[]}".utf8),
            Data("{\"version\":1,\"plainText\":\"PRIVATE\",\"blocks\":[{\"kind\":\"paragraph\",\"spans\":[{\"text\":\"x\",\"marks\":[],\"linkURL\":null}],\"indentLevel\":9,\"codeInfoString\":null}]}".utf8)
        ]
        for data in privateCandidates {
            board.clearContents()
            _ = board.setString("COMPLETE", forType: .string)
            _ = board.setData(data, forType: BlockPasteboardAdapter.privateType)
            _ = board.setData(rtf, forType: .rtf)
            #expect(adapter.readPayload() == .plainText("COMPLETE"))
        }

        board.clearContents()
        _ = board.setData(Data("not json".utf8), forType: BlockPasteboardAdapter.privateType)
        _ = board.setData(rtf, forType: .rtf)
        #expect(adapter.readPayload() == .plainText("CONFLICTING RTF"))

        board.clearContents()
        _ = board.setData(Data("not json".utf8), forType: BlockPasteboardAdapter.privateType)
        #expect(adapter.readPayload() == nil)

        let sameItem = NSPasteboardItem()
        sameItem.setData(Data("not json".utf8), forType: BlockPasteboardAdapter.privateType)
        sameItem.setString("SAME ITEM", forType: .string)
        sameItem.setData(rtf, forType: .rtf)
        board.clearContents()
        #expect(board.writeObjects([sameItem]))
        #expect(adapter.readPayload() == .plainText("SAME ITEM"))

        let stringAfterRTF = NSPasteboardItem()
        stringAfterRTF.setData(Data("not json".utf8), forType: BlockPasteboardAdapter.privateType)
        stringAfterRTF.setData(rtf, forType: .rtf)
        stringAfterRTF.setString("STRING AFTER RTF", forType: .string)
        board.clearContents()
        #expect(board.writeObjects([stringAfterRTF]))
        #expect(adapter.readPayload() == .plainText("STRING AFTER RTF"))

        let sameTextAfterRTF = NSPasteboardItem()
        sameTextAfterRTF.setData(Data("not json".utf8), forType: BlockPasteboardAdapter.privateType)
        sameTextAfterRTF.setData(rtf, forType: .rtf)
        sameTextAfterRTF.setString("CONFLICTING RTF", forType: .string)
        board.clearContents()
        #expect(board.writeObjects([sameTextAfterRTF]))
        #expect(adapter.readPayload() == .plainText("CONFLICTING RTF"))

        let explicitStringBesideBrokenRTF = NSPasteboardItem()
        explicitStringBesideBrokenRTF.setData(Data("not json".utf8), forType: BlockPasteboardAdapter.privateType)
        explicitStringBesideBrokenRTF.setData(Data("broken rtf".utf8), forType: .rtf)
        explicitStringBesideBrokenRTF.setString("EXPLICIT STRING", forType: .string)
        board.clearContents()
        #expect(board.writeObjects([explicitStringBesideBrokenRTF]))
        #expect(adapter.readPayload() == .plainText("EXPLICIT STRING"))

        for privateFirst in [true, false] {
            let privateItem = NSPasteboardItem()
            privateItem.setData(Data("not json".utf8), forType: BlockPasteboardAdapter.privateType)
            privateItem.setData(rtf, forType: .rtf)
            let stringItem = NSPasteboardItem()
            stringItem.setString(privateFirst ? "PRIVATE FIRST" : "STRING FIRST", forType: .string)
            board.clearContents()
            #expect(board.writeObjects(privateFirst ? [privateItem, stringItem] : [stringItem, privateItem]))
            #expect(
                adapter.readPayload() == .plainText(
                    privateFirst
                        ? "CONFLICTING RTF\nPRIVATE FIRST"
                        : "STRING FIRST\nCONFLICTING RTF"
                )
            )
        }
    }

    @Test func attributedLinksAcceptFoundationRepresentationsThroughOneValidatorAndStripOnlyUnsafeStyle() throws {
        let safe = "https://example.com/path"
        let safeValues: [Any] = [
            try #require(URL(string: safe)),
            try #require(NSURL(string: safe)),
            safe,
            safe as NSString
        ]
        for value in safeValues {
            let board = NSPasteboard.withUniqueName()
            let adapter = BlockPasteboardAdapter(pasteboard: board)
            let attributed = NSMutableAttributedString(string: "link")
            attributed.addAttribute(.link, value: value, range: .init(location: 0, length: 4))
            try adapter.write(attributedString: attributed)
            guard case let .richText(blocks, fallback) = try #require(adapter.readPayload()) else {
                Issue.record("expected rich payload")
                continue
            }
            #expect(fallback == "link")
            #expect(blocks[0].inlineContent.spans.map(\.text).joined() == "link")
            #expect(blocks[0].inlineContent.spans[0].linkURL == URL(string: safe))
        }

        for unsafeURL in ["https://example.com/%00", "https://example.com/%01"] {
            let board = NSPasteboard.withUniqueName()
            let adapter = BlockPasteboardAdapter(pasteboard: board)
            let attributed = NSMutableAttributedString(string: "unsafe")
            attributed.addAttribute(.link, value: unsafeURL as NSString, range: .init(location: 0, length: 6))
            try adapter.write(attributedString: attributed)
            guard case let .richText(blocks, fallback) = try #require(adapter.readPayload()) else {
                Issue.record("expected rich payload")
                continue
            }
            #expect(fallback == "unsafe")
            #expect(blocks[0].inlineContent.spans.map(\.text).joined() == "unsafe")
            #expect(blocks[0].inlineContent.spans.allSatisfy { $0.linkURL == nil })
        }
    }

    @Test func productionInsertAndIMEApplyEveryMarkdownShortcutAsOneCallbackAndOneUndo() throws {
        let cases: [(String, BlockKind, String?)] = [
            ("# ", .heading1, nil), ("## ", .heading2, nil), ("### ", .heading3, nil),
            ("- ", .bullet, nil), ("* ", .bullet, nil), ("1. ", .ordered, nil),
            ("[] ", .task, nil), ("[ ] ", .task, nil), ("> ", .quote, nil),
            ("``` ", .code, nil), ("```swift ", .code, "swift")
        ]
        for (prefix, kind, codeInfo) in cases {
            let fixture = markdownProductionFixture()
            fixture.view.insertText(prefix, replacementRange: .init(location: NSNotFound, length: 0))
            #expect(fixture.session.document.blocks[0].kind == kind, Comment(rawValue: prefix.debugDescription))
            #expect(fixture.session.document.blocks[0].codeInfoString == codeInfo)
            #expect(fixture.session.document.blocks[0].inlineContent.spans.map(\.text).joined().isEmpty)
            #expect(fixture.counter.value == 1)
            fixture.session.undoManager.undo()
            #expect(fixture.session.document == fixture.original)
            fixture.session.undoManager.redo()
            #expect(fixture.session.document.blocks[0].kind == kind)
        }

        let ime = markdownProductionFixture()
        ime.view.setMarkedText(
            "# ", selectedRange: .init(location: 2, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        ime.view.insertText("# ", replacementRange: .init(location: NSNotFound, length: 0))
        ime.view.unmarkText()
        #expect(ime.session.document.blocks[0].kind == .heading1)
        #expect(ime.counter.value == 1)
        #expect(ime.session.undoManager.canUndo)

        for value in ["中文🙂", "#", "#### "] {
            let rejected = markdownProductionFixture()
            rejected.view.insertText(value, replacementRange: .init(location: NSNotFound, length: 0))
            #expect(rejected.session.document.blocks[0].kind == .paragraph)
            #expect(rejected.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == value)
            #expect(rejected.counter.value == 1)
        }
    }

    @Test func productionProjectionCarriesInlineSpansAndDistinctVisualSemanticsForEveryBlockKind() throws {
        let link = try #require(URL(string: "https://example.com/visual"))
        let ids = (0..<11).map { _ in BlockID() }
        let blocks: [DocumentBlock] = [
            .init(id: ids[0], kind: .paragraph, inlineContent: .init(spans: [
                .init(text: "B", marks: [.bold]), .init(text: "I", marks: [.italic]),
                .init(text: "C", marks: [.code]), .init(text: "L", linkURL: link)
            ]), taskState: nil, indentLevel: 0),
            projectionBlock(ids[1], .heading1, "H1"), projectionBlock(ids[2], .heading2, "H2"),
            projectionBlock(ids[3], .heading3, "H3"), projectionBlock(ids[4], .bullet, "Bullet"),
            projectionBlock(ids[5], .ordered, "Ordered"),
            .init(id: ids[6], kind: .task, inlineContent: .plain("Task"), taskState: .init(completedAt: Date(timeIntervalSince1970: 1)), indentLevel: 0),
            projectionBlock(ids[7], .quote, "Quote"), projectionBlock(ids[8], .code, "Code"),
            projectionBlock(ids[9], .divider, ""),
            .init(id: ids[10], kind: .link, inlineContent: .init(spans: [.init(text: "Link", linkURL: link)]), taskState: nil, indentLevel: 0)
        ]
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: .init(blocks: blocks),
            initialSelection: projectionCaret(ids[0], 0), focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        var views: [BlockID: BlockEditorTextView] = [:]
        for block in blocks {
            let view = BlockEditorTextView()
            session.attach(blockID: block.id, hostToken: UUID(), textView: view)
            views[block.id] = view
        }
        let paragraph = try #require(views[ids[0]]?.textStorage)
        let bold = try #require(paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let italic = try #require(paragraph.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.italic))
        #expect((paragraph.attribute(NSAttributedString.Key("com.adeptify.jelly.inline-code"), at: 2, effectiveRange: nil) as? Bool) == true)
        #expect((paragraph.attribute(.link, at: 3, effectiveRange: nil) as? URL) == link)

        let bodyFont = try #require(bold as NSFont?)
        let h1 = try projectionFont(views[ids[1]])
        let h2 = try projectionFont(views[ids[2]])
        let h3 = try projectionFont(views[ids[3]])
        #expect(h1.pointSize > h2.pointSize && h2.pointSize > h3.pointSize && h3.pointSize > bodyFont.pointSize)
        #expect(try projectionParagraph(views[ids[4]]).headIndent > 0)
        #expect(try projectionParagraph(views[ids[5]]).headIndent > 0)
        #expect(try projectionParagraph(views[ids[7]]).headIndent > 0)
        #expect(try projectionFont(views[ids[8]]).fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(views[ids[8]]?.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(views[ids[6]]?.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil)
        #expect(views[ids[10]]?.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
        #expect(views[ids[9]]?.accessibilityRole() == .splitter)
    }

    @Test func fixedFormattingBarNeverMovesWithSelectionAndKeepsEveryActionKeyboardReachable() throws {
        _ = NSApplication.shared
        let id = BlockID()
        let link = try #require(URL(string: "https://example.com/control"))
        let document = BlockDocument(blocks: [.init(
            id: id, kind: .paragraph,
            inlineContent: .init(spans: [.init(text: "link", linkURL: link)]),
            taskState: nil, indentLevel: 0
        )])
        var callbacks = 0
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
            initialSelection: .text(
                anchor: .init(blockID: id, graphemeOffset: 0),
                focus: .init(blockID: id, graphemeOffset: 4), preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            ), focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 }
        )
        let root = VStack {
            ContinuousBlockEditorRepresentable(session: session, appearance: CalendarTheme.light)
            BlockFormattingBar(session: session, requestLinkURL: { link })
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 500, height: 240)
        hosting.layoutSubtreeIfNeeded()
        let buttons = accessibilityDescendants(of: hosting, as: NSButton.self)
        let identifiers = Set(buttons.compactMap { $0.accessibilityIdentifier() })
        #expect(identifiers.isSuperset(of: Set(BlockFormattingAction.allCases.map(\.accessibilityIdentifier))))
        #expect(identifiers.contains("block-format-toggle"))
        for action in BlockFormattingAction.allCases {
            let button = try #require(buttons.first {
                $0.accessibilityIdentifier() == action.accessibilityIdentifier
            })
            #expect(button.accessibilityLabel() == action.accessibilityLabel)
        }
        let bold = try #require(buttons.first { $0.accessibilityIdentifier() == "block-format-bold" })
        let linkButton = try #require(buttons.first { $0.accessibilityIdentifier() == "block-format-link" })
        #expect(bold.acceptsFirstResponder)
        #expect(linkButton.acceptsFirstResponder)
        bold.performClick(bold)
        let textView = try #require(accessibilityDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        #expect(textView.beginPointerSelection(atUTF16Offset: 0))
        #expect(textView.extendPointerSelection(toUTF16Offset: 4))
        hosting.layoutSubtreeIfNeeded()
        let refreshedLinkButton = try #require(
            accessibilityDescendants(of: hosting, as: NSButton.self).first {
                $0.accessibilityIdentifier() == "block-format-link"
            }
        )
        refreshedLinkButton.performClick(refreshedLinkButton)
        #expect(callbacks == 2)

        try session.adoptNativeSelection(
            .init(location: 0, length: 0),
            direction: .forward,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        hosting.layoutSubtreeIfNeeded()
        #expect(Set(accessibilityDescendants(of: hosting, as: NSButton.self).compactMap {
            $0.accessibilityIdentifier()
        }).isSuperset(of: Set(BlockFormattingAction.allCases.map(\.accessibilityIdentifier))))

        let codeDocument = BlockDocument(blocks: [projectionBlock(id, .code, "code")])
        let codeSession = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: codeDocument,
            initialSelection: .text(
                anchor: .init(blockID: id, graphemeOffset: 0),
                focus: .init(blockID: id, graphemeOffset: 4), preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            ), focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let unsupported = NSHostingView(rootView: BlockFormattingBar(session: codeSession))
        unsupported.frame = hosting.frame
        unsupported.layoutSubtreeIfNeeded()
        #expect(Set(accessibilityDescendants(of: unsupported, as: NSButton.self).compactMap {
            $0.accessibilityIdentifier()
        }).isSuperset(of: Set(BlockFormattingAction.allCases.map(\.accessibilityIdentifier))))

        let toggle = try #require(buttons.first { $0.accessibilityIdentifier() == "block-format-toggle" })
        toggle.performClick(toggle)
        hosting.layoutSubtreeIfNeeded()
        let collapsedIDs = Set(accessibilityDescendants(of: hosting, as: NSButton.self).compactMap {
            $0.accessibilityIdentifier()
        })
        #expect(collapsedIDs.contains("block-format-toggle"))
        #expect(collapsedIDs.isDisjoint(with: Set(BlockFormattingAction.allCases.map(\.accessibilityIdentifier))))
        let expand = try #require(accessibilityDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == "block-format-toggle"
        })
        #expect(expand.accessibilityLabel() == "展开格式栏")
    }

    @Test func taskBlockExposesTheCalendarSchedulingEntryInsideTheProductionEditor() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let noteID = NoteID()
        let blockID = BlockID()
        let document = BlockDocument(blocks: [try .task(id: blockID, text: "安排复盘")])

        let hosting = NSHostingView(rootView: BlockEditorView(
            noteID: noteID,
            editSessionID: UUID(),
            initialDocument: document,
            initialSelection: projectionCaret(blockID, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in },
            taskCalendarContext: .init(store: store, now: { .distantPast }, onOpenItem: { _ in })
        ))
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 240)
        hosting.layoutSubtreeIfNeeded()

        #expect(accessibilityDescendants(of: hosting, as: NSButton.self).contains {
            $0.accessibilityLabel() == "安排待办到日历"
        })
    }

    @Test func taskCalendarEntryStaysCompactInsteadOfStretchingAcrossTheEditor() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let noteID = NoteID()
        let blockID = BlockID()
        let document = BlockDocument(blocks: [try .task(id: blockID, text: "安排复盘")])
        let hosting = NSHostingView(rootView: BlockEditorView(
            noteID: noteID,
            editSessionID: UUID(),
            initialDocument: document,
            initialSelection: projectionCaret(blockID, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in },
            taskCalendarContext: .init(store: store, now: { .distantPast }, onOpenItem: { _ in })
        ))
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 240)
        hosting.layoutSubtreeIfNeeded()

        let button = try #require(accessibilityDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityLabel() == "安排待办到日历"
        })
        #expect(
            button.frame.width <= button.intrinsicContentSize.width + 12,
            "日历入口应是紧凑次级操作，实际宽度 \(button.frame.width)，自然宽度 \(button.intrinsicContentSize.width)"
        )
        #expect(button.frame.width < hosting.bounds.width / 2)
    }

    @Test func dynamicallyRevealedTaskCalendarEntryStaysCompactAfterEditorLayoutSettles() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let noteID = NoteID()
        let blockID = BlockID()
        var capturedSession: BlockEditorSession?
        let hosting = NSHostingView(rootView:
            ScrollView {
                BlockEditorView(
                    noteID: noteID,
                    editSessionID: UUID(),
                    initialDocument: BlockDocument(blocks: [projectionBlock(blockID, .paragraph, "待转换")]),
                    initialSelection: projectionCaret(blockID, 0),
                    focusRegistry: EditorFocusRegistry(),
                    onDocumentChange: { _ in },
                    sessionSink: { capturedSession = $0 },
                    taskCalendarContext: .init(
                        store: store,
                        now: { .distantPast },
                        onOpenItem: { _ in }
                    )
                )
                .frame(maxWidth: NoteEditorLayout.maximumContentWidth, minHeight: 200, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, NoteEditorLayout.horizontalSafetyMargin)
                .padding(.vertical, 20)
            }
        )
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        let session = try #require(capturedSession)
        #expect(session.dispatchTextCommand(.convert(.task)))
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()

        let button = try #require(accessibilityDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityLabel() == "安排待办到日历"
        })
        #expect(
            button.frame.width <= button.intrinsicContentSize.width + 12,
            "动态出现的入口也必须保持紧凑，实际宽度 \(button.frame.width)"
        )
        #expect(button.frame.width < hosting.bounds.width / 2)

        let textView = try #require(accessibilityDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: 0)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: .init(location: firstGlyph, length: 1),
            in: textContainer
        )
        let textStartInHost = textView.convert(
            .init(x: textView.textContainerOrigin.x + glyphRect.minX, y: 0),
            to: hosting
        ).x
        let buttonStartInHost = button.convert(.zero, to: hosting).x
        #expect(
            abs(buttonStartInHost - textStartInHost) < 1,
            "日历入口应与待办正文起笔线对齐，正文 x=\(textStartInHost)，入口 x=\(buttonStartInHost)"
        )
    }

    @Test func darkAppearanceProjectsAConcreteReadableForegroundColor() throws {
        let blockID = BlockID()
        let view = BlockEditorTextView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.applyAuthoritativeProjection(
            block: .init(
                id: blockID,
                kind: .paragraph,
                inlineContent: .plain("深色正文"),
                taskState: nil,
                indentLevel: 0
            ),
            selectedRange: .init(location: 0, length: 0)
        )

        let color = try #require(view.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor)
        let rgb = try #require(color.usingColorSpace(.deviceRGB))
        #expect(rgb.brightnessComponent > 0.7)
    }

    @Test func hostedDarkEditorPropagatesItsSchemeIntoTheNativeTextView() throws {
        _ = NSApplication.shared
        let blockID = BlockID()
        let document = BlockDocument(blocks: [
            .init(
                id: blockID,
                kind: .paragraph,
                inlineContent: .plain("可见正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let hosting = NSHostingView(rootView: BlockEditorView(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: document,
            initialSelection: projectionCaret(blockID, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        ).preferredColorScheme(.dark))
        hosting.frame = .init(x: 0, y: 0, width: 500, height: 180)
        hosting.layoutSubtreeIfNeeded()

        let textView = try #require(accessibilityDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        #expect(textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let color = try #require(textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor)
        var resolved: NSColor?
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB)
        }
        #expect(try #require(resolved).brightnessComponent > 0.7)

        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 500, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.displayIfNeeded()
        #expect(textView.bounds.width > 100)
        #expect(textView.bounds.height > 20)
        #expect(textView.textStorage?.length == 4)
        #expect(textView.layoutManager?.numberOfGlyphs == 4)
        #expect(textView.isHidden == false)
        #expect(textView.alphaValue == 1)
        let textContainer = try #require(textView.textContainer)
        #expect(textContainer.textView === textView)
        #expect(textContainer.containerSize.width > 100)
        #expect(textContainer.containerSize.height > 20)
        let usedRect = try #require(textView.layoutManager?.usedRect(for: textContainer))
        #expect(usedRect.width > 10)
        #expect(usedRect.height > 10)
        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        var lightPixels = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if pixel.alphaComponent > 0.1, pixel.brightnessComponent > 0.7 {
                    lightPixels += 1
                }
            }
        }
        #expect(lightPixels > 20)
    }
}

@MainActor
private final class SelectorCounter { var value = 0 }

@MainActor
private func selectorFixture(selection range: Range<Int>) -> (session: BlockEditorSession, view: BlockEditorTextView, counter: SelectorCounter) {
    let id = BlockID()
    let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("abc"), taskState: nil, indentLevel: 0)])
    let selection = BlockEditorSelection.text(
        anchor: .init(blockID: id, graphemeOffset: range.lowerBound),
        focus: .init(blockID: id, graphemeOffset: range.upperBound),
        preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
    )
    let counter = SelectorCounter()
    let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in counter.value += 1 })
    let view = BlockEditorTextView()
    session.attach(blockID: id, hostToken: UUID(), textView: view)
    return (session, view, counter)
}

private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    ))
}

@MainActor
private func markdownProductionFixture() -> (
    session: BlockEditorSession, view: BlockEditorTextView,
    counter: SelectorCounter, original: BlockDocument
) {
    let id = BlockID()
    let original = BlockDocument(blocks: [projectionBlock(id, .paragraph, "")])
    let counter = SelectorCounter()
    let session = BlockEditorSession(
        noteID: NoteID(), editSessionID: UUID(), initialDocument: original,
        initialSelection: projectionCaret(id, 0), focusRegistry: EditorFocusRegistry(),
        onDocumentChange: { _ in counter.value += 1 }
    )
    let view = BlockEditorTextView()
    session.attach(blockID: id, hostToken: UUID(), textView: view)
    return (session, view, counter, original)
}

private func projectionBlock(_ id: BlockID, _ kind: BlockKind, _ text: String) -> DocumentBlock {
    .init(
        id: id, kind: kind, inlineContent: .plain(text),
        taskState: kind == .task ? .init(completedAt: nil) : nil,
        indentLevel: 0
    )
}

private func projectionCaret(_ id: BlockID, _ offset: Int) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: id, graphemeOffset: offset),
        focus: .init(blockID: id, graphemeOffset: offset),
        preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
    )
}

@MainActor
private func projectionFont(_ view: BlockEditorTextView?) throws -> NSFont {
    let storage = try #require(view?.textStorage)
    return try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
}

@MainActor
private func projectionParagraph(_ view: BlockEditorTextView?) throws -> NSParagraphStyle {
    let storage = try #require(view?.textStorage)
    return try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
}

@MainActor
private func accessibilityDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { accessibilityDescendants(of: $0, as: type) }
}
