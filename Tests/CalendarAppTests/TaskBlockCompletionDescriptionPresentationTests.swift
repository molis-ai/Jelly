import AppKit
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("TaskBlockCompletionDescriptionPresentationTests", .serialized)
struct TaskBlockCompletionDescriptionPresentationTests {
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
        let style = try #require(projection.attributedString.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let reserved = TaskCompletionDescriptionMetrics.measuredHeight(
            for: "拿到明确时间",
            width: 320
        ) + TaskCompletionDescriptionMetrics.topGap + TaskCompletionDescriptionMetrics.bottomGap
        #expect(abs(style.paragraphSpacing - reserved) < 0.5)
    }

    @Test func removingCompletionDescriptionClearsReservedParagraphSpacing() throws {
        let id = BlockID()
        let withDescription = try DocumentBlock.task(
            id: id,
            text: "给物业打电话",
            completionDescription: "拿到明确时间"
        )
        let withoutDescription = try DocumentBlock.task(id: id, text: "给物业打电话")
        let reserved = BlockDocumentTextProjection(
            document: .init(blocks: [withDescription]),
            appearance: CalendarTheme.light,
            completionDescriptionWidth: 320
        )
        let cleared = BlockDocumentTextProjection(
            document: .init(blocks: [withoutDescription]),
            appearance: CalendarTheme.light,
            completionDescriptionWidth: 320
        )
        let reservedStyle = try #require(reserved.attributedString.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let clearedStyle = try #require(cleared.attributedString.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(clearedStyle.paragraphSpacing == 0)
        #expect(reservedStyle.paragraphSpacing > clearedStyle.paragraphSpacing)
        #expect(cleared.attributedString.string == reserved.attributedString.string)
    }

    @Test @MainActor func overlayShowsStaticCompletionTextBelowTitleWithoutCoveringNextBlock() throws {
        _ = NSApplication.shared
        let taskID = BlockID()
        let nextID = BlockID()
        let task = try DocumentBlock.task(
            id: taskID,
            text: "给物业打电话",
            completionDescription: "拿到明确时间"
        )
        let next = DocumentBlock(
            id: nextID,
            kind: .paragraph,
            inlineContent: .plain("下一件事"),
            taskState: nil,
            indentLevel: 0
        )
        let fixture = completionDescriptionFixture(
            blocks: [task, next],
            selection: completionDescriptionCaret(taskID, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 520, height: 240)
        let window = NSWindow(
            contentRect: fixture.host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        fixture.host.layoutSubtreeIfNeeded()

        let textViews = completionDescriptionDescendants(of: fixture.host, as: NSTextView.self)
            .filter(\.isEditable)
        #expect(textViews.count == 1)
        #expect(fixture.view.string == "给物业打电话\n下一件事")

        let label = try #require(completionDescriptionLabel(in: fixture.host, blockID: taskID))
        #expect(label.accessibilityRole() == .staticText)
        #expect(label.accessibilityLabel() == "完成说明")
        #expect(label.stringValue == "拿到明确时间")
        #expect(label.font?.pointSize == 12)
        #expect(label.isEditable == false)
        #expect(fixture.host.taskCompletionDescriptionOverlay.hitTest(.zero) == nil)

        let titleLine = try #require(completionDescriptionLineFragment(
            in: fixture.view,
            blockID: taskID,
            first: false
        ))
        let nextLine = try #require(completionDescriptionLineFragment(
            in: fixture.view,
            blockID: nextID,
            first: true
        ))
        #expect(label.frame.minY >= titleLine.maxY - 0.5)
        #expect(label.frame.maxY <= nextLine.minY + 0.5)
        #expect(abs(label.frame.minX - titleLine.minX) < 2)
        #expect(label.frame.maxX <= fixture.host.bounds.maxX + 0.5)
    }

    @Test @MainActor func emptyTitleStillShowsCompletionDescriptionWithoutCoveringNextBlock() throws {
        _ = NSApplication.shared
        let taskID = BlockID()
        let nextID = BlockID()
        let task = try DocumentBlock.task(
            id: taskID,
            text: "",
            completionDescription: "拿到明确上门时间"
        )
        let next = DocumentBlock(
            id: nextID,
            kind: .paragraph,
            inlineContent: .plain("正文"),
            taskState: nil,
            indentLevel: 0
        )
        let fixture = completionDescriptionFixture(
            blocks: [task, next],
            selection: completionDescriptionCaret(taskID, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 220)
        fixture.host.layoutSubtreeIfNeeded()

        let label = try #require(completionDescriptionLabel(in: fixture.host, blockID: taskID))
        #expect(label.stringValue == "拿到明确上门时间")
        #expect(fixture.view.string == "\n正文")
        let nextLine = try #require(completionDescriptionLineFragment(
            in: fixture.view,
            blockID: nextID,
            first: true
        ))
        #expect(label.frame.maxY <= nextLine.minY + 0.5)
    }

    @Test @MainActor func longChineseCompletionDescriptionGrowsAtNarrowWidthAndPushesNextBlock() throws {
        _ = NSApplication.shared
        let long = String(repeating: "确认物业上门时间并拿到书面答复", count: 3)
        let task = try DocumentBlock.task(text: "打电话", completionDescription: long)
        let next = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("下一块"),
            taskState: nil,
            indentLevel: 0
        )

        let narrow = completionDescriptionGeometry(blocks: [task, next], width: 360)
        let wide = completionDescriptionGeometry(blocks: [task, next], width: 720)

        #expect(narrow.labelHeight > wide.labelHeight + 1)
        #expect(narrow.nextBlockMinY > wide.nextBlockMinY + 1)
        #expect(narrow.labelMaxX <= 360 + 0.5)
        #expect(wide.labelMaxX <= 720 + 0.5)
    }

    @Test @MainActor func completionDescriptionFollowsThemeAndCompletedOpacityWithoutStrikethrough() throws {
        _ = NSApplication.shared
        let openID = BlockID()
        let doneID = BlockID()
        let open = try DocumentBlock.task(
            id: openID,
            text: "未完成",
            completionDescription: "浅色说明"
        )
        let done = try DocumentBlock.task(
            id: doneID,
            text: "已完成",
            completedAt: Date(timeIntervalSince1970: 1_755_000_200),
            completionDescription: "深色说明"
        )
        let fixture = completionDescriptionFixture(
            blocks: [open, done],
            selection: completionDescriptionCaret(openID, 0)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 520, height: 260)
        fixture.host.layoutSubtreeIfNeeded()

        let lightOpen = try #require(completionDescriptionLabel(in: fixture.host, blockID: openID))
        let lightDone = try #require(completionDescriptionLabel(in: fixture.host, blockID: doneID))
        let lightOpenColor = try #require(lightOpen.textColor)
        #expect(lightOpen.alphaValue == 1)
        #expect(lightDone.alphaValue < 1)
        #expect(lightDone.attributedStringValue.attribute(
            .strikethroughStyle,
            at: 0,
            effectiveRange: nil
        ) == nil)

        let doneLocation = (fixture.view.string as NSString).range(of: "已完成").location
        #expect(fixture.view.textStorage?.attribute(
            .strikethroughStyle,
            at: doneLocation,
            effectiveRange: nil
        ) != nil)
        let titleColor = try #require(fixture.view.textStorage?.attribute(
            .foregroundColor,
            at: doneLocation,
            effectiveRange: nil
        ) as? NSColor)
        #expect(titleColor.alphaComponent < 1)

        fixture.host.semanticAppearance = CalendarTheme.dark
        fixture.session.projectAuthoritativeState()
        fixture.host.layoutSubtreeIfNeeded()
        let darkOpen = try #require(completionDescriptionLabel(in: fixture.host, blockID: openID))
        let darkColor = try #require(darkOpen.textColor)
        #expect(lightOpenColor != darkColor)
    }

    @Test @MainActor func titleEditingSelectionIMEAndUndoStayOnTheTitleProjection() throws {
        _ = NSApplication.shared
        let task = try DocumentBlock.task(
            text: "给物业打电话",
            completionDescription: "拿到明确时间"
        )
        let fixture = completionDescriptionFixture(
            blocks: [task],
            selection: completionDescriptionCaret(task.id, "给物业打电话".count)
        )
        fixture.host.frame = .init(x: 0, y: 0, width: 480, height: 180)
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
        fixture.host.layoutSubtreeIfNeeded()

        fixture.view.insertText("！", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(fixture.view.string == "给物业打电话！")
        #expect(continuousCompletionText(fixture.session.document.blocks[0]) == "给物业打电话！")
        #expect(fixture.session.document.blocks[0].taskState?.completionDescription == "拿到明确时间")
        #expect(fixture.view.selectedRange == .init(
            location: ("给物业打电话！" as NSString).length,
            length: 0
        ))

        fixture.session.undoManager.undo()
        #expect(fixture.view.string == "给物业打电话")
        #expect(continuousCompletionText(fixture.session.document.blocks[0]) == "给物业打电话")

        fixture.view.setMarkedText(
            "pin",
            selectedRange: .init(location: 3, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        #expect(fixture.view.hasMarkedText())
        #expect(fixture.view.string.contains("拿到明确时间") == false)
        fixture.view.unmarkText()
    }
}

