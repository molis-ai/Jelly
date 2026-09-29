import AppKit
import Foundation
import WorkspaceDomain

@MainActor
final class BlockEditorTextView: NSTextView, NSTextViewDelegate {
    private weak var editorSession: BlockEditorSession?
    private var blockID: BlockID?
    private var hostToken: UUID?
    private var applyingProjection = false
    private var executingComposingTextSystemCommand = false
    private var markedCandidate: String?
    private var markedCompositionToken: UInt?
    private var projectedKind: BlockKind = .paragraph
    private var projectedTaskCompleted = false
    private(set) var projectedAccessibilitySelected = false
    // NSTextContainer does not keep the legacy text system alive by itself.
    // The host must retain this chain for the lifetime of the native view.
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager
    private let ownedTextContainer: NSTextContainer

    convenience init() {
        self.init(frame: .zero)
    }

    convenience override init(frame frameRect: NSRect) {
        let textSystem = Self.makeTextSystem()
        self.init(frame: frameRect, textSystem: textSystem)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let textSystem = Self.makeTextSystem()
        ownedTextStorage = textSystem.storage
        ownedLayoutManager = textSystem.layoutManager
        ownedTextContainer = textSystem.container
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    private init(frame frameRect: NSRect, textSystem: TextSystem) {
        ownedTextStorage = textSystem.storage
        ownedLayoutManager = textSystem.layoutManager
        ownedTextContainer = textSystem.container
        super.init(frame: frameRect, textContainer: textSystem.container)
        configure()
    }

    required init?(coder: NSCoder) {
        let textSystem = Self.makeTextSystem()
        ownedTextStorage = textSystem.storage
        ownedLayoutManager = textSystem.layoutManager
        ownedTextContainer = textSystem.container
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = true
        allowsUndo = false // The session has the one authoritative UndoManager.
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainer?.containerSize = .init(
            width: bounds.width,
            height: .greatestFiniteMagnitude
        )
        textContainer?.widthTracksTextView = true
        textContainerInset = .init(width: 0, height: 4)
        setAccessibilityRole(.textArea)
        setAccessibilityPlaceholderValue("开始写点什么…")
        delegate = self
    }

    private struct TextSystem {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    private static func makeTextSystem() -> TextSystem {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(container)
        return .init(storage: storage, layoutManager: layoutManager, container: container)
    }

    func install(session: BlockEditorSession, blockID: BlockID, hostToken: UUID) {
        editorSession = session
        self.blockID = blockID
        self.hostToken = hostToken
        setAccessibilityIdentifier(blockID.rawValue.uuidString)
    }

    func applyAuthoritativeProjection(text: String, selectedRange: NSRange, isSelected: Bool = false) {
        projectedKind = .paragraph
        projectedTaskCompleted = false
        applyAuthoritativeProjection(
            attributedString: NSAttributedString(string: text),
            selectedRange: selectedRange,
            isSelected: isSelected,
            accessibilityRole: .textArea
        )
    }

    func applyAuthoritativeProjection(block: DocumentBlock, selectedRange: NSRange, isSelected: Bool = false) {
        projectedKind = block.kind
        projectedTaskCompleted = block.taskState?.completedAt != nil
        let attributed = BlockTextStyle.attributedString(for: block, appearance: nil)
        applyAuthoritativeProjection(
            attributedString: attributed,
            selectedRange: selectedRange,
            isSelected: isSelected,
            accessibilityRole: block.kind == .divider ? .splitter : .textArea
        )
    }

    private func applyAuthoritativeProjection(
        attributedString: NSAttributedString,
        selectedRange: NSRange,
        isSelected: Bool,
        accessibilityRole: NSAccessibility.Role
    ) {
        guard !applyingProjection else { return }
        applyingProjection = true
        defer { applyingProjection = false }
        textStorage?.setAttributedString(attributedString)
        setAccessibilityRole(accessibilityRole)
        setAccessibilityValue(attributedString.string)
        setAccessibilitySelected(isSelected)
        projectedAccessibilitySelected = isSelected
        isEditable = projectedKind != .divider
        needsDisplay = true
        let length = attributedString.length
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.location <= length,
              selectedRange.length >= 0,
              selectedRange.location <= length - selectedRange.length else { return }
        self.selectedRange = selectedRange
        // AppKit reapplies the insertion-point typing font to the backing store
        // when a rich text view receives a programmatic selection. Restore the
        // authoritative attributes without replacing the string (which would
        // itself collapse the just-projected selection to the document end).
        if let textStorage, attributedString.length > 0 {
            textStorage.beginEditing()
            textStorage.setAttributes([:], range: .init(location: 0, length: attributedString.length))
            attributedString.enumerateAttributes(
                in: .init(location: 0, length: attributedString.length),
                options: []
            ) { attributes, range, _ in
                textStorage.setAttributes(attributes, range: range)
            }
            textStorage.endEditing()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = NSColor.secondaryLabelColor
        if string.isEmpty, projectedKind != .divider {
            ("开始写点什么…" as NSString).draw(
                at: .init(x: textContainerOrigin.x, y: textContainerOrigin.y),
                withAttributes: [
                    .font: BlockTextStyle.baseFont(for: projectedKind),
                    .foregroundColor: color.withAlphaComponent(0.72)
                ]
            )
        }
        switch projectedKind {
        case .bullet:
            ("•" as NSString).draw(at: .init(x: 1, y: textContainerOrigin.y), withAttributes: [.foregroundColor: color])
        case .ordered:
            ("1." as NSString).draw(at: .init(x: 0, y: textContainerOrigin.y), withAttributes: [.foregroundColor: color])
        case .task:
            let marker = projectedTaskCompleted ? "☑" : "☐"
            (marker as NSString).draw(at: .init(x: 0, y: textContainerOrigin.y), withAttributes: [.foregroundColor: color])
        case .quote:
            color.setFill()
            NSBezierPath(rect: .init(x: 1, y: 2, width: 2, height: max(0, bounds.height - 4))).fill()
        case .divider:
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: .init(x: 0, y: bounds.midY))
            path.line(to: .init(x: bounds.maxX, y: bounds.midY))
            path.stroke()
        case .paragraph, .heading1, .heading2, .heading3, .code, .link:
            break
        }
    }

    var attachedSession: BlockEditorSession? { editorSession }
    var representedBlockID: BlockID? { blockID }

    /// This is the host-side pointer seam used by both AppKit mouse events and
    /// the hosted production harness. It always bridges native UTF-16 first.
    @discardableResult
    func beginPointerSelection(atUTF16Offset utf16Offset: Int, extendingWithShift: Bool = false) -> Bool {
        guard let position = bridgedPosition(utf16Offset: utf16Offset), let hostToken else { return false }
        if extendingWithShift {
            return editorSession?.extendSelectionWithShift(to: position, hostToken: hostToken) ?? false
        }
        return editorSession?.beginPointerSelection(at: position, hostToken: hostToken) ?? false
    }

    @discardableResult
    func extendPointerSelection(toUTF16Offset utf16Offset: Int) -> Bool {
        guard let position = bridgedPosition(utf16Offset: utf16Offset), let hostToken else { return false }
        return editorSession?.extendPointerSelection(to: position, hostToken: hostToken) ?? false
    }

    @discardableResult
    func extendSelectionWithShift(toUTF16Offset utf16Offset: Int) -> Bool {
        beginPointerSelection(atUTF16Offset: utf16Offset, extendingWithShift: true)
    }

    override func mouseDown(with event: NSEvent) {
        if !applyingProjection, let offset = utf16Offset(at: convert(event.locationInWindow, from: nil)) {
            let handled = beginPointerSelection(
                atUTF16Offset: offset,
                extendingWithShift: event.modifierFlags.contains(.shift)
            )
            if handled {
                // Our projection has already placed the native caret/range. Letting
                // NSTextView run its own tracker now would report a one-host range
                // through the delegate and erase a cross-host selection.
                window?.makeFirstResponder(self)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !applyingProjection,
           editorSession?.extendPointerSelection(atWindowPoint: event.locationInWindow, in: window) == true {
            return
        }
        super.mouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        beginNativeInputEvent()
        super.keyDown(with: event)
    }

    /// AppKit calls `keyDown` before a new ordinary input event. Keeping this
    /// seam explicit lets hosted event tests distinguish that event from a late
    /// duplicate terminal callback emitted by the same IME composition.
    func beginNativeInputEvent() {
        if let hostToken { editorSession?.beginNativeInputEvent(hostToken: hostToken) }
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder, let hostToken { editorSession?.focus(hostToken: hostToken) }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let hostToken { editorSession?.blur(hostToken: hostToken) }
        return resigned
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProjection, let blockID, let hostToken else { return }
        editorSession?.updateNativeSelection(blockID: blockID, range: selectedRange, hostToken: hostToken)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !applyingProjection, let editorSession, let blockID, let hostToken else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        markedCompositionToken = editorSession.beginComposition(
            blockID: blockID, replacementRange: replacementRange, hostToken: hostToken
        )
        guard markedCompositionToken != nil else {
            editorSession.projectAuthoritativeState()
            return
        }
        markedCandidate = Self.string(from: string)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if executingComposingTextSystemCommand {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard !applyingProjection, let value = Self.string(from: insertString) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard let editorSession, let blockID, let hostToken else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        _ = editorSession.dispatchInsertText(value, blockID: blockID, replacementRange: replacementRange, hostToken: hostToken)
        editorSession.projectAuthoritativeState()
        if editorSession.isComposing == false {
            markedCandidate = nil
            markedCompositionToken = nil
        }
    }

    override func unmarkText() {
        if executingComposingTextSystemCommand {
            super.unmarkText()
            return
        }
        if let hostToken, editorSession?.isComposing == true {
            let value = markedCandidate ?? ""
            markedCandidate = nil
            markedCompositionToken = nil
            editorSession?.commitComposition(value, hostToken: hostToken)
            return
        }
        super.unmarkText()
    }

    override func cancelOperation(_ sender: Any?) {
        if let hostToken, editorSession?.isComposing == true {
            let terminalValue = markedCandidate
            markedCandidate = nil
            markedCompositionToken = nil
            editorSession?.cancelComposition(hostToken: hostToken, terminalValue: terminalValue)
            return
        }
        if editorSession?.handleNoteLinkSelector(#selector(NSResponder.cancelOperation(_:))) == true { return }
        if editorSession?.handleSlashSelector(#selector(NSResponder.cancelOperation(_:))) == true { return }
        super.cancelOperation(sender)
    }

    override func doCommand(by selector: Selector) {
        // IME owns every structural key while a candidate is marked.
        if editorSession?.isComposing == true {
            // Keep the native marked-text buffer live for candidate navigation and
            // editing. The session ignores its delegate callbacks until the terminal
            // insert/unmark/cancel restores one authoritative projection.
            executingComposingTextSystemCommand = true
            defer { executingComposingTextSystemCommand = false }
            super.doCommand(by: selector)
            return
        }
        if editorSession?.handleNoteLinkSelector(selector) == true { return }
        if editorSession?.handleSlashSelector(selector) == true { return }
        if let command = Self.command(for: selector), let editorSession {
            if let outcome = editorSession.dispatchTextCommandOutcome(command) {
                if outcome.commandHandled { return }
                super.doCommand(by: selector)
                return
            }
            editorSession.projectAuthoritativeState()
            return
        }
        if editorSession != nil {
            editorSession?.projectAuthoritativeState()
            return
        }
        super.doCommand(by: selector)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard editorSession == nil else {
            editorSession?.projectAuthoritativeState()
            return false
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func copy(_ sender: Any?) {
        if editorSession?.copy() == true { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if let editorSession {
            _ = editorSession.cut()
            editorSession.projectAuthoritativeState()
            return
        }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        if let editorSession {
            _ = editorSession.paste()
            editorSession.projectAuthoritativeState()
            return
        }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard editorSession?.isComposing != true,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let character = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch character {
        case "b":
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.bold))
            editorSession?.projectAuthoritativeState()
            return true
        case "i":
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.italic))
            editorSession?.projectAuthoritativeState()
            return true
        case "c" where event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift):
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.code))
            editorSession?.projectAuthoritativeState()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private static func command(for selector: Selector) -> BlockInputCommand? {
        switch selector.description {
        case "insertNewline:": .enter
        case "insertLineBreak:": .softBreak
        case "deleteBackward:": .backspace
        case "insertTab:": .indent
        case "insertBacktab:": .outdent
        case "moveLeft:": .moveHorizontal(.backward, extending: false)
        case "moveRight:": .moveHorizontal(.forward, extending: false)
        case "moveUp:": .moveVertical(.up, extending: false)
        case "moveDown:": .moveVertical(.down, extending: false)
        case "moveLeftAndModifySelection:": .moveHorizontal(.backward, extending: true)
        case "moveRightAndModifySelection:": .moveHorizontal(.forward, extending: true)
        case "moveUpAndModifySelection:": .moveVertical(.up, extending: true)
        case "moveDownAndModifySelection:": .moveVertical(.down, extending: true)
        default: nil
        }
    }

    private static func string(from value: Any) -> String? {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    func utf16Offset(at point: NSPoint) -> Int? {
        guard !string.isEmpty else { return 0 }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = ownedLayoutManager.glyphIndex(for: containerPoint, in: ownedTextContainer)
        let character = ownedLayoutManager.characterIndexForGlyph(at: glyph)
        return min(max(character, 0), string.utf16.count)
    }

    func windowPoint(forUTF16Offset utf16Offset: Int) -> NSPoint? {
        guard utf16Offset >= 0, utf16Offset < string.utf16.count else { return nil }
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        let glyph = ownedLayoutManager.glyphIndexForCharacter(at: utf16Offset)
        let rect = ownedLayoutManager.boundingRect(forGlyphRange: .init(location: glyph, length: 1), in: ownedTextContainer)
        guard !rect.isEmpty else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: origin.x + rect.midX, y: origin.y + rect.midY)
        return convert(local, to: nil)
    }

    private func bridgedPosition(utf16Offset: Int) -> BlockTextPosition? {
        guard let editorSession, let blockID else { return nil }
        return try? BlockSelectionBridge.graphemePosition(
            blockID: blockID, utf16Offset: utf16Offset, document: editorSession.document
        )
    }
}
