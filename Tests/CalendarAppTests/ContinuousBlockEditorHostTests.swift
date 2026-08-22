import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("ContinuousBlockEditorHostTests")
struct ContinuousBlockEditorHostTests {
    @Test @MainActor func productionTwentyBlockDocumentCreatesOneEditableTextViewAndOneUndoOwner() throws {
        _ = NSApplication.shared
        let blocks = (0..<20).map {
            continuousBlock(id: $0 + 1, text: "第\($0 + 1)段")
        }
        var capturedSession: BlockEditorSession?
        let root = BlockEditorView(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: blocks),
            initialSelection: continuousCaret(blocks[0].id, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in },
            sessionSink: { capturedSession = $0 }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 800)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let textViews = continuousDescendants(of: hosting, as: ContinuousBlockEditorTextView.self)
        let session = try #require(capturedSession)
        let textView = try #require(textViews.first)
        #expect(textViews.count == 1)
        #expect(textView.isEditable)
        #expect(textView.authoritativeUndoManager === session.undoManager)
        #expect(textView.string == blocks.map(continuousText).joined(separator: "\n"))
        #expect(continuousDescendants(of: hosting, as: BlockEditorTextView.self).isEmpty)
        window.orderOut(nil)
    }

    @Test @MainActor func nativeHostGrowsWithTextKitContentWithoutCreatingANestedScrollView() {
        let text = (0..<30).map { "第\($0)行连续正文" }.joined(separator: "\n")
        let block = continuousBlock(id: 25, text: text)
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))
        fixture.host.frame = .init(x: 0, y: 0, width: 220, height: 80)
        fixture.host.layoutSubtreeIfNeeded()

        #expect(fixture.host.intrinsicContentSize.height > 300)
        #expect(fixture.view.enclosingScrollView == nil)
        #expect(continuousDescendants(of: fixture.host, as: NSScrollView.self).isEmpty)
    }

    @Test @MainActor func emptyDocumentHasOnePresentationOnlyPlaceholderThatCompositionHides() {
        let block = continuousBlock(id: 26, text: "")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))

        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder)
        #expect(fixture.view.string.isEmpty)
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)

        fixture.view.setMarkedText(
            "pin",
            selectedRange: .init(location: 3, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder == false)
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)
        fixture.view.cancelOperation(nil)
        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder)
    }

    @Test @MainActor func focusedEmptyDocumentHidesPlaceholderBeforeTheFirstCharacter() {
        _ = NSApplication.shared
        let block = continuousBlock(id: 261, text: "")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))
        fixture.host.frame = .init(x: 0, y: 0, width: 420, height: 140)
        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder)
        let window = NSWindow(
            contentRect: fixture.host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        #expect(window.makeFirstResponder(fixture.view))
        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder == false)
        #expect(window.makeFirstResponder(nil))
        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder)
    }

    @Test @MainActor func bodyCaretDrawsNearGlyphHeightInsteadOfFillingTheLineFragment() throws {
        let block = continuousBlock(id: 27, text: "正文")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 1))
        let proposed = NSRect(x: 10, y: 4, width: 2, height: 34)

        let drawn = try drawnInsertionPointBounds(in: fixture.view, proposed: proposed)

        #expect(drawn.height <= 20)
        #expect(abs(drawn.midY - proposed.midY) <= 1)
    }

    @Test @MainActor func editorUsesOneSystemInsertionIndicatorInsteadOfTheTextViewCaret() throws {
        let block = continuousBlock(id: 32, text: "正文")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 1))
        let systemColor = try #require(fixture.view.insertionPointColor)

        #expect(systemColor.alphaComponent == 0)
        #expect(fixture.view.immediateInsertionIndicator.hitTest(.zero) == nil)
    }

    @Test @MainActor func insertionIndicatorIsImmediateThenSystemAnimatedAndHidesWithoutACaret() throws {
        let block = continuousBlock(id: 72, text: "正文")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 1))
        fixture.host.frame = .init(x: 0, y: 0, width: 320, height: 100)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(fixture.view))
        fixture.host.layoutSubtreeIfNeeded()

        #expect(fixture.view.immediateInsertionIndicator.displayMode == .automatic)
        #expect(fixture.view.immediateInsertionIndicator.frame.width == 1)
        #expect(fixture.view.immediateInsertionIndicator.frame.height <= 20)

        fixture.view.setAccessibilitySelectedTextRange(.init(location: 0, length: 2))
        #expect(fixture.view.immediateInsertionIndicator.displayMode == .hidden)

        fixture.view.setAccessibilitySelectedTextRange(.init(location: 1, length: 0))
        #expect(fixture.view.immediateInsertionIndicator.displayMode == .automatic)

        #expect(window.makeFirstResponder(nil))
        #expect(fixture.view.immediateInsertionIndicator.displayMode == .hidden)
    }

    @Test @MainActor func immediateIndicatorMovesToTheNewCaretPositionDuringTheKeystroke() throws {
        let block = continuousBlock(id: 33, text: "原")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 1))
        fixture.host.frame = .init(x: 0, y: 0, width: 320, height: 100)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(fixture.view))
        fixture.host.layoutSubtreeIfNeeded()
        let before = fixture.view.immediateInsertionIndicator.frame

        fixture.view.insertText("文", replacementRange: .init(location: NSNotFound, length: 0))

        let after = fixture.view.immediateInsertionIndicator.frame
        #expect(after.minX > before.minX)
        #expect(after.height <= 20)
        #expect(fixture.view.immediateInsertionIndicator.displayMode == .automatic)
        window.orderOut(nil)
    }

    @Test @MainActor func immediateIndicatorFollowsTextWrappingDuringLayout() throws {
        let block = continuousBlock(
            id: 34,
            text: "这是一段会在编辑器变窄时重新换行的连续正文内容"
        )
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, continuousText(block).count)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 420, height: 160)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(fixture.view))
        fixture.host.layoutSubtreeIfNeeded()
        let before = fixture.view.immediateInsertionIndicator.frame

        fixture.host.frame.size.width = 140
        fixture.host.layoutSubtreeIfNeeded()

        let after = fixture.view.immediateInsertionIndicator.frame
        #expect(after.minY > before.minY)
        window.orderOut(nil)
    }

    @Test @MainActor func tabLeavesAnOrdinaryParagraphForTheNextKeyboardControl() throws {
        let block = continuousBlock(id: 35, text: "普通正文")
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 2)
        )
        let container = NSView(frame: .init(x: 0, y: 0, width: 420, height: 180))
        fixture.host.frame = .init(x: 0, y: 40, width: 420, height: 140)
        let nextControl = ContinuousKeyboardFocusProbe(
            frame: .init(x: 0, y: 0, width: 80, height: 30)
        )
        container.addSubview(fixture.host)
        container.addSubview(nextControl)
        fixture.view.nextKeyView = nextControl
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(fixture.view))

        fixture.view.doCommand(by: #selector(NSResponder.insertTab(_:)))

        #expect(window.firstResponder === nextControl)
        #expect(fixture.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "普通正文")
    }

    @Test @MainActor func emptyHeadingCaretKeepsTheHeadingGlyphHeight() throws {
        let block = continuousBlock(id: 28, text: "", kind: .heading1)
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))
        let proposed = NSRect(x: 10, y: 2, width: 2, height: 40)

        let drawn = try drawnInsertionPointBounds(in: fixture.view, proposed: proposed)

        #expect(drawn.height >= 29)
        #expect(drawn.height <= 32)
        #expect(abs(drawn.midY - proposed.midY) <= 1)
    }

    @Test @MainActor func headingStartCaretUsesTheHeadingRatherThanPreviousSeparatorFont() throws {
        let paragraph = continuousBlock(id: 29, text: "上一段")
        let heading = continuousBlock(id: 30, text: "标题", kind: .heading1)
        let fixture = continuousFixture(
            blocks: [paragraph, heading],
            selection: continuousCaret(heading.id, 0)
        )
        let proposed = NSRect(x: 10, y: 2, width: 2, height: 40)

        let drawn = try drawnInsertionPointBounds(in: fixture.view, proposed: proposed)

        #expect(drawn.height >= 24)
        #expect(drawn.height <= 32)
    }

    @Test @MainActor func nativeCrossThreeBlockSelectionRoundTripsWithReverseDirection() throws {
        let blocks = [
            continuousBlock(id: 30, text: "甲乙"),
            continuousBlock(id: 31, text: "丙丁"),
            continuousBlock(id: 32, text: "戊己")
        ]
        let fixture = continuousFixture(blocks: blocks, selection: continuousCaret(blocks[0].id, 0))
        let attributes = BlockTypingAttributes(marks: [.bold], linkURL: nil)

        try fixture.session.adoptNativeSelection(
            .init(location: 1, length: 5),
            direction: .reverse,
            typingAttributes: attributes
        )

        #expect(fixture.session.selection == .text(
            anchor: .init(blockID: blocks[2].id, graphemeOffset: 0),
            focus: .init(blockID: blocks[0].id, graphemeOffset: 1),
            preferredColumn: nil,
            typingAttributes: attributes
        ))
        #expect(fixture.view.selectedRange == .init(location: 1, length: 5))
    }

    @Test @MainActor func nativeEnterSoftBreakAndBoundaryBackspaceUseTheExistingReducer() throws {
        let first = continuousBlock(id: 40, text: "甲乙")
        let second = continuousBlock(id: 41, text: "丙")
        let fixture = continuousFixture(
            blocks: [first, second],
            selection: continuousCaret(first.id, 1)
        )

        fixture.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(fixture.session.document.blocks.count == 3)
        #expect(fixture.session.document.blocks.map(continuousText) == ["甲", "乙", "丙"])

        fixture.view.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        #expect(fixture.session.document.blocks.map(continuousText) == ["甲", "\n乙", "丙"])

        fixture.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(fixture.session.document.blocks.map(continuousText) == ["甲", "乙", "丙"])
        #expect(fixture.session.undoManager.canUndo)
    }

    @Test @MainActor func consecutiveBulletRowsKeepACompactContinuousWritingRhythm() throws {
        let blocks = [
            continuousBlock(id: 42, text: "三年级啊", kind: .bullet),
            continuousBlock(id: 43, text: "是大数据大", kind: .bullet),
            continuousBlock(id: 44, text: "三菱电机按时", kind: .bullet)
        ]
        let fixture = continuousFixture(
            blocks: blocks,
            selection: continuousCaret(blocks[0].id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 240)
        fixture.host.layoutSubtreeIfNeeded()
        let layoutManager = try #require(fixture.view.layoutManager)
        let textContainer = try #require(fixture.view.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let offsets = [
            0,
            "三年级啊\n".utf16.count,
            "三年级啊\n是大数据大\n".utf16.count
        ]
        let rows = offsets.map { offset in
            layoutManager.lineFragmentUsedRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: offset),
                effectiveRange: nil
            )
        }
        let gaps = zip(rows, rows.dropFirst()).map { $1.minY - $0.minY }

        #expect(
            gaps.allSatisfy { $0 >= 24 && $0 <= 29 },
            "连续列表的行距应在 24...29pt，实际为 \(gaps)"
        )
    }

    @Test @MainActor func bulletMarkerUsesTheSameBaselineAsItsFirstTextGlyph() throws {
        let block = continuousBlock(id: 142, text: "但是哦哦啊啊", kind: .bullet)
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 120)
        fixture.host.layoutSubtreeIfNeeded()

        let markerBaseline = try #require(fixture.view.structuralMarkerBaselineY(for: block.id))
        let layoutManager = try #require(fixture.view.layoutManager)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: 0)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let textBaseline = fixture.view.textContainerOrigin.y + line.minY + glyphLocation.y

        #expect(abs(markerBaseline - textBaseline) < 0.5)
    }

    @Test @MainActor func markedTextCaretUsesTheComposingGlyphBaselineInsteadOfTheLineBox() throws {
        let block = continuousBlock(id: 143, text: "")
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 320, height: 100)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(fixture.view))

        fixture.view.setMarkedText(
            "d",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        fixture.host.layoutSubtreeIfNeeded()

        let layoutManager = try #require(fixture.view.layoutManager)
        let textStorage = try #require(fixture.view.textStorage)
        let font = try #require(textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: 0)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let baseline = fixture.view.textContainerOrigin.y + line.minY + glyphLocation.y
        let expectedTop = baseline - font.ascender
        let expectedBottom = baseline - font.descender
        let caret = fixture.view.immediateInsertionIndicator.frame

        #expect(abs(caret.minY - expectedTop) < 1)
        #expect(abs(caret.maxY - expectedBottom) < 1)
    }

    @Test @MainActor func trailingEmptyListCaretUsesTheExtraLineTextStartInsteadOfTheRightEdge() throws {
        let first = continuousBlock(id: 144, text: "已有内容", kind: .bullet)
        let empty = continuousBlock(id: 145, text: "", kind: .bullet)
        let fixture = continuousFixture(
            blocks: [first, empty],
            selection: continuousCaret(empty.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 140)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(fixture.view))
        fixture.host.layoutSubtreeIfNeeded()

        let layoutManager = try #require(fixture.view.layoutManager)
        let textContainer = try #require(fixture.view.textContainer)
        let extraLine = layoutManager.extraLineFragmentUsedRect
        let caret = fixture.view.immediateInsertionIndicator.frame
        let expectedX = fixture.view.textContainerOrigin.x
            + extraLine.minX
            + textContainer.lineFragmentPadding

        #expect(extraLine.isEmpty == false)
        #expect(abs(caret.minX - expectedX) < 0.5)
        #expect(caret.minX < fixture.view.bounds.midX)
    }

    @Test @MainActor func trailingEmptyListCaretAlignsWithThePreviousListTextColumn() throws {
        let first = continuousBlock(id: 244, text: "列表正文", kind: .bullet)
        let empty = continuousBlock(id: 245, text: "", kind: .bullet)
        let fixture = continuousFixture(
            blocks: [first, empty],
            selection: continuousCaret(empty.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 140)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(fixture.view))
        fixture.host.layoutSubtreeIfNeeded()

        let layoutManager = try #require(fixture.view.layoutManager)
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: 0)
        let firstTextRect = layoutManager.boundingRect(
            forGlyphRange: .init(location: firstGlyph, length: 1),
            in: try #require(fixture.view.textContainer)
        )
        let firstTextX = fixture.view.textContainerOrigin.x + firstTextRect.minX
        let emptyCaretX = fixture.view.immediateInsertionIndicator.frame.minX

        #expect(
            abs(emptyCaretX - firstTextX) < 0.5,
            "空列表光标应与列表正文起笔位置对齐，正文 x=\(firstTextX)，光标 x=\(emptyCaretX)"
        )
    }

    @Test @MainActor func emptyListAfterParagraphUsesItsOwnIndentInsteadOfThePreviousParagraphIndent() throws {
        let paragraph = continuousBlock(id: 146, text: "dsk", kind: .paragraph)
        let empty = continuousBlock(id: 147, text: "", kind: .bullet)
        let fixture = continuousFixture(
            blocks: [paragraph, empty],
            selection: continuousCaret(empty.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 140)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(fixture.view))
        fixture.host.layoutSubtreeIfNeeded()

        let textContainer = try #require(fixture.view.textContainer)
        let expectedX = fixture.view.textContainerOrigin.x
            + BlockTextStyle.paragraphStyle(for: .bullet).firstLineHeadIndent
            + textContainer.lineFragmentPadding
        let caret = fixture.view.immediateInsertionIndicator.frame

        #expect(abs(caret.minX - expectedX) < 0.5)
    }

    @Test @MainActor func markedTextInEmptyListAfterParagraphKeepsTheListTextIndent() throws {
        let paragraph = continuousBlock(id: 148, text: "dsk", kind: .paragraph)
        let empty = continuousBlock(id: 149, text: "", kind: .bullet)
        let fixture = continuousFixture(
            blocks: [paragraph, empty],
            selection: continuousCaret(empty.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 140)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(fixture.view))

        for candidate in ["s", "s'", "s'd"] {
            fixture.view.setMarkedText(
                candidate,
                selectedRange: .init(location: (candidate as NSString).length, length: 0),
                replacementRange: .init(location: NSNotFound, length: 0)
            )
        }
        fixture.host.layoutSubtreeIfNeeded()

        let markedRange = fixture.view.markedRange()
        let textStorage = try #require(fixture.view.textStorage)
        let style = try #require(textStorage.attribute(
            .paragraphStyle,
            at: markedRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let expectedIndent = BlockTextStyle.paragraphStyle(for: .bullet).firstLineHeadIndent
        let layoutManager = try #require(fixture.view.layoutManager)
        let textContainer = try #require(fixture.view.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let firstMarkedGlyph = layoutManager.glyphIndexForCharacter(at: markedRange.location)
        let firstMarkedGlyphRect = layoutManager.boundingRect(
            forGlyphRange: .init(location: firstMarkedGlyph, length: 1),
            in: textContainer
        )
        let expectedGlyphX = expectedIndent + textContainer.lineFragmentPadding

        #expect(markedRange.length == 3)
        #expect(style.firstLineHeadIndent == expectedIndent)
        #expect(style.headIndent == expectedIndent)
        #expect(abs(firstMarkedGlyphRect.minX - expectedGlyphX) < 0.5)
    }

    @Test @MainActor func trailingEmptyTaskUsesTheExtraLineForItsCheckbox() throws {
        let first = continuousBlock(id: 45, text: "完成一项", kind: .task)
        let last = continuousBlock(id: 46, text: "", kind: .task)
        let fixture = continuousFixture(
            blocks: [first, last],
            selection: continuousCaret(last.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 160)
        fixture.host.layoutSubtreeIfNeeded()
        let layoutManager = try #require(fixture.view.layoutManager)
        let textContainer = try #require(fixture.view.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let checkbox = try #require(fixture.view.taskCheckboxFrame(for: last.id))
        let extraLine = layoutManager.extraLineFragmentUsedRect
        let expectedMinY = fixture.view.textContainerOrigin.y
            + extraLine.minY
            + max(0, (extraLine.height - 18) / 2)

        #expect(abs(checkbox.minY - expectedMinY) < 0.5)
    }

    @Test @MainActor func horizontalMovementCrossesStructuralNewlineAndLastCharacterDeletionKeepsOneBlock() throws {
        let first = continuousBlock(id: 45, text: "甲")
        let second = continuousBlock(id: 46, text: "乙")
        let fixture = continuousFixture(
            blocks: [first, second],
            selection: continuousCaret(first.id, 1)
        )

        fixture.view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(fixture.session.selection == continuousCaret(second.id, 0))
        #expect(fixture.view.selectedRange == .init(location: 2, length: 0))
        fixture.view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(fixture.session.selection == continuousCaret(first.id, 1))

        let only = continuousBlock(id: 47, text: "字")
        let single = continuousFixture(blocks: [only], selection: continuousCaret(only.id, 1))
        single.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(single.session.document.blocks.count == 1)
        #expect(continuousText(single.session.document.blocks[0]).isEmpty)
        #expect(single.view.string.isEmpty)
    }

    @Test @MainActor func ordinaryKeystrokeAppliesOneBoundedDiffWithoutASecondFullProjection() {
        let block = continuousBlock(id: 48, text: "原")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 1))
        #expect(fixture.view.fullProjectionApplyCount == 1)
        #expect(fixture.view.diffProjectionApplyCount == 0)

        fixture.view.insertText("文", replacementRange: .init(location: NSNotFound, length: 0))

        #expect(fixture.view.string == "原文")
        #expect(fixture.view.fullProjectionApplyCount == 1)
        #expect(fixture.view.diffProjectionApplyCount == 1)
        #expect(fixture.view.textStorage?.attribute(
            .jellyBlockID,
            at: 0,
            effectiveRange: nil
        ) as? String == block.id.rawValue.uuidString)
        #expect(fixture.view.textStorage?.attribute(
            .jellyBlockKind,
            at: 0,
            effectiveRange: nil
        ) as? String == BlockKind.paragraph.rawValue)
    }

    @Test @MainActor func focusedTypingRequestsCaretRevealAgainAfterDeferredHeightGrowth() async throws {
        let block = continuousBlock(id: 53, text: "")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))
        fixture.host.frame = .init(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(fixture.view))
        let revealCount = fixture.view.selectionRevealRequestCount

        fixture.view.insertText("第一行\n第二行\n第三行", replacementRange: .init(location: NSNotFound, length: 0))

        #expect(fixture.view.selectionRevealRequestCount == revealCount + 1)
        try await Task.sleep(for: .milliseconds(350))
        #expect(fixture.view.selectionRevealRequestCount >= revealCount + 2)
        window.orderOut(nil)
    }

    @Test @MainActor func clickingTheFormattingBarKeepsTheWholeNativeSelection() throws {
        let last = continuousBlock(id: 55, text: "")
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: [last]),
            initialSelection: continuousCaret(last.id, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let root = VStack {
            ContinuousBlockEditorRepresentable(session: session, appearance: CalendarTheme.light)
            BlockFormattingBar(session: session)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(continuousDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        #expect(window.makeFirstResponder(textView))
        textView.insertText(
            "alpha JellyFormatProbe omega",
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        let nativeRange = NSRange(
            location: "alpha ".utf16.count,
            length: "JellyFormatProbe".utf16.count
        )
        textView.setAccessibilitySelectedTextRange(nativeRange)
        #expect(textView.selectedRange == nativeRange)
        let bold = try #require(continuousDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == BlockFormattingAction.bold.accessibilityIdentifier
        })
        #expect(bold.acceptsFirstResponder)
        #expect(window.firstResponder === textView)
        session.prepareAuxiliaryControlAction()
        // AppKit can publish this transient caret while a non-focusable
        // toolbar control is activating. It must not replace the user's range.
        textView.selectedRange = .init(location: nativeRange.location, length: 0)

        bold.performClick(bold)

        #expect(window.firstResponder === textView)
        let spans = session.document.blocks[0].inlineContent.spans
        #expect(spans.map(\.text).joined() == "alpha JellyFormatProbe omega")
        #expect(spans.filter { $0.marks.contains(.bold) }.map(\.text) == ["JellyFormatProbe"])
        let expectedProjection = BlockDocumentTextProjection(
            document: session.document,
            appearance: CalendarTheme.light
        )
        for offset in nativeRange.location..<NSMaxRange(nativeRange) {
            let actualFont = try #require(textView.textStorage?.attribute(
                .font,
                at: offset,
                effectiveRange: nil
            ) as? NSFont)
            let expectedFont = try #require(expectedProjection.attributedString.attribute(
                .font,
                at: offset,
                effectiveRange: nil
            ) as? NSFont)
            #expect(actualFont == expectedFont)
        }
        window.orderOut(nil)
    }

    @Test @MainActor func realMouseClickOnFormattingBarRunsTheCommandAndRestoresEditorFocus() throws {
        _ = NSApplication.shared
        let block = continuousBlock(id: 59, text: "alpha beta")
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: [block]),
            initialSelection: continuousCaret(block.id, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let root = VStack {
            ContinuousBlockEditorRepresentable(session: session, appearance: CalendarTheme.light)
            BlockFormattingBar(session: session)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(continuousDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        #expect(window.makeFirstResponder(textView))
        textView.setAccessibilitySelectedTextRange(.init(location: 6, length: 4))
        let bold = try #require(continuousDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == BlockFormattingAction.bold.accessibilityIdentifier
        })
        let location = bold.convert(
            .init(x: bold.bounds.midX, y: bold.bounds.midY),
            to: nil
        )
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        NSApplication.shared.postEvent(up, atStart: false)

        bold.mouseDown(with: down)

        #expect(window.firstResponder === textView)
        #expect(session.document.blocks[0].inlineContent.spans.filter {
            $0.marks.contains(.bold)
        }.map(\.text) == ["beta"])
    }

    @Test @MainActor func firstKeystrokeImmediatelyAfterARealFormattingClickIsNotDropped() throws {
        _ = NSApplication.shared
        let block = continuousBlock(id: 60, text: "abc")
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: [block]),
            initialSelection: continuousCaret(block.id, 3),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let root = VStack {
            ContinuousBlockEditorRepresentable(session: session, appearance: CalendarTheme.light)
            BlockFormattingBar(session: session)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(continuousDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        #expect(window.makeFirstResponder(textView))
        let bold = try #require(continuousDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == BlockFormattingAction.bold.accessibilityIdentifier
        })
        let location = bold.convert(
            .init(x: bold.bounds.midX, y: bold.bounds.midY),
            to: nil
        )
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        NSApplication.shared.postEvent(up, atStart: false)

        bold.mouseDown(with: down)
        textView.insertText("X", replacementRange: .init(location: NSNotFound, length: 0))

        #expect(window.firstResponder === textView)
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "abcX")
        #expect(session.document.blocks[0].inlineContent.spans.filter {
            $0.marks.contains(.bold)
        }.map(\.text) == ["X"])
        #expect(textView.selectedRange == .init(location: 4, length: 0))
    }

    @Test @MainActor func structuralFormattingBarConvertsASelectedLineAndKeepsItSelected() throws {
        let block = continuousBlock(id: 58, text: "Task")
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: block.id, graphemeOffset: 0),
            focus: .init(blockID: block.id, graphemeOffset: 4),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: [block]),
            initialSelection: selection,
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let root = VStack {
            ContinuousBlockEditorRepresentable(session: session, appearance: CalendarTheme.light)
            BlockFormattingBar(session: session)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(continuousDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        let task = try #require(continuousDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == BlockFormattingAction.task.accessibilityIdentifier
        })

        task.performClick(task)

        #expect(session.document.blocks[0].kind == .task)
        #expect(textView.selectedRange == .init(location: 0, length: 4))
        #expect(window.firstResponder === textView)
        window.orderOut(nil)
    }

    @Test @MainActor func repeatedNativeSelectionNotificationDoesNotRepublishEditorState() throws {
        let block = continuousBlock(id: 56, text: "alpha JellyFormatProbe omega")
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 28)
        )
        let range = NSRange(
            location: "alpha ".utf16.count,
            length: "JellyFormatProbe".utf16.count
        )
        try fixture.session.adoptSelectionFromNativeTextView(
            range,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        var publicationCount = 0
        let observation = fixture.session.objectWillChange.sink { _ in publicationCount += 1 }

        try fixture.session.adoptSelectionFromNativeTextView(
            range,
            typingAttributes: .init(marks: [], linkURL: nil)
        )

        #expect(publicationCount == 0)
        withExtendedLifetime(observation) {}
    }

    @Test @MainActor func deferredAccessibilitySelectionStillWinsBeforeFormatting() throws {
        let last = continuousBlock(id: 57, text: "")
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: [last]),
            initialSelection: continuousCaret(last.id, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let root = VStack {
            ContinuousBlockEditorRepresentable(session: session, appearance: CalendarTheme.light)
            BlockFormattingBar(session: session)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(continuousDescendants(
            of: hosting,
            as: ContinuousBlockEditorTextView.self
        ).first)
        #expect(window.makeFirstResponder(textView))
        textView.insertText(
            "alpha JellyFormatProbe omega",
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        let nativeRange = NSRange(
            location: "alpha ".utf16.count,
            length: "JellyFormatProbe".utf16.count
        )
        textView.setAccessibilitySelectedTextRange(nativeRange)
        // Match the delayed single-character AX notification observed in the
        // packaged app after the visual selection already spans the phrase.
        textView.setAccessibilitySelectedTextRange(.init(location: nativeRange.location, length: 1))

        let bold = try #require(continuousDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == BlockFormattingAction.bold.accessibilityIdentifier
        })
        bold.performClick(bold)

        let spans = session.document.blocks[0].inlineContent.spans
        #expect(spans.filter { $0.marks.contains(.bold) }.map(\.text) == ["JellyFormatProbe"])
        window.orderOut(nil)
    }

    @Test @MainActor func nativeArrowMovementDoesNotReprojectTheDocument() {
        let first = continuousBlock(id: 49, text: "甲")
        let second = continuousBlock(id: 50, text: "乙")
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: [first, second]),
            initialSelection: continuousCaret(first.id, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let host = CountingContinuousHost()
        session.attach(host: host, hostToken: UUID())
        let projectionCount = host.applyCount

        host.textView.doCommand(by: #selector(NSResponder.moveRight(_:)))

        #expect(host.textView.selectedRange == .init(location: 1, length: 0))
        #expect(session.selection == continuousCaret(first.id, 1))
        #expect(host.applyCount == projectionCount)
    }

    @Test @MainActor func collapsingANativeSelectionRecomputesTypingMarksAtTheCaret() throws {
        let block = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "alpha "),
                .init(text: "bold", marks: [.bold]),
                .init(text: " omega")
            ]),
            taskState: nil,
            indentLevel: 0
        )
        let boldRange = NSRange(location: 6, length: 4)
        let fixture = continuousFixture(
            blocks: [block],
            selection: .text(
                anchor: .init(blockID: block.id, graphemeOffset: 6),
                focus: .init(blockID: block.id, graphemeOffset: 10),
                preferredColumn: nil,
                typingAttributes: .init(marks: [.bold], linkURL: nil)
            )
        )
        fixture.view.selectedRange = boldRange

        try fixture.session.adoptSelectionFromNativeTextView(
            .init(location: 6, length: 0),
            typingAttributes: .init(marks: [.bold], linkURL: nil)
        )
        #expect(fixture.session.currentTypingAttributes.marks.isEmpty)

        fixture.view.insertText("X", replacementRange: .init(location: NSNotFound, length: 0))
        let inserted = try #require(fixture.session.document.blocks[0].inlineContent.spans.first {
            $0.text.contains("X")
        })
        #expect(inserted.marks.isEmpty)
    }

    @Test @MainActor func repeatedCaretNotificationPreservesAnExplicitTypingMark() throws {
        let block = continuousBlock(id: 57, text: "")
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 0)
        )
        _ = fixture.session.dispatchTextCommand(.toggleInlineMark(.bold))
        #expect(fixture.session.currentTypingAttributes.marks == [.bold])

        try fixture.session.adoptSelectionFromNativeTextView(
            .init(location: 0, length: 0),
            typingAttributes: fixture.session.currentTypingAttributes
        )

        #expect(fixture.session.currentTypingAttributes.marks == [.bold])
    }

    @Test @MainActor func repeatedSwiftUIAttachmentOfTheSameHostIsProjectionNeutral() {
        let block = continuousBlock(id: 52, text: "不重复投影")
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: [block]),
            initialSelection: continuousCaret(block.id, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let host = CountingContinuousHost()
        let token = UUID()
        session.attach(host: host, hostToken: token)
        let projectionCount = host.applyCount

        session.attach(host: host, hostToken: token)

        #expect(host.applyCount == projectionCount)
    }

    @Test @MainActor func clickingPastTheLastGlyphPlacesTheCaretAtTheLineEnd() {
        let block = continuousBlock(id: 51, text: "abc")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))
        fixture.host.frame = .init(x: 0, y: 0, width: 320, height: 100)
        fixture.host.layoutSubtreeIfNeeded()

        #expect(fixture.view.utf16Offset(at: .init(x: 300, y: 18)) == 3)
    }

    @Test @MainActor func clickingBelowDocumentContentPlacesTheCaretAtTheDocumentEnd() {
        let first = continuousBlock(id: 151, text: "第一行")
        let last = continuousBlock(id: 152, text: "最后一行")
        let fixture = continuousFixture(
            blocks: [first, last],
            selection: continuousCaret(first.id, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 320, height: 280)
        fixture.host.layoutSubtreeIfNeeded()

        #expect(
            fixture.view.utf16Offset(at: .init(x: 40, y: 250))
                == fixture.view.string.utf16.count
        )
    }

    @Test @MainActor func markedCandidatesPublishOnlyOnceAtTerminalCommitAndUndoOnce() throws {
        let block = continuousBlock(id: 50, text: "")
        var publications: [BlockDocument] = []
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 0),
            onDocumentChange: { publications.append($0) }
        )

        fixture.view.setMarkedText(
            "n",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        fixture.view.setMarkedText(
            "ni🙂",
            selectedRange: .init(location: 4, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        fixture.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        fixture.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(publications.isEmpty)
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)

        fixture.view.insertText("你🙂", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(publications.count == 1)
        #expect(continuousText(fixture.session.document.blocks[0]) == "你🙂")
        #expect(fixture.session.undoManager.canUndo)
        fixture.session.undoManager.undo()
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)
    }

    @Test @MainActor func cancellingMarkedTextRestoresTheAuthoritativeProjectionWithoutPublishing() throws {
        let block = continuousBlock(id: 60, text: "原文")
        var publicationCount = 0
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 2),
            onDocumentChange: { _ in publicationCount += 1 }
        )
        fixture.view.setMarkedText(
            "候选",
            selectedRange: .init(location: 2, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )

        fixture.view.cancelOperation(nil)

        #expect(publicationCount == 0)
        #expect(fixture.view.string == "原文")
        #expect(continuousText(fixture.session.document.blocks[0]) == "原文")
    }

    @Test @MainActor func unmarkCommitsTheLatestChineseEmojiCandidateExactlyOnce() throws {
        let block = continuousBlock(id: 61, text: "")
        var publicationCount = 0
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 0),
            onDocumentChange: { _ in publicationCount += 1 }
        )
        fixture.view.setMarkedText(
            "中文🙂",
            selectedRange: .init(location: 4, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )

        fixture.view.unmarkText()

        #expect(publicationCount == 1)
        #expect(continuousText(fixture.session.document.blocks[0]) == "中文🙂")
        #expect(fixture.session.undoManager.canUndo)
    }

    @Test @MainActor func documentEdgeFocusUsesTheFirstAndLastCaretAndAddsOneParagraphAfterDivider() throws {
        let first = continuousBlock(id: 70, text: "开头")
        let last = continuousBlock(id: 71, text: "结尾")
        let fixture = continuousFixture(blocks: [first, last], selection: continuousCaret(first.id, 1))

        fixture.session.focusDocumentEnd()
        #expect(fixture.session.selection == continuousCaret(last.id, 2))
        fixture.session.focusDocumentStart()
        #expect(fixture.session.selection == continuousCaret(first.id, 0))

        let divider = DocumentBlock(
            id: BlockID(),
            kind: .divider,
            inlineContent: .plain(""),
            taskState: nil,
            indentLevel: 0
        )
        let dividerFixture = continuousFixture(
            blocks: [first, divider],
            selection: continuousCaret(first.id, 0)
        )
        dividerFixture.session.focusDocumentEnd()
        #expect(dividerFixture.session.document.blocks.count == 3)
        #expect(dividerFixture.session.document.blocks.last?.kind == .paragraph)
        dividerFixture.session.focusDocumentEnd()
        #expect(dividerFixture.session.document.blocks.count == 3)
    }

    @Test @MainActor func taskCompletionDescriptionKeepsASingleEditableBodyAndTitleCoordinates() throws {
        let task = try DocumentBlock.task(
            text: "给物业打电话",
            completionDescription: "拿到明确时间"
        )
        let next = continuousBlock(id: 80, text: "下一块")
        let fixture = continuousFixture(
            blocks: [task, next],
            selection: continuousCaret(task.id, "给物业打电话".count)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 220)
        fixture.host.layoutSubtreeIfNeeded()

        #expect(continuousDescendants(of: fixture.host, as: ContinuousBlockEditorTextView.self).count == 1)
        #expect(fixture.view.isEditable)
        #expect(fixture.view.string == "给物业打电话\n下一块")
        #expect(fixture.host.completionDescriptionWidth == fixture.host.bounds.width
            - BlockTextStyle.textColumnOffset(for: .task) - 10)

        fixture.view.insertText("x", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(fixture.view.string == "给物业打电话x\n下一块")
        #expect(fixture.view.selectedRange == .init(
            location: ("给物业打电话x" as NSString).length,
            length: 0
        ))
        #expect(fixture.session.document.blocks[0].taskState?.completionDescription == "拿到明确时间")
    }
}