@MainActor
private func completionDescriptionFixture(
    blocks: [DocumentBlock],
    selection: BlockEditorSelection
) -> (session: BlockEditorSession, host: ContinuousBlockEditorHostView, view: ContinuousBlockEditorTextView) {
    let session = BlockEditorSession(
        noteID: NoteID(),
        editSessionID: UUID(),
        initialDocument: .init(blocks: blocks),
        initialSelection: selection,
        focusRegistry: EditorFocusRegistry(),
        onDocumentChange: { _ in }
    )
    let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
    session.attach(host: host, hostToken: UUID())
    return (session, host, host.textView)
}

private func completionDescriptionCaret(_ blockID: BlockID, _ offset: Int) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: blockID, graphemeOffset: offset),
        focus: .init(blockID: blockID, graphemeOffset: offset),
        preferredColumn: nil,
        typingAttributes: .init(marks: [], linkURL: nil)
    )
}

@MainActor
private func completionDescriptionDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { completionDescriptionDescendants(of: $0, as: type) }
}

@MainActor
private func completionDescriptionLabel(in host: NSView, blockID: BlockID) -> NSTextField? {
    completionDescriptionDescendants(of: host, as: NSTextField.self).first {
        $0.accessibilityIdentifier() == "task-block-completion-\(blockID.rawValue.uuidString)"
    }
}

@MainActor
private func completionDescriptionLineFragment(
    in textView: ContinuousBlockEditorTextView,
    blockID: BlockID,
    first: Bool
) -> NSRect? {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer,
          let storage = textView.textStorage else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    let origin = textView.textContainerOrigin
    let full = NSRange(location: 0, length: storage.length)
    var contentRange: NSRange?
    storage.enumerateAttribute(.jellyBlockID, in: full) { value, range, stop in
        if (value as? String) == blockID.rawValue.uuidString {
            contentRange = range
            stop.pointee = true
        }
    }
    guard let contentRange, contentRange.length > 0, layoutManager.numberOfGlyphs > 0 else {
        return textView.taskCheckboxFrame(for: blockID).map { checkbox in
            NSRect(
                x: origin.x + BlockTextStyle.textColumnOffset(for: .task),
                y: checkbox.minY,
                width: max(1, textView.bounds.width - BlockTextStyle.textColumnOffset(for: .task) - 10),
                height: checkbox.height
            )
        }
    }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: contentRange, actualCharacterRange: nil)
    var chosen: NSRect?
    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, stop in
        let converted = usedRect.offsetBy(dx: origin.x, dy: origin.y)
        if first {
            chosen = converted
            stop.pointee = true
        } else {
            chosen = converted
        }
    }
    return chosen
}

@MainActor
private func completionDescriptionGeometry(
    blocks: [DocumentBlock],
    width: CGFloat
) -> (labelHeight: CGFloat, nextBlockMinY: CGFloat, labelMaxX: CGFloat) {
    let fixture = completionDescriptionFixture(
        blocks: blocks,
        selection: completionDescriptionCaret(blocks[0].id, 0)
    )
    fixture.host.frame = .init(x: 0, y: 0, width: width, height: 400)
    fixture.host.layoutSubtreeIfNeeded()
    let label = completionDescriptionLabel(in: fixture.host, blockID: blocks[0].id)
    let nextLine = completionDescriptionLineFragment(
        in: fixture.view,
        blockID: blocks[1].id,
        first: true
    )
    return (
        labelHeight: label?.frame.height ?? 0,
        nextBlockMinY: nextLine?.minY ?? 0,
        labelMaxX: label?.frame.maxX ?? .greatestFiniteMagnitude
    )
}

private func continuousCompletionText(_ block: DocumentBlock) -> String {
    block.inlineContent.spans.map(\.text).joined()
}