@MainActor
private final class CountingContinuousHost: ContinuousBlockEditorHost {
    let textView = ContinuousBlockEditorTextView(frame: .init(x: 0, y: 0, width: 400, height: 120))
    let semanticAppearance = CalendarTheme.light
    private(set) var applyCount = 0

    func apply(
        diff: BlockDocumentProjectionDiff?,
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    ) {
        applyCount += 1
        textView.apply(diff: diff, projection: projection, selectedRange: selectedRange)
    }
}

@MainActor
private final class ContinuousKeyboardFocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private func continuousFixture(
    blocks: [DocumentBlock],
    selection: BlockEditorSelection,
    onDocumentChange: @escaping (BlockDocument) -> Void = { _ in }
) -> (session: BlockEditorSession, host: ContinuousBlockEditorHostView, view: ContinuousBlockEditorTextView) {
    let session = BlockEditorSession(
        noteID: NoteID(),
        editSessionID: UUID(),
        initialDocument: .init(blocks: blocks),
        initialSelection: selection,
        focusRegistry: EditorFocusRegistry(),
        onDocumentChange: onDocumentChange
    )
    let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
    session.attach(host: host, hostToken: UUID())
    return (session, host, host.textView)
}

private func continuousBlock(
    id: Int,
    text: String,
    kind: BlockKind = .paragraph
) -> DocumentBlock {
    .init(
        id: BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", id))!),
        kind: kind,
        inlineContent: .plain(text),
        taskState: nil,
        indentLevel: 0
    )
}

private func continuousText(_ block: DocumentBlock) -> String {
    block.inlineContent.spans.map(\.text).joined()
}

private func continuousCaret(_ blockID: BlockID, _ offset: Int) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: blockID, graphemeOffset: offset),
        focus: .init(blockID: blockID, graphemeOffset: offset),
        preferredColumn: nil,
        typingAttributes: .init(marks: [], linkURL: nil)
    )
}

@MainActor
private func drawnInsertionPointBounds(
    in textView: ContinuousBlockEditorTextView,
    proposed: NSRect
) throws -> NSRect {
    let width = 50
    let height = 50
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    textView.drawInsertionPoint(in: proposed, color: .systemBlue, turnedOn: true)
    context.flushGraphics()

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
        for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    _ = try #require(maxX >= minX && maxY >= minY)
    return NSRect(
        x: minX,
        y: height - maxY - 1,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}

@MainActor
private func continuousDescendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
    var result = root as? T == nil ? [] : [root as! T]
    for child in root.subviews {
        result.append(contentsOf: continuousDescendants(of: child, as: type))
    }
    return result
}
